---
weight: 21
title: "Kubernetes 中多副本服务 Leader 选举原理"
date: 2023-06-16T21:57:40+08:00
lastmod: 2023-06-16T16:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "k8s-dev.jpg"

tags: ["Kubernetes-dev"]
categories: ["Kubernetes-dev"]

lightgallery: true
---

# k8s 中的 leader 选举机制

## 介绍

在有状态的服务开启多副本的情况下，如果不选主的话，多个 pod 都监听资源的变化以及进行变更操作，势必会造成并发冲突的情况，所以需要在多个 pod 之间选主一个主，多个从，只有主才会真正运行 operator 逻辑，其他从不断监听锁的情况，当主 down 了的情况，从去争抢锁资源，从而成为主。

实际上选主的逻辑是在 client-go 中实现的，kube-controller-manager，kube-scheduler 的选主也是调用 client-go 的选主逻辑实现。大概逻辑是多个 pod 启动时都去获取集群中的某个资源，然后更新相关信息到该资源中，表示获得该锁，即成为主，其余都成为从。

目前 client-go 中有三种锁资源，configmap，endpoint，lease，同时也支持 configmap && lease 以及 endpoint && lease 混合资源锁。其底层采用 k8s resourceVersion 乐观锁机制实现选主，对比 etcd 选主，效率更高。

## 源码分析

这里基于 [k8s.io/client-go](http://k8s.io/client-go) v0.23.4 源码讲解

### 结构体定义

前面说到 client-go 中支持 configmap，endpoint，lease，configmap && lease 以及 endpoint && lease 这五种资源锁

```go
// [k8s.io/client-go/tools/leaderelection/resourcelock/interface.go](http://k8s.io/client-go/tools/leaderelection/resourcelock/interface.go) 
const (
	LeaderElectionRecordAnnotationKey = "control-plane.alpha.kubernetes.io/leader"
	EndpointsResourceLock             = "endpoints"
	ConfigMapsResourceLock            = "configmaps"
	LeasesResourceLock                = "leases"
	EndpointsLeasesResourceLock       = "endpointsleases"
	ConfigMapsLeasesResourceLock      = "configmapsleases"
)
```

除了 lease 资源锁定义了如下字段，configmap，endpoint 这两个资源锁都是在 annotation 字段里记录这些信息。锁的结构体定义如下：

```go
// [k8s.io/client-go/tools/leaderelection/resourcelock/interface.go](http://k8s.io/client-go/tools/leaderelection/resourcelock/interface.go) 

type LeaderElectionRecord struct {
	// leader 标识，通常是 pod 的 hostname + 随机字符串
	HolderIdentity       string      `json:"holderIdentity"`
	// 租约时长，用来从结点判断该资源锁是否过期
	LeaseDurationSeconds int         `json:"leaseDurationSeconds"`
	// leader 第一次成功获得租约的时间戳
	AcquireTime          metav1.Time `json:"acquireTime"`
	// leader 定时刷新锁的时间戳
	RenewTime            metav1.Time `json:"renewTime"`
	// leader 转换的次数，比如第一次 pod1 为 leader, 这时 LeaderTransitions 等于1，过段时间 pod1 挂了，pod2 成为 leader， LeaderTransitions 加1 
	LeaderTransitions    int         `json:"leaderTransitions"`
}
```

每种锁资源都会实现这个 `resourcelock.Interface` 接口，基本操作就是对上述资源进行 CRU

```go
// Interface offers a common interface for locking on arbitrary
// resources used in leader election.  The Interface is used
// to hide the details on specific implementations in order to allow
// them to change over time.  This interface is strictly for use
// by the leaderelection code.
type Interface interface {
	// Get returns the LeaderElectionRecord
	Get(ctx context.Context) (*LeaderElectionRecord, []byte, error)

	// Create attempts to create a LeaderElectionRecord
	Create(ctx context.Context, ler LeaderElectionRecord) error

	// Update will update and existing LeaderElectionRecord
	Update(ctx context.Context, ler LeaderElectionRecord) error

	// RecordEvent is used to record events
	RecordEvent(string)

	// Identity will return the locks Identity
	Identity() string

	// Describe is used to convert details on current resource lock
	// into a string
	Describe() string
}
```

### 启动选举

在使用 controller-runtime 开发 operator 时，operator 在启动时创建资源锁，这里 controller-runtime 对创建资源锁进行封装

```go
// sigs.k8s.io/controller-runtime/pkg/leaderelection/leader_election.go

func NewResourceLock(config *rest.Config, recorderProvider recorder.Provider, options Options) (resourcelock.Interface, error) {
	if !options.LeaderElection {
		return nil, nil
	}
	// 默认资源锁类型为 ConfigMapsLeasesResourceLock 类型，现在 kube-controller-manager，kube-scheduler
  // 默认都是 lease，主要是以前使用都是 configmap 作为默认类型，所以使用 ConfigMapsLeasesResourceLock
  // 作为过渡。
	if options.LeaderElectionResourceLock == "" {
		options.LeaderElectionResourceLock = resourcelock.ConfigMapsLeasesResourceLock
	}

	// LeaderElectionID 需要指定，一般 operator 都会指定该运行参数
	if options.LeaderElectionID == "" {
		return nil, errors.New("LeaderElectionID must be configured")
	}

	// 如果不指定 namespace，那么直接获取当前 pod 所运行的 namespace
	if options.LeaderElectionNamespace == "" {
		var err error
		options.LeaderElectionNamespace, err = getInClusterNamespace()
		if err != nil {
			return nil, fmt.Errorf("unable to find leader election namespace: %w", err)
		}
	}

	// Leader id 设置为 pod 的主机名加一串随机字符
	id, err := os.Hostname()
	if err != nil {
		return nil, err
	}
	id = id + "_" + string(uuid.NewUUID())

	// 生成 k8s client 用来操作资源锁，corev1Client 用来操作 configmap, endpoint
	rest.AddUserAgent(config, "leader-election")
	corev1Client, err := corev1client.NewForConfig(config)
	if err != nil {
		return nil, err
	}
	// 生成 k8s client 用来操作资源锁，coordinationv1client用来操作 lease
	coordinationClient, err := coordinationv1client.NewForConfig(config)
	if err != nil {
		return nil, err
	}
	// 调用 client-go 方法创建 reosurceLock
	return resourcelock.New(options.LeaderElectionResourceLock,
		options.LeaderElectionNamespace,
		options.LeaderElectionID,
		corev1Client,
		coordinationClient,
		resourcelock.ResourceLockConfig{
			Identity:      id,
			EventRecorder: recorderProvider.GetEventRecorderFor(id),
		})
}
```

下面具体看看 [resourcelock.New](http://resourcelock.New) 方法的实现

```go
// k8s.io/client-go/tools/leaderelection/resourcelock/interface.go
func New(lockType string, ns string, name string, coreClient corev1.CoreV1Interface, coordinationClient coordinationv1.CoordinationV1Interface, rlc ResourceLockConfig) (Interface, error) {
	endpointsLock := &EndpointsLock{
		EndpointsMeta: metav1.ObjectMeta{
			Namespace: ns,
			Name:      name,
		},
		Client:     coreClient,
		LockConfig: rlc,
	}
	configmapLock := &ConfigMapLock{
		ConfigMapMeta: metav1.ObjectMeta{
			Namespace: ns,
			Name:      name,
		},
		Client:     coreClient,
		LockConfig: rlc,
	}
	leaseLock := &LeaseLock{
		LeaseMeta: metav1.ObjectMeta{
			Namespace: ns,
			Name:      name,
		},
		Client:     coordinationClient,
		LockConfig: rlc,
	}
	// 根据传入的资源锁类型，默认 configmapLease，创建对应的资源锁
	switch lockType {
	case EndpointsResourceLock:
		return endpointsLock, nil
	case ConfigMapsResourceLock:
		return configmapLock, nil
	case LeasesResourceLock:
		return leaseLock, nil
	case EndpointsLeasesResourceLock:
		return &MultiLock{
			Primary:   endpointsLock,
			Secondary: leaseLock,
		}, nil
	// 默认会走到这一步，初始化configmap && lease 混合资源锁
	case ConfigMapsLeasesResourceLock:
		return &MultiLock{
			Primary:   configmapLock,
			Secondary: leaseLock,
		}, nil
	default:
		return nil, fmt.Errorf("Invalid lock-type %s", lockType)
	}
}
```

上面看到如果不指定资源锁类型(在operator启动时可以指定运行参数)，默认为 MultiLock 类型，我们知道每个资源锁都会实现 `resourcelock.Interface`下面看看 MultiLock 是如何实现 这个接口的。

```go
// k8s.io/client-go/tools/leaderelection/resourcelock/leaselock.go

type MultiLock struct {
	Primary   Interface
	Secondary Interface
}

// 获取资源锁
func (ml *MultiLock) Get(ctx context.Context) (*LeaderElectionRecord, []byte, error) {
	primary, primaryRaw, err := ml.Primary.Get(ctx)
	if err != nil {
		return nil, nil, err
	}

	secondary, secondaryRaw, err := ml.Secondary.Get(ctx)
	if err != nil {
		// Lock is held by old client
		if apierrors.IsNotFound(err) && primary.HolderIdentity != ml.Identity() {
			return primary, primaryRaw, nil
		}
		return nil, nil, err
	}

	if primary.HolderIdentity != secondary.HolderIdentity {
		primary.HolderIdentity = UnknownLeader
		primaryRaw, err = json.Marshal(primary)
		if err != nil {
			return nil, nil, err
		}
	}
	return primary, ConcatRawRecord(primaryRaw, secondaryRaw), nil
}

// Create attempts to create both primary lock and secondary lock
func (ml *MultiLock) Create(ctx context.Context, ler LeaderElectionRecord) error {
	err := ml.Primary.Create(ctx, ler)
	if err != nil && !apierrors.IsAlreadyExists(err) {
		return err
	}
	return ml.Secondary.Create(ctx, ler)
}

// Update will update and existing annotation on both two resources.
func (ml *MultiLock) Update(ctx context.Context, ler LeaderElectionRecord) error {
	err := ml.Primary.Update(ctx, ler)
	if err != nil {
		return err
	}
	_, _, err = ml.Secondary.Get(ctx)
	if err != nil && apierrors.IsNotFound(err) {
		return ml.Secondary.Create(ctx, ler)
	}
	return ml.Secondary.Update(ctx, ler)
}

// RecordEvent in leader election while adding meta-data
func (ml *MultiLock) RecordEvent(s string) {
	ml.Primary.RecordEvent(s)
	ml.Secondary.RecordEvent(s)
}

// Describe is used to convert details on current resource lock
// into a string
func (ml *MultiLock) Describe() string {
	return ml.Primary.Describe()
}

// Identity returns the Identity of the lock
func (ml *MultiLock) Identity() string {
	return ml.Primary.Identity()
}
```

到这里基本上 reosurcelock 就初始化好了，下面看看是如何启动选举的

### 选举原理

operator 会在业务 controller 启动之前完成选举，之后调用回调函数启动业务 controller

```go
// k8s.io/client-go/tools/leaderelection/leaderelection.go
func (le *LeaderElector) Run(ctx context.Context) {
	defer runtime.HandleCrash()
	defer func() {
		le.config.Callbacks.OnStoppedLeading()
	}()
	// 尝试获取资源锁，失败直接退出
	if !le.acquire(ctx) {
		return // ctx signalled done
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// 调用回调函数，启动业务 controller
	go le.config.Callbacks.OnStartedLeading(ctx)
	// leader 持续更新锁信息
	le.renew(ctx)
}
```

可以看到调用 acquire 这个方法来尝试获取锁，acquire 会定时调用 tryAcquireOrRenew，下面看 tryAcquireOrRenew这个方法的实现

- 将该 pod 的 identity( hostname + string)，LeaseDurationSeconds，RenewTime，AcquireTime 先保存到 leaderElectionRecord 字段中
- 尝试获取资源锁，如果资源锁没有创建，直接用 leaderElectionRecord 信息来创建资源锁，这样这个资源锁就写入了该 pod 的 leaderElectionRecord 信息，即该pod获取到锁，成为 leader。
- 如果锁已存在，对比当前锁资源信息与获取到的锁资源信息，如果不一样，将当前信息改为获取到资源。并且如果当前资源锁的持有时间还未到期且该 pod 不是 leader，返回 false，表示无需尝试更新锁
- 如果该 pod 是 leader，更新 RenewTime 即可，该字段在函数开始处已设置为当前时间，其余字段无需改动，如果不是 leader，表示该 pod 去获取锁，将 LeaderTransitions +1
- 调用 k8s api 更新锁资源

```go
// k8s.io/client-go/tools/leaderelection/leaderelection.go:317
func (le *LeaderElector) tryAcquireOrRenew(ctx context.Context) bool {
	now := metav1.Now()
	// 将当前 pod 的信息保存到 leaderElectionRecord 字段中
	leaderElectionRecord := rl.LeaderElectionRecord{
		HolderIdentity:       le.config.Lock.Identity(),
		LeaseDurationSeconds: int(le.config.LeaseDuration / time.Second),
		RenewTime:            now,
		AcquireTime:          now,
	}

	// 获取锁资源，注意这里返回两个返回值，第二个返回值是[]byte，主要用于后面比较判断
	// 第一个为结构体，不好比较是否相等
	oldLeaderElectionRecord, oldLeaderElectionRawRecord, err := le.config.Lock.Get(ctx)
	if err != nil {
		// 如果锁不存在，说明还没有 pod 创建
		if !errors.IsNotFound(err) {
			klog.Errorf("error retrieving resource lock %v: %v", le.config.Lock.Describe(), err)
			return false
		}
		// 用当前 leaderElectionRecord 信息来创建锁资源
		if err = le.config.Lock.Create(ctx, leaderElectionRecord); err != nil {
			klog.Errorf("error initially creating leader election record: %v", err)
			return false
		}
		// 此时该 pod 已成为 leader，将 leader 信息保存到 leaderElectionRecord
		le.setObservedRecord(&leaderElectionRecord)
		// 成功获取锁
		return true
	}

	// 到这里，表示集群中已经有了锁资源，判断如果当前信息与集群的资源信息不一致（比如从节点），
	// 将集群资源信息更新到 leaderElectionRecord 和 observedRawRecord 
	if !bytes.Equal(le.observedRawRecord, oldLeaderElectionRawRecord) {
		le.setObservedRecord(oldLeaderElectionRecord)

		le.observedRawRecord = oldLeaderElectionRawRecord
	}
	// oldLeaderElectionRecord.HolderIdentity > 0 表示已经有 leader 了
	// le.observedTime.Add(le.config.LeaseDuration).After(now.Time) 表示 leader 持锁时间还未到期
	// !le.IsLeader() 表示该 pod 不是leader, 这里判断是否为 leader 下面有详解
	// 满足这三个条件，说明锁资源是正常，且该 pod 无需更新锁，直接返回
	if len(oldLeaderElectionRecord.HolderIdentity) > 0 &&
		le.observedTime.Add(le.config.LeaseDuration).After(now.Time) &&
		!le.IsLeader() {
		klog.V(4).Infof("lock is held by %v and has not yet expired", oldLeaderElectionRecord.HolderIdentity)
		return false
	}

	// 到了这一步，说明 leader 需要续约锁，非 leader 需要成为 leader，主要看谁能成功执
	if le.IsLeader() {
		// leader 续约锁，直接更新 renewTime 字段即可，该函数开头处已设置
		leaderElectionRecord.AcquireTime = oldLeaderElectionRecord.AcquireTime
		leaderElectionRecord.LeaderTransitions = oldLeaderElectionRecord.LeaderTransitions
	} else {
		// 非 leader 想要成为 leader，则将 LeaderTransitions +1
		leaderElectionRecord.LeaderTransitions = oldLeaderElectionRecord.LeaderTransitions + 1
	}

	// 更新资源，只会有一个 pod 执行成功，其余都会失败
	// 这里主要依靠 k8s 的乐观锁机制，根据 resourceVersion 判断当前资源已被更新，如果被更新则直接报错
	if err = le.config.Lock.Update(ctx, leaderElectionRecord); err != nil {
		klog.Errorf("Failed to update lock: %v", err)
		return false
	}
	// 将最新集群资源更新到 leaderElectionRecord
	le.setObservedRecord(&leaderElectionRecord)
	return true
}
```

上面有个 IsLeader 方法，表示该 pod 是否为 leader

```go
// k8s.io/client-go/tools/leaderelection/leaderelection.go:237
func (le *LeaderElector) IsLeader() bool {
	// le.getObservedRecord().HolderIdentity 获取的集群中leader id，在创建完锁后，会将
	// 当前锁资源信息保存到 leaderElectionRecord 字段中。
	// le.config.Lock.Identity() 是当前 pod 的 id
	return le.getObservedRecord().HolderIdentity == le.config.Lock.Identity()
}
```

经过上述逻辑，集群中就存在 leader 了，后续就执行业务 controller，然后 leader 持续续约，非 leader 尝试获取锁。

```go
// k8s.io/client-go/tools/leaderelection/leaderelection.go:265

func (le *LeaderElector) renew(ctx context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// 定期续约
	wait.Until(func() {
		timeoutCtx, timeoutCancel := context.WithTimeout(ctx, le.config.RenewDeadline)
		defer timeoutCancel()
		err := wait.PollImmediateUntil(le.config.RetryPeriod, func() (bool, error) {
			// 返回续约结果
			return le.tryAcquireOrRenew(timeoutCtx), nil
		}, timeoutCtx.Done())

		le.maybeReportTransition()
		desc := le.config.Lock.Describe()
		// 续约成功
		if err == nil {
			klog.V(5).Infof("successfully renewed lease %v", desc)
			return
		}
		le.config.Lock.RecordEvent("stopped leading")
		le.metrics.leaderOff(le.config.Name)
		klog.Infof("failed to renew lease %v: %v", desc, err)
		// 到这里说明续约失败，则执行cancel，父context 就会监听到，执行 stop 回调函数退出服务。其余非 leader 就会竞争锁资源。
		cancel()
	}, le.config.RetryPeriod, ctx.Done())

	// if we hold the lease, give it up
	if le.config.ReleaseOnCancel {
		le.release()
	}
}
```

## 总结

使用 controller-runtime 编写 operator，很容易就可以实现 leader 选举，但是需要注意

- 最好使用 lease 作为锁资源，因为原生 configmap，endpoint 会造成不同控制器监听同一个资源，造成并发错误
