---
weight: 30
title: "calico V3.22.1 使用 NodeInternalIP Bug"
date: 2024-06-13T11:57:40+08:00
lastmod: 2024-06-13T12:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "k8s-dev.jpg"

tags: ["Kubernetes-dev"]
categories: ["Kubernetes-dev"]

lightgallery: true
---

# 简介

在部署完 Calico 之后，会在每个 K8S 节点上运行一个 calico-node 组件，该组件保证 pod 间网络通的建立与维护。每个 calico-node 启动后都会自动发现当前节点上可用的网卡地址，calico 提供了很多种方式来自动发现：

- **Kubernetes Node IP:** 该模式下 calico 会选择 Kubernetes node's `Status.Addresses` 字段第一个 `Internal` 类型的 ip
- **Source address used to reach an IP or domain name:** calico 将选择给定“可访问” IP 地址或域的IP地址
- **Including matching interfaces:** calico 根据正则表达式自动选择可用的网卡地址
- **Excluding matching interfaces:** calico 根据正则表达式排除不满足的网卡地址
- **Including CIDRs:** calico 选择在配置的 cidr 范围内的网卡地址，适用于一个网卡有多个网段的 IP

以上几种方式具体细节可参考[官网](https://docs.tigera.io/calico/latest/networking/ipam/ip-autodetection#autodetecting-node-ip-address-and-subnet) 。

Calico 在 V3.22 支持了 **Kubernetes Node IP** 模式，但是在 V3.22.4 之前的小版本都存在 bug，下面就详细讲解该 bug 现象以及原理。

# 现象

使用 **Kubernetes Node IP** 模式部署 calico V3.22.1，会发现有部分 calico-node 启动失败

```bash
$ kubectl get pods -n calico-system -o wide
NAME                                       READY   STATUS             RESTARTS      AGE     IP               NODE                   NOMINATED NODE   READINESS GATES
calico-kube-controllers-6b656f88d7-fhjz7   0/1     CrashLoopBackOff   3 (47s ago)   2m20s   100.121.83.69    node-172-29-231-161    <none>           <none>
calico-node-bhk2j                          0/1     CrashLoopBackOff   4 (30s ago)   2m20s   172.29.231.161   node-172-29-231-161    <none>           <none>
calico-node-h99d4                          1/1     Running            0             2m20s   172.29.231.76    master-172-29-231-76   <none>           <none>
calico-typha-64cf4b56d4-wqtjr              1/1     Running            0             2m20s   172.29.231.161   node-172-29-231-161    <none>           <none>
```

查看报错 pod 日志，可以确定该节点获取的主机 IP 是 172.29.231.0，且已经被 master-172-29-231-76 节点使用。

```bash
$ kubectl logs -f pods/calico-node-bhk2j -n calico-system
2024-06-13 11:13:52.121 [INFO][8] startup/startup.go 425: Early log level set to info
2024-06-13 11:13:52.122 [INFO][8] startup/utils.go 127: Using NODENAME environment for node name node-172-29-231-161
2024-06-13 11:13:52.122 [INFO][8] startup/utils.go 139: Determined node name: node-172-29-231-161
2024-06-13 11:13:52.122 [INFO][8] startup/startup.go 94: Starting node node-172-29-231-161 with version v3.22.1
2024-06-13 11:13:52.123 [INFO][8] startup/startup.go 430: Checking datastore connection
2024-06-13 11:13:52.134 [INFO][8] startup/startup.go 454: Datastore connection verified
2024-06-13 11:13:52.134 [INFO][8] startup/startup.go 104: Datastore is ready
2024-06-13 11:13:52.150 [INFO][8] startup/startup.go 483: Initialize BGP data
2024-06-13 11:13:52.151 [INFO][8] startup/autodetection_methods.go 225: Including CIDR information from host interface. CIDR="172.29.231.161/24"
2024-06-13 11:13:52.151 [INFO][8] startup/startup.go 559: Node IPv4 changed, will check for conflicts
2024-06-13 11:13:52.155 [WARNING][8] startup/startup.go 983: Calico node 'master-172-29-231-76' is already using the IPv4 address 172.29.231.0.
2024-06-13 11:13:52.155 [INFO][8] startup/startup.go 389: Clearing out-of-date IPv4 address from this node IP="172.29.231.0/24"
2024-06-13 11:13:52.163 [WARNING][8] startup/utils.go 49: Terminating
Calico node failed to start
```

通过 calicoctl 工具查看节点详情，发现确实 master-172-29-231-76 节点使用了 172.29.231.0

```bash
$ ./calicoctl-linux-amd64 get node -o wide
NAME                   ASN       IPV4              IPV6   
master-172-29-231-76   (64512)   172.29.231.0/24
node-172-29-231-161
```

为什么会使用 172.29.231.0 这个 IP 呢，理论上 calico 通过 NodeInternalIP 模式会获取  ****Kubernetes node's `Status.Addresses` 字段第一个 `Internal` 类型的 ip，通过命令证实该字段下的 ip 也不是 172.29.231.0，应该是 172.29.231.76 才对。

```yaml
status:
  addresses:
  - address: 172.29.231.76
    type: InternalIP
  - address: master-172-29-231-76
    type: Hostname
```

# bug 分析

既然 K8S 节点的 internal ip 是正确的，那问题应该是 calico，通过阅读 calico v3.22.1 源码。

calico 自动获取 ip 的源码在 calico/node/pkg/lifecycle/startup/autodetection/autodetection_methods.go

```go
// autoDetectCIDR auto-detects the IP and Network using the requested
// detection method.
func AutoDetectCIDR(method string, version int, k8sNode *v1.Node, getInterfaces func([]string, []string, int) ([]Interface, error)) *cnet.IPNet {
	if method == "" || method == AUTODETECTION_METHOD_FIRST {
		// Autodetect the IP by enumerating all interfaces (excluding
		// known internal interfaces).
		return autoDetectCIDRFirstFound(version)
	} else if strings.HasPrefix(method, AUTODETECTION_METHOD_INTERFACE) {
		// Autodetect the IP from the specified interface.
		ifStr := strings.TrimPrefix(method, AUTODETECTION_METHOD_INTERFACE)
		// Regexes are passed in as a string separated by ","
		ifRegexes := regexp.MustCompile(`\s*,\s*`).Split(ifStr, -1)
		return autoDetectCIDRByInterface(ifRegexes, version)
	} else if strings.HasPrefix(method, AUTODETECTION_METHOD_CIDR) {
		// Autodetect the IP by filtering interface by its address.
		cidrStr := strings.TrimPrefix(method, AUTODETECTION_METHOD_CIDR)
		// CIDRs are passed in as a string separated by ","
		matches := []cnet.IPNet{}
		for _, r := range regexp.MustCompile(`\s*,\s*`).Split(cidrStr, -1) {
			_, cidr, err := cnet.ParseCIDR(r)
			if err != nil {
				log.Errorf("Invalid CIDR %q for IP autodetection method: %s", r, method)
				return nil
			}
			matches = append(matches, *cidr)
		}
		return autoDetectCIDRByCIDR(matches, version)
	} else if strings.HasPrefix(method, AUTODETECTION_METHOD_CAN_REACH) {
		// Autodetect the IP by connecting a UDP socket to a supplied address.
		destStr := strings.TrimPrefix(method, AUTODETECTION_METHOD_CAN_REACH)
		return autoDetectCIDRByReach(destStr, version)
	} else if strings.HasPrefix(method, AUTODETECTION_METHOD_SKIP_INTERFACE) {
		// Autodetect the Ip by enumerating all interfaces (excluding
		// known internal interfaces and any interfaces whose name
		// matches the given regexes).
		ifStr := strings.TrimPrefix(method, AUTODETECTION_METHOD_SKIP_INTERFACE)
		// Regexes are passed in as a string separated by ","
		ifRegexes := regexp.MustCompile(`\s*,\s*`).Split(ifStr, -1)
		return autoDetectCIDRBySkipInterface(ifRegexes, version)
	} else if strings.HasPrefix(method, K8S_INTERNAL_IP) {
		// K8s InternalIP configured for node is used
		if k8sNode == nil {
			log.Error("Cannot use method 'kubernetes-internal-ip' when not running on a Kubernetes cluster")
			return nil
		}
		// 通过 k8s node internal ip 获取节点 ip
		return autoDetectUsingK8sInternalIP(version, k8sNode, getInterfaces)
	}

	// The autodetection method is not recognised and is required.  Exit.
	log.Errorf("Invalid IP autodetection method: %s", method)
	utils.Terminate()
	return nil
}

```

通过上面代码发现 autoDetectUsingK8sInternalIP(version, k8sNode, getInterfaces) 这个函数就是通过 k8s node internal ip 获取节点 ip 接下来看 这个函数的实现

```go
// autoDetectUsingK8sInternalIP reads K8s Node InternalIP.
func autoDetectUsingK8sInternalIP(version int, k8sNode *v1.Node, getInterfaces func([]string, []string, int) ([]Interface, error)) *cnet.IPNet {
	var address string
	var err error

	nodeAddresses := k8sNode.Status.Addresses
	for _, addr := range nodeAddresses {
	  // 获取 internalIP 类型的 ip，并和主机上每个网卡 ip 比较，如果相等，则返回该网卡 ip
		if addr.Type == v1.NodeInternalIP {
			if (version == 4 && utils.IsIPv4String(addr.Address)) || (version == 6 && utils.IsIPv6String(addr.Address)) {
				address, err = GetLocalCIDR(addr.Address, version, getInterfaces)
				if err != nil {
					return nil
				}
				break
			}
		}
	}

	// bug 就出现在这个位置，这个 cnet.ParseCIDR 函数返回 ip，ipNet 两个值，但是只接受了 ipNet，
	// ipNet 是一个网段，并不是 ip 地址，即 172.29.231.0/24，所以 calico 将 172.29.231.0/24 当作该节点 ip
	_, ipNet, err := cnet.ParseCIDR(address)
	if err != nil {
		log.Errorf("Unable to parse CIDR %v : %v", address, err)
		return nil
	}
	
	return ipNet
}
```

通过上面分析，知道了 bug 出现的原因，那么通过翻阅高版本 calico 源码，发现在 calico V3.22.4 这个 Tag 修复了这个问题。下面是 V3.22.4 的对应源码。

```go
// autoDetectUsingK8sInternalIP reads K8s Node InternalIP.
func autoDetectUsingK8sInternalIP(version int, k8sNode *v1.Node, getInterfaces func([]string, []string, int) ([]Interface, error)) *cnet.IPNet {
	var address string
	var err error

	nodeAddresses := k8sNode.Status.Addresses
	for _, addr := range nodeAddresses {
		if addr.Type == v1.NodeInternalIP {
			if (version == 4 && utils.IsIPv4String(addr.Address)) || (version == 6 && utils.IsIPv6String(addr.Address)) {
				address, err = GetLocalCIDR(addr.Address, version, getInterfaces)
				if err != nil {
					return nil
				}
				break
			}
		}
	}
	
	// 和 v3.22.1 不同之处就在这里，这里也接收了 ip 字段
	ip, ipNet, err := cnet.ParseCIDR(address)
	if err != nil {
		log.Errorf("Unable to parse CIDR %v : %v", address, err)
		return nil
	}
	
	// ParseCIDR masks off the IP addr of the IPNet it returns eg. ParseCIDR("192.168.1.2/24" will return
	//"192.168.1.2, 192.168.1.0/24". Callers of this function (autoDetectUsingK8sInternalIP) expect the full IP address
	// to be preserved in the CIDR ie. we should return 192.168.1.2/24
	// 将 ip 赋值给 ipNet 并返回
	ipNet.IP = ip.IP
	return ipNet
}
```

V3.22.4 版本的这块逻辑只是稍微修改，并且给出了对应注释来解释之前的 bug 原因。

# 解决

既然知道了 bug 的原因，只需要升级 calico 到 V3.22.4 及以上即可修复该问题。