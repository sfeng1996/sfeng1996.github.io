---
weight: 26
title: "Kubernetes 删除机制"
date: 2023-09-28T11:57:40+08:00
lastmod: 2023-09-28T12:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "k8s-dev.jpg"

tags: ["Kubernetes-dev"]
categories: ["Kubernetes-dev"]

lightgallery: true
---

# Kubernetes 删除机制

## 简介

当多个资源存在相互依赖的情况，需要删除其中某个资源获多个资源时，就会涉及到 Kubernetes 的垃圾收集器和删除策略。

Kubernetes 的垃圾收集器的作用就是删除当前已删除资源的附属资源，例如 Pod 与 Replicaset 是附属和属主的关系。当删除 Replicaset 时 Kubernetes 会自动删除其 Pod。

但是是否需要自动删除附属资源，这块是可以通过策略控制，也就是 Kubernetes 的删除策略。

## OwnerReference

Kubernetes 垃圾回收是通过在附属资源上设置 `metadata.ownerReferences` 字段实现，例如 Kube-controller-manager 会自动给每个 Pod 都设置 `ownerReferences` ，其 owner 为 Replicaset。当然在 Kubernetes 中，有很多内置资源都会自动设置。

```yaml
apiVersion: v1
kind: Pod
metadata:
  ...
  ownerReferences:
  - apiVersion: apps/v1
    controller: true
    blockOwnerDeletion: true
    kind: ReplicaSet
    name: my-repset
    uid: d9607e19-f88f-11e6-a518-42010a800195
```

`metadata.ownerReferences` 字段值也比较好理解，就是设置当前资源的属主资源基本信息，包括 GVK、name、uid 等。

其中 `blockOwnerDeletion` 字段与下面说的删除策略有关。

当使用 `kubectl delete ReplicaSet my-repset` ，那么 该 pod 就会被自动删除。

## Finalizers

Finalizers 机制可以控制资源删除前能够完成一些预删除动作。

k8s 中默认有两种 finalizer：`OrphanFinalizer` 和 `ForegroundFinalizer`，finalizer 存在于对象的 ObjectMeta 中，当一个对象的依赖对象被删除后其对应的 `finalizers` 字段也会被移除，只

有 `finalizers` 字段为空时，kube-apiserver 才会删除该对象。

```json
{
    ......
    "metadata": {
       ......
        "finalizers": [
            "foregroundDeletion"
        ]
    }
    ......
}
```

此外，finalizer 不仅仅支持以上两种字段，在使用自定义 controller 时也可以在 CR 中设置自定义的 finalizer 标识。

### 删除流程

理解了 K8S 的资源删除流程，就清楚了 Finalizers 的用途和原理了。

- 客户端提交删除请求到 Kube-apiserver，可能会有优雅删除的选项，这里不作介绍；
- Kube-apiserver 首先检查该资源的 `finalizers` 字段是否为空；
    - `metadata.finalizers` 为空，直接删除；
    - `metadata.Finalizers` 不为空，不删除，只更新 `metadata.DeletionTimestamp` ，并将状态设置为 `Terminating`。
- 该资源的控制器会 Watch 到资源发生了 Update 事件，进而来完成一系列预删除操作，最后将 `finalizers` 字段删除；
- Kube-apiserver 发现该资源 `finalizers` 字段 为空，直接删除。

所以要想使用 Finalizers 还需结合该资源的控制器，控制器需要根据定义的 `finalizer` 字段来完成一些 pre-delete-hook 逻辑

## 删除策略

Kubernetes 也提供了删除策略：Orphan、Background、Foreground。可以控制对象删除

当使用 kubectl 命令或者调用 Kubernetes 删除 API 时都提供了删除选项

kubectl 通过`--cascade` 参数来设置删除策略， 如果不设置该参数，默认删除策略是 Background

```bash
$ kubectl delete --help
--cascade='background':
	Must be "background", "orphan", or "foreground". Selects the deletion cascading strategy for the dependents
	(e.g. Pods created by a ReplicationController). Defaults to background.
```

REST API 同样提供这三个选项

所以在使用 kubectl 和 API 来删除 Kubernetes 资源时需要注意下。

### Background

先删除属主对象，再删除附属对象。

在 Background 模式下，Kubernetes 会立即删除属主对象，之后 K8S 垃圾收集器会在后台删除其附属对象。

### Orphan

该删除策略表示不会自动删除它的附属对象，这些残留的依赖被称为原对象的孤儿对象。

K8S 会添加 Orphan Finalizer，即上面所说的其中一个默认 Finalizer，这样控制器在删除属主对象之后，会忽略附属资源。

因为该资源的控制器实现了 Orphan Finalizer，所以该资源的控制器会监听对象的更新事件并将它自己从它全部依赖对象的 `OwnerReferences` 数组中删除，与此同时会删除所有依赖对象中已

经失效的 `OwnerReferences` 并将 `OrphanFinalizer` 从 `Finalizers` 数组中删除。

通过 `OrphanFinalizer` 我们能够在删除一个 Kubernetes 对象时保留它的全部依赖，为使用者提供一种更灵活的办法来保留和删除对象。

### Foreground

先删除附属对象，再删除属主对象。

Kube-apiserver 先将对象的 `metadata.finalizers` 字段值设置为 `foregroundDeletion`，控制器需要主动处理 `foregroundDeletion` 的 `finalizers`。

在该模式下，对象首先进入“删除中” 状态，即会设置对象的 `deletionTimestamp` 字段并且对象的 `metadata.finalizers` 字段包含了值 “foregroundDeletion”，此时该对象依然存在，然后垃圾

收集器会删除该对象的所有依赖对象，垃圾收集器在删除了所有 “Blocking” 状态的依赖对象（指其子对象中 `ownerReference.blockOwnerDeletion=true` 的对象）之后，然后才会删除对象本

身。

此时有三种方式避免该对象处于删除阻塞状态：

- 是将依赖对象直接删除
- 将依赖对象自身的 `OwnerReferences` 中 owner 字段删除
- 将该依赖对象 `OwnerReferences` 字段中对应 owner 的 `BlockOwnerDeletion` 设置为 false

以上三个操作最终都是与属主对象切断联系，进而使得属主对象被删除。

## 总结

OwnerRefence 可以设置资源之间的属主关系，为级联删除做准备；

Finalizers 可以阻止资源被 Kube-apiserver 删除，进而可以自定义 Pre-delete-hook 达到预删除的效果；

删除策略使得级联删除更加灵活，使用者根据自身场景来选择不同的策略。

这三个功能在 K8S 删除机制中非常重要，也是相互作用，并不是起单一效果。无论是 K8S 内部还是开发者都频繁使用。