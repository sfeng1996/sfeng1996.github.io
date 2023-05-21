---
weight: 10
title: "Client-go Infomer 使用"
date: 2022-05-25T21:57:40+08:00
lastmod: 2022-05-25T16:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "informer-use-home.png"

tags: ["Kubernetes-dev"]
categories: ["Kubernetes-dev"]

lightgallery: true
---

## 简介

上一篇文章介绍了 Client-go 中四种客户端的使用及原理，但是使用场景主要就是一次性对数据进行处理，那如果需要监听数据的变化，进而对数据做一些增，删，查，改的操作该怎么办？Informer 实现了这个功能，在 Client-go 架构一文中介绍了 Client-go 组件的原理，下面就介绍一下 Informer 的使用。

现在不考虑 Informer 里面的机制，暂时理解 Informer 实现了对 Kube-apiserver 的 List 和 Watch，List() 从 Kube-apiserver 拉取全量对应资源数据，而 Watch() 是监听 Kube-Apiserver 对应资源数据的变化，是一个长链接。然后通过 Informer 注册的回调函数来异步处理这些资源变化事件。

## 示例

下面简单写个 Informer Demo，感受 k8s controller 基本原理。

```go
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
)

// 获取系统家目录
func homeDir() string {
	if h := os.Getenv("HOME"); h != "" {
		return h
	}

	// for windows
	return os.Getenv("USERPROFILE")
}

func main() {
	var kubeConfig *string

	if h := homeDir(); h != "" {
		kubeConfig = flag.String("kubeconfig", filepath.Join(h, ".kube", "config"), "use kubeconfig access to kubeapiserver")
	} else {
		kubeConfig = flag.String("kubeconfig", "", "use kubeconfig access to kubeapiserver")
	}

	// 获取 kubeconfig
	config, err := clientcmd.BuildConfigFromFlags("", *kubeConfig)
	if err != nil {
		panic(err.Error())
	}
	// 初始化 clientSet
	clientSet, err := kubernetes.NewForConfig(config)
	if err != nil {
		panic(err.Error())
	}

	// 初始化 default 命名空间下的 informer 工厂, 这个 informer 工厂包含 k8s 所有内置资源的 informer
	// 同时设置 5s 的同步周期，同步是指将 indexer 的数据同步到 deltafifo，防止因为特殊原因处理失败的数据能够得到重新处理
	informerFactory := informers.NewSharedInformerFactoryWithOptions(clientSet, 5*time.Second, informers.WithNamespace("default"))
	// 获取 pod informer
	podInformer := informerFactory.Core().V1().Pods().Informer()
	// 向 pod informer 注册处理函数
	podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc:    add,
		UpdateFunc: update,
		DeleteFunc: delete,
	})

	stopChan := make(chan struct{})
	defer close(stopChan)
	// 启动 pod informer
	podInformer.Run(stopChan)
	// 等待数据同步到 cache 中
	isCache := cache.WaitForCacheSync(stopChan, podInformer.HasSynced)
	if !isCache {
		fmt.Println("pod has not cached")
		return
	}
}
// 资源新增回调函数
func add(obj interface{}) {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		panic("invalid obj")
	}
	fmt.Println("add a pod:", pod.Name)
}

// 资源更新回调函数
func update(oldObj, newObj interface{}) {
	oldPod, ok := oldObj.(*corev1.Pod)
	if !ok {
		panic("invalid oldObj")
	}
	newPod, ok := newObj.(*corev1.Pod)
	if !ok {
		panic("invalid newObj")
	}
	fmt.Println("update a pod:", oldPod.Name, newPod.Name)
}

// 资源删除回调函数
func delete(obj interface{}) {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		panic("invalid obj")
	}
	fmt.Println("delete a pod:", pod.Name)
}
```

运行结果如下：

```bash
// informer 启动时第一次 list，所以是 add 
add a pod: wordpress-5b8d496f6d-xv2pp
add a pod: mysql-65c584658f-9t46m
// informer 周期同步数据，是 update
update a pod: wordpress-5b8d496f6d-xv2pp wordpress-5b8d496f6d-xv2pp
update a pod: mysql-65c584658f-9t46m mysql-65c584658f-9t46m
update a pod: wordpress-5b8d496f6d-xv2pp wordpress-5b8d496f6d-xv2pp
update a pod: mysql-65c584658f-9t46m mysql-65c584658f-9t46m
update a pod: wordpress-5b8d496f6d-xv2pp wordpress-5b8d496f6d-xv2pp
update a pod: mysql-65c584658f-9t46m mysql-65c584658f-9t46m
// 删除了 wordpress, 是 delete
delete a pod: wordpress-5b8d496f6d-xv2pp
// 后期只有 mysql 的 update
update a pod: mysql-65c584658f-9t46m mysql-65c584658f-9t46m
update a pod: mysql-65c584658f-9t46m mysql-65c584658f-9t46m
```

可以发现刚开始启动 informer 会 list 全量数据到 cache 中，所以有两个 add 事件，后面每次 resync 时，indexer 将数据同步到 deltafifo 会认为是更新事件，所有会周期出现更新事件。当删除了 wordpress pod 后，出现了 delete 事件，后期也就只有 mysql 的 update 事件了。

### 注意

1、在初始化 informer 的时候，一般使用 shanredInformer，这样同一个资源比如(pod) 就会共享这个 informer，不需要重新启动一个新的 informer。如果每个使用者都去初始化一个 informer，每个 informer 都会 list & watch kube-apiserver，这样 kube-apiserver 的压力会非常大。

2、初始化 informer 会传同步时间，这个同步是指 indexer 会定期将数据重新同步到 deltafifo 中，这样可以保证由于特殊原因处理失败的资源能够重新被处理。

## 总结

上面只是简单介绍了 informer 的用法，没有讲解 informer 的原理。我认为 informer 内部原理相对较复杂，这个阶段讲解原理可能不大合适，所以等到后面 reflector、deltafifo、indexer、workqueue 讲解完之后，再讲 informer 原理可能会更加合适。