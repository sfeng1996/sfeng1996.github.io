---
weight: 53
title: "controller-runtime 源码解析(一)"
date: 2023-08-20T01:57:40+08:00
lastmod: 2023-08-20T01:57:40+08:00
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

controller-runtime(https://github.com/kubernetes-sigs/controller-runtime) 框架实际上是kubernetes 特殊兴趣社区帮我们封装的一个控制器处理的框架，其底层也是利用 client-go 里面的一些组件和原理(reflector、deltafifo、indexer、informer)。利用 controller-runtime 我们不用关系底层 client-go 原理就可以非常方便和高效开发一些自定义资源的控制器。kuberbuild、operator-sdk 也是利用 controller-runtime 帮助开发者生成控制器脚手架。

Controller-runtime 包括两大功能：

一、提供封装好的控制器框架，开发者无需关系底层 client-go 原理即可开发 operator

二、operator 可能会包含多个 controller 或者会包含 webhook，controller-runtime 可以提供管理这个 controller、webhook 的功能。

接下来从源码视角分析 controller-runtime 第一大功能。

## 如何封装控制器

我们知道在不使用 controller-runtime 开发 operator 的前提下，开发者就需要自己去实现一个控制器，大概原理是通过初始化一个 sharedInformer ，初始化 sharedInformer 会传入 indexer，然后注册一个处理器(三个回调函数)到 sharedInformer 中；最后 [informer.run](http://informer.run) 会初始化一个对应得 reflector，reflector 包含 deltafifo，会直接将数据 push 到deltafifo。见下图：

### 控制器的定义

看一个组件的功能，首先看它的结构体定义

```go
// sigs.k8s.io/controller-runtime/pkg/internal/controller/controller.go:41
type Controller struct {
	// 名称用于在跟踪、日志记录和监视中唯一标识控制器
	Name string

	// 可以运行的最大并发 Reconciles 数量，默认值为1
	MaxConcurrentReconciles int

	// Reconciler 是一个可以随时调用对象的 Name/Namespace 的函数
  // 确保系统的状态与对象中指定的状态一致，默认为 DefaultReconcileFunc 函数
	Do reconcile.Reconciler

	//一旦控制器准备好启动，MakeQueue就会为该控制器构造队列。
  //这是因为标准的Kubernetes工作队列会立即启动
  //如果有东西反复调用controller.New，就会导致goroutine泄漏。
	MakeQueue func() workqueue.RateLimitingInterface

	// 即 workqueue 的限速队列
	Queue workqueue.RateLimitingInterface

	// SetFields 用来将依赖关系注入到其他对象，比如 Sources、EventHandlers 以及 Predicates
	SetFields func(i interface{}) error

	// 控制器同步信号量
	mu sync.Mutex

	// 表示控制器是否已经启动
	Started bool

	// ctx is the context that was passed to Start() and used when starting watches.
	//
	// According to the docs, contexts should not be stored in a struct: https://golang.org/pkg/context,
	// while we usually always strive to follow best practices, we consider this a legacy case and it should
	// undergo a major refactoring and redesign to allow for context to not be stored in a struct.
	ctx context.Context

	// CacheSyncTimeout是指在等待缓存同步时设置的时间限制
	// 默认两分钟
	CacheSyncTimeout time.Duration

	// startWatches 维护了一个 sources、handlers 以及 predicates 列表以方便在控制器启动的时候启动
	startWatches []watchDescription

	// 日志记录
	Log logr.Logger

	// RecoverPanic表示是否应恢复由调谐函数引起的恐慌。
	RecoverPanic bool
}
```

Controller 结构体实现了几个方法，其中最重要的是 Watch 方法和 Start 方法，首先看 Watch 方法的实现

### Watch 方法实现

```go
// sigs.k8s.io/controller-runtime/pkg/internal/controller/controller.go:118
func (c *Controller) Watch(src source.Source, evthdler handler.EventHandler, prct ...predicate.Predicate) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Inject Cache into arguments
	if err := c.SetFields(src); err != nil {
		return err
	}
	if err := c.SetFields(evthdler); err != nil {
		return err
	}
	for _, pr := range prct {
		if err := c.SetFields(pr); err != nil {
			return err
		}
	}

	// 控制器尚未启动，请在本地存储手表并返回。
	//
	// 这些监视将保留在控制器结构上，直到manager或用户调用Start（…）为止。
	if !c.Started {
		c.startWatches = append(c.startWatches, watchDescription{src: src, handler: evthdler, predicates: prct})
		return nil
	}

	c.Log.Info("Starting EventSource", "source", src)
	return src.Start(c.ctx, evthdler, c.Queue, prct...)
}
```

Watch 函数主要先将 src(事件源)、handler(处理器)、prct(过滤器) 注入到对象中。如果 controller 没有启动，将上述三个参数存储到 startWatches ，如果 controller 已经启动，直接调用 Start 函数。下面 src.Start() 函数。

source.Source 是一个接口，src 是一个 kind 类型

```go
// sigs.k8s.io/controller-runtime/pkg/source/source.go:107
func (ks *Kind) Start(ctx context.Context, handler handler.EventHandler, queue workqueue.RateLimitingInterface,
	prct ...predicate.Predicate) error {
	// Type should have been specified by the user.
	if ks.Type == nil {
		return fmt.Errorf("must specify Kind.Type")
	}

	// cache should have been injected before Start was called
	if ks.cache == nil {
		return fmt.Errorf("must call CacheInto on Kind before calling Start")
	}

	// cache.GetInformer will block until its context is cancelled if the cache was already started and it can not
	// sync that informer (most commonly due to RBAC issues).
	ctx, ks.startCancel = context.WithCancel(ctx)
	ks.started = make(chan error)
	go func() {
		var (
			i       cache.Informer
			lastErr error
		)

		// Tries to get an informer until it returns true,
		// an error or the specified context is cancelled or expired.
		if err := wait.PollImmediateUntilWithContext(ctx, 10*time.Second, func(ctx context.Context) (bool, error) {
			// 循环获取 informer
			i, lastErr = ks.cache.GetInformer(ctx, ks.Type)
			if lastErr != nil {
				kindMatchErr := &meta.NoKindMatchError{}
				if errors.As(lastErr, &kindMatchErr) {
					log.Error(lastErr, "if kind is a CRD, it should be installed before calling Start",
						"kind", kindMatchErr.GroupKind)
				}
				return false, nil // Retry.
			}
			return true, nil
		}); err != nil {
			if lastErr != nil {
				ks.started <- fmt.Errorf("failed to get informer from cache: %w", lastErr)
				return
			}
			ks.started <- err
			return
		}
		添加处理器到 informer
		i.AddEventHandler(internal.EventHandler{Queue: queue, EventHandler: handler, Predicates: prct})
		if !ks.cache.WaitForCacheSync(ctx) {
			// Would be great to return something more informative here
			ks.started <- errors.New("cache did not sync")
		}
		close(ks.started)
	}()

	return nil
}
```

上述 Start 函数主要是获取 informer 以及给当前 informer 添加处理器，下面分别看看 GetInformer 和 AddEventHandler 的实现

```go
// sigs.k8s.io/controller-runtime/pkg/cache/informer_cache.go:148
func (ip *informerCache) GetInformer(ctx context.Context, obj client.Object) (Informer, error) {
	gvk, err := apiutil.GVKForObject(obj, ip.Scheme)
	if err != nil {
		return nil, err
	}

	_, i, err := ip.InformersMap.Get(ctx, gvk, obj)
	if err != nil {
		return nil, err
	}
	return i.Informer, err
}

// sigs.k8s.io/controller-runtime/pkg/cache/internal/deleg_map.go:94
func (m *InformersMap) Get(ctx context.Context, gvk schema.GroupVersionKind, obj runtime.Object) (bool, *MapEntry, error) {
	switch obj.(type) {
	case *unstructured.Unstructured:
		return m.unstructured.Get(ctx, gvk, obj)
	case *unstructured.UnstructuredList:
		return m.unstructured.Get(ctx, gvk, obj)
	case *metav1.PartialObjectMetadata:
		return m.metadata.Get(ctx, gvk, obj)
	case *metav1.PartialObjectMetadataList:
		return m.metadata.Get(ctx, gvk, obj)
	default:
		return m.structured.Get(ctx, gvk, obj)
	}
}

// sigs.k8s.io/controller-runtime/pkg/cache/internal/informers_map.go:210
func (ip *specificInformersMap) addInformerToMap(gvk schema.GroupVersionKind, obj runtime.Object) (*MapEntry, bool, error) {}

// k8s.io/client-go/tools/cache/shared_informer.go:210
func NewSharedIndexInformer(lw ListerWatcher, exampleObject runtime.Object, defaultEventHandlerResyncPeriod time.Duration, indexers Indexers) SharedIndexInformer {
	realClock := &clock.RealClock{}
	sharedIndexInformer := &sharedIndexInformer{
		processor:                       &sharedProcessor{clock: realClock},
		// 初始化 indexer
		indexer:                         NewIndexer(DeletionHandlingMetaNamespaceKeyFunc, indexers),
		listerWatcher:                   lw,
		objectType:                      exampleObject,
		resyncCheckPeriod:               defaultEventHandlerResyncPeriod,
		defaultEventHandlerResyncPeriod: defaultEventHandlerResyncPeriod,
		cacheMutationDetector:           NewCacheMutationDetector(fmt.Sprintf("%T", exampleObject)),
		clock:                           realClock,
	}
	return sharedIndexInformer
}
```

最终调用 NewSharedIndexInformer 函数初始化一个 informer。

一般初始化完成 informer 需要给该 informer 注册一个处理器，用于处理从 deltafifo pop 出来的事件源。下面看看 AddEventHandler 的实现

```go
// vendor/k8s.io/client-go/tools/cache/shared_informer.go:466
func (s *sharedIndexInformer) AddEventHandler(handler ResourceEventHandler) {
	s.AddEventHandlerWithResyncPeriod(handler, s.defaultEventHandlerResyncPeriod)
}

// vendor/k8s.io/client-go/tools/cache/shared_informer.go:487
func (s *sharedIndexInformer) AddEventHandlerWithResyncPeriod(handler ResourceEventHandler, resyncPeriod time.Duration) {
	s.startedLock.Lock()
	defer s.startedLock.Unlock()

	if s.stopped {
		klog.V(2).Infof("Handler %v was not added to shared informer because it has stopped already", handler)
		return
	}

	if resyncPeriod > 0 {
		if resyncPeriod < minimumResyncPeriod {
			klog.Warningf("resyncPeriod %v is too small. Changing it to the minimum allowed value of %v", resyncPeriod, minimumResyncPeriod)
			resyncPeriod = minimumResyncPeriod
		}

		if resyncPeriod < s.resyncCheckPeriod {
			if s.started {
				klog.Warningf("resyncPeriod %v is smaller than resyncCheckPeriod %v and the informer has already started. Changing it to %v", resyncPeriod, s.resyncCheckPeriod, s.resyncCheckPeriod)
				resyncPeriod = s.resyncCheckPeriod
			} else {
				// if the event handler's resyncPeriod is smaller than the current resyncCheckPeriod, update
				// resyncCheckPeriod to match resyncPeriod and adjust the resync periods of all the listeners
				// accordingly
				s.resyncCheckPeriod = resyncPeriod
				s.processor.resyncCheckPeriodChanged(resyncPeriod)
			}
		}
	}

	listener := newProcessListener(handler, resyncPeriod, determineResyncPeriod(resyncPeriod, s.resyncCheckPeriod), s.clock.Now(), initialBufferSize)

	if !s.started {
		s.processor.addListener(listener)
		return
	}

	// in order to safely join, we have to
	// 1. stop sending add/update/delete notifications
	// 2. do a list against the store
	// 3. send synthetic "Add" events to the new handler
	// 4. unblock
	s.blockDeltas.Lock()
	defer s.blockDeltas.Unlock()

	s.processor.addListener(listener)
	for _, item := range s.indexer.List() {
		listener.add(addNotification{newObj: item})
	}
}
```

AddEventHandler() 函数需要传入一个 handler ResourceEventHandler 参数，这是一个接口类型

```go
// k8s.io/client-go/tools/cache/controller.go:212
type ResourceEventHandler interface {
	OnAdd(obj interface{})
	OnUpdate(oldObj, newObj interface{})
	OnDelete(obj interface{})
}
```

所以这个函数的实参需要实现这个接口，EventHandler 是controller-runtime 自动实现好的

```go
// sigs.k8s.io/controller-runtime/pkg/source/internal/eventsource.go:37
type EventHandler struct {
	EventHandler handler.EventHandler
	Queue        workqueue.RateLimitingInterface
	Predicates   []predicate.Predicate
}

// OnAdd creates CreateEvent and calls Create on EventHandler.
func (e EventHandler) OnAdd(obj interface{}) {
	c := event.CreateEvent{}

	// Pull Object out of the object
	if o, ok := obj.(client.Object); ok {
		c.Object = o
	} else {
		log.Error(nil, "OnAdd missing Object",
			"object", obj, "type", fmt.Sprintf("%T", obj))
		return
	}
	// 调用过滤函数，过滤掉无用事件
	for _, p := range e.Predicates {
		if !p.Create(c) {
			return
		}
	}

	// 调用处理器的 create 函数
	e.EventHandler.Create(c, e.Queue)
}

// OnUpdate creates UpdateEvent and calls Update on EventHandler.
func (e EventHandler) OnUpdate(oldObj, newObj interface{}) {
	u := event.UpdateEvent{}

	if o, ok := oldObj.(client.Object); ok {
		u.ObjectOld = o
	} else {
		log.Error(nil, "OnUpdate missing ObjectOld",
			"object", oldObj, "type", fmt.Sprintf("%T", oldObj))
		return
	}

	// Pull Object out of the object
	if o, ok := newObj.(client.Object); ok {
		u.ObjectNew = o
	} else {
		log.Error(nil, "OnUpdate missing ObjectNew",
			"object", newObj, "type", fmt.Sprintf("%T", newObj))
		return
	}

	for _, p := range e.Predicates {
		if !p.Update(u) {
			return
		}
	}

	// Invoke update handler
	e.EventHandler.Update(u, e.Queue)
}

// OnDelete creates DeleteEvent and calls Delete on EventHandler.
func (e EventHandler) OnDelete(obj interface{}) {
	d := event.DeleteEvent{}

	// Deal with tombstone events by pulling the object out.  Tombstone events wrap the object in a
	// DeleteFinalStateUnknown struct, so the object needs to be pulled out.
	// Copied from sample-controller
	// This should never happen if we aren't missing events, which we have concluded that we are not
	// and made decisions off of this belief.  Maybe this shouldn't be here?
	var ok bool
	if _, ok = obj.(client.Object); !ok {
		// If the object doesn't have Metadata, assume it is a tombstone object of type DeletedFinalStateUnknown
		tombstone, ok := obj.(cache.DeletedFinalStateUnknown)
		if !ok {
			log.Error(nil, "Error decoding objects.  Expected cache.DeletedFinalStateUnknown",
				"type", fmt.Sprintf("%T", obj),
				"object", obj)
			return
		}

		// Set obj to the tombstone obj
		obj = tombstone.Obj
	}

	// Pull Object out of the object
	if o, ok := obj.(client.Object); ok {
		d.Object = o
	} else {
		log.Error(nil, "OnDelete missing Object",
			"object", obj, "type", fmt.Sprintf("%T", obj))
		return
	}

	for _, p := range e.Predicates {
		if !p.Delete(d) {
			return
		}
	}

	// Invoke delete handler
	e.EventHandler.Delete(d, e.Queue)
}
```

发现这三个回调函数并没有将事件 push 到 workqueue，真正 push workqueue 的逻辑在 EventHandler 中，controller-runtime 会给每个资源初始化 EnqueueRequestForObject，该结构体实现了 Create，Update，Delete，Generic

```go
// sigs.k8s.io/controller-runtime/pkg/handler/enqueue.go:36
type EnqueueRequestForObject struct{}

// Create implements EventHandler.
func (e *EnqueueRequestForObject) Create(evt event.CreateEvent, q workqueue.RateLimitingInterface) {
	if evt.Object == nil {
		enqueueLog.Error(nil, "CreateEvent received with no metadata", "event", evt)
		return
	}
	q.Add(reconcile.Request{NamespacedName: types.NamespacedName{
		Name:      evt.Object.GetName(),
		Namespace: evt.Object.GetNamespace(),
	}})
}

// Update implements EventHandler.
func (e *EnqueueRequestForObject) Update(evt event.UpdateEvent, q workqueue.RateLimitingInterface) {
	switch {
	case evt.ObjectNew != nil:
		q.Add(reconcile.Request{NamespacedName: types.NamespacedName{
			Name:      evt.ObjectNew.GetName(),
			Namespace: evt.ObjectNew.GetNamespace(),
		}})
	case evt.ObjectOld != nil:
		q.Add(reconcile.Request{NamespacedName: types.NamespacedName{
			Name:      evt.ObjectOld.GetName(),
			Namespace: evt.ObjectOld.GetNamespace(),
		}})
	default:
		enqueueLog.Error(nil, "UpdateEvent received with no metadata", "event", evt)
	}
}

// Delete implements EventHandler.
func (e *EnqueueRequestForObject) Delete(evt event.DeleteEvent, q workqueue.RateLimitingInterface) {
	if evt.Object == nil {
		enqueueLog.Error(nil, "DeleteEvent received with no metadata", "event", evt)
		return
	}
	q.Add(reconcile.Request{NamespacedName: types.NamespacedName{
		Name:      evt.Object.GetName(),
		Namespace: evt.Object.GetNamespace(),
	}})
}

// Generic implements EventHandler.
func (e *EnqueueRequestForObject) Generic(evt event.GenericEvent, q workqueue.RateLimitingInterface) {
	if evt.Object == nil {
		enqueueLog.Error(nil, "GenericEvent received with no metadata", "event", evt)
		return
	}
	q.Add(reconcile.Request{NamespacedName: types.NamespacedName{
		Name:      evt.Object.GetName(),
		Namespace: evt.Object.GetNamespace(),
	}})
}
```

完成 informer 的初始化以及处理器的注册，就需要启动 informer，启动 informer 会启动 reflector 对资源进行监听，然后将事件缓存到 indexer 中。这个实现在 Manager 的 Start 函数里实现的，见下一篇

基本上 Watch 函数实现就到此了，主要就是初始化 informer，然后给当前 informer 注册事件处理器

## Start 函数实现

start 就是启动当前 controller

```go
// sigs.k8s.io/controller-runtime/pkg/internal/controller/controller.go:148
func (c *Controller) Start(ctx context.Context) error {
	// use an IIFE to get proper lock handling
	// but lock outside to get proper handling of the queue shutdown
	c.mu.Lock()
	if c.Started {
		return errors.New("controller was started more than once. This is likely to be caused by being added to a manager multiple times")
	}

	c.initMetrics()

	// Set the internal context.
	c.ctx = ctx

	c.Queue = c.MakeQueue()
	go func() {
		<-ctx.Done()
		c.Queue.ShutDown()
	}()

	wg := &sync.WaitGroup{}
	err := func() error {
		defer c.mu.Unlock()

		// TODO(pwittrock): Reconsider HandleCrash
		defer utilruntime.HandleCrash()

		// 启动事件函数，初始化 informer 注册处理函数
		for _, watch := range c.startWatches {
			c.Log.Info("Starting EventSource", "source", fmt.Sprintf("%s", watch.src))
	
			if err := watch.src.Start(ctx, watch.handler, c.Queue, watch.predicates...); err != nil {
				return err
			}
		}

		// Start the SharedIndexInformer factories to begin populating the SharedIndexInformer caches
		c.Log.Info("Starting Controller")

		for _, watch := range c.startWatches {
			syncingSource, ok := watch.src.(source.SyncingSource)
			if !ok {
				continue
			}

			if err := func() error {
				// use a context with timeout for launching sources and syncing caches.
				sourceStartCtx, cancel := context.WithTimeout(ctx, c.CacheSyncTimeout)
				defer cancel()

				// 等待数据同步到缓存(indexer)
				if err := syncingSource.WaitForSync(sourceStartCtx); err != nil {
					err := fmt.Errorf("failed to wait for %s caches to sync: %w", c.Name, err)
					c.Log.Error(err, "Could not wait for Cache to sync")
					return err
				}

				return nil
			}(); err != nil {
				return err
			}
		}

		// All the watches have been started, we can reset the local slice.
		//
		// We should never hold watches more than necessary, each watch source can hold a backing cache,
		// which won't be garbage collected if we hold a reference to it.
		c.startWatches = nil

		// Launch workers to process resources
		c.Log.Info("Starting workers", "worker count", c.MaxConcurrentReconciles)
		wg.Add(c.MaxConcurrentReconciles)
		for i := 0; i < c.MaxConcurrentReconciles; i++ {
			go func() {
				defer wg.Done()
				// 处理 workqueue 里的事件
				for c.processNextWorkItem(ctx) {
				}
			}()
		}

		c.Started = true
		return nil
	}()
	if err != nil {
		return err
	}

	<-ctx.Done()
	c.Log.Info("Shutdown signal received, waiting for all workers to finish")
	wg.Wait()
	c.Log.Info("All workers finished")
	return nil
}
```

看看 processNextWorkItem ****

```go
// sigs.k8s.io/controller-runtime/pkg/internal/controller/controller.go:248
func (c *Controller) processNextWorkItem(ctx context.Context) bool {
	obj, shutdown := c.Queue.Get()
	if shutdown {
		// Stop working
		return false
	}

	// We call Done here so the workqueue knows we have finished
	// processing this item. We also must remember to call Forget if we
	// do not want this work item being re-queued. For example, we do
	// not call Forget if a transient error occurs, instead the item is
	// put back on the workqueue and attempted again after a back-off
	// period.
	defer c.Queue.Done(obj)

	ctrlmetrics.ActiveWorkers.WithLabelValues(c.Name).Add(1)
	defer ctrlmetrics.ActiveWorkers.WithLabelValues(c.Name).Add(-1)

	c.reconcileHandler(ctx, obj)
	return true
}
```

processNextWorkItem 从 workqueue 获取事件，然后调用开发者开发的调谐函数

```go
// sigs.k8s.io/controller-runtime/pkg/internal/controller/controller.go:287
func (c *Controller) reconcileHandler(ctx context.Context, obj interface{}) {
	// Update metrics after processing each item
	reconcileStartTS := time.Now()
	defer func() {
		c.updateMetrics(time.Since(reconcileStartTS))
	}()

	// Make sure that the the object is a valid request.
	req, ok := obj.(reconcile.Request)
	if !ok {
		// As the item in the workqueue is actually invalid, we call
		// Forget here else we'd go into a loop of attempting to
		// process a work item that is invalid.
		c.Queue.Forget(obj)
		c.Log.Error(nil, "Queue item was not a Request", "type", fmt.Sprintf("%T", obj), "value", obj)
		// Return true, don't take a break
		return
	}

	log := c.Log.WithValues("name", req.Name, "namespace", req.Namespace)
	ctx = logf.IntoContext(ctx, log)

	// 调用调谐函数
	result, err := c.Reconcile(ctx, req)
	switch {
	// 调谐失败，重新入队列
	case err != nil:
		c.Queue.AddRateLimited(req)
		ctrlmetrics.ReconcileErrors.WithLabelValues(c.Name).Inc()
		ctrlmetrics.ReconcileTotal.WithLabelValues(c.Name, labelError).Inc()
		log.Error(err, "Reconciler error")
	// 需要重回队列的话，先忘记该事件，到 RequeueAfter 时间后重回队列
	case result.RequeueAfter > 0:
		// The result.RequeueAfter request will be lost, if it is returned
		// along with a non-nil error. But this is intended as
		// We need to drive to stable reconcile loops before queuing due
		// to result.RequestAfter
		c.Queue.Forget(obj)
		c.Queue.AddAfter(req, result.RequeueAfter)
		ctrlmetrics.ReconcileTotal.WithLabelValues(c.Name, labelRequeueAfter).Inc()
	case result.Requeue:
		c.Queue.AddRateLimited(req)
		ctrlmetrics.ReconcileTotal.WithLabelValues(c.Name, labelRequeue).Inc()
	// 默认忘记元素
	default:
		// Finally, if no error occurs we Forget this item so it does not
		// get queued again until another change happens.
		c.Queue.Forget(obj)
		ctrlmetrics.ReconcileTotal.WithLabelValues(c.Name, labelSuccess).Inc()
	}
}
```

到这里整个 controller 启动过程就完成了。