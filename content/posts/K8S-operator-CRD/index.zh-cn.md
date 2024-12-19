---
weight: 52
title: "Operator - CRD 简介"
date: 2023-08-19T01:57:40+08:00
lastmod: 2023-08-19T01:57:40+08:00
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

从本篇文章开始讲解 [Operator](https://kubernetes.io/zh-cn/docs/concepts/extend-kubernetes/operator/) 相关内容，Operator 是 Kubernetes 的扩展软件。

**Operator 模式** 旨在记述（正在管理一个或一组服务的）运维人员的关键目标。 这些运维人员负责一些特定的应用和 Service，他们需要清楚地知道系统应该如何运行、如何部署以及出现问题时如何处理。

在 Kubernetes 上运行工作负载的人们都喜欢通过自动化来处理重复的任务。 Operator 模式会封装你编写的（Kubernetes 本身提供功能以外的）任务自动化代码。

Operator 即可以用来对 K8S 内置资源做一些处理，也可以处理开发者自定义的资源，即 [CRD(`Custom Resource Define`)](https://kubernetes.io/zh-cn/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/)。

CRD 是 Kubernetes（v1.7+）为提高可扩展性，让开发者去自定义资源的一种方式。下面就具体看看 CRD 的使用。

## 创建 CRD

要想在 K8S 集群中使用我们自定义的资源，第一步就需要定义好这个资源的一些规范，比如这个资源有哪些字段，字段类型是什么等，这个可以理解为 Mysql 的表结构。定义好资源规范后就需要注册到 K8S 集群中，表示 K8S 集群可以发布具体资源了，这一步可以理解为把 Mysql 的表结构创建出来。最后我们就可以创建、更新、删除真正的具体资源了，可以理解为向 Mysql 表中 CRUD 数据了。

把 CRD 比作为 Mysql 的表可能会更容易理解。下面看一个简单 CRD 定义：

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  # 名字必需与下面的 spec 字段匹配，并且格式为 '<名称的复数形式>.<组名>'
  name: crontabs.stable.example.com
spec:
  # 组名称，用于 REST API: /apis/<组>/<版本>
  group: stable.example.com
  # 列举此 CustomResourceDefinition 所支持的版本
  versions:
    - name: v1
      # 每个版本都可以通过 served 标志来独立启用或禁止
      served: true
      # 其中一个且只有一个版本必需被标记为存储版本
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                cronSpec:
                  type: string
                image:
                  type: string
                replicas:
                  type: integer
  # 可以是 Namespaced 或 Cluster
  scope: Namespaced
  names:
    # 名称的复数形式，用于 URL：/apis/<组>/<版本>/<名称的复数形式>
    plural: crontabs
    # 名称的单数形式，作为命令行使用时和显示时的别名
    singular: crontab
    # kind 通常是单数形式的驼峰命名（CamelCased）形式。你的资源清单会使用这一形式。
    kind: CronTab
    # shortNames 允许你在命令行使用较短的字符串来匹配资源
    shortNames:
    - ct
```

> 需要注意的是 v1.16 版本以后已经 GA 了，使用的是 v1 版本，之前都是 v1beta1，定义规范有部分变化，所以要注意版本变化。
>

将上面的 CustomResourceDefinition 保存到 `resourcedefinition.yaml` 文件，之后可以把它创建到 K8S 集群中：

```bash
kubectl apply -f resourcedefinition.yaml
```

创建成功后，表示 K8S 集群中存在 CronTab 类型的定义了，也就是 Kube-apiserver 注册了一个新的 API：

```bash
/apis/stable.example.com/v1/namespaces/*/crontabs/...
```

此端点 URL 自此可以用来创建和管理定制对象。创建端点的操作可能需要几秒钟。你可以监测你的 CustomResourceDefinition 的 `Established` 状况变为 true。

## 创建具体资源对象

在创建了 CustomResourceDefinition 对象之后，你可以创建具体资源对象（Custom Objects）。具体资源对象可以包含定制字段。在下面的例子中，在 `Kind` 为 `CronTab` 的定制对象中，设置了`cronSpec` 和 `image` 定制字段。`CronTab` 来自你在上面所创建的 CRD 的规约。

将下面的 YAML 保存到 `my-crontab.yaml`：

```yaml
apiVersion: "stable.example.com/v1"
kind: CronTab
metadata:
  name: my-new-cron-object
spec:
  cronSpec: "* * * * */5"
  image: my-awesome-cron-image
```

执行创建命令：

```bash
kubectl apply -f my-crontab.yaml
```

现在就可以管理这个 Crontab 资源了

```bash
kubectl get crontab
# 也可以使用简写名称
kubectl get ct
```

输出如下：

```bash
NAME                 AGE
my-new-cron-object   6s
```

使用 kubectl 时，资源名称是大小写不敏感的，而且你既可以使用 CRD 中所定义的单数形式或复数形式，也可以使用其短名称：

```bash
kubectl get ct -o yaml
```

可以看到输出中包含了你创建定制对象时在 YAML 文件中指定的定制字段 `cronSpec` 和 `image`：

```yaml
apiVersion: v1
items:
- apiVersion: stable.example.com/v1
  kind: CronTab
  metadata:
    annotations:
      kubectl.kubernetes.io/last-applied-configuration: |
        {"apiVersion":"stable.example.com/v1","kind":"CronTab","metadata":{"annotations":{},"name":"my-new-cron-object","namespace":"default"},"spec":{"cronSpec":"* * * * */5","image":"my-awesome-cron-image"}}        
    creationTimestamp: "2021-06-20T07:35:27Z"
    generation: 1
    name: my-new-cron-object
    namespace: default
    resourceVersion: "1326"
    uid: 9aab1d66-628e-41bb-a422-57b8b3b1f5a9
  spec:
    cronSpec: '* * * * */5'
    image: my-awesome-cron-image
kind: List
metadata:
  resourceVersion: ""
  selfLink: ""
```

可以看出来操作自定义资源和 K8S 内置资源的方式其实是一样的，只不过自定义资源需要多一步注册资源。

## 总结

CRD 在 K8S 二开领域使用频率非常高，要想扩展 K8S 的 API，使用 CRD + Operator 是一种非常常见的方式。

上面只是讲解了 CRD 的简答使用，还有很多高级的使用方法没有说，可以看看[官方文档](https://kubernetes.io/zh-cn/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/)，里面有详细的阐述。

有了 CRD，只是在 ETCD 中存储了这个数据而已，实际上并没有带来任何功能上的扩展，所以需要一个控制器来对这个资源做一些逻辑处理才能真正实现效果。