---
weight: 19
title: "如何使用 nsenter 调试容器网络"
date: 2023-06-10T21:57:40+08:00
lastmod: 2023-06-10T16:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "pod-debug.jpg"

tags: ["Kubernetes-ops"]
categories: ["Kubernetes-ops"]

lightgallery: true
---
# nsenter 调试容器

现在大部分的公司业务基本都已经容器化，甚至 K8S 化的情况下，当容器、Pod 运行异常时，无非是看看其日志和一些 K8S event 信息，当容器、Pod 内部出现网络访问失败时，或者其他一些问题时。通常会进入容器、Pod 内部通过一些网络工具来进行调试，那么问题来了。一般容器内是不会安装太多的调试工具，基本都是最小化的操作系统，所以有的时候根本没办法调试。

可以有以下几种方式解决：

- 就在制作镜像时，安装一些常用的工具，比如：`ip`、`ping`、`telnet`、`ss`、`tcpdump` 等命令，方便后期使用，但是这个就违背了容器化的最小化镜像原则。本身上容器就是实现更轻便、更快速地启动业务，安装一些列工具就增加了镜像大小。
- 在容器、Pod 内直接安装所需的命令，但是安装过程可能会比较困难，有的时候容器内操作系统连 `yum`、`rpm` 等安装工具都没有，编译安装显然太浪费时间。同时有可能离线环境，没 `yum` 等特殊情况，都会使得安装非常麻烦。
- 利用容器的运行原理，使用 `nsenter` 来进入容器的对应 `namespace` 进行调试。

所以，显然第一、第二两种方法不方便且不现实，所以看看第三种方法是如何操作的。

# 容器原理

在介绍 `nsenter` 之前，先见到说下容器的原理，当我们用 `docker run` 启动一个容器时，实际上底层做的就是创建一个进程以及对应的 network namespace、mount namespace、uts namespace、ipc namespace、pid namspace、user namespace，然后将这个进程加入到这些到命令空间，同时给划分对应的 cgroup，最后使用 `chroot` 将容器的文件系统切换为根目录。这样就实现了这个进程与 `root namespace` 的多维度隔离，使得进入容器内就像是进入一个新的操作系统。

所以说容器就是一个进程，只不过他都加入到不同的命名空间下了。

# nsenter 原理

`nsenter` 是一个 Linux 命令行工具，作用是可以进入 Linux 系统下某个进程的命令空间，如 network namespace、mount namespace、uts namespace、ipc namespace、pid namspace、user namespace、cgroup。

所以使用 `nsenter` 调试容器网络，可以按照以下步骤操作：

- 在 `root namespace` 下找到容器的  Pid，也就是这个容器在 `root namespace` 下的进程号
- 使用 `nsenter` 进入到该 Pid 的 `network namespace` 即可，这样就保证了当前的环境是容器的网络环境，但是文件系统还是在 `root namespace` 下，以及 user、uts 等命名空间都还是在 `root namespace` 下。所以就可以使用 `root namespace` 下的调试命令来进行调试了。

# 实验

上面介绍了 `nsenter` 的原理，下面就实际演示一下。

`nsenter` 位于 `util-linux` 包中，一般常用的 Linux 发行版都已经默认安装。如果你的系统没有安装，可以使用以下命令进行安装：

```bash
# Centos 
$ yum install util-linux
```

使用 `nsenter - - help` 查看 `nsenter` 用法。

```bash
$ nsenter --help

用法：
 nsenter [选项] [<程序> [<参数>...]]

以其他程序的名字空间运行某个程序。

选项：
 -a, --all              enter all namespaces
 -t, --target <pid>     要获取名字空间的目标进程
 -m, --mount[=<文件>]   进入 mount 名字空间
 -u, --uts[=<文件>]     进入 UTS 名字空间(主机名等)
 -i, --ipc[=<文件>]     进入 System V IPC 名字空间
 -n, --net[=<文件>]     进入网络名字空间
 -p, --pid[=<文件>]     进入 pid 名字空间
 -C, --cgroup[=<文件>]  进入 cgroup 名字空间
 -U, --user[=<文件>]    进入用户名字空间
 -S, --setuid <uid>     设置进入空间中的 uid
 -G, --setgid <gid>     设置进入名字空间中的 gid
     --preserve-credentials 不干涉 uid 或 gid
 -r, --root[=<目录>]     设置根目录
 -w, --wd[=<dir>]       设置工作目录
 -F, --no-fork          执行 <程序> 前不 fork
 -Z, --follow-context  根据 --target PID 设置 SELinux 环境

 -h, --help             display this help
 -V, --version          display version
```

这里演示两个场景，都是在工作中非常常见的。

## 调试容器网络

当使用 `docker run` 启动一个容器时，容器运行无报错，即容器不在重启的情况下。这种情况直接使用 `nsenter` 进入可以。

先进入容器内 `curl www.baidu.com`，发现容器内没有 `curl` 命令

```bash
$ docker run -it alpine-amd64:3.11 sh
$ curl http://www.baidu.com
sh: curl: not found
```

下面使用 `nsenter` 进行调试

1、获取容器 Pid，即 3448

```bash
$ docker inspect fd9ec0381062 | grep Pid
            "Pid": 3448,
            "PidMode": "",
            "PidsLimit": null,
```

2、使用 `nsenter` 进入该 Pid 的 `network namespace`

```bash
# -t 表示目标进程号, -n 表示进入 network namespace
$ nsenter -t 3448 -n
```

3、查看当前的网络环境，再使用 `curl`，发现正常返回

```bash
# 查看当前网络环境，可以确认是容器内的网络
$ ip addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
12: eth0@if13: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default 
    link/ether 02:42:ac:11:00:02 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 172.17.0.2/16 brd 172.17.255.255 scope global eth0
       valid_lft forever preferred_lft forever
# 再次使用 curl, 发现有命令
$ curl http://www.baidu.com
<!DOCTYPE html>
<!--STATUS OK--><html> <head><meta http-equiv=content-ty......
```

## 调试 Pod 网络

实际上 Pod 网络与容器网络是一样的，下面看两个场景

### Pod running 状态

当一个 Pod 运行状态是 `running` 时，其调试方式和上面的 docker 调试方式一样，直接进入容器的 `network namespace`。

1、找到 Pod 的运行结点，即 `master-172-31-97-104`

```bash
$ kubectl get pods -A -o wide | grep test-nsenter
NAMESPACE          NAME                                       READY   STATUS    RESTARTS   AGE     IP                NODE                   NOMINATED NODE   READINESS GATES
test               test-nsenter-7df7d5fff7-5f666              1/1     Running   0          4m21s   100.121.45.129    master-172-31-97-104   <none>           <none>
```

2、去 `master-172-31-97-104` 结点获取容器 `Pid`。会发现有两个 `test-nsenter` 容器，其中一个是业务容器，另一个是 K8S 起的 `pause` 容器用于共享容器网络。

直接获取业务容器的 `Pid`，即 48344

```bash
$ docker ps | grep test-nsenter
f5fdbd788a8e  test-nsenter:latest   "sleep 300"  6 minutes ago  Up 6 minutes   k8s_test-nsenter-c5577484c-wlndj_test_516c4915-0fa9-4d1f-a4c3-612b1ab02c13_0
b387d915a853  sea.hub:5000/pause:3.5  "/pause"   7 minutes ago  Up 7 minutes   k8s_POD_test-nsneter-c5577484c-wlndj_test_516c4915-0fa9-4d1f-a4c3-612b1ab02c13_2
$ docker inspect f5fdbd788a8e | grep Pid
			"Pid": 48344,
			"PidMode": "",
			"PidsLimit": null,
```

3、`nsenter` 进入该 `Pid` 的 `network namespace` 中，使用 `curl`

```bash
$ nsenter -t 48344 -n
# 查看当前网络环境，可以确认是容器内的网络
$ ip addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
3: eth0@if101: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1480 qdisc noqueue state UP group default 
    link/ether 32:b3:d0:37:ad:e9 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 100.118.171.133/32 scope global eth0
       valid_lft forever preferred_lft forever
4: tunl0@NONE: <NOARP> mtu 1480 qdisc noop state DOWN group default qlen 1000
    link/ipip 0.0.0.0 brd 0.0.0.0
# 再次使用 curl, 发现有命令
$ curl http://www.baidu.com
<!DOCTYPE html>
<!--STATUS OK--><html> <head><meta http-equiv=content-ty......
```

### Pod crashLookBackOff 状态

上面演示的容器都是 `running` 状态，可以在结点上找到对应 `Pid`，但是如果 Pod 一直在重启，则 `Pid` 一直都在变，所以调试也会不断中断。

所以当 Pod 处于`crashLookBackOff` 状态 时，可以进入 Pod `Pause` 容器，因为 `Pause` 容器与业务容器是共享网络的，而且永远不会重启，除非 Pod 被删除了。

1、进入 Pod `crashLookBackOff` 状态 的容器 `network namespace`

```bash
# 发现只有pause 容器，因为业务容器一直在重启
$ docker ps|grep test-nsenter
70e8079e82ed   sea.hub:5000/pause:3.5    "/pause"   39 seconds ago   up 38 seconds   k8s_POD_test-nsenter-7cdf977947-thk57_test_9fedbb55-4726-4f13-a669-d5bcb0b19b94_0
# 查看 Pause 容器的 Pid
$ docker inspect 70e8079e82ed |grep Pid
            "Pid": 14213,
            "PidMode": "",
            "PidsLimit": null,      
# nsenter 进入 Pause 容器的 network namespace
$ nsneter -t 14213 -n    
# 查看 pause 容器的网络, 和 Pod 网络一致
$ ip addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
2: tunl0@NONE: <NOARP> mtu 1480 qdisc noop state DOWN group default qlen 1000
    link/ipip 0.0.0.0 brd 0.0.0.0
4: eth0@if68: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1480 qdisc noqueue state UP group default 
    link/ether c2:64:99:f0:a6:f1 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 100.121.45.130/32 scope global eth0
       valid_lft forever preferred_lft forever   
# 再次使用 curl, 发现有命令
$ curl http://www.baidu.com
<!DOCTYPE html>
<!--STATUS OK--><html> <head><meta http-equiv=content-ty......       
```

所以说，当使用 `nsenter` 调试 Pod 网络时，不管 Pod 状态如何，我们直接进入其 `Pause` 容器的 `network namespace` 即可。

# 总结

nsenter 非常便捷地帮助我们调试容器环境下和 K8S 环境下的网络调试，也可以调试其他问题。`nsenter` 使用也非常简单，是一个非常好用的调试工具，很好地解决了容器镜像缺少命令行工具的问题。

除了调试网络，也可以调试容器的 `ipc`、`mount` 等，可以根据场景自行演示。

下一篇会介绍另一个 K8S 环境下 Pod 网络调试工具，`kubectl-debug`。
