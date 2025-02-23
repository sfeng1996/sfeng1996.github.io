---
weight: 42
title: "K8S 探针原理"
date: 2024-11-19T01:57:40+08:00
lastmod: 2024-11-19T02:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "k8s-dev.jpg"

tags: ["Kubernetes-ops"]
categories: ["Kubernetes-ops"]

lightgallery: true
---

## K8S 探针的背景

Kubernetes 可以对业务进行故障自愈，即针对运行异常的 Pod 进行重启。那么 K8S 是如何认定 Pod 是否异常呢？

Kubelet 组件根据 Pod 中容器退出状态码判定 Pod 是否异常，然后重启 Pod，进而达到故障自愈的效果。但是有些复杂场景，这种判定 Pod 异常的机制就无法满足了。

例如，Pod 中容器进程依然存在，但是容器死锁了，那么服务肯定是异常了，但是这时候利用上述异常检测机制就无法认定 Pod 异常了，从而无法重启 Pod。

这时候就需要利用 K8S 中的探针检测机制了，探针检测机制的意思是 Kubelet K8S 中有三种探针：

- **livenessProbe**：存活探针，即探测容器是否运行、存活；
- **readinessProbe**：就绪探针，探测容器是否就绪，是否能够正常提供服务了；
- **startupProbe**：启动探针，探测容器是否启动。

下面针对以上三种探针展开说下每个探针的使用场景、作用、使用方式。

## 探针原理

K8S 中探针的原理，实际上就是利用业务服务自身提供的健康检查接口，Kubelet 根据策略去探测该接口。

探针定义在 `pod.spec.containers` 字段中，例如下面是一个 **livenessProbe** 例子：

```yaml
apiVersion: v1
kind: Pod
metadata:
  labels:
    test: liveness
  name: liveness-exec
spec:
  containers:
  - name: liveness
    image: registry.k8s.io/busybox
    args:
    - /bin/sh
    - -c
    - touch /tmp/healthy; sleep 30; rm -f /tmp/healthy; sleep 600
    livenessProbe:
      exec:
        command:
        - cat
        - /tmp/healthy
      initialDelaySeconds: 5
      periodSeconds: 5
```

在这个配置文件中，可以看到 Pod 中只有一个 `Container`。 `periodSeconds` 字段指定了 Kubelet 应该每 5 秒执行一次存活探测。 `initialDelaySeconds` 字段告诉 Kubelet 在执行第一次探测前应该等待 5 秒。 Kubelet 在容器内执行命令 `cat /tmp/healthy` 来进行探测。 如果命令执行成功并且返回值为 0，Kubelet 就会认为这个容器是健康存活的。 如果这个命令返回非 0 值，Kubelet 会根据 pod `restartPolicy` 决定是否杀死这个容器并重新启动它。

### restartPolicy

Kubelet 在知道容器异常后，是根据 `restartPolicy` 字段来决定如何操作。

在 Pod 的 `spec` 中有一个 `restartPolicy` 字段，如下：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: xxx
spec:
  restartPolicy: Always
  ...
```

**restartPolicy** 的值有三个：

**Always**：只要 container 退出就重启，即使它的退出码为 0（即成功退出）

**OnFailure**：如果 container 的退出码不是 0（即失败退出），就重启

**Never**：container 退出后永不重启

默认值为 **Always**

所谓 container 的退出码，就是 container 中进程号为 1 的进程的退出码。每个进程退出时都有一个退出码，我们常见的提示 `exit 0` 表示退出码为 0（即成功退出）。

举个例子：shell 命令 `cat /tmp/file`，如果文件 `/tmp/file` 存在，则该命令（进程）的退出码为 0。

> **注意 1：**虽然 `restartPolicy` 字段是 pod 的配置，但是其实是作用于 pod 的 container，换句话说，不应该叫 pod 的重启策略，而是叫 container 的重启策略；pod 中的所有 container 都适用于这个策略。
>
>
> **注意 2：**重启策略适用于 pod 对象中的所有容器，首次需要重启的容器，将在其需要时立即进行重启，随后再次需要重启的操作将由 Kubelet 延迟一段时间后进行，且反复的重启操作的延迟时长为10s，20s，40s，80s，160s，300s，300s 是最大延迟时长。
>

### 探针机制

上面例子使用 EXEC 执行命令的方式来探测服务，同样还支持 HTTP、TCP、GRPC 协议这三种探测的方式，使用方式和上面例子类似，具体可参考 [kubernetes 官网](https://kubernetes.io/zh-cn/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)

使用探针来检查容器有四种不同的方法。 每个探针都必须准确定义为这四种机制中的一种：

- **`exec`** 在容器内执行指定命令。如果命令退出时返回码为 0 则认为诊断成功。
- **`grpc`** 使用 [gRPC](https://grpc.io/) 执行一个远程过程调用。 目标应该实现  [gRPC 健康检查](https://grpc.io/grpc/core/md_doc_health-checking.html)。 如果响应的状态是 "SERVING"，则认为诊断成功。
- **`httpGet`** 对容器的 IP 地址上指定端口和路径执行 HTTP `GET` 请求。如果响应的状态码大于等于 200 且小于 400，则诊断被认为是成功的。
- **`tcpSocket`** 对容器的 IP 地址上的指定端口执行 TCP 检查。如果端口打开，则诊断被认为是成功的。 如果远程系统（容器）在打开连接后立即将其关闭，这算作是健康的。

> 注意： 和其他机制不同，`exec` 探针的实现涉及每次执行时创建/复制多个进程。 因此，在集群中具有较高 pod 密度、较低的 `initialDelaySeconds` 和 `periodSeconds` 时长的时候， 配置任何使用 exec 机制的探针可能会增加节点的 CPU 负载。 这种场景下，请考虑使用其他探针机制以避免额外的开销。
>

### 探针参数

上面例子发现探针配置中有几个配置参数，可以使用这些字段精确地控制启动、存活和就绪检测的行为：：

- **initialDelaySeconds**：容器启动后要等待多少秒后才启动启动、存活和就绪探针。 如果定义了启动探针，则存活探针和就绪探针的延迟将在启动探针已成功之后才开始计算。 如果 `periodSeconds` 的值大于 `initialDelaySeconds`，则 `initialDelaySeconds` 将被忽略。默认是 0 秒，最小值是 0。
- **periodSeconds**：执行探测的时间间隔（单位是秒）。默认是 10 秒。最小值是 1。
- **timeoutSeconds**：探测的超时后等待多少秒。默认值是 1 秒。最小值是 1。
- **successThreshold**：探针在失败后，被视为成功的最小连续成功数。默认值是 1。 存活和启动探测的这个值必须是 1。最小值是 1。
- **failureThreshold**：探针连续失败了 `failureThreshold` 次之后， Kubernetes 认为总体上检查已失败：容器状态未就绪、不健康、不活跃。 对于启动探针或存活探针而言，如果至少有 `failureThreshold` 个探针已失败， Kubernetes 会将容器视为不健康并为这个特定的容器触发重启操作。 Kubelet 遵循该容器的 `terminationGracePeriodSeconds` 设置。 对于失败的就绪探针，Kubelet 继续运行检查失败的容器，并继续运行更多探针； 因为检查失败，Kubelet 将 Pod 的 `Ready` [状况](https://kubernetes.io/zh-cn/docs/concepts/workloads/pods/pod-lifecycle/#pod-conditions)设置为 `false`。
- **terminationGracePeriodSeconds**：为 Kubelet 配置从为失败的容器触发终止操作到强制容器运行时停止该容器之前等待的宽限时长。 默认值是继承 Pod 级别的 `terminationGracePeriodSeconds` 值（如果不设置则为 30 秒），最小值为 1。 更多细节请参见[探针级别 `terminationGracePeriodSeconds`](https://kubernetes.io/zh-cn/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/#probe-level-terminationgraceperiodseconds)。

### 探针结果

三种类型的探针每次探测都将获得以下三种结果之一：

- `Success`（成功）容器通过了诊断。
- `Failure`（失败）容器未通过诊断。
- `Unknown`（未知）诊断失败，因此不会采取任何行动。

## livenessProbe

存活探针，检查容器是否运行正常，如死锁、无法响应等，探测失败后 Kubelet 根据 `restartPolicy` 来重启容器。

当一个 pod 内有多个容器，且 `restartpolicy` 为默认值( Always )。其中某个容器探针失败后，Kubelet 重启该容器，并不会重启其他容器，且 pod 的状态值会变为 `NotReady`。

如果一个容器不包含 **livenessProbe** 探针，则 Kubelet 认为容器的 **livenessProbe** 探针的返回值永远成功。

## readinessProbe

就绪探针，探测容器启动后，是否就绪，是否能够提供服务，只有 pod 所有容器都探测成功后，pod 状态变成 `Ready`。只要有一个容器的 readinessProbe 失败，那么整个 pod 都会处于 `NotReady` 状态。

控制器将此 Pod 的 `Endpoint` 从对应的 `service` 的 `Endpoint` 列表中移除，从此不再将任何请求调度此 Pod 上，直到下次探测成功。

通过使用 **ReadinessProbe**，Kubernetes 能够等待应用程序完全启动，然后才允许服务将流量发送到新副本。

就绪探针在容器的整个生命期内持续运行。

## startupProbe

启动探针，判断容器是否已启动。如果提供了启动探测探针，则禁用所有其他探测探针( **readinessProbe，livenessProbe** )，直到它成功为止。如果启动探测失败，Kubelet 将杀死容器，容器将服从其重启策略。如果容器没有提供启动探测，则默认状态为成功。
这类探针仅在启动时执行，不像存活探针和就绪探针那样周期性地运行。

那什么时候需要使用到启动探针呢？

例如如下有个含有 **livenessProbe** 的 pod：

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    prot: 80
  failureThreshold: 1
  initialDelay：10
  periodSeconds: 10
```

该探针的意思是容器启动 10s 后开始探测，每 10s 检查一次，允许失败的次数是 1 次。如果失败次数超过 1 则表示探针失败。

如果这个服务启动时间在 10s 内则没有任何问题，因为探针 10s 后才开始探测。但是该服务在启动的时候需要一些预启动的操作，比如导数据之类，需要 60s 才能完全启动好。这时候上面的探针就会进入死循环，因为上面的探针10s 后就开始探测，这时候我们服务并没有起来，发现探测失败就会触发容器重启策略。当然可以把 `initialDelay` 调成 60s ，但是我们并不能保证这个服务每次起来都是 60s ，假如新的版本起来要70s，甚至更多的时间，我们就不好控制了。有的朋友可能还会想到把失败次数增加，比如下面配置：

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    prot: 80
  failureThreshold: 5
  initialDelay：60
  periodSeconds: 10

```

这在启动的时候是可以解决我们目前的问题，但是如果这个服务挂了呢？如果 `failureThreshold=1`  则 10s 后就会报警通知服务挂了，如果设置了`failureThreshold=5`，那么就需要 `5*10s=50s` 的时间，在现在大家追求快速发现、快速定位、快速响应的时代是不被允许的。

在这时候我们把 **startupProbe** 和 **livenessProbe** 结合起来使用就可以很大程度上解决我们的问题。

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    prot: 80
  failureThreshold: 1
  initialDelay：10
  periodSeconds: 10

startupProbe:
  httpGet:
    path: /healthz
    prot: 80
  failureThreshold: 10
  initialDelay：10
  periodSeconds: 10
```

上面的配置是只有 **startupProbe** 探测成功后再交给 **livenessProbe** 。应用在 `10s + 10s * 10s = 110s` 内启动都是可以的，而且应用启动后运行过程中挂掉了 10s 就会发现问题。

所以说启动探针一般都是搭配着存活探针一起工作的，不会单独配置启动配置。

## 实践

熟练使用好上面三种探针，可以增强业务的可用性和稳定性。

如果服务自身启动时间略长，`0s-20s` 之间那么需要配置 **readinessProbe**

```yaml
readinessProbe:
  httpGet:
    path: /healthz
    prot: 80
  failureThreshold: 1
  initialDelay：10
  periodSeconds: 10
```

- 该配置作用是当容器启动 10s 后，开始第一次探针，且每隔 10s 探针一次。
- 一次探针失败即表示失败，将该 pod 表示为 `NotReady`。
- 如果启动后探针成功后，pod 状态置为 `Ready`，该服务即可被请求。
- 后续每隔 10s 请求一次，如果失败了，将 pod 状态置为 `NotReady`，Endpoint Controller 就会将该 endpoint 从 service 上剔除。

> 关于 **ReadinessProbe** 有一点很重要，它会在容器的整个生命周期中运行。这意味着 **ReadinessProbe** 不仅会在启动时运行，而且还会在 Pod 运行期间反复运行。这是为了处理应用程序暂时不可用的情况（比如加载大量数据、等待外部连接时）。在这种情况下，我们不一定要杀死应用程序，可以等待它恢复。**ReadinessProbe** 可用于检测这种情况，并在 Pod 再次通过 **ReadinessProbe** 检查后，将流量发送到这些 Pod。
>

如果服务会出现假死现象，即服务进程在，但已经无法提供服务了。那么这时候就需要 **livenessProbe**

```yaml
readinessProbe:
  httpGet:
    path: /healthz
    prot: 80
  failureThreshold: 3
  initialDelay：10
  periodSeconds: 10
  
livenessProbe:
  httpGet:
    path: /healthz
    prot: 80
  failureThreshold: 10
  initialDelay：15
  periodSeconds: 10
```

当同时使用 **readinessProbe、livenessProbe**，两者配置不能保持一样。

- 如果两者 `initialDelay` 都为 10 ，即服务启动 10s 后，readinessProbe、livenessProbe 都开始探测，这样两者都探测失败后，该 pod 即重启也会 NotReady  是一个多此一举的过程。
- 可以将 **readinessProbe** 的 `initialDelay` 设置的短一点，即先开始就绪探针，再开始存活探针。
- 或者将 **livenessProbe** 的 `failureThreshold` 设置大一点。（例如，在 3 次尝试后标记为未就绪，在 10 次尝试后将 **LivenessProbe** 标记为失败）

如果服务启动时间很长，20s - 100s，就需要使用 **startupProbe**

```yaml
readinessProbe:
  httpGet:
    path: /healthz
    prot: 80
  failureThreshold: 3
  initialDelay：10
  periodSeconds: 10
  
livenessProbe:
  httpGet:
    path: /healthz
    prot: 80
  failureThreshold: 10
  initialDelay：15
  periodSeconds: 10

startupProbe:
  httpGet:
    path: /healthz
    prot: 80
  failureThreshold: 10
  initialDelay：10
  periodSeconds: 10
```

- 当该服务启动 10s 后开始启动探针，探测成功后，该探针结束，后面不会再探测了，然后到 readinessProbe、livenessProbe 工作；
- startupProbe 探测失败后，重启该 pod，重新探测，直到服务启动成功。

## 总结

Kubernetes 探针可以极大地提高服务的健壮性和弹性，并提供出色的最终用户体验。但是，如果您不仔细考虑如何使用这些探针，特别是如果您不考虑异常的系统动态（无论多么罕见），则有可能使服务的可用性变差，而不是变好。下面列举了探针使用的一些技巧和注意事项。

- 对于提供 HTTP 协议（REST 服务等）的微服务， 始终定义一个 **readinessProbe**，用于检查的应用程序（Pod）是否已准备好接收流量。
- 对于慢启动的应用，我们应该使用 **startupProbe**，来防止容器没有启动，就被 **livenessProbe** 杀死了。
- 不要依赖外部依赖项（如数据存储）进行就绪/探活检查，因为这可能会导致级联故障

  > 1、假如10 个 pod 的服务，数据库使用 Postgres，缓存使用 redis：当你的探针的路径依赖于工作的 redis 连接时，如果出现 redis 网络故障，则所有 10 个 Pod 都将“重启。这通常会产生影响比它应该的更糟。因为服务还能到 Postgres 拿去数据。
  >
  >
  > 2、服务最好不要与数据库做强依赖。
  >
  > 3、只探测自己内部的端口，不要去探测外部 pod 的端口。探测器不应依赖于同一集群中其他 Pod 的状态，以防止级联故障。
>
- 需要明确知道使用 **livenessProbe** 的原因，否则不要为的 Pod 使用 **livenessProbe**。
    - **livenessProbe** 可以帮助恢复假死的容器，但是当我们能控制我们的应用程序，出现意料之外的假死进程和死锁之类的故障，更好的选择是从应用内部故意崩溃以恢复到已知良好状态。
    - 失败的 **livenessProbe** 将导致容器重启，从而可能使与负载相关的错误的影响变得更糟：容器重启将导致停机（至少的应用程序的启动时间，例如 30s+），从而导致更多错误并为其他容器提供更多流量负载，导致更多失败的容器，等等
- 如果同时使用 **readinessProbe、livenessProbe**，请不要为 **readinessProbe、livenessProbe** 设置相同的规范