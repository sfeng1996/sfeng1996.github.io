---
weight: 54
title: "controller-runtime 源码解析(二)"
date: 2023-08-21T01:57:40+08:00
lastmod: 2023-08-21T01:57:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "k8s-dev.jpg"

tags: ["Kubernetes-Dev"]
categories: ["Kubernetes-Dev"]

lightgallery: true
---

## 简介

上一篇介绍了 controller-runtime 是如何封装一个 controller 并启动该 controller。但是在很多时候一个 operator 往往会存在多个 controller 以及 webhook，所以 controller-runtime 实现了管理这些 controller 和 webhook。

## Manager 的使用

controller-runtime 定义了 Manager 这个结构体，使用步骤如下：

- 初始化 Manager
- 向 Manager 注册 controller，webhook
- 启动 Manager

```go
// sigs.k8s.io/controller-runtime/pkg/manager/manager.go:309
// 初始化 Manager
func New(config *rest.Config, options Options) (Manager, error) {}

// 注册 Controller 到 Manager
// For：监控的资源，相当于调用 Watches(&source.Kind{Type: apiType},&handler.EnqueueRequestForObject{})
// Owns：拥有的下属资源，如果 corev1.Pod{} 资源属于 api.ChaosPod{}，也将会被监控，相当于调用 Watches(&source.Kind{Type: <ForType-apiType>}, &handler.EnqueueRequestForOwner{OwnerType: apiType, IsController: true})
// reconciler 结构体：继承 Reconciler，需要实现该结构体和 Reconcile 方法
// mgr.GetClient()、mgr.GetScheme() 是 Client 和 Scheme，前面的 manager.New 初始化了
err = builder.ControllerManagedBy(mgr).
		For(&api.ChaosPod{}).
		Owns(&corev1.Pod{}).
		Complete(&reconciler{
			Client: mgr.GetClient(),
			scheme: mgr.GetScheme(),
		})

// 构建webhook
err = builder.WebhookManagedBy(mgr).For(&api.ChaosPod{}).Complete()
// 启动manager,实际上是启动controller
mgr.Start(ctrl.SetupSignalHandler())
```

下面单独看看每个步骤的细节

### 初始化Manager

```go
// sigs.k8s.io/controller-runtime/pkg/manager/manager.go:309
func New(config *rest.Config, options Options) (Manager, error) {
	// 这是默认参数
	options = setOptionsDefaults(options)

	cluster, err := cluster.New(config, func(clusterOptions *cluster.Options) {
		clusterOptions.Scheme = options.Scheme
		clusterOptions.MapperProvider = options.MapperProvider
		clusterOptions.Logger = options.Logger
		clusterOptions.SyncPeriod = options.SyncPeriod
		clusterOptions.Namespace = options.Namespace
		clusterOptions.NewCache = options.NewCache
		clusterOptions.NewClient = options.NewClient
		clusterOptions.ClientDisableCacheFor = options.ClientDisableCacheFor
		clusterOptions.DryRunClient = options.DryRunClient
		clusterOptions.EventBroadcaster = options.EventBroadcaster //nolint:staticcheck
	})
	if err != nil {
		return nil, err
	}

	// Create the recorder provider to inject event recorders for the components.
	// TODO(directxman12): the log for the event provider should have a context (name, tags, etc) specific
	// to the particular controller that it's being injected into, rather than a generic one like is here.
	recorderProvider, err := options.newRecorderProvider(config, cluster.GetScheme(), options.Logger.WithName("events"), options.makeBroadcaster)
	if err != nil {
		return nil, err
	}

	// Create the resource lock to enable leader election)
	leaderConfig := options.LeaderElectionConfig
	if leaderConfig == nil {
		leaderConfig = rest.CopyConfig(config)
	}
	resourceLock, err := options.newResourceLock(leaderConfig, recorderProvider, leaderelection.Options{
		LeaderElection:             options.LeaderElection,
		LeaderElectionResourceLock: options.LeaderElectionResourceLock,
		LeaderElectionID:           options.LeaderElectionID,
		LeaderElectionNamespace:    options.LeaderElectionNamespace,
	})
	if err != nil {
		return nil, err
	}

	// Create the metrics listener. This will throw an error if the metrics bind
	// address is invalid or already in use.
	metricsListener, err := options.newMetricsListener(options.MetricsBindAddress)
	if err != nil {
		return nil, err
	}

	// By default we have no extra endpoints to expose on metrics http server.
	metricsExtraHandlers := make(map[string]http.Handler)

	// Create health probes listener. This will throw an error if the bind
	// address is invalid or already in use.
	healthProbeListener, err := options.newHealthProbeListener(options.HealthProbeBindAddress)
	if err != nil {
		return nil, err
	}

	errChan := make(chan error)
	runnables := newRunnables(errChan)

	// 最终初始化 controllerManager 
	return &controllerManager{
		stopProcedureEngaged:          pointer.Int64(0),
		cluster:                       cluster,
		runnables:                     runnables,
		errChan:                       errChan,
		recorderProvider:              recorderProvider,
		resourceLock:                  resourceLock,
		metricsListener:               metricsListener,
		metricsExtraHandlers:          metricsExtraHandlers,
		controllerOptions:             options.Controller,
		logger:                        options.Logger,
		elected:                       make(chan struct{}),
		port:                          options.Port,
		host:                          options.Host,
		certDir:                       options.CertDir,
		webhookServer:                 options.WebhookServer,
		leaseDuration:                 *options.LeaseDuration,
		renewDeadline:                 *options.RenewDeadline,
		retryPeriod:                   *options.RetryPeriod,
		healthProbeListener:           healthProbeListener,
		readinessEndpointName:         options.ReadinessEndpointName,
		livenessEndpointName:          options.LivenessEndpointName,
		gracefulShutdownTimeout:       *options.GracefulShutdownTimeout,
		internalProceduresStop:        make(chan struct{}),
		leaderElectionStopped:         make(chan struct{}),
		leaderElectionReleaseOnCancel: options.LeaderElectionReleaseOnCancel,
	}, nil
}
```

### 注册 controller

```go
err = builder.ControllerManagedBy(mgr).
		For(&api.ChaosPod{}).
		Owns(&corev1.Pod{}).
		Complete(&reconciler{
			Client: mgr.GetClient(),
			scheme: mgr.GetScheme(),
		})
```

`builder.ControllerManagedBy` 函数返回一个新的控制器构造器 Builder 对象，生成的控制器将由所提供的管理器 Manager 启动，函数实现很简单：

```go
// pkg/builder/controller.go

// 控制器构造器
type Builder struct {
	forInput         ForInput
	ownsInput        []OwnsInput
	watchesInput     []WatchesInput
	mgr              manager.Manager
	globalPredicates []predicate.Predicate
	config           *rest.Config
	ctrl             controller.Controller
	ctrlOptions      controller.Options
	log              logr.Logger
	name             string
}

// ControllerManagedBy 返回一个新的控制器构造器
// 它将由提供的 Manager 启动
func ControllerManagedBy(m manager.Manager) *Builder {
	return &Builder{mgr: m}
}
```

可以看到 controller-runtime 封装了一个 Builder 的结构体用来生成 Controller，将 Manager 传递给这个构造器，然后是调用构造器的 `For` 函数：

```go
// pkg/builder/controller.go

// ForInput 表示 For 方法设置的信息
type ForInput struct {
	object     runtime.Object
	predicates []predicate.Predicate
}

// For 函数定义了被调谐的对象类型
// 并配置 ControllerManagedBy 通过调谐对象来响应 create/delete/update 事件
// 调用 For 函数相当于调用：
// Watches(&source.Kind{Type: apiType}, &handler.EnqueueRequestForObject{})
func (blder *Builder) For(object runtime.Object, opts ...ForOption) *Builder {
	input := ForInput{object: object}
	for _, opt := range opts {
		opt.ApplyToFor(&input)
	}
	// 最终 controller 的 watch 函数会 watch 该资源
	blder.forInput = input
	return blder
}
```

`For` 函数就是用来定义我们要处理的对象类型的，接着调用了 `Owns` 函数：

```go
// pkg/builder/controller.go

// OwnsInput 表示 Owns 方法设置的信息
type OwnsInput struct {
	object     runtime.Object
	predicates []predicate.Predicate
}

// Owns 定义了 ControllerManagedBy 生成的对象类型
// 并配置 ControllerManagedBy 通过调谐所有者对象来响应 create/delete/update 事件
// 这相当于调用：
// Watches(&source.Kind{Type: <ForType-forInput>}, &handler.EnqueueRequestForOwner{OwnerType: apiType, IsController: true})
func (blder *Builder) Owns(object runtime.Object, opts ...OwnsOption) *Builder {
	input := OwnsInput{object: object}
	for _, opt := range opts {
		opt.ApplyToOwns(&input)
	}

	blder.ownsInput = append(blder.ownsInput, input)
	return blder
}
```

`Owns` 函数就是来配置我们监听的资源对象的子资源，如果想要协调资源则需要调用 `Owns` 函数进行配置，然后就是最重要的 `Complete` 函数了：

```go
// pkg/builder/controller.go

func (blder *Builder) Complete(r reconcile.Reconciler) error {
  // 调用 Build 函数构建 Controller
	_, err := blder.Build(r)
	return err
}

// Build 构建应用程序 ControllerManagedBy 并返回它创建的 Controller
func (blder *Builder) Build(r reconcile.Reconciler) (controller.Controller, error) {
	if r == nil {
		return nil, fmt.Errorf("must provide a non-nil Reconciler")
	}
	if blder.mgr == nil {
		return nil, fmt.Errorf("must provide a non-nil Manager")
	}

	// 配置 Rest Config
	blder.loadRestConfig()

	// 配置 ControllerManagedBy
	if err := blder.doController(r); err != nil {
		return nil, err
	}

	// 配置 Watch
	if err := blder.doWatch(); err != nil {
		return nil, err
	}

	return blder.ctrl, nil
}
```

`Complete` 函数通过调用 Build 函数来构建 Controller，其中比较重要的就是 `doController` 和 `doWatch` 两个函数，`doController` 就是去真正*实例*化 Controller 的函数：

```go
// pkg/builder/controller.go

// 根据 GVK 获取控制器名称
func (blder *Builder) getControllerName(gvk schema.GroupVersionKind) string {
	if blder.name != "" {
		return blder.name
	}
	return strings.ToLower(gvk.Kind)
}

func (blder *Builder) doController(r reconcile.Reconciler) error {
	ctrlOptions := blder.ctrlOptions
	if ctrlOptions.Reconciler == nil {
		ctrlOptions.Reconciler = r
	}

	// 从我们正在调谐的对象中检索 GVK
	gvk, err := getGvk(blder.forInput.object, blder.mgr.GetScheme())
	if err != nil {
		return err
	}

	// 配置日志 Logger
	if ctrlOptions.Log == nil {
		ctrlOptions.Log = blder.mgr.GetLogger()
	}
	ctrlOptions.Log = ctrlOptions.Log.WithValues("reconcilerGroup", gvk.Group, "reconcilerKind", gvk.Kind)

	// 构造 Controller 
  // var newController = controller.New
	blder.ctrl, err = newController(blder.getControllerName(gvk), blder.mgr, ctrlOptions)
	return err
}
```

上面的函数通过获取资源对象的 GVK 来获取 Controller 的名称，最后通过一个 newController 函数（controller.New 的别名）来实例化一个真正的 Controller：

```go
// pkg/controller/controller.go

// New 返回一个 Manager 处注册的 Controller
// Manager 将确保共享缓存在控制器启动前已经同步
func New(name string, mgr manager.Manager, options Options) (Controller, error) {
	c, err := NewUnmanaged(name, mgr, options)
	if err != nil {
		return nil, err
	}

	// 将 controller 作为 manager 的组件
	return c, mgr.Add(c)
}

// NewUnmanaged 返回一个新的控制器，而不将其添加到 manager 中
// 调用者负责启动返回的控制器
func NewUnmanaged(name string, mgr manager.Manager, options Options) (Controller, error) {
	if options.Reconciler == nil {
		return nil, fmt.Errorf("must specify Reconciler")
	}

	if len(name) == 0 {
		return nil, fmt.Errorf("must specify Name for Controller")
	}

	if options.MaxConcurrentReconciles <= 0 {
		options.MaxConcurrentReconciles = 1
	}

	if options.RateLimiter == nil {
		options.RateLimiter = workqueue.DefaultControllerRateLimiter()
	}

	if options.Log == nil {
		options.Log = mgr.GetLogger()
	}

	// 在 Reconciler 中注入依赖关系
	if err := mgr.SetFields(options.Reconciler); err != nil {
		return nil, err
	}

	// 创建 Controller 并配置依赖关系
	return &controller.Controller{
		Do: options.Reconciler,
		MakeQueue: func() workqueue.RateLimitingInterface {
			return workqueue.NewNamedRateLimitingQueue(options.RateLimiter, name)
		},
		MaxConcurrentReconciles: options.MaxConcurrentReconciles,
		SetFields:               mgr.SetFields,
		Name:                    name,
		Log:                     options.Log.WithName("controller").WithValues("controller", name),
	}, nil
}
```

可以看到 `NewUnmanaged` 函数才是真正实例化 Controller 的地方，终于和前文的 Controller 联系起来来，Controller 实例化完成后，又通过 `mgr.Add(c)` 函数将控制器添加到 Manager 中去进行管理，所以我们还需要去查看下 Manager 的 Add 函数的实现，当然是看 controllerManager 中的具体实现：

```go
// pkg/manager/manager.go

// Runnable 允许一个组件被启动
type Runnable interface {
	Start(<-chan struct{}) error
}

// pkg/manager/internal.go

// Add 设置i的依赖，并将其他添加到 Runnables 列表中启动
func (cm *controllerManager) Add(r Runnable) error {
	cm.mu.Lock()
	defer cm.mu.Unlock()
	if cm.stopProcedureEngaged {
		return errors.New("can't accept new runnable as stop procedure is already engaged")
	}

	// 设置对象的依赖
	if err := cm.SetFields(r); err != nil {
		return err
	}

	var shouldStart bool

	// 添加 runnable 到 leader election 或者非 leaderelection 列表
	if leRunnable, ok := r.(LeaderElectionRunnable); ok && !leRunnable.NeedLeaderElection() {
		shouldStart = cm.started
		cm.nonLeaderElectionRunnables = append(cm.nonLeaderElectionRunnables, r)
	} else {
		shouldStart = cm.startedLeader
		cm.leaderElectionRunnables = append(cm.leaderElectionRunnables, r)
	}

	if shouldStart {
		// 如果已经启动，启动控制器
		cm.startRunnable(r)
	}

	return nil
}

func (cm *controllerManager) startRunnable(r Runnable) {
	cm.waitForRunnable.Add(1)
	go func() {
		defer cm.waitForRunnable.Done()
		if err := r.Start(cm.internalStop); err != nil {
			cm.errChan <- err
		}
	}()
}
```

controllerManager 的 Add 函数传递的是一个 Runnable 参数，Runnable 是一个接口，用来表示可以启动的一个组件，而恰好 Controller 实际上就实现了这个接口的 Start 函数，所以可以通过 Add 函数来添加 Controller 实例，在 Add 函数中除了依赖注入之外，还根据 Runnable 来判断组件是否支持选举功能，支持则将组件加入到 `leaderElectionRunnables` 列表中，否则加入到 `nonLeaderElectionRunnables` 列表中，这点非常重要，涉及到后面控制器的启动方式。

### 启动Manager

上面逻辑将 controller 通过 Add 函数注册到 Manager 中，接下来启动 Manager 就是一个 controller 通过一个 goroutine 来启动

上面初始化的 controllerManager 实现了 Start 函数

```go
// sigs.k8s.io/controller-runtime/pkg/manager/internal.go:399
func (cm *controllerManager) Start(ctx context.Context) (err error) {
	cm.Lock()
	if cm.started {
		cm.Unlock()
		return errors.New("manager already started")
	}
	var ready bool
	defer func() {
		// Only unlock the manager if we haven't reached
		// the internal readiness condition.
		if !ready {
			cm.Unlock()
		}
	}()

	// Initialize the internal context.
	cm.internalCtx, cm.internalCancel = context.WithCancel(ctx)

	// This chan indicates that stop is complete, in other words all runnables have returned or timeout on stop request
	stopComplete := make(chan struct{})
	defer close(stopComplete)
	// This must be deferred after closing stopComplete, otherwise we deadlock.
	defer func() {
		// https://hips.hearstapps.com/hmg-prod.s3.amazonaws.com/images/gettyimages-459889618-1533579787.jpg
		stopErr := cm.engageStopProcedure(stopComplete)
		if stopErr != nil {
			if err != nil {
				// Utilerrors.Aggregate allows to use errors.Is for all contained errors
				// whereas fmt.Errorf allows wrapping at most one error which means the
				// other one can not be found anymore.
				err = kerrors.NewAggregate([]error{err, stopErr})
			} else {
				err = stopErr
			}
		}
	}()

	// 这个 cm.cluster 里的 cache 实现了 Start，用于启动 informer
	if err := cm.add(cm.cluster); err != nil {
		return fmt.Errorf("failed to add cluster to runnables: %w", err)
	}

	// Metrics should be served whether the controller is leader or not.
	// (If we don't serve metrics for non-leaders, prometheus will still scrape
	// the pod but will get a connection refused).
	if cm.metricsListener != nil {
		cm.serveMetrics()
	}

	// Serve health probes.
	if cm.healthProbeListener != nil {
		cm.serveHealthProbes()
	}

	//启动 webhook
	if err := cm.runnables.Webhooks.Start(cm.internalCtx); err != nil {
		if err != wait.ErrWaitTimeout {
			return err
		}
	}

	// 等待 cache 完成
	if err := cm.runnables.Caches.Start(cm.internalCtx); err != nil {
		if err != wait.ErrWaitTimeout {
			return err
		}
	}

	// 启动不带 leaderelection 的controller
	if err := cm.runnables.Others.Start(cm.internalCtx); err != nil {
		if err != wait.ErrWaitTimeout {
			return err
		}
	}

	// 启动带 leaderelection 的controller
	{
		ctx, cancel := context.WithCancel(context.Background())
		cm.leaderElectionCancel = cancel
		go func() {
			if cm.resourceLock != nil {
				if err := cm.startLeaderElection(ctx); err != nil {
					cm.errChan <- err
				}
			} else {
				// Treat not having leader election enabled the same as being elected.
				if err := cm.startLeaderElectionRunnables(); err != nil {
					cm.errChan <- err
				}
				close(cm.elected)
			}
		}()
	}

	ready = true
	cm.Unlock()
	select {
	case <-ctx.Done():
		// We are done
		return nil
	case err := <-cm.errChan:
		// Error starting or running a runnable
		return err
	}
}
```

上面 start 函数有一步比较难理解，cm.add(cm.cluster)，add 需要传入一个 runable 接口类型参数，cm.cluster 实现了 runable 接口的 Start()

```go
// sigs.k8s.io/controller-runtime/pkg/cluster/internal.go:125
func (c *cluster) Start(ctx context.Context) error {
	defer c.recorderProvider.Stop(ctx)
	return c.cache.Start(ctx)
}

```

可以看到 实际上是 cluster.cache 最终调用了 Start()，该 Start() 是 informer 接口的一个方法，所以需要看看这个 cache 是如何初始化的，这样就知道该 Start() 的作用

```go
// sigs.k8s.io/controller-runtime/pkg/cache/cache.go:136
func New(config *rest.Config, opts Options) (Cache, error) {
	opts, err := defaultOpts(config, opts)
	if err != nil {
		return nil, err
	}
	selectorsByGVK, err := convertToSelectorsByGVK(opts.SelectorsByObject, opts.DefaultSelector, opts.Scheme)
	if err != nil {
		return nil, err
	}
	disableDeepCopyByGVK, err := convertToDisableDeepCopyByGVK(opts.UnsafeDisableDeepCopyByObject, opts.Scheme)
	if err != nil {
		return nil, err
	}
	im := internal.NewInformersMap(config, opts.Scheme, opts.Mapper, *opts.Resync, opts.Namespace, selectorsByGVK, disableDeepCopyByGVK)
	return &informerCache{InformersMap: im}, nil
}

func NewInformersMap(config *rest.Config,
	scheme *runtime.Scheme,
	mapper meta.RESTMapper,
	resync time.Duration,
	namespace string,
	selectors SelectorsByGVK,
	disableDeepCopy DisableDeepCopyByGVK,
) *InformersMap {
	return &InformersMap{
		structured:   newStructuredInformersMap(config, scheme, mapper, resync, namespace, selectors, disableDeepCopy),
		unstructured: newUnstructuredInformersMap(config, scheme, mapper, resync, namespace, selectors, disableDeepCopy),
		metadata:     newMetadataInformersMap(config, scheme, mapper, resync, namespace, selectors, disableDeepCopy),

		Scheme: scheme,
	}
}

// 启动 informer
func (m *InformersMap) Start(ctx context.Context) error {
	go m.structured.Start(ctx)
	go m.unstructured.Start(ctx)
	go m.metadata.Start(ctx)
	<-ctx.Done()
	return nil
}
```

这样就解答了上篇文章里不知道 informer 如何启动的疑问，controller-runtime 将 informer 当作 controller 注册到 manager 中，最终在 manager 启动时启动 informer。informer 具体实现可以看这篇文章。

manager 启动还有一步比较关键，就是 controller 之间的选举，这篇文章不做具体分析，可以看看这篇

下面再具体看看每一个 controller 是如何启动的 cm.startLeaderElectionRunnables()

```go
// sigs.k8s.io/controller-runtime/pkg/manager/runnable_group.go:177
func (r *runnableGroup) reconcile() {
	// 从 runable channel 里获取 controller
	for runnable := range r.ch {
		// Handle stop.
		// If the shutdown has been called we want to avoid
		// adding new goroutines to the WaitGroup because Wait()
		// panics if Add() is called after it.
		{
			r.stop.RLock()
			if r.stopped {
				// Drop any runnables if we're stopped.
				r.errChan <- errRunnableGroupStopped
				r.stop.RUnlock()
				continue
			}

			// Why is this here?
			// When StopAndWait is called, if a runnable is in the process
			// of being added, we could end up in a situation where
			// the WaitGroup is incremented while StopAndWait has called Wait(),
			// which would result in a panic.
			r.wg.Add(1)
			r.stop.RUnlock()
		}

		// 启动每个 runnable
		go func(rn *readyRunnable) {
			go func() {
				if rn.Check(r.ctx) {
					if rn.signalReady {
						r.startReadyCh <- rn
					}
				}
			}()

			// If we return, the runnable ended cleanly
			// or returned an error to the channel.
			//
			// We should always decrement the WaitGroup here.
			defer r.wg.Done()

			// Start the runnable.
			if err := rn.Start(r.ctx); err != nil {
				r.errChan <- err
			}
		}(runnable)
	}
}
```

具体启动实现得看 runnable 是如何实现的，比如 controller，webhook，还有上面所说的 informer

结合上一篇文章，基本上 controller-runtime 的实现就基本摸清楚了，要想更轻松的开发 operator，弄懂 controller-runtime 实现原理还是非常有必要的。