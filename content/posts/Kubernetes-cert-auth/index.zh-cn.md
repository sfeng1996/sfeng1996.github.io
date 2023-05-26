---
weight: 12
title: "Kubernetes 证书鉴权"
date: 2021-12-26T21:57:40+08:00
lastmod: 2021-12-26T16:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "k8s-cert-auth-home.png"

tags: ["Kubernetes-ops"]
categories: ["Kubernetes-ops"]

lightgallery: true
---

## 简介

[上一篇](https://www.sfernetes.com/kubernetes-cert/)  系统分析了 Kubernetes 集群中每个证书的作用和证书认证的原理。对于 Kube-apiserver，Kubelet 来说，它们都能提供 HTTPS 服务，Kube-apiserver、Kubelet 对于一个请求，既要认证也要鉴权。在 Kube-apiserver 中，鉴权也有多种方式：

- Node
- ABAC
- RBAC
- Webhook

在 TLS + RBAC 模式下，访问 Kube-apiserver 有三种方式：

- 证书 + RBAC(就是上一篇说到的那些证书)
- Node + RBAC( Kubelet 访问 Kube-apiserver 时)
- ServiceAccount + RBAC( Kubernetes 集群内 Pod 访问 Kube-apiserver ）

关于 RBAC 的内容不熟悉的可以参考[官网](https://kubernetes.io/zh-cn/docs/reference/access-authn-authz/rbac/)

## K8S 证书的 CN、O

RBAC 鉴权需要对 User 或者 Group 来绑定相应权限达到效果。Kubernetes 证书中的 *`CN`* 表示 User，*`O`* 表示 Group，看一个例子：

用 *`openssl`* 命令解析 kubelet 的客户端证书，kubelet 访问 Kube-apiserver 的时候就会用这个证书来认证，鉴权。

```bash
$ openssl x509 -noout -text -in kubelet-client-current.pem 
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number: 271895513527774644 (0x3c5f7876bd86db4)
    Signature Algorithm: sha256WithRSAEncryption
        Issuer: CN=kubernetes
        Validity
            Not Before: May 10 06:48:30 2023 GMT
            Not After : Apr 16 06:48:37 2123 GMT
				# 看这里
        Subject: O=system:nodes, CN=system:node:master-172-31-97-104
        Subject Public Key Info:
        .......
```

可以发现 Kubelet 的客户端证书的 *`O`* 是 *`system.nodes`*，*`CN`* 是 *`system:node:master-172-31-97-104` ，*所以在 Kubernetes 中，每个结点的 Kubelet 都被赋予 `*system:node:"结点名称"*` 的 User，且附属于 `*system.nodes*` 的 Group。 

Kubernetes RBAC 鉴权机制就是利用将权限绑定到 User 或者 Group，使得 User、Group 拥有对应权限，下面就看看 Kubernetes 如何 根据证书、ServiceAccount 鉴权的。

## Kubectl

Kubectl 使用 KubeConfig 与 Kube-apiserver 进行认证、鉴权。认证上一篇说过了，就是通过 TLS 认证。这里说鉴权，先看看 KubeConfig 的客户端证书 *`O`*、*`CN`*

使用 *`openssl`* 命令解析 KubeConfig 中 *`client-certificate-data`* 字段，查看 KubeConfig 客户端证书的 *`O`*、*`CN`*

```bash
$ cat /root/.kube/config | grep client-certificate-data: | sed 's/    client-certificate-data: //g' | base64 -d | openssl x509 -noout  -subject
# 结果
subject= /O=system:masters/CN=kubernetes-admin
```

可以发现 KubeConfig 客户端证书为 *`kubernetes-admin`* User 且属于 *`system:masters`*  Group。

*`system:masters`* 是 Kubernetes 内置的用户组，且 Kubernetes 集群中也包含许多**默认** ClusterRole、ClusterRolebinding，其中 *`cluster-admin`* 的 ClusterRolebinding 就将 *`cluster-admin`* 的 ClusterRole 绑定到 `*system:masters*` Group，这样 KubeConfig 就拥有权限来操作 Kube-apiserver 了。

```yaml
# cluster-admin ClusterRole 拥有所有资源的所有权限
$ kubectl get clusterrole cluster-admin -o yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  creationTimestamp: "2023-05-10T06:49:27Z"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: cluster-admin
  resourceVersion: "85"
  uid: 006af228-e6ef-43fa-a73f-ca0c109b13f0
rules:
- apiGroups:
  - '*'
  resources:
  - '*'
  verbs:
  - '*'
- nonResourceURLs:
  - '*'
  verbs:
  - '*'
-------------------------------------------------------------------

# cluster-admin ClusterRoleBinding 将 cluster-admin ClusterRole 绑定到 system:masters Group
$ kubectl get clusterrolebinding cluster-admin -o yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  creationTimestamp: "2023-05-10T06:49:27Z"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: cluster-admin
  resourceVersion: "147"
  uid: 980fbdff-6750-4957-b5fa-954a5013b192
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
	# clusterRole name
  name: cluster-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
	# Group name
  name: system:masters
```

经过上面的操作，Kubectl 就可以使用 KubeConfig 来操作 Kube-apiserver 了。

## Kube-scheduler、Kube-controller-manager

同样 Kube-scheduler、Kube-controller-manager 也是使用各自的 KubeConfig 来认证、鉴权。但是他们和 Kubectl 的 KubeConfig 不属于同一个用户、组。

使用 *`openssl`* 命令解析 Kube-scheduler 的 KubeConfig 中 *`client-certificate-data`* 字段，查看 KubeConfig 客户端证书的 *`O`*、*`CN`*

```bash
$ cat /etc/kubernetes/scheduler.conf | grep client-certificate-data: | sed 's/    client-certificate-data: //g' | base64 -d | openssl x509 -noout  -subject
# 结果
subject= /CN=system:kube-scheduler
```

可以发现 KubeConfig 客户端证书为 *`kubernetes-admin`* User 但是不属于某个 Group。

*`system:kube-scheduler`* 也是 Kubernetes 集群内部的设置的用户，Kubernetes 集群中也存在对应默认的 ClusterRole *`system:kube-scheduler`* 和 ClusterRoleBinding *`system:kube-scheduler`*。

```yaml
# system:kube-scheduler ClusterRole 拥有细分的权限
$ kubectl get clusterrole system:kube-scheduler -o yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  creationTimestamp: "2023-05-10T06:49:27Z"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-scheduler
  resourceVersion: "115"
  uid: b1ddf98c-bdb9-4d4d-9af3-9db1c97b038a
rules:
- apiGroups:
  - ""
  - events.k8s.io
  resources:
  - events
  verbs:
  - create
  - patch
  - update
- apiGroups:
  - coordination.k8s.io
  resources:
  - leases
  verbs:
  - create
- apiGroups:
  - coordination.k8s.io
  resourceNames:
  - kube-scheduler
  resources:
  - leases
  verbs:
  - get
  - update
- apiGroups:
  - ""
  resources:
  - endpoints
  verbs:
  - create
 .......
 # 一些更细致的权限
--------------------------------------------------------------------------

# system:kube-scheduler ClusterRoleBinding 将 system:kube-scheduler ClusterRole 绑定到 system:kube-scheduler User
$ kubectl get clusterrolebinding system:kube-scheduler -o yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  creationTimestamp: "2023-05-10T06:49:27Z"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-scheduler
  resourceVersion: "155"
  uid: a9b8a85e-bb5c-483c-a08e-51822ce84d7f
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
	# ClusterRole name
  name: system:kube-scheduler
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
	# User name
  name: system:kube-scheduler
```

可以发现 Kube-scheduler 权限并不是向 Kubectl 那样拥有所有资源的所有操作权限，即使是内部组件，基于最小权限原则，Kubernetes 依然会为这两个用户只绑定必要的权限。

Kube-controller-manager 和 Kube-scheduler 一样，只不过 Kube-controller-manager 的 User 是 *`system:kube-controller-manager`*，其默认的 ClusterRole、ClusterRoleBinding 名称不同而已，可以根据 Kube-scheduler 自行验证~

> `system:` 前缀是 Kubernetes 保留的关键字，用于描述内置的系统用户和系统用户组，在 Kube-apiserver 启动时，会默认为这些用户绑定好对应的权限，具体参考[官网](https://kubernetes.io/zh-cn/docs/reference/access-authn-authz/rbac/#core-component-roles)
> 

## Kubelet

Kubelet 同样也会访问 Kube-apiserver，Kubelet 使用其客户端证书与 Kube-apiserver 认证、鉴权。

使用 *`openssl`* 命令解析 Kubelet 客户端证书，查看证书的 *`O`*、*`CN`*

```bash
$ openssl x509 -noout  -subject -in /var/lib/kubelet/pki/kubelet-client-current.pem 
# 结果
subject= /O=system:nodes/CN=system:node:master-172-31-97-104
```

可以发现 Kubelet 客户端证书为 *`system:node:master-172-31-97-104`*  User 且属于 *`system:nodes`*  Group。

还是和上面一样，*`system:nodes`* 也是 Kubernetes 内置用户组，通过查看其默认的 ClusterRole、ClusterRoleBinding

```yaml
$ kubectl get clusterrolebinding system:node -o yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  creationTimestamp: "2023-05-10T06:49:27Z"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:node
  resourceVersion: "157"
  uid: 8ba46211-bdae-493f-8f5f-3386fe63ba29
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node
```

发现 *`system:node`* ClusterRoleBinding 并没有绑定 *`system:node:master-172-31-97-104`*  User 或者 *`system:nodes`*  Group。官方文档也有介绍：https://kubernetes.io/zh-cn/docs/reference/access-authn-authz/rbac/#core-component-roles

实际上 Kubernetes 现在基于 Node Authorizer 来限制`kubelet`只能读取和修改本节点上的资源，并不是使用 RBAC 来鉴权。为了获得节点鉴权器的授权，Kubelet 必须使用一个凭证以表示它在 `system:nodes` 组中，用户名为 `system:node:<nodeName>`。这个凭证就是从 Kubelet 客户端证书获取，也就是上面的 *`O`*、*`CN`*

> Node Authorizer 参考：https://kubernetes.io/zh-cn/docs/reference/access-authn-authz/node/
> 

## Kube-apiserver

前面都是在说其他组件访问 Kube-apiserver，然后 Kube-apiserver 对访问者进行授权，然而 Kube-apiserver 也会作为客户端去访问 Kubelet，例如：kubectl logs/exec，Kube-apiserver 都会去访问 Kubelet。Kubelet 作为服务端内部也是通过 TLS + RBAC 这种模式去认证、鉴权。

使用 *`openssl`* 命令解析 Kube-apiserver 客户端证书，查看证书的 *`O`*、*`CN`*

```bash
$ openssl x509 -noout  -subject -in /etc/kubernetes/pki/apiserver-kubelet-client.crt 
# 结果
subject= /O=system:masters/CN=kube-apiserver-kubelet-client
```

可以发现 Kube-apiserver 访问 Kubelet 客户端证书为 *`kube-apiserver-kubelet-client`*  User 且属于 *`system:masters`*  Group。

在 Kubectl 章节介绍了 *`system:masters`* 属于内置用户组，且默认拥有超级权限，所以 Kube-apiserver 可以去访问 Kubelet 操作资源。

## ServiceAccount

上面说的几种情况，都是根据 User 或者 Group 鉴别其是否拥有权限，ServiceAccount 和 User、Group 属于同一性质。

在 Kubernetes 集群内部，比如 Pod 需要访问 Kube-apiserver，就会使用其配置的 Service Account（没有配置，则使用默认) 与 Kube-apiserver 认证、鉴权。

通过一个例子来说明：

*`mysql`* 这个 Pod 配置 *`mysql-sa`* 这个 ServiceAccount

```yaml
# pod 部分 yaml

nodeName: master-172-31-97-104
  preemptionPolicy: PreemptLowerPriority
  priority: 0
  restartPolicy: Always
  schedulerName: default-scheduler
  securityContext: {}
	# serviceAccount 配置
  serviceAccount: mysql-sa
  serviceAccountName: mysql-sa
  terminationGracePeriodSeconds: 10
  tolerations:
  - effect: NoSchedule
    key: node-role.kubernetes.io/master
    operator: Exists
  - effect: NoExecute
    key: node.kubernetes.io/not-ready
    operator: Exists
    tolerationSeconds: 300
  - effect: NoExecute
    key: node.kubernetes.io/unreachable
    operator: Exists
    tolerationSeconds: 300
```

然后查看对应 Role，查看拥有的权限

```yaml
$ kubectl get role mysql-role -n test -o yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: mysql-role
  namespace: test
rules:
- apiGroups:
  - ""
  resources:
  - configmaps
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
- apiGroups:
  - ""
  resources:
  - events
  verbs:
  - create
  - patch
```

查看 RoleBinding，然后会发现将上面的 Role 与 Pod 的 ServiceAccount 绑定。

```yaml
$ kubectl get rolebinding mysql-role -n test -o yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: mysql-rolebinding
  namespace: test
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
	# role name
  name: mysql-role
subjects:
- kind: ServiceAccount
	# serviceAccount name
  name: mysql-sa
  namespace: test
```

这样 *`mysql-sa`* ServiceAccount 就拥有了 Configmmap，Event 这两个资源的所有权限。

所以当 Pod 内部去访问 Kube-apiserver，实际上 Kube-apiserver 是根据其 ServiceAccount 来鉴定其拥有的权限，而不是 User 或者 Group。

## 总结

上面的鉴权原理，可以下面这张图做个总结

![k8s-cert-auth](k8s-cert-auth.png "K8S 证书鉴权")

每个组件都代表着不同的 K8S 角色与 Kube-apiserver 鉴权。

到这里整个 Kubernetes 证书都讲解完了，包括认证、鉴权。掌握了 Kubernetes 组件之间的调用关系，以及双向 TLS 认证 就可以理清证书的作用和关系，同时还需掌握证书内容的 *`O`*、*`CN`*、*`SANS`* 等字段作用，才能明白 Kubernetes 是如何根据证书 + RBAC 进行访问授权的。

最后有兴趣可以使用二进制部署一个 Kubernetes 集群，通过手动签发证书，来加深理解~

## 引用

[Kubernetes 官方文档 Node Authorizer](https://kubernetes.io/zh-cn/docs/reference/access-authn-authz/node/)

[Kubernetes 官方文档 RBAC](https://kubernetes.io/zh-cn/docs/reference/access-authn-authz/rbac/)