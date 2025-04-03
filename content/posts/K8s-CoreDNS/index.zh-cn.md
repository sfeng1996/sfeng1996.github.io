---
weight: 59
title: "CoreDNS 的使用和原理"
date: 2025-03-28T01:57:40+08:00
lastmod: 2025-03-28T01:57:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "linux.png"

tags: ["Kubernetes-dev"]
categories: ["Kubernetes-dev"]

lightgallery: true
---

在使用 K8S 过程中，Pod 之间通过 Pod ip 访问，那么 Pod 重启后肯定没法通信了，因为 Pod 每次重启后，ip 会自动更新。那么也可以给 Pod 创建一个 SVC，通过 SVC **ClusterIP** 去访问，显然这种做法也需要在创建 SVC 的时候去固定 **ClusterIP**，这种做法也不是太优雅。既然使用 ip 地址通信不可取，就可以通过使用**域名**进行 Pod 间通信，对于无状态的 Pod，可以通过 SVC Domain 去访问，那么对于有状态的 Pod，大部分通过 **Headless** SVC Domain 访问。

使用域名就需要一个 DNS，用来解析 K8S 里面各个域名，这里介绍 K8S 中默认使用的 [CoreDNS](https://coredns.io/)

## 系统环境

本篇文章实验环境如下：

**系统**：`openEuler22.03 LTS`

**内核**：`5.10.0-60.18.0.50.oe2203.aarch64`

**Kubernetes**：`v1.28.8`

**CoreDNS**：`v1.10.1`

## K8S 如何使用 CoreDNS

### CoreDNS 部署形态

CoreDNS 通过 Deployment 部署在 K8S 集群 `kube-system` 命名空间中

```bash
$ kubectl get pods -n kube-system | grep coredns
coredns-59d6ff599b-css8q                        1/1     Running   0          46h
coredns-59d6ff599b-gq2lm                        1/1     Running   0          46h
```

### CoreDNS 域名记录

CoreDNS 会为哪些域名创建域名解析记录呢？在 K8S 中，CoreDNS 会监听三类 K8S 资源事件，分别是 **Service、Statefulset、Pod**，并会为这三类资源自动创建、更新、删除相应的域名记录。这里都以 **A/Cname** 记录说明：

- **Service**：CoreDNS 生成 K8S Service 域名规则如：`<svc-name>.<namespace-name>.svc.<cluster-domain>`
- **StatefulSet**：对于 StatefulSet，CoreDNS 会为其包含的每一个 Pod 创建 A 记录，域名命名规则如：`<pod-name>.<svc-name>.<namespace-name>.svc.<cluster-domain>`
- **Pod**：CoreDNS 只会为一种 Pod 创建域名记录，记录类型为 A：Pod 配置了 **hostName** 和 **subdomain**，并且该 Pod 的 **subdomain** 与该 Pod 关联的 Service 名称相同时，域名命名规则与 StatefulSet 的 Pod 类似。`<host-name>.<svc-name>.<namespace-name>.svc.<cluster-domain>`

### 实验说明

先通过实验说明在 K8S 中使用**域名**访问的效果，这里在同一个命名空间下部署两个 Deployment ，其对应的 Pod 分别为：`pod-a、pod-b`，以及创建对应的 Service：`svc-a，svc-b`。

```bash
$ kubectl get pods
NAME                     READY   STATUS    RESTARTS        AGE
pod-a-55fcf5456c-86mw6   1/1     Running   0               10m
pod-b-7c5d9c86b8-s7mvn   1/1     Running   1 (4h20m ago)   21h
$ kubectl get svc | grep svc
svc-a        ClusterIP   10.233.56.44   <none>        80/TCP    21h
svc-b        ClusterIP   10.233.98.21   <none>        80/TCP    21h
```

进入 `pod-a` 访问 `svc-b`，可以正常解析出 `svc-b` 的 `ip (10.233.98.21)`

```bash
$ kubectl exec -it pod-a-55fcf5456c-86mw6 -- sh
/ # ping svc-b
PING svc-b (10.233.98.21): 56 data bytes
```

在 Kubernetes 中，Service 域名的全称格式为：`<service-name>.<namespace-name>.svc.<cluster-domain>` ，

> 如果 pod-b 在 `test namespace` 下，那么 pod-a 去访问 svc-b，就需要通过 `svc-b.test` 访问。
>

查看 pod-a 内的 `/etc/resolv.conf` 文件，里面有 `nameserver、search、options` 三个配置项。

```bash
$ cat /etc/resolv.conf 
nameserver 10.233.0.10
search default.svc.cluster.local svc.cluster.local cluster.local novalocal
options ndots:5
```

**nameserver** 表示选择 `nameserver 10.233.0.3` 进行解析，然后在解析域名的时候用域名依次带入 **search** 中每个搜索域，进行 DNS 查找，直到解析完成，例如解析 `svc-b`

会依次对 `svc-b.default.svc.cluster.local → svc-b.svc.cluster.local → svc-b.cluster.local → svc-b.novalocal`，直到找到记录为止。

那么根据 K8S 中 Service 完整域名格式规则，解析 svc-b 第一次匹配 `svc-b.default.svc.cluster.local` 即可直接完成 DNS 解析请求。

当然访问 `svc-b.default` 就需要 `svc-b.default.default.svc.cluster.local → svc-b.default.svc.cluster.local` 查早两次。

所以根据以上说明，要访问 pod-b，我们通过访问 `svc-b、svc-b.default、svc-b.default.svc、svc-b.default.svc.cluster.local` 都可以，区别在解析效率不同。

显然访问 svc-b 的效率最高，因为只有访问 svc-b 只需要一次查询即可，其他都至少需要两次，通过抓包实验验证：

在 pod-a 内访问 svc-b，同时在 pod-a 内抓 dns 请求报文

> 这里实验不能使用 `nslookup` 去测试域名解析，因为 `nslookup` 不管是否解析到，都会依次匹配所有 **search 域**，达不到上述说明的现象
>

```bash
$ kubectl exec -it pod-a-55fcf5456c-86mw6 -- ping svc-b
PING svc-b (10.233.98.21): 56 data bytes

$ tcpdump -i eth0 udp dst port 53
14:01:32.932652 IP master-172-29-235-101.56791 > 10.233.0.10.domain: 13290+ A? svc-b.default.svc.cluster.local. (49)
14:01:32.932777 IP master-172-29-235-101.56791 > 10.233.0.10.domain: 13530+ AAAA? svc-b.default.svc.cluster.local. (49)
```

显然在 pod-a `ping svc-b` 能够解析，同时在 pod-a 抓到的 dns 报文就只查找了 `svc-b.default.svc.cluster.local.` 就返回了记录。

> 为什么每条报文显示的域名最后多一个点 “.”，这是绝对域名，即后面没有 search 域了。在后文会详细说明
>

再测试在 pod-a 内访问 `svc-b.default`

```bash
$ kubectl exec -it pod-a-55fcf5456c-86mw6 -- ping svc-b.default
PING svc-b (10.233.98.21): 56 data bytes

$  tcpdump -i eth0 udp dst port 53
14:07:09.101153 IP master-172-29-235-101.50794 > 10.233.0.10.domain: 1230+ A? svc-b.default.default.svc.cluster.local. (57)
14:07:09.101286 IP master-172-29-235-101.50794 > 10.233.0.10.domain: 1470+ AAAA? svc-b.default.default.svc.cluster.local. (57)
14:07:09.102162 IP master-172-29-235-101.41404 > 10.233.0.10.domain: 41158+ A? svc-b.default.svc.cluster.local. (49)
14:07:09.102223 IP master-172-29-235-101.41404 > 10.233.0.10.domain: 41398+ AAAA? svc-b.default.svc.cluster.local. (49)
```

通过报文可以发现访问 `svc-b.default` 查找了两次才返回记录。

依次通过实验访问 `svc-b.default.svc、svc-b.default.svc.cluster.local`，会发现效果和上述说明是一致的。

> 这里抓包有个小技巧，通常 pod 内可能没有 `tcpdump` 命令，我们可以通过 `nsenter` 命令进入这个 pod 的**网络命名空间**去抓包，可参考 [nsenter 使用](https://sfeng1996.github.io/k8s-network-debug/)
>
>
> ```bash
> # 1、找到容器ID，并打印它的NS ID
> $ docker inspect --format "{{.State.Pid}}"  16938de418ac
> # 2、进入此容器的网络 Namespace
> $ nsenter -n -t  54438
> # 3、抓DNS包
> $ tcpdump -i eth0 udp dst port 53
> ```
>

除了 **nameserver、search** 还有个 **options ndots:5** 配置。

**ndots: 5** 表示：如果查询的域名包含的点 “.”，不到 5 个，那么根据 search 进行 DNS 查找，将使用非完全限定名称（或者叫绝对域名），如果你查询的域名包含点数大于等于 5，那么 DNS 查询，默认会使用绝对域名进行查询。举例来说：

如果我们请求的域名是 `a.b.c.d.e`，这个域名中有 4 个点，那么容器中进行 DNS 请求时，会使用非绝对域名进行查找，使用非绝对域名，会按照 `/etc/resolv.conf` 中的 **search** 域，走一遍追加匹配，即按照 `a.b.c.d.e.default.svc.cluster.local. —> a.b.c.d.e.svc.cluster.local. —> a.b.c.d.e.cluster.local.` 查询。直到找到为止。如果走完了 **search** 域还找不到，则使用 **a.b.c.d.e.** ，作为绝对域名进行 DNS 查找。我们同样通过抓包验证：

**域名中点数少于 5 个**

在 pod-a 中 `ping a.b.c.d.e`，并在 pod-a 中抓 DNS 请求报文

```bash
$ kubectl exec -it pod-a-55fcf5456c-86mw6 -- ping a.b.c.d.e
ping: bad address 'a.b.c.d.e'
command terminated with exit code 1

# 在 pod-a 内抓包
$ tcpdump -i eth0 udp dst port 53
dropped privs to tcpdump
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
16:51:44.406391 IP master-172-29-235-101.50760 > 10.233.0.10.domain: 16740+ A? a.b.c.d.e.default.svc.cluster.local. (53)
16:51:44.406585 IP master-172-29-235-101.50760 > 10.233.0.10.domain: 16930+ AAAA? a.b.c.d.e.default.svc.cluster.local. (53)
16:51:44.407497 IP master-172-29-235-101.58546 > 10.233.0.10.domain: 48953+ A? a.b.c.d.e.svc.cluster.local. (45)
16:51:44.407557 IP master-172-29-235-101.58546 > 10.233.0.10.domain: 49163+ AAAA? a.b.c.d.e.svc.cluster.local. (45)
16:51:44.408269 IP master-172-29-235-101.35041 > 10.233.0.10.domain: 37535+ A? a.b.c.d.e.cluster.local. (41)
16:51:44.408317 IP master-172-29-235-101.35041 > 10.233.0.10.domain: 37745+ AAAA? a.b.c.d.e.cluster.local. (41)
16:51:44.408852 IP master-172-29-235-101.54335 > 10.233.0.10.domain: 31079+ A? a.b.c.d.e.novalocal. (37)
16:51:44.408895 IP master-172-29-235-101.54335 > 10.233.0.10.domain: 31289+ AAAA? a.b.c.d.e.novalocal. (37)
16:51:44.609628 IP master-172-29-235-101.34686 > 10.233.0.10.domain: 51168+ A? a.b.c.d.e. (27)
16:51:44.609730 IP master-172-29-235-101.34686 > 10.233.0.10.domain: 51298+ AAAA? a.b.c.d.e. (27)
```

可以通过报文发现请求走了一遍 **search** 域，查不到才按照绝对域名去请求。

**域名中点数 >=5 个**

在 pod-a 内 `ping a.b.c.d.e.f`，并在 pod-a 中抓 DNS 请求报文

```bash
$ kubectl exec -it pod-a-55fcf5456c-86mw6 -- ping a.b.c.d.e.f
ping: bad address 'a.b.c.d.e.f'
command terminated with exit code 1

# 在 pod-a 内抓包
$ tcpdump -i eth0 udp dst port 53
17:05:08.735240 IP master-172-29-235-101.40782 > 10.233.0.10.domain: 40059+ A? a.b.c.d.e.f. (29)
17:05:08.735366 IP master-172-29-235-101.40782 > 10.233.0.10.domain: 40189+ AAAA? a.b.c.d.e.f. (29)
```

发现没有走 **search** 域，直接查询 `a.b.c.d.e.f`

那么如果在 pod 内访问公网域名呢，下面再 `pod-a` 内去 `ping [www.baidu.com](http://www.baidu.com)` ，注意这次去 **CoreDNS pod** 内抓包

```bash
$ kubectl exec -it pod-a-55fcf5456c-86mw6 -- ping www.baidu.com.
PING www.baidu.com. (153.3.238.127): 56 data bytes
^[[6~64 bytes from 153.3.238.127: seq=0 ttl=49 time=28.182 ms
64 bytes from 153.3.238.127: seq=1 ttl=49 time=28.052 ms
64 bytes from 153.3.238.127: seq=2 ttl=49 time=28.089 ms

$ tcpdump -i eth0 udp dst port 53
dropped privs to tcpdump
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
11:43:51.289724 IP 101.76.9.141.42524 > master-172-29-235-101.domain: 9433+ A? www.baidu.com.default.svc.cluster.local. (57)
11:43:51.289782 IP 101.76.9.141.42524 > master-172-29-235-101.domain: 9633+ AAAA? www.baidu.com.default.svc.cluster.local. (57)
11:43:51.290882 IP 101.76.9.141.35512 > master-172-29-235-101.domain: 50669+ A? www.baidu.com.svc.cluster.local. (49)
11:43:51.290921 IP 101.76.9.141.35512 > master-172-29-235-101.domain: 50889+ AAAA? www.baidu.com.svc.cluster.local. (49)
11:43:51.291609 IP 101.76.9.141.43437 > master-172-29-235-101.domain: 15680+ A? www.baidu.com.cluster.local. (45)
11:43:51.291637 IP 101.76.9.141.43437 > master-172-29-235-101.domain: 15860+ AAAA? www.baidu.com.cluster.local. (45)
11:43:51.292248 IP 101.76.9.141.49269 > master-172-29-235-101.domain: 590+ A? www.baidu.com.novalocal. (41)
11:43:51.292277 IP 101.76.9.141.49269 > master-172-29-235-101.domain: 750+ AAAA? www.baidu.com.novalocal. (41)
11:43:51.294325 IP 101.76.9.141.50658 > master-172-29-235-101.domain: 40138+ A? www.baidu.com. (31)
11:43:51.294354 IP 101.76.9.141.50658 > master-172-29-235-101.domain: 40298+ AAAA? www.baidu.com. (31)
11:43:51.294651 IP master-172-29-235-101.43802 > 10.255.255.88.domain: 58279+ AAAA? www.baidu.com. (31)
```

通过报文发现即使在 pod 内去访问外网，也是去走一遍 **search** 域，但是最终没有返回记录，所以 CoreDNS 转发至 `10.255.255.88`，最终 `10.255.255.88` 查询到记录并返回。

CoreDNS 如果自身没有查询到记录，会将请求转发至自身 pod 所在的宿主机的 `/etc/resolv.conf` 里的 **nameserver**，所以这个 `10.255.255.88` 就是 CoreDNS pod 所在宿主机的 `/etc/resolv.conf` 的 **nameserver**。通过在 coredns configmap 配置。

```yaml
apiVersion: v1
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
```

> 这里抓包如果在 pod-a 内抓包是抓不到 CoreDNS 请求转发报文的
>

## 优化 DNS 请求

根据以上说明，在 K8S 中很有必要通过以下方式去优化 DNS 请求。

### 使用绝对域名

只要域名最后有一个点 “.” 就是**绝对域名**，这样就会避免走 **search 域**进行匹配，即使请求的域名的点数小于 **ndots** 配置的数量。

我们在 pod-a 中分别访问 `svc-a.  svc-a.default.svc.cluster.local.`

```bash
# 访问 svc-a.
$ kubectl exec -it pod-a-55fcf5456c-86mw6 -- ping svc-a.
ping: bad address 'svc-a.'
command terminated with exit code 1

# 访问 svc-a.default.svc.cluster.local.
$ kubectl exec -it pod-a-55fcf5456c-86mw6 -- ping svc-a.default.svc.cluster.local.
PING svc-a.default.svc.cluster.local. (10.233.56.44): 56 data bytes

# 不管域名中点数量是否小于 ndots 数量，都直接请求，不走 search 域
$ tcpdump -i eth0 udp dst port 53
17:15:19.893559 IP master-172-29-235-101.52840 > 10.233.0.10.domain: 1736+ A? svc-a. (23)
17:15:19.893695 IP master-172-29-235-101.52840 > 10.233.0.10.domain: 1866+ AAAA? svc-a. (23)

17:25:42.833206 IP master-172-29-235-101.33267 > 10.233.0.10.domain: 56414+ A? svc-a.default.svc.cluster.local. (49)
17:25:42.833325 IP master-172-29-235-101.33267 > 10.233.0.10.domain: 56634+ AAAA? svc-a.default.svc.cluster.local. (49)
```

上述报文表明，不管域名中点数量是否小于 **ndots** 数量，都直接请求，不走 **search** 域。所以在 K8S 中我们尽量采用绝对域名去请求，防止出现 DNS 请求浪费现象。

### 配置特定 ndots

大部分人使用往往并太会用这种绝对域名的方式，有谁请求 [www.baidu.com](http://www.baidu.com) 的时候，还写成 `wwww.baidu.com.` 呢？

那么为了避免多次请求的情况，可以根据域名的点数来自定义 **ndots** 数量，默认每个 pod 里的 **ndots** 配置为 5。

> 因为 K8S 内部域名的规则保证域名至少 4 个点，Kubernetes 为了保证内部域名优先走内部的 DNS，所以默认设置 **ndots** 为 5
>

可以在 pod yaml 去定义该 pod 的 **ndots** 数量。

```yaml
apiVersion: v1
kind: Pod
metadata:
  namespace: default
  name: dns-example
spec:
  containers:
    - name: test
      image: nginx
  dnsConfig:
    options:
      - name: ndots
        value: "1"
```

### 使用 NodeLocalDNS

`NodeLocal DNSCache` 是一套 DNS 本地缓存解决方案。**NodeLocal DNSCache 通过在集群节点上运行一个 DaemonSet 来提高集群 DNS 性能和可靠性，**下次详细介绍下使用和原理。

## K8S DNS 策略

K8S 在创建具体 Pod 时提供四种 DNS 策略，可自定义配置，默认为 **ClusterFirst**

### None

None 表示不设置 DNS 策略，这种设置一般用于自定义 DNS 配置的场景，即通过在 Pod 里定义 `dnsConfig` 字段自定义该 Pod 的 DNS 策略，达到自定义 DNS 的目的。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pod-a
spec:
  selector:
    matchLabels:
      app: pod-a
  template:
    metadata:
      labels:
        app: pod-a
    spec:
      containers:
      - image: nginx:1.22.1
        command: ["sleep", "60000"]
        name: nginx
        ports:
        - containerPort: 80
      dnsPolicy: Default
      dnsConfig:
        nameservers:
        - 1.1.1.1
        searches:
        - test.svc.cluster.local
        - my.dns.search.suffix
        options:
        - name: ndots
          value: "2"
        - name: edns0
```

以上 Deployment 定义将 `dnsPolicy` 设置为 `None`，且通过 `dnsConfig` 字段自定义的 DNS 的相关配置，包括解析的 **nameserver、search、ndots**。创建该 Deployment，发现该 Pod 里的 `/etc/resolv.conf` 文件和定义的一致。

```bash
$ kubectl exec -it pod-a-7bddb79ddd-gd8kl -- cat /etc/resolv.conf
nameserver 1.1.1.1
search test.svc.cluster.local my.dns.search.suffix
options ndots:2 edns0
```

### Default

> 虽然 **Defaul**t 策略名字是 “Default”，但是并不是 K8S 默认提供的策略
>

Pod 里面的 DNS 配置继承了宿主机上的 DNS 配置。这种说法不准确。其实 **Default** 策略是让节点上的 Kubelet 决定使用哪种 DNS 策略。而 Kubelet 默认就是使用节点上的 `/etc/resolv.conf` 。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pod-a
spec:
  selector:
    matchLabels:
      app: pod-a
  template:
    metadata:
      labels:
        app: pod-a
    spec:
      nodeName: master-172-29-235-101
      containers:
      - image: nginx:1.22.1
        command: ["sleep", "60000"]
        name: nginx
        ports:
        - containerPort: 80
      dnsPolicy: Default
```

该 Deployment 设置 DNS 策略为 **Default**，创建后查看 Pod `/etc/resolv.conf` 文件发现与该 Pod 所在节点的 `/etc/resolv.conf` 文件内容一致。

```bash
# 查看宿主机 /etc/resolv.conf
$ cat /etc/resolv.conf 
# Generated by NetworkManager
search novalocal
nameserver 10.255.255.88
nameserver 10.255.254.88

# 查看 pod /etc/resolv.conf
$ kubectl exec -it  pod-a-57bff577cb-l9ld7 -- cat /etc/resolv.conf
nameserver 10.255.255.88
nameserver 10.255.254.88
search novalocal
```

> 当然 Kubelet 可以通过配置灵活配置使用哪个文件，即通过 `--resolv-conf=/etc/resolv.conf` 来决定你的 DNS 解析文件地址。
>

### ClusterFirst

这种策略是默认的 DNS 策略，即在 yaml 定义中不配置 `dnsPolicy` 字段，K8S 默认使用 **ClusterFirst** 来解析域名。表示 Pod 使用集群中配置的 DNS 服务，如果集群部署了 CoreDNS，那么就使用 CoreDNS 来解析。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pod-a
spec:
  selector:
    matchLabels:
      app: pod-a
  template:
    metadata:
      labels:
        app: pod-a
    spec:
      nodeName: master-172-29-235-101
      containers:
      - image: nginx:1.22.1
        command: ["sleep", "60000"]
        name: nginx
        ports:
        - containerPort: 80
```

创建后查看 Pod `/etc/resolv.conf` 文件发现配置使用 CoreDNS

```bash
$ kubectl exec -it pod-a-55fcf5456c-7nnlf -- cat /etc/resolv.conf 
nameserver 10.233.0.10
search default.svc.cluster.local svc.cluster.local cluster.local novalocal
options ndots:5
```

`10.233.0.10` 实际上就是 CoreDNS 的 **Service ClusterIP**

### ClusterFirstWithHostNet

如果 Pod 使用 **HostNetwork** 模式部署，那么该 Pod 的网络就是和宿主机共享，同时该 Pod 的 DNS 策略也会被强制转为 **Default**，即继承 Kubelet 配置的 DNS 解析文件。

但是该 Pod 还需要访问集群内的服务，那么就还需要使用 CoreDNS 来解析，那么就需要将 `dnsPolicy` 设置为 **ClusterFirstWithHostNet**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pod-a
spec:
  selector:
    matchLabels:
      app: pod-a
  template:
    metadata:
      labels:
        app: pod-a
    spec:
      nodeName: master-172-29-235-101
      containers:
      - image: nginx:1.22.1
        command: ["sleep", "60000"]
        name: nginx
        ports:
        - containerPort: 80
      hostNetwork: true
```

以上 Deployment 开启了 **HostNetwork** 模式，发现该 Pod `/etc/resolv.conf` 与宿主机内容一致。

```bash
# 与宿主机 /etc/resolv.conf 内容一致
$ kubectl exec -it pod-a-7b7cfc64fd-sbg8w -- cat /etc/resolv.conf 
nameserver 10.255.255.88
nameserver 10.255.254.88
search novalocal
```

将上述 Deployment `dnsPolicy` 改为 **ClusterFirstWithHostNet**，发现 Pod 就使用了 **ClusterFirst** 的策略了。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pod-a
spec:
  selector:
    matchLabels:
      app: pod-a
  template:
    metadata:
      labels:
        app: pod-a
    spec:
      nodeName: master-172-29-235-101
      containers:
      - image: nginx:1.22.1
        command: ["sleep", "60000"]
        name: nginx
        ports:
        - containerPort: 80
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
```

进入 Pod 后发现使用 **ClusterFirst** 的策略

```bash
kubectl exec -it pod-a-6d4f778975-h46jh -- cat /etc/resolv.conf 
nameserver 10.233.0.10
search default.svc.cluster.local svc.cluster.local cluster.local novalocal
options ndots:5
```

## 总结

以上详细讲解了在 K8S 中如何使用 CoreDNS，并通过实验抓包分析了其原理，以上实验基本覆盖了大部分使用场景。

当然在使用的时候，CoreDNS 和 K8S 还提供了灵活的配置供开发者和运维去灵活调整，以便兼容各种复杂场景。

CoreDNS 可以在 configmap 中配置针对于某个域名的 **nameserver**、以及配置多个 **host**。这样创建 pod 时，默认这些配置都会生效。

如果有些 pod 需要个性化的解析需求，就不能放在 CoreDNS 配置，因为会全局生效。那么可以在 pod 定义中配置 `dnsConfig` 字段，支持丰富的配置，例如 **nameserver、ndots、search** 等。

所以要想灵活使用 DNS，需要全面了解 CoreDNS 和 K8S 相关 DNS 配置的使用和原理。