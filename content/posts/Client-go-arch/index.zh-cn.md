---
weight: 11
title: "Client-go 架构"
date: 2022-05-20T23:57:40+08:00
lastmod: 2022-05-20T23:58:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "k8s-dev.jpg"

tags: ["Kubernetes-dev"]
categories: ["Kubernetes-dev"]

lightgallery: true
---

# Client-go 架构

## 简介

Client-go 源码位于 https://github.com/kubernetes/client-go，是 Kubernetes 项目非常重要的子项目，Client-Go 是负责与 Kubernetes APIServer 服务进行交互的客户端库，利用 Client-Go 与Kubernetes APIServer 进行的交互访问，来对 Kubernetes 中的各类资源对象进行管理操作，包括内置的资源对象及CRD。在云原生开发的项目中使用频率非常高，例如开发 operator，k8s 管理平台等。

## 架构

Client-go 架构比较复杂，极大程度运用异步处理，提高服务运行效率。

![Client-go 架构](client-arch.png "Client-go 架构")

上图上半部分是 client-go 代码组件，下半部分是需要开发者自己实现，主要实现如何对资源事件进行处理，但是 workqueue 也是 client-go 实现的，只不过是在开发者写的程序中进行使用的。

### Reflector

Reflector 用于监控（Watch）指定的 Kubernetes 资源，当监控的资源发生变化时，例如 Add 事件、Update 事件、Delete 事件，并将其资源对象存放到本地缓存 DeltaFIFO 中。

### Deltafifo

DeltaFIFO 是一个生产者-消费者的队列，生产者是 Reflector，消费者是 informer Pop 函数，FIFO 是一个先进先出的队列，而 Delta 是一个资源对象存储，它可以保存资源对象的操作类型，例如 Add 操作类型、Update 操作类型、Delete 操作类型、Sync 操作类型等。

### Indexer

Indexer 是 client-go 用来存储资源对象并自带索引功能的本地存储，informer 从 DeltaFIFO 中将消费出来的资源对象存储至 Indexer。Indexer 与 Etcd 集群中的数据保持完全一致。这样我们就可以很方便地从本地存储中读取相应的资源对象数据，而无须每次从远程 APIServer 中读取，以减轻服务器的压力。

### Informer

Informer 将上述三个组件协同运行起来，保证整个流程串联起来，是 client-go 中的大脑。

### workqueue

Workqueue 是一个先进先出的队列，informer 将事件获取到并不及时处理，先将事件 push 到 workqueue 中，然后再从 workqueue 消费处理。

大大提高运行效率

## 运行流程

例如现在创建一个 pods，kubelet 中的 controller 是如何运行的(K8s 中源码中也大量使用 client-go，主要是大量的 controller)

- 初始化并启动 informer，informer 启动会初始化并启动 reflector，reflector 从 kube-apiserver list 所有 pod 资源，并 sync 到 Deltafifo 中。
- Deltafifo 存有全部 pod 资源，informer 通过 pop 函数消费 deltafifo 事件并存储到 indexer 中。
- 如果需要调用 pod 资源，那么可以直接从 indexer 中获取
- informer 初始化完成后，Reflector 开始 Watch Pod 相关的事件
- 如果创建一个 pod，1. 那么 Reflector 会监听到这个事件，然后将这个事件发送到 DeltaFIFO 中
- informer pop 消费改 ADD 事件，并将该 pod 存储到 indexer
- informer 处理器函数同样拿到该 ADD 事件去处理该事件，通过workqueue获取到事件的key，再通过indexer获取到真正操作的对象
- reflector 会周期性将 indexer 数据同步到 Deltafifo，防止一些事件处理失败，重新处理。

## 总结

理解 client-go 原理是非常重要的，里面很多设计值得我们去学习，也可以运用到自己项目中。