---
weight: 8
title: "Kubernetes 证书详解(认证)"
date: 2021-12-24T21:57:40+08:00
lastmod: 2021-12-24T16:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "k8s-cert.png"

tags: ["Kubernetes-ops"]
categories: ["Kubernetes-ops"]

lightgallery: true
---

## **K8S 证书介绍**

在 Kube-apiserver 中提供了很多认证方式，其中最常用的就是 TLS 认证，当然也有 BootstrapToken，BasicAuth 认证等，只要有一个认证通过，那么 Kube-apiserver 即认为认证通过。下面就主要讲解 TLS 认证。

如果你是使用 [kubeadm](https://kubernetes.io/zh/docs/reference/setup-tools/kubeadm/kubeadm/) 安装的 Kubernetes， 则会自动生成集群所需的证书。但是如果是通过二进制搭建，所有的证书是需要自己生成的，这里我们说说集群必需的证书。

在了解 Kubernetes 证书之前，需要先了解什么是 “单向 TLS 认证” 和 “双向 TLS 认证”

- 服务器单向认证：只需要服务器端提供证书，客户端通过服务器端证书验证服务的身份，但服务器并不验证客户端的身份。这种情况一般适用于对 Internet 开放的服务，例如搜索引擎网站，任何客户端都可以连接到服务器上进行访问，但客户端需要验证服务器的身份，以避免连接到伪造的恶意服务器。
- 双向 TLS 认证：除了客户端需要验证服务器的证书，服务器也要通过客户端证书验证客户端的身份。这种情况下服务器提供的是敏感信息，只允许特定身份的客户端访问。开启服务端验证客户端默认是关闭的，需要在服务端开启认证配置。

Kubernetes 为了安全性，都是采用双向认证。通常我们使用 Kubeadm 在部署 Kubernetes 时候，Kubeadm 会自动生成集群所需要的证书，下面我们就这些证书一一给大家进行讲解。

这是我们用 Kubeadm 搭建完一个集群后在 *`/etc/kubernetes`* 目录下所生成的文件

```bash
$ tree kubernetes/
kubernetes/
|-- admin.conf
|-- controller-manager.conf
|-- kubelet.conf
|-- scheduler.conf
|-- manifests
|   |-- etcd.yaml
|   |-- kube-apiserver.yaml
|   |-- kube-controller-manager.yaml
|   `-- kube-scheduler.yaml
|-- pki
|   |-- apiserver.crt
|   |-- apiserver-etcd-client.crt
|   |-- apiserver-etcd-client.key
|   |-- apiserver.key
|   |-- apiserver-kubelet-client.crt
|   |-- apiserver-kubelet-client.key
|   |-- ca.crt
|   |-- ca.key
|   |-- etcd
|   |   |-- ca.crt
|   |   |-- ca.key
|   |   |-- healthcheck-client.crt
|   |   |-- healthcheck-client.key
|   |   |-- peer.crt
|   |   |-- peer.key
|   |   |-- server.crt
|   |   `-- server.key
|   |-- front-proxy-ca.crt
|   |-- front-proxy-ca.key
|   |-- front-proxy-client.crt
|   |-- front-proxy-client.key
|   |-- sa.key
|   `-- sa.pub
```

下面我们根据这个 Kubernetes 的组件之间通讯图来一一讲解每个证书的作用。本文基于 [Kubernetes:v1.22.17](https://github.com/kubernetes/kubernetes/tree/release-1.22) 

![k8s-crt](k8s-cert-arch.png "Kubernetes 证书概览")

## **CA证书**

Kubeadm 安装的集群中我们都是用 3 套 CA 证书来管理和签发其他证书，一套 CA 给 ETCD 使用，一套是给 Kuberntes 内部组件使用，还有一套是给配置聚合层使用的，当然如果你觉得管理 3 套 CA 比较麻烦，您也可以用一套来管理。

## **Etcd 证书**

```bash
ca.crt  ca.key  healthcheck-client.crt  healthcheck-client.key  peer.crt  peer.key  server.crt  server.key
```

etcd 证书位于 *`/etc/kubernetes/pki/etcd`* 目录下，我们根据 etcd 的 static-pod yaml 配置解释下证书的作用

```yaml
spec:
  containers:
  - command:
    - etcd
    - --advertise-client-urls=https://10.0.4.3:2379
    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
    - --client-cert-auth=true
    - --data-dir=/var/lib/etcd
    - --initial-advertise-peer-urls=https://10.0.4.3:2380
    - --initial-cluster=vm-4-3-centos=https://10.0.4.3:2380
    - --key-file=/etc/kubernetes/pki/etcd/server.key
    - --listen-client-urls=https://127.0.0.1:2379,https://10.0.4.3:2379
    - --listen-peer-urls=https://10.0.4.3:2380
    - --name=vm-4-3-centos
    - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
    - --peer-client-cert-auth=true
    - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --snapshot-count=10000
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    image: k8s.gcr.io/etcd:3.3.10
    imagePullPolicy: IfNotPresent
    livenessProbe:
      exec:
        command:
        - /bin/sh
        - -ec
        - ETCDCTL_API=3 etcdctl --endpoints=https://[127.0.0.1]:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt
          --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt --key=/etc/kubernetes/pki/etcd/healthcheck-client.key
          get foo
      failureThreshold: 8
```

### Etcd 根证书

Etcd 根证书用于签发其余证书，比如服务端证书，客户端证书等

```bash
ca.crt   ca.key
```

### Etcd 服务端证书

Etcd 对外提供服务的服务器证书及私钥，比如 etcd-ctl 访问 Etcd 的时候就会用 ca.crt 去验证 server.crt

Etcd 启动时通过 *`- --cert-file=/etc/kubernetes/pki/etcd/server.crt`*，*`- --key-file=/etc/kubernetes/pki/etcd/server.key`* 来配置服务端证书可私钥

```bash
server.crt  server.key
```

### Etcd node 间证书

Etcd 节点之间相互进行认证的 peer 证书、私钥，结点之间心跳检测，数据同步等通信都会使用 peer.crt 来验证

通过 *`- --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt`*，*`- --peer-key-file=/etc/kubernetes/pki/etcd/peer.key`* 来配置

```bash
peer.crt  peer.key
```

### Etcd 健康检查客户端证书

探测 Etcd 服务健康检查接口，客户端会下载服务端证书进行验证，服务端也会下载客户端证书验证，即下面的客户端证书，这个需要客户端来配置

```bash
healthcheck-client.crt  healthcheck-client.key
```

## **Kube-apiserver**

Kube-apiserver 证书位于 *`/etc/kubernetes/pki`* ，同样我们通过 Kube-apiserver 的 static-pod yaml 文件来一一解释下每个证书的作用。

```yaml
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --advertise-address=10.0.4.3
    - --allow-privileged=true
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --enable-admission-plugins=NodeRestriction
    - --enable-bootstrap-token-auth=true
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --etcd-servers=https://127.0.0.1:2379
    - --insecure-port=0
    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
    - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
    - --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt
    - --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key
    - --requestheader-allowed-names=front-proxy-client
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --requestheader-extra-headers-prefix=X-Remote-Extra-
    - --requestheader-group-headers=X-Remote-Group
    - --requestheader-username-headers=X-Remote-User
    - --secure-port=6443
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-cluster-ip-range=10.96.0.0/12
    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    image: k8s.gcr.io/kube-apiserver:v1.15.2

```

### Kube-apiserver 根证书

用来签发 Kubernetes 中其他证书的 CA 证书及私钥，Kube-apiserver 会配置自己的根证书，也会配置 etcd 的根证书，是因为 Kube-apiserver 会作为客户端去访问 Kubelet，需要 ca.crt 来验证 Kubelet 的服务端证书，而且 Kube-apiserver 也会作为客户端去访问 Etcd，因为 Etcd 与 Kubernetes 不同属一个根证书，所以配置两个不同 CA。

通过 *`- --client-ca-file=/etc/kubernetes/pki/ca.crt`*，*`- --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt`* 分别配置

```bash
ca.crt  ca.key
```

### Kube-apiserver 服务端证书

Kube-apiserver 对外提供服务的证书及私钥，通过 *`--tls-cert-file=/etc/kubernetes/pki/apiserver.crt`*，*`--tls-private-key-file=/etc/kubernetes/pki/apiserver.key`* 配置

```bash
apiserver.crt   apiserver.key
```

假如 Kube-apiserver 自定义对外访问时，要在服务端证书的 *`SANs（Subject Alternative Name)`* 字段中添加对应的 DNS名称 或 IP地址，否则客户端会因访问地址与证书不匹配而报错。`kubeadm` 会帮我们设置一些默认的 SANs，包括 master 结点 IP，Kube-apiserver SVC IP 等。可以通过 openssl 命令查看证书的 SANs

```bash
$ openssl x509 -noout -text -in /etc/kubernetes/pki/apiserver.crt
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number: 1302536908518083956 (0x12138a6acb0e4d74)
    Signature Algorithm: sha256WithRSAEncryption
        Issuer: CN=kubernetes
        Validity
            Not Before: May 10 06:48:30 2023 GMT
            Not After : Apr 16 06:48:32 2123 GMT
        Subject: CN=kube-apiserver
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (2048 bit)
                Modulus:
                    00:d8:c6:9c:82:2c:92:53:5b:68:34:ac:09:4a:2c:
                    3c:1f:8b:e9:bd:be:bb:61:cf:96:f6:e8:5d:60:da:
                    4f:ea:38:c4:81:6a:bf:33:6f:d7:42:1f:9e:02:09:
                    51:f6:bc:9d:8f:56:9a:aa:fd:d7:b1:41:20:1e:cd:
                    69:6c:1e:04:d3:5f:6a:cd:3a:84:9b:51:a5:c5:79:
                    9c:8b:d8:b0:a0:fb:7e:3c:b6:b0:47:a7:56:d9:bf:
                    cd:76:40:e5:5f:08:a0:e1:50:dd:89:8a:76:2b:fc:
                    46:8b:53:fb:92:a1:ab:35:01:fe:11:8b:5b:d2:9a:
                    c8:41:4a:1f:6f:09:04:24:a1:44:bd:d2:73:97:75:
                    d7:25:9a:18:cf:a0:42:8b:22:9b:0e:c4:98:09:c2:
                    95:11:30:56:30:4e:7c:cb:47:18:9b:4e:f4:3d:5f:
                    cd:c2:f1:ca:f5:f2:02:78:9a:26:c8:cd:97:d4:30:
                    da:07:97:33:9e:63:54:5f:a4:3a:e9:82:00:f2:53:
                    2a:bc:98:b6:bc:ba:22:9a:c9:22:34:2e:86:cd:4f:
                    9a:e7:7a:1d:e4:5f:d8:8a:2e:28:12:01:d3:40:5e:
                    63:37:ba:46:c4:e2:1d:be:20:52:fd:69:37:75:79:
                    1b:69:e6:20:d7:c8:43:bf:09:3f:27:0d:f8:5e:95:
                    fd:db
                Exponent: 65537 (0x10001)
        X509v3 extensions:
            X509v3 Key Usage: critical
                Digital Signature, Key Encipherment
            X509v3 Extended Key Usage: 
                TLS Web Server Authentication
            X509v3 Authority Key Identifier: 
                keyid:8B:81:2B:52:44:15:2A:D0:CF:96:FE:FD:40:14:E8:C0:56:8E:83:9E
						**# 这里**
            X509v3 Subject Alternative Name: 
                DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:apiserver.cluster.local, DNS:kubernetes.default.svc.cluster.local, DNS:master-172-31-97-104, DNS:localhost, DNS:kubernetes, IP Address:127.0.0.1, IP Address:10.233.0.1, IP Address:10.103.97.2, IP Address:172.31.97.104
    Signature Algorithm: sha256WithRSAEncryption
         c2:c4:a4:48:1c:78:32:3c:04:37:79:f0:87:7e:92:ac:14:64:
         ef:84:28:d2:f7:c0:62:75:c3:bf:cf:ec:f7:c2:8f:2f:91:3e:
         b0:99:f1:6c:7f:98:62:4b:82:a5:d6:e5:d0:4a:cb:16:b2:8d:
         d6:95:89:ff:50:15:01:0f:29:13:49:c7:8c:69:c4:50:9a:5d:
         7c:fc:b1:8a:30:02:10:2e:c1:cf:b5:37:65:a3:5c:e6:50:ee:
         b0:60:a6:77:6e:3b:98:b7:2d:c2:4c:e3:2d:8f:9e:9f:25:b1:
         32:97:e7:08:d9:cd:cb:69:29:5f:30:08:b3:37:23:25:1d:6a:
         b7:41:20:10:30:44:df:e3:7a:0f:f9:6f:a0:e8:7f:0d:6a:d0:
         89:80:cb:99:a1:32:b9:ca:84:a5:1d:95:91:c5:a6:17:c8:87:
         88:3e:44:b6:5b:d9:21:09:7d:13:68:42:43:2e:33:4d:49:d4:
         c7:0c:38:55:b7:96:d5:27:3d:71:dd:f5:73:de:d9:bd:f9:6b:
         5c:9b:42:c9:18:2c:f9:29:37:87:cc:58:12:24:66:b8:58:31:
         d3:5b:1a:08:a0:f6:b7:ea:f9:49:31:12:a2:aa:8e:6c:3a:56:
         5c:c4:2c:d9:91:32:d3:3a:7d:5e:8c:d5:85:4c:d7:49:71:8b:
         53:26:1b:71
```

可以看到在 *`Subject Alternative Name`* 字段中，已经包含了一些默认的 Kube-apiserver 访问 DNS 或者 IP。

> Tips： 当我们使用 kubeadm 创建集群时候，可以在init时使用 *`--apiserver-cert-extra-sans`* 参数指定 SANs，kubeadm 会在生成证书时在默认的基础上增加设置的 SANs。
> 

### Kube-apiserver 访问 Etcd 的客户端证书

前面说过 Kubernetest 组件间访问都是采用双向 TLS 认证，所以 Kube-apiserver 访问 Etcd 的时候，Kube-apiserver 回去校验 Etcd 服务端证书，同时 Etcd 也会校验 Kube-apiserver 的客户端证书，达到双向认证。因为 Etcd 服务端证书是有 Etcd 的根证书签发，所以 Kube-apiserver 需要配置该 CA，通过 *`--etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt`* 配置。Etcd 校验 Kube-apiserver 的客户端证书时，Kube-apiserver 会把该证书发送给 Etcd，通过 *`--etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt`*，*`--etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key`* 配置。

```bash
apiserver-etcd-client.key   apiserver-etcd-client.crt
```

### Kube-apiserver 访问 Kubelet 的客户端证书

Kube-apiserver 也会去访问 Kubelet，例如 kubectl 查看 pod 日志，或者进入 pod 内部。和访问 Etcd 一样，Kube-apiserver 访问 Kubelet 也是双向 TLS 认证，Kube-apiserver 校验 Kubelet 的服务端证书，通过 *`--client-ca-file=/etc/kubernetes/pki/ca.crt`*，Kubelet 校验 Kube-apiserver 通过 *`--kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt`*，*`--kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key`*。

```bash
apiserver-kubelet-client.crt  apiserver-kubelet-client.key
```

### 聚合层证书/Webhook 证书

要扩展 Kube-apiserver 的 API 时，可以采用 Kube-apiserver 聚合功能，具体 Kube-apiserver 聚合原理参考 https://kubernetes.io/zh-cn/docs/tasks/extend-kubernetes/configure-aggregation-layer/。
或者自行开发的 Webhook，这两种开发都需要 Kube-apiserver 来调用，所以都会设计 TLS 认证，Webhook 原理见 https://kubernetes.io/zh-cn/docs/reference/access-authn-authz/extensible-admission-controllers/

这里以扩展 apiserver 简单说明下请求链路，当使用 kubectl 对扩展 API 发起请求时，首先 Kube-apiserver 收到请求对 kubectl 使用的 Kube-config 进行认证、鉴权，通过后将请求转发给 APIAggregator，APIAggregator 可以理解为一层代理，然后 APIAggregator 根据 API 的 GroupVersion 来将请求转发给扩展 apiserver，所以 APIAggregator 与开发者开发的扩展 apiserver 就需要进行 TLS 认证。

理想情况扩展 apiserver 需要自己签发 CA，然后使用该 CA 签发服务端证书，服务端证书由扩展 apiserver 程序使用，CA 通过 APIService 资源来发布告知 Kube-apiserver APIAggregator ，然后 APIAggregator 访问时获取 APIService  的 caBundle 字段来认证扩展 apiserver。*`--requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt`* 来校验，同时扩展 apiserver 也会校验 APIAggregator 的客户端证书，APIAggregator 的客户端证书通过 *`--proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt`*，*`--proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key`* 配置，扩展 apiserver 会通过 kube-system 命名空间下的 extension-apiserver-authentication configmap 获取签发 *`front-proxy-client.crt`* 的 CA，即  *`--requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt`* ，*`Kube-apiserver 启动时会将该 CA 信息写入 *`extension-apiserver-authentication`* configmap 中。这样就达到双向 TLS 认证的效果。但是扩展 apiserver 也可以关闭服务端校验，通过 APIservice 的配置 *`insecureSkipTLSVerify: true`* ，这样就只会扩展 apiserver 校验 APIAggregator 了。

```bash
front-proxy-ca.crt  front-proxy-client.crt  front-proxy-ca.key   front-proxy-client.key
```
> 包括代理转发到用户 api-server 的请求和调用 Webhook 准入控制插件的请求，Kube-apiserver 都是用 *`--proxy-client-cert-file`* 来认证的
>

上面所说的证书都在 *`/etc/kubernetes/pki`* 目录下，除了 [sa.pub](http://sa.pub) 和 sa.key，这个下文讲解。在 Kubernetes 集群中，Kube-controller-manager 和 Kube-scheduler，Kubelet，Kubectl 都是通过 KubeConfig 来访问 Kube-apiserver，原理上都是证书，下面详细讲解下。

## **Kube-controller-mananger**

还是和之前一样，我们通过 kube-controller-mananger 的 yaml 文件配置来看看是如何访问 Kube-apiserver。

```yaml
spec:
  containers:
  - command:
    - kube-controller-manager
    - --allocate-node-cidrs=true
    - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --bind-address=127.0.0.1
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --cluster-cidr=10.244.0.0/16
    - --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
    - --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
    - --controllers=*,bootstrapsigner,tokencleaner
    - --kubeconfig=/etc/kubernetes/controller-manager.conf
    - --leader-elect=true
    - --node-cidr-mask-size=24
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --root-ca-file=/etc/kubernetes/pki/ca.crt
    - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
    - --use-service-account-credentials=true
    image: k8s.gcr.io/kube-controller-manager:v1.15.2
```

你会发现在 yaml 中配置了 /etc/kubernetes/controller-manager.conf 这个配置文件，而不是配置 controller-manager 的客户端证书之类的。Kubernetes 这里的设计是这样的，kube-controller-mananger、kube-scheduler、kubelet 等组件，采用一个kubeconfig 文件中配置的信息来访问 Kube-apiserver。该文件中包含了 Kube-apiserver 的地址，验证 Kube-apiserver 服务器证书的 CA 证书，自己的客户端证书和私钥等访问信息，这样组件只需要配置这个 Kubeconfig 就行。

下面我们看看 controller-manager.conf 这个文件配置的证书和秘钥是什么。

```bash
$ cat controller-manager.conf
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUN5RENDQWJDZ0F3SUJBZ0lCQURBTkJna3Foa2lHOXcwQkFRc0ZBREFWTVJNd0VRWURWUVFERXdwcmRXSmwKY201bGRHVnpNQjRYRFRJd01EZ3lNREF5TXpBd05Wb1hEVE13TURneE9EQXlNekF3TlZvd0ZURVRNQkVHQTFVRQpBeE1LYTNWaVpYSnVaWFJsY3pDQ0FTSXdEUVlKS29aSWh2Y05BUUVCQlFBRGdnRVBBRENDQVFvQ2dnRUJBSndoCmw4ZVd5SlBsSWpwajlTN09VSWRSTWVxV0Mwb2crN3hQemJQZDhzS2NTemZqWjdHc0ttUXlvQjhoQnNlaVVDdUwKai9teVl5Tk02MkxIa0ZKbDI3MXNFWVdmOEtiWS81Y210UmFjRnlMOEpyaTNLQi91eHZnZlEvMXhMK2c3UmRBcQpGQllWRzNtaSs1T1orTExyZlVMUU5qemtoTVllaEhDdHNDRmZJMGF5amJpYk1UUGJLT3lobjV3cHVMZzgvOVdlClNTSnI1TmtnK2R0WHJSZ05YelNpc1JMQVF5MmdEczdOaTN0SklaNjRuRGdIakpyS21HR2dqbEljN1RFdGFUdWcKcnltKy92akVZZ2NxTlhHakY2ekJlT1FXNW5NdUh0K1plYXphZ1QyQTNkUDhGY3lEWVZrSFJVd0RESDBZOVZlcwpOUFAyZnhURzVVZlhWOUV0WVJNQ0F3RUFBYU1qTUNFd0RnWURWUjBQQVFIL0JBUURBZ0trTUE4R0ExVWRFd0VCCi93UUZNQU1CQWY4d0RRWUpLb1pJaHZjTkFRRUxCUUFEZ2dFQkFEajZLYXVQR2dvVnlGQmdNUzFZYlVFRXFHQmoKN3IwaG5vclNuOVp4dlUxZkM1UkZ0UEd0OEI0YU40T3RMa1REUno5ZmdFc1ZidFdoMXRXWURIWUF6N2FDYkVZawpMRTArRzZQMkpxR043SHlrd05BZFp1QS96emhOdVFKZnhjZG5qVHlIRWZXZyt5OEd1S2JqSU1QdFJVOU45bFpoCkZTeUxsYjNvektYbURDK2RuSHhHMXhNbnpCM05TQStYeGk3ZDVHakExemUzYXFxZXM2bWVONTNYWnFkeDE2N0gKLzNBNld6NjZ4UE9nOHlsUFNVa3R5bU1HNTFkOTFsdTFiZWJYUExtdmc0K3BBeFdhZGJGZ21MR0Z0UE1URXcrWgpIRHZzK3E2NDBIOWJpeitPV2Rld0hjUXE0TW9oQ1dubDhhVzVJYWVSYW1mWS9zZy8xd1NXMkZteGViQT0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=
    server: https://10.0.4.3:6443
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: system:kube-controller-manager
  name: system:kube-controller-manager@kubernetes
current-context: system:kube-controller-manager@kubernetes
kind: Config
preferences: {}
users:
- name: system:kube-controller-manager
  user:
    client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUM1ekNDQWMrZ0F3SUJBZ0lJSWN4Ynk4VWEvV1F3RFFZSktvWklodmNOQVFFTEJRQXdGVEVUTUJFR0ExVUUKQXhNS2EzVmlaWEp1WlhSbGN6QWVGdzB5TURBNE1qQXdNak13TURWYUZ3MHlNVEE0TWpBd01qTXdNRGRhTUNreApKekFsQmdOVkJBTVRIbk41YzNSbGJUcHJkV0psTFdOdmJuUnliMnhzWlhJdGJXRnVZV2RsY2pDQ0FTSXdEUVlKCktvWklodmNOQVFFQkJRQURnZ0VQQURDQ0FRb0NnZ0VCQU5YK0Vqa3c0NDNTNzh5d05LL0dIQTV2eFZCS0Rhbi8KZ21yaUlFTW1hYWhlbDllREJXR0s0dVVtY1VXMXU1TCszeUR0amJlKy83MHZ2M3hvSWY1VkNZQXZqYUorN2twUQpyYW5RUE93cFJnbUlqNTEzV1FsZzMxWDlqREpuNlAybVpYTmZ6YWVOalBwOXdrZGkzZGVqSUZaSm1zYjQ0R3VwCkNrdlpodE5iYUlrVVU1U3dCT3h1dE92Um1uemdHQ3BQa0c4ME9pNWdYcDVzTHJ2dmVYSWxpem5wbHNsa3pxbjQKdWNJMHZMekhQY0JsSWhncEVJOXdCVTFOK3VWLzIxTmRaT3p1UlpFVFRMQ0xmNjhVR0FlM0ZCVXJHblJCUTJJZgpKLzhpNnJVQ2l1T25PQWUvOFNLbzlVM0ExOHN3RDJYandTZVo1NzRRclRGdkFjUjBYQ1BibW4wQ0F3RUFBYU1uCk1DVXdEZ1lEVlIwUEFRSC9CQVFEQWdXZ01CTUdBMVVkSlFRTU1Bb0dDQ3NHQVFVRkJ3TUNNQTBHQ1NxR1NJYjMKRFFFQkN3VUFBNElCQVFBcTY0cVBnVllzRzFGb05QQTRTNlJ0bGwrbUdTVUE2QlVNakQrWkt0eVM1NExCVFZnWQp5K1IrL0Zpd3o2RW1xWUpnZ0EyNWZGdkszSWlGNCt5d3JxeDZETlVZa3BBQkZFWXQ5VjU4a2gxV0pha3BvMEZQCnRZRkFaNmlEMlg4UlBZeUUwSXBMYlFqTGRncS9LYTRiSlhZRFhsS3RTV2UwbmJoY2FUWjRpRm5BcldndmpRQ0sKU05kV0tmSUpGNjJiWGE5a1BGc3ROYWVrWjdoQVZEZzhBbEd1c0tlYVFLdFNLZ2dMREFreElRWjlnNTZSVUprYwp6UUhRVHlibmVTcXJEN3cxT0xIR2RpYmZEYXhzMWdtbi9oL20xNk5ib3NMUlgxNkkxK3VKOWV1d29TWlp3Z29zCmpVRExuWVg1Zm1ZcEdhK2ZDbjdiMTJ4Mzg3SFpmbkE4eTFDTQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCg==
    client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlFb3dJQkFBS0NBUUVBMWY0U09URGpqZEx2ekxBMHI4WWNEbS9GVUVvTnFmK0NhdUlnUXlacHFGNlgxNE1GCllZcmk1U1p4UmJXN2t2N2ZJTzJOdDc3L3ZTKy9mR2doL2xVSmdDK05vbjd1U2xDdHFkQTg3Q2xHQ1lpUG5YZFoKQ1dEZlZmMk1NbWZvL2FabGMxL05wNDJNK24zQ1IyTGQxNk1nVmttYXh2amdhNmtLUzltRzAxdG9pUlJUbExBRQo3RzYwNjlHYWZPQVlLaytRYnpRNkxtQmVubXd1dSs5NWNpV0xPZW1XeVdUT3FmaTV3alM4dk1jOXdHVWlHQ2tRCmozQUZUVTM2NVgvYlUxMWs3TzVGa1JOTXNJdC9yeFFZQjdjVUZTc2FkRUZEWWg4bi95THF0UUtLNDZjNEI3L3gKSXFqMVRjRFh5ekFQWmVQQko1bm52aEN0TVc4QnhIUmNJOXVhZlFJREFRQUJBb0lCQURCTHVrTXNGSDlpdHZwRQpYbSs1VDRXMmxocXJ5Kyt0R2ZzVGMrS1QzYzdCSXBYaUhTbkpsYkhQL2txVVhIUXRqNkEzM1A4MlhUT09maklPCnNuVmJMZHkvWHNEbzB0RDA2bXpqOFl2L09LNVlJc21RTVFrYjB1dnVZR0RUOE5LbVpra211eHh3cHZ1MXZFNHUKTXhGQzRMNTR1RFRsNElpTHl5WVpQd09lb3JZazlYVi9LSkN4a2g1RnVmZzBublI5MjNXQ1lDZVNyaUVWRm9LbQovbzBKYmlVNE1MU3FxallRWnljRnFSbGM0Vy9sMVJuMldLbU1KZ29EVUE4eEZiOEtJYjk4bGpOR0F0Z2QyNFQwCmcxS1VnbDRNazlPOTEvUzdrbHc3L3dsaHBkY3g0eFJ2dEtBTWZiM0RBa1V4MmpFZDB2ckZvU3NseHM0NXJOc2QKM296ZDhFRUNnWUVBM1p2OGJZTDE0ZlU3c0ZnVXlXekl4ejA3WlJ5czFzZitESmVXRmNCOEZoa2Jpb3Q1T0dqZwp0RHZmQlcvOXliMmtPM3RRNlJxNkFMOFpKcGE1QjcyOVF2YUJ1bDlpRHladVZndC8xUnY1d290Smo1SGZQS25vCnFVNzh6NVdtQUR2VitmQTVXaW9ad0hBVzQ3RHFLUU5OdzYyNWZaZFV3NTFXblZOWHpBZWR2VkVDZ1lFQTl6TjgKU3JrOXlsUlBaZnQ4emgrK05OZndoOFgzRWlZR2JwUHNpWG4zTitxYnQ4eXJORFhNYXRId1NrS2dxWDdxU0twQQpDc3ZGeXRreDhBc2VMaDZhQzBMbXh1aVVtQW8yMnBBU21veDY3VFo1ditqeXdtNGt3TFFXdjh6R0ptMjhyUlRVClZkejMvZC9pTkJHZDlKaHB0dzY3REUvcENPTm9vVWhOOHFwbVQyMENnWUJSYm9vNWE1QVNzZHgzRmthOUpWNDUKNkVRMUNXNXhsaGZDWk1sZndOVllBVzNmWVJUd0o0bTZjTzJvdjloUUU0R1A0ZVovWWJUTHBXMEdnd2dHMGpBRAp0VFZDV041ZGxzK2dpcVUwbUEwVThiM2NKY3dVTEpNejg3UnVTeDB1cE00aUE2WHZmZHpzbThPdGMwcjRPeUNPCk1QNGlLa09aaGUxWDdsSXF4UG12b1FLQmdFdk45UUp4RmJxeTZmb3JDWlduOUVyK0lSdHhvSmRuSTdmTEV0RUIKbnNiOTRheVdUYlhmL1lTUVJuQnZTQmRSL1FRMWVSZ1didHdLaUo3RXVnZUlpTktGUElHb2x0Q2M2VDlTeVBHdAp2SkI3a1JCQm5oZnpjTC9MT2VLdEorSm02bUhsTGt2NlMrNEZOcmVpNDE0N1VzZTQ4N0VOM0RkR2pUSlFHdDhjClUrMXRBb0dCQU1JVzFrcHhGZ1NOUjJORGczdHlJWGNhVDJiQStPTWZrc25nNVdrQUdqb0xveS9laE5waWtJTHAKbHFVVG5oZENaMHBvV3d2MUkxdkZ5VVRJTTREUHd1WVNicnZQNjV2UkJua1M5RGlldVE5Q0FEbXRkT0h1WWR2VgpzSy90cmQ5RTNTdUNVNWNSdXJqVkFacGJoOVNIQzU3bk9rVTRJY2EzT0EvbGZsSmRvbUl0Ci0tLS0tRU5EIFJTQSBQUklWQVRFIEtFWS0tLS0tCg==
```

我们解析下 certificate-authority-data 这个内容看看是不是 Kubernetes 的 CA 的证书

```bash
$ echo "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUN5RENDQWJDZ0F3SUJBZ0lCQURBTkJna3Foa2lHOXcwQkFRc0ZBREFWTVJNd0VRWURWUVFERXdwcmRXSmwKY201bGRHVnpNQjRYRFRJd01EZ3lNREF5TXpBd05Wb1hEVE13TURneE9EQXlNekF3TlZvd0ZURVRNQkVHQTFVRQpBeE1LYTNWaVpYSnVaWFJsY3pDQ0FTSXdEUVlKS29aSWh2Y05BUUVCQlFBRGdnRVBBRENDQVFvQ2dnRUJBSndoCmw4ZVd5SlBsSWpwajlTN09VSWRSTWVxV0Mwb2crN3hQemJQZDhzS2NTemZqWjdHc0ttUXlvQjhoQnNlaVVDdUwKai9teVl5Tk02MkxIa0ZKbDI3MXNFWVdmOEtiWS81Y210UmFjRnlMOEpyaTNLQi91eHZnZlEvMXhMK2c3UmRBcQpGQllWRzNtaSs1T1orTExyZlVMUU5qemtoTVllaEhDdHNDRmZJMGF5amJpYk1UUGJLT3lobjV3cHVMZzgvOVdlClNTSnI1TmtnK2R0WHJSZ05YelNpc1JMQVF5MmdEczdOaTN0SklaNjRuRGdIakpyS21HR2dqbEljN1RFdGFUdWcKcnltKy92akVZZ2NxTlhHakY2ekJlT1FXNW5NdUh0K1plYXphZ1QyQTNkUDhGY3lEWVZrSFJVd0RESDBZOVZlcwpOUFAyZnhURzVVZlhWOUV0WVJNQ0F3RUFBYU1qTUNFd0RnWURWUjBQQVFIL0JBUURBZ0trTUE4R0ExVWRFd0VCCi93UUZNQU1CQWY4d0RRWUpLb1pJaHZjTkFRRUxCUUFEZ2dFQkFEajZLYXVQR2dvVnlGQmdNUzFZYlVFRXFHQmoKN3IwaG5vclNuOVp4dlUxZkM1UkZ0UEd0OEI0YU40T3RMa1REUno5ZmdFc1ZidFdoMXRXWURIWUF6N2FDYkVZawpMRTArRzZQMkpxR043SHlrd05BZFp1QS96emhOdVFKZnhjZG5qVHlIRWZXZyt5OEd1S2JqSU1QdFJVOU45bFpoCkZTeUxsYjNvektYbURDK2RuSHhHMXhNbnpCM05TQStYeGk3ZDVHakExemUzYXFxZXM2bWVONTNYWnFkeDE2N0gKLzNBNld6NjZ4UE9nOHlsUFNVa3R5bU1HNTFkOTFsdTFiZWJYUExtdmc0K3BBeFdhZGJGZ21MR0Z0UE1URXcrWgpIRHZzK3E2NDBIOWJpeitPV2Rld0hjUXE0TW9oQ1dubDhhVzVJYWVSYW1mWS9zZy8xd1NXMkZteGViQT0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo="|base64 -d
-----BEGIN CERTIFICATE-----
MIICyDCCAbCgAwIBAgIBADANBgkqhkiG9w0BAQsFADAVMRMwEQYDVQQDEwprdWJl
cm5ldGVzMB4XDTIwMDgyMDAyMzAwNVoXDTMwMDgxODAyMzAwNVowFTETMBEGA1UE
AxMKa3ViZXJuZXRlczCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJwh
l8eWyJPlIjpj9S7OUIdRMeqWC0og+7xPzbPd8sKcSzfjZ7GsKmQyoB8hBseiUCuL
j/myYyNM62LHkFJl271sEYWf8KbY/5cmtRacFyL8Jri3KB/uxvgfQ/1xL+g7RdAq
FBYVG3mi+5OZ+LLrfULQNjzkhMYehHCtsCFfI0ayjbibMTPbKOyhn5wpuLg8/9We
SSJr5Nkg+dtXrRgNXzSisRLAQy2gDs7Ni3tJIZ64nDgHjJrKmGGgjlIc7TEtaTug
rym+/vjEYgcqNXGjF6zBeOQW5nMuHt+ZeazagT2A3dP8FcyDYVkHRUwDDH0Y9Ves
NPP2fxTG5UfXV9EtYRMCAwEAAaMjMCEwDgYDVR0PAQH/BAQDAgKkMA8GA1UdEwEB
/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBADj6KauPGgoVyFBgMS1YbUEEqGBj
7r0hnorSn9ZxvU1fC5RFtPGt8B4aN4OtLkTDRz9fgEsVbtWh1tWYDHYAz7aCbEYk
LE0+G6P2JqGN7HykwNAdZuA/zzhNuQJfxcdnjTyHEfWg+y8GuKbjIMPtRU9N9lZh
FSyLlb3ozKXmDC+dnHxG1xMnzB3NSA+Xxi7d5GjA1ze3aqqes6meN53XZqdx167H
/3A6Wz66xPOg8ylPSUktymMG51d91lu1bebXPLmvg4+pAxWadbFgmLGFtPMTEw+Z
HDvs+q640H9biz+OWdewHcQq4MohCWnl8aW5IaeRamfY/sg/1wSW2FmxebA=
-----END CERTIFICATE-----
// 查看集群 ca
$ cat pki/ca.crt
-----BEGIN CERTIFICATE-----
MIICyDCCAbCgAwIBAgIBADANBgkqhkiG9w0BAQsFADAVMRMwEQYDVQQDEwprdWJl
cm5ldGVzMB4XDTIwMDgyMDAyMzAwNVoXDTMwMDgxODAyMzAwNVowFTETMBEGA1UE
AxMKa3ViZXJuZXRlczCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJwh
l8eWyJPlIjpj9S7OUIdRMeqWC0og+7xPzbPd8sKcSzfjZ7GsKmQyoB8hBseiUCuL
j/myYyNM62LHkFJl271sEYWf8KbY/5cmtRacFyL8Jri3KB/uxvgfQ/1xL+g7RdAq
FBYVG3mi+5OZ+LLrfULQNjzkhMYehHCtsCFfI0ayjbibMTPbKOyhn5wpuLg8/9We
SSJr5Nkg+dtXrRgNXzSisRLAQy2gDs7Ni3tJIZ64nDgHjJrKmGGgjlIc7TEtaTug
rym+/vjEYgcqNXGjF6zBeOQW5nMuHt+ZeazagT2A3dP8FcyDYVkHRUwDDH0Y9Ves
NPP2fxTG5UfXV9EtYRMCAwEAAaMjMCEwDgYDVR0PAQH/BAQDAgKkMA8GA1UdEwEB
/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBADj6KauPGgoVyFBgMS1YbUEEqGBj
7r0hnorSn9ZxvU1fC5RFtPGt8B4aN4OtLkTDRz9fgEsVbtWh1tWYDHYAz7aCbEYk
LE0+G6P2JqGN7HykwNAdZuA/zzhNuQJfxcdnjTyHEfWg+y8GuKbjIMPtRU9N9lZh
FSyLlb3ozKXmDC+dnHxG1xMnzB3NSA+Xxi7d5GjA1ze3aqqes6meN53XZqdx167H
/3A6Wz66xPOg8ylPSUktymMG51d91lu1bebXPLmvg4+pAxWadbFgmLGFtPMTEw+Z
HDvs+q640H9biz+OWdewHcQq4MohCWnl8aW5IaeRamfY/sg/1wSW2FmxebA=
-----END CERTIFICATE-----
```

从解码可以发现，Kubeconfig 配置的就是 Kubernetes 的 CA 证书，client-certificate-data 和 client-key-data 就是 Kube-controller-manager 用来访问 Kube-apiserver 的客户端证书和秘钥，只不过 Kubeconfig 对内容进行了 base64 编码。这个就是整个 Kube-controller-manager和 Kube-apiserver 证书认证的方式。

## **Kube-scheduler**

Kube-scheduler 也是同样的原理，也是在 yaml 中配置一个 Kubeconfig 来进行访问 Kube-apiserver

```bash
$ cat scheduler.conf
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUN5RENDQWJDZ0F3SUJBZ0lCQURBTkJna3Foa2lHOXcwQkFRc0ZBREFWTVJNd0VRWURWUVFERXdwcmRXSmwKY201bGRHVnpNQjRYRFRJd01EZ3lNREF5TXpBd05Wb1hEVE13TURneE9EQXlNekF3TlZvd0ZURVRNQkVHQTFVRQpBeE1LYTNWaVpYSnVaWFJsY3pDQ0FTSXdEUVlKS29aSWh2Y05BUUVCQlFBRGdnRVBBRENDQVFvQ2dnRUJBSndoCmw4ZVd5SlBsSWpwajlTN09VSWRSTWVxV0Mwb2crN3hQemJQZDhzS2NTemZqWjdHc0ttUXlvQjhoQnNlaVVDdUwKai9teVl5Tk02MkxIa0ZKbDI3MXNFWVdmOEtiWS81Y210UmFjRnlMOEpyaTNLQi91eHZnZlEvMXhMK2c3UmRBcQpGQllWRzNtaSs1T1orTExyZlVMUU5qemtoTVllaEhDdHNDRmZJMGF5amJpYk1UUGJLT3lobjV3cHVMZzgvOVdlClNTSnI1TmtnK2R0WHJSZ05YelNpc1JMQVF5MmdEczdOaTN0SklaNjRuRGdIakpyS21HR2dqbEljN1RFdGFUdWcKcnltKy92akVZZ2NxTlhHakY2ekJlT1FXNW5NdUh0K1plYXphZ1QyQTNkUDhGY3lEWVZrSFJVd0RESDBZOVZlcwpOUFAyZnhURzVVZlhWOUV0WVJNQ0F3RUFBYU1qTUNFd0RnWURWUjBQQVFIL0JBUURBZ0trTUE4R0ExVWRFd0VCCi93UUZNQU1CQWY4d0RRWUpLb1pJaHZjTkFRRUxCUUFEZ2dFQkFEajZLYXVQR2dvVnlGQmdNUzFZYlVFRXFHQmoKN3IwaG5vclNuOVp4dlUxZkM1UkZ0UEd0OEI0YU40T3RMa1REUno5ZmdFc1ZidFdoMXRXWURIWUF6N2FDYkVZawpMRTArRzZQMkpxR043SHlrd05BZFp1QS96emhOdVFKZnhjZG5qVHlIRWZXZyt5OEd1S2JqSU1QdFJVOU45bFpoCkZTeUxsYjNvektYbURDK2RuSHhHMXhNbnpCM05TQStYeGk3ZDVHakExemUzYXFxZXM2bWVONTNYWnFkeDE2N0gKLzNBNld6NjZ4UE9nOHlsUFNVa3R5bU1HNTFkOTFsdTFiZWJYUExtdmc0K3BBeFdhZGJGZ21MR0Z0UE1URXcrWgpIRHZzK3E2NDBIOWJpeitPV2Rld0hjUXE0TW9oQ1dubDhhVzVJYWVSYW1mWS9zZy8xd1NXMkZteGViQT0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=
    server: https://10.0.4.3:6443
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: system:kube-scheduler
  name: system:kube-scheduler@kubernetes
current-context: system:kube-scheduler@kubernetes
kind: Config
preferences: {}
users:
- name: system:kube-scheduler
  user:
    client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUMzakNDQWNhZ0F3SUJBZ0lJVlUybER1V2Y1OHd3RFFZSktvWklodmNOQVFFTEJRQXdGVEVUTUJFR0ExVUUKQXhNS2EzVmlaWEp1WlhSbGN6QWVGdzB5TURBNE1qQXdNak13TURWYUZ3MHlNVEE0TWpBd01qTXdNRGhhTUNBeApIakFjQmdOVkJBTVRGWE41YzNSbGJUcHJkV0psTFhOamFHVmtkV3hsY2pDQ0FTSXdEUVlKS29aSWh2Y05BUUVCCkJRQURnZ0VQQURDQ0FRb0NnZ0VCQU14SzJrNmZnWG50cHVNM2JPZ2ZUS0V4aVhsdzdMQVc2VHpUK2thcndVS2UKK2hKSExWSjF4OUphazlDajZ2VWRZdEdkRzMyd0V1R0VFa3ltN0dFZXlyeHJneGRsU3NyVmRqQkFTYnhwNndpZApvZ3dmL2xVa2kza2FPVUozVXd6bmFnWCt6ZUh1d2hVN0R3NkNuaUpkMy9SZW9hU0FjZitvbDl0TTRiazRldVRrCnRXaUE5SDk0VnlQam42SUpkUDdNb1h4TWpZN1c1UysxNy9aczBwbXJabHhuWFdqZjZESXdyNnplbStSNlF1YnAKeE5adEk1WWdsNDk2a09BaTZMVW5xemhCNHIzaDdDOUd0SjFnVDk1YmxiQ0VZNzRtNmVLREZpNXFwZ3JRZnA0YwoxMlhRYzNtcGQzY2IrZXlGUFNsYUVDUmRwS1BKazRpZXgxNnN4TmwzRmk4Q0F3RUFBYU1uTUNVd0RnWURWUjBQCkFRSC9CQVFEQWdXZ01CTUdBMVVkSlFRTU1Bb0dDQ3NHQVFVRkJ3TUNNQTBHQ1NxR1NJYjNEUUVCQ3dVQUE0SUIKQVFBWFovVTcxSnRqQXQ3MjJLeVl6Q1RDZlF1bHdMM2EySGN6NGw5NXVaMFNWVG5ncTNhWUJxeVdwQ2puM3VNaApTaGN5OUZ4ZC92am52YXVTWUdXY05abm84dEVNUFhTaitNNzI5bW1vTUNUa0xCUGJSVGZwRGt3aDNnRS9IRWtuCnN0emRoZTZ3dWp4OWduMXl5WTJSOTFTZ3U3cjdwZjlLM1hOeFh2SFo3Z0tDQnJIVisyMVlQTkNCaC8rYlVuZkcKY2pvNlNNZHphT0Y5SlJod2pUS0l5VTlkeXJkbFBLUlR0Q3NGVEttdy9HM1d4Z1gvbGRCZnNsZmNaVXR4TlpsYQpablBVNlYvK3gwelBTVG56RzRmYTQ3UkhlZmc3YzczQkZjL0ZiYW9obmhrZHNPMVBNWGdhSjQ1bGo1NVNPL1phCmlIbUphZUF3bnh5d0hMazFtclE1b0ttVAotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCg==
    client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlFcEFJQkFBS0NBUUVBekVyYVRwK0JlZTJtNHpkczZCOU1vVEdKZVhEc3NCYnBQTlA2UnF2QlFwNzZFa2N0ClVuWEgwbHFUMEtQcTlSMWkwWjBiZmJBUzRZUVNUS2JzWVI3S3ZHdURGMlZLeXRWMk1FQkp2R25yQ0oyaURCLysKVlNTTGVSbzVRbmRURE9kcUJmN040ZTdDRlRzUERvS2VJbDNmOUY2aHBJQngvNmlYMjB6aHVUaDY1T1MxYUlEMApmM2hYSStPZm9nbDAvc3loZkV5Tmp0YmxMN1h2OW16U21hdG1YR2RkYU4vb01qQ3ZyTjZiNUhwQzV1bkUxbTBqCmxpQ1hqM3FRNENMb3RTZXJPRUhpdmVIc0wwYTBuV0JQM2x1VnNJUmp2aWJwNG9NV0xtcW1DdEIrbmh6WFpkQnoKZWFsM2R4djU3SVU5S1ZvUUpGMmtvOG1UaUo3SFhxekUyWGNXTHdJREFRQUJBb0lCQVFDbmJhVlRFSGlkdy82bApjMVJIUFBlaG1DYXlKN0ZqYzdOOWpjRXRVREJZZUZBODBLYTlVUmdPTnZ1ejM5TjlSYk1xVlpjbFFEdUpKYU9WCnZLdzN3SE9wVG5lbW9mWlZHL0w4QW9RcjdhYVpiZzlUM3BpamtRclptbnRaRk5BMDRDZk5lQkdsMi9hbVRidSsKU2FCdVMvOXltR2ZqbVAxVTZRaGp5N09uQ0RuNEFsMmw1SXJpUCtlSTgxS3ZjVjRWUWNhcmtQL0F5SityQm56SgpSZjNRSFBRL2pFaUVRMm9kKzQ4N1FzSWNZVlcwZ0FmQ3pKN05NMUJMeTE0Yy8zUFJRS3JLZTdXT3AwM2Z3QmkxCk5TRlc1dmxSUkpnTDduSHQ4TkdsSUhHRE5VT29KR0UvVnppekJUVFpQRS9nOEkxZ1FLYko5b3ZSdXJQa0J6VGsKRHNGQ281bEJBb0dCQU5qalNTVXIybFo0Z1B6MEZ6bnBMTEFBaVhBSDkwZFlBb1BQSUhoWDR2WmtRUjE4Ykx2NgoraXVSR2dMTkQyckV4dHk3dE1tcTQrZkt2S1VXRWorOVR0KzNqWTVmTFdCeWhNTk1uaXN2eDFsdkxlZnFybkRvCnlkODdPb0p3TnZZdit2YitQR3NGaU51SHdXUTR4Wit3WTFaYitCUnB5UVJNUEs1TnVEbDRFMXZQQW9HQkFQRWkKRitwS1VJSmE0NGZuWDk3L1lHalh6Z1lWTEQ4RkRRMTh4dmY3TG43UEhUNzJoK1VCaXJFV29uK2RmcDFBZS95UwpTMER6Q2ZLUDdiM0R3YkxPbmRKcHdLWnUrUjdBaEs5RGFlVEJ3Y2FkRDFpTzNoME5RSVFoVFJPaVJRclN4RWpmCllXVnRmUXFuSUJhS3pMSnRCakVtakRDcXJ2QjJ3QTRza1Z5d09WZWhBb0dBTWZWb3k5OG1FL1QrQVVaWWMwWjYKdksvaStLTmRHbG56ZWxranFaVFUrdHh0QTFXOTFpOGhvUmR6WG1ITncxSkFYR2dBWk5Pd1c1d2ZpQWRsZkxrbQppZkhGOFoySzNrU0N3Rm5OdFRUMFBtMlZyVzRwY0dpdTEzVFZMV2Fid21tYTdYbnlnTlJ0aWVQamNDcURteDBPClJMNDZqcmt2VElZakZDTmk1Qm44bTVFQ2dZQmNHdUs1cW1Nd041bGJpd1J5d0dkS0JNeDhSRkFmVGtXYkZrTkYKNjVycDh5Qy9zUmxkWHdaaitEcGZ0bi9yZnZzZEVhQlBFY2FGOFhZbEd3WDh6N0UyOHhBVVFxVkRtdFBUd2xOTApmcnNPcTJWMk5UUWdNclNuQTdWV1A1QlJ2d29jcjc2YktJUXZzb0N1TzV4T3R4ZzdZL2IraStQQWxBdHVIcFh6CnFwaHNvUUtCZ1FERkxITzFwTTNPNlRWN3cybThKWVI0WGxBUWtLZkRPMlFGaDB0bGM1bk1rZUdZbHZFUUlZdVMKS2liV3NJNHVwMHFRcFZjdHF2VU9wc2V1Rk5ZdGVRQzF6YncxNWp4a0xEMm9Gb2c1Yk9WRXk3ekZERU1kVmdpRwpEbjhkbHN3SWp0bUF1SDFGOWdBbGR1V1M0cXkyV0I0SlRPZjBlTDVOM1dTWkRzcm91anA5NlE9PQotLS0tLUVORCBSU0EgUFJJVkFURSBLRVktLS0tLQo=
-24
```

同理，解析 certificate-authority-data 也是 Kubernates 的 CA 证书，client-certificate-data 和 client-key-data 就是 Kube-scheduler 用来访问Kube-apiserver 的客户端证书和秘钥

## **Kubelet**

Kubelet 与 Kube-apiserver 一样，即可以作为服务端，又可以作为客户端，所以分类讲解

### Kubelet 客户端证书

Kubelet 和其他组件类似，用的 Kubeconfig 与 Kube-apiserver 进行认证、鉴权的，都是用 Kubernates 的 CA 签发。

这边我们会给每个节点生成一份客户端的证书和私钥，直接指向一个 kubelet-client-current.pem 文件，这里包含了证书和私钥，每一个节点都不一样。因此每个节点都会有一个自己的客户端证书和私钥。

```bash
$ cat /etc/kubernetes/kubelet.conf
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUN5RENDQWJDZ0F3SUJBZ0lCQURBTkJna3Foa2lHOXcwQkFRc0ZBREFWTVJNd0VRWURWUVFERXdwcmRXSmwKY201bGRHVnpNQjRYRFRJd01EZ3lNREF5TXpBd05Wb1hEVE13TURneE9EQXlNekF3TlZvd0ZURVRNQkVHQTFVRQpBeE1LYTNWaVpYSnVaWFJsY3pDQ0FTSXdEUVlKS29aSWh2Y05BUUVCQlFBRGdnRVBBRENDQVFvQ2dnRUJBSndoCmw4ZVd5SlBsSWpwajlTN09VSWRSTWVxV0Mwb2crN3hQemJQZDhzS2NTemZqWjdHc0ttUXlvQjhoQnNlaVVDdUwKai9teVl5Tk02MkxIa0ZKbDI3MXNFWVdmOEtiWS81Y210UmFjRnlMOEpyaTNLQi91eHZnZlEvMXhMK2c3UmRBcQpGQllWRzNtaSs1T1orTExyZlVMUU5qemtoTVllaEhDdHNDRmZJMGF5amJpYk1UUGJLT3lobjV3cHVMZzgvOVdlClNTSnI1TmtnK2R0WHJSZ05YelNpc1JMQVF5MmdEczdOaTN0SklaNjRuRGdIakpyS21HR2dqbEljN1RFdGFUdWcKcnltKy92akVZZ2NxTlhHakY2ekJlT1FXNW5NdUh0K1plYXphZ1QyQTNkUDhGY3lEWVZrSFJVd0RESDBZOVZlcwpOUFAyZnhURzVVZlhWOUV0WVJNQ0F3RUFBYU1qTUNFd0RnWURWUjBQQVFIL0JBUURBZ0trTUE4R0ExVWRFd0VCCi93UUZNQU1CQWY4d0RRWUpLb1pJaHZjTkFRRUxCUUFEZ2dFQkFEajZLYXVQR2dvVnlGQmdNUzFZYlVFRXFHQmoKN3IwaG5vclNuOVp4dlUxZkM1UkZ0UEd0OEI0YU40T3RMa1REUno5ZmdFc1ZidFdoMXRXWURIWUF6N2FDYkVZawpMRTArRzZQMkpxR043SHlrd05BZFp1QS96emhOdVFKZnhjZG5qVHlIRWZXZyt5OEd1S2JqSU1QdFJVOU45bFpoCkZTeUxsYjNvektYbURDK2RuSHhHMXhNbnpCM05TQStYeGk3ZDVHakExemUzYXFxZXM2bWVONTNYWnFkeDE2N0gKLzNBNld6NjZ4UE9nOHlsUFNVa3R5bU1HNTFkOTFsdTFiZWJYUExtdmc0K3BBeFdhZGJGZ21MR0Z0UE1URXcrWgpIRHZzK3E2NDBIOWJpeitPV2Rld0hjUXE0TW9oQ1dubDhhVzVJYWVSYW1mWS9zZy8xd1NXMkZteGViQT0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=
    server: https://10.0.4.3:6443
  name: default-cluster
contexts:
- context:
    cluster: default-cluster
    namespace: default
    user: default-auth
  name: default-context
current-context: default-context
kind: Config
preferences: {}
users:
- name: default-auth
  user:
    client-certificate: /var/lib/kubelet/pki/kubelet-client-current.pem
    client-key: /var/lib/kubelet/pki/kubelet-client-current.pem
```

```bash
$ cat /var/lib/kubelet/pki/kubelet-client-current.pem
-----BEGIN CERTIFICATE-----
MIICZzCCAU+gAwIBAgIUPrHB6WlowbhzImI5+NnT0Y4ZzlAwDQYJKoZIhvcNAQEL
BQAwFTETMBEGA1UEAxMKa3ViZXJuZXRlczAeFw0yMDA4MjAwMjI4MDBaFw0yMTA4
MjAwMjI4MDBaMDsxFTATBgNVBAoTDHN5c3RlbTpub2RlczEiMCAGA1UEAxMZc3lz
dGVtOm5vZGU6dm0tNC05LWNlbnRvczBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IA
BJ1Qb3DwFRUjIYaaBxNGTieXObGKdGLG8/HVdwXNkVSIWLGBkz9QsFaOh1IsiQ6g
5FfxRBneWhyQTOgMmD0yvymjVDBSMA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAK
BggrBgEFBQcDAjAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBR2QsIZ/qWdhOExDObO
wiBjcpbUMTANBgkqhkiG9w0BAQsFAAOCAQEATF/xpZD9kcCMFqFDlbo1Zn4DwXh6
X3s5T6r3QNtZQ1SeUHUhnL2Q1DrpICAEFxoqMdB75hxlYCs5UOP6YwBUX77qAVs9
QAXW7/sEhS5firGGP8pEQXgaUWwv6tu2V574JL7M9p+koHL/Fbev9fad8I71XIDQ
qkmnf892VCYnkvw1s7wNJENlxNQUQ1rw0wEccyKlYpxbqXCYStSloSaz6JCFnT06
+EXV5cr/G8UZnYRoMNu6jiajIxhFmYQqBNCqOlJo24TVjeLlNTL5AD8aSXcQ+O16
PWhBYNdEOulokdjg84gAg6jSqN2g+hi4+gHMG1Rw2h+9iu5E5txFjKGiMQ==
-----END CERTIFICATE-----
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIN75eP2QG76VLv/nRWiLzW9Fg9hCzeb33BrZ5n9PhwhToAoGCCqGSM49
AwEHoUQDQgAEnVBvcPAVFSMhhpoHE0ZOJ5c5sYp0Ysbz8dV3Bc2RVIhYsYGTP1Cw
Vo6HUiyJDqDkV/FEGd5aHJBM6AyYPTK/KQ==
-----END EC PRIVATE KEY-----
```

Kubelet 客户端证书可以被自动续签，上面的证书期限都是固定的，下面具体续签的原理

### CSR(**CertificateSigningRequest)**

Kubernetes 提供了一套证书相关的 API(Certificate API），用于实现证书的申请与自动签发。证书的申请者，如 Kubelet，可以通过创建一个 CSR资源来向指定的证书签名者（由 CSR 的 `singerName` 字段指定）申请证书签名，CSR 请求可能被批准，也可能被拒绝。当 CSR 请求被批准后，对应的证书签名者才会对证书签名，并将签名后的证书保存在 CSR 的 `status.Certificat` 字段中，至此整个签发流程就完成了。证书的申请者可以从 `status.Certificate` 中获取已经签名的证书。Kube-controller-manager 内置了一些签名者，分别处理对应 `singerName` 的 CSR 请求：

- `kubernetes.io/kube-apiserver-client`，申请用于访问 Kube-apiserver的证书，**不会自动批准。**
- `kubernetes.io/kube-apiserver-client-kubelet`，Kubelet 申请用于访问 Kube-apiserver的客户端证书，**可能会被自动批准。**
- `kubernetes.io/kubelet-serving`， Kubelet 的服务端证书，**不会自动批准。**
- `kubernetes.io/legacy-unknown`，第三方应用的证书申请，**不会自动批准。**

Kubelet 进行客户端证书轮换时，创建的 CSR 中的 `singerName` 就是 `kubernetes.io/kube-apiserver-client-kubelet`，正常情况下，会被 Kube-controller-manager 自动批准，然后签发证书。

当 CSR 提交后，需要由审批者（可以是人，也可以是程序）批准后才能进行后续的证书签发操作。Kube-controller-manager 内置了一个审批控制器，可以自动批准某些 CSR 请求。但为了防止与其他的审批者发生冲突，Kube-controller-manager 不会显式的拒绝任何 CSR。对于不会被Kube-controller-manager 处理的 CSR，我们可以使用 API 的方式处理，如实现一个专门的控制器来来自动批准或拒绝，或者使用 Kubectl 命令行：

```bash
# 批准一个CSR
$ kubectl certificate approve <certificate-signing-request-name>
# 拒绝一个CSR
$ kubectl certificate deny <certificate-signing-request-name>
```

### Kubelet 客户端证书自动续签

对于 `kubernetes.io/kube-apiserver-client-kubelet` 类型的 CSR，Kube-controller-manager 根据申请者是否具备对应的 RBAC 权限，来决定是否批准该 CSR。Kubelet 在两种情况下都会创建 CSR 请求：

1、在首次加入集群时，还没有生成客户端证书，Kubelet 需要创建 CSR 资源来申请，这个阶段也就是 TLS 引导阶段。

2、当客户端证书快过期时，Kubelet 会发起证书轮换，创建 CSR 请求申请新的证书。

对于这两种场景，Kubernetes 提供了两个默认权限（ClusterRole）：

1、`nodeclient`：当节点首次创建证书时，Kubelet 还没有正式的客户端证书，处于 TLS 引导阶段。此时Kubelet 会使用 `bootstrap token` 认证方式来请求 Kube-apiserver。`kubeadm init`创建的 `bootstrap token` 所属用户组为 `system:bootstrappers:kubeadm:default-node-token`，`kubeadm` 会负责将 `nodeclient` 权限赋予该用户组。

2、`selfnodeclient`：当节点请求证书轮换时，Kubelet 已经有一个正式的客户端证书。Kubelet 的证书属于 `system:nodes` 用户组，`kubeadm` 会负责将 `selfnodeclient` 权限赋予该用户组。

```bash
# 两个默认权限
$ kubectl get clusterrole -l kubernetes.io/bootstrapping=rbac-defaults  | grep nodeclient
system:certificates.k8s.io:certificatesigningrequests:nodeclient       2021-09-08T14:59:17Z
system:certificates.k8s.io:certificatesigningrequests:selfnodeclient   2021-09-08T14:59:17Z
# kubeadm会负责将这两个权限绑定到对应的用户组
$ kubectl get clusterrolebinding kubeadm:node-autoapprove-bootstrap kubeadm:node-autoapprove-certificate-rotation  -owide
NAME                                            ROLE                                                                               AGE   USERS   GROUPS                                            SERVICEACCOUNTS
kubeadm:node-autoapprove-bootstrap              ClusterRole/system:certificates.k8s.io:certificatesigningrequests:nodeclient       27d           system:bootstrappers:kubeadm:default-node-token
kubeadm:node-autoapprove-certificate-rotation   ClusterRole/system:certificates.k8s.io:certificatesigningrequests:selfnodeclient   27d           system:nodes

```

当 CSR 请求被批准后，签发者才可以签发证书。Kube-controller-manager 同样也内置了签发控制器。通过为 Kube-controller-manager 设置 `--cluster-signing-cert-file` 和 `--cluster-signing-key-file` 启动参数以开启内置的签发控制器，这两个参数分别表示用于签名的证书和私钥，也就是集群的 CA 证书。

在1.18之前，`kube-controller-manager`会为所有已经批准的CSR签发证书。1.18之后，`kube-controller-manager`限制了CSR的`singerName`，只会为上述的四种指定`singerName`的CSR请求签发证书。类似的，对于不会自动签发证书的CSR请求，我们同样可以通过`kubectl`来手动签发，亦或者通过实现一个专门的控制器来自动签发。

> Kube-controller-manager 通过配置 Kubelet 客户端证书续签周期 *`--experimental-cluster-signing-duration=87600h0m0s`*，来开启自动续签 Kubelet 客户端证书
> 

### Kubelet 的服务端证书

Kubelet 同样对外暴露了 HTTPS 服务，其客户端主要是 Kube-apiserver 和一些监控组件，如 metric-server。Kube-apiserver 需要访问 Kubelet 来获取容器的日志和执行命令（*`kubectl logs/exec`*)， 监控组件需要访问 Kubelet 暴露的 cadvisor 接口来获取监控信息。理想情况下，我们需要将 Kubelet 的 CA 证书配置到 Kube-apiserver 和 metric-server 中，以便于校验 Kubelet 的服务端证书，保证安全性。但使用默认的集群设置方法是无法做到这点的，需要做一些额外的工作。

Kubernetes 中除了 Kubelet 的服务端证书以外，其他证书都要由集群根 CA（或是基于根CA的中间CA）签发。 Kubelet 的证书则没有这个要求。实际上，在 Kubelet 在启动时，如果没有指定服务端证书路径，会创建一个自签的 CA 证书，并使用该 CA 为自己签发服务端证书。

Kubelet 服务端证书和客户端证书生成逻辑不一样，有以下三种情况，可自选：

- 使用通过 *`--tls-private-key-file`* 和 *`--tls-cert-file`*  所设置的密钥和证书，这样每个节点的根证书有可能就不一样
- 如果没有提供密钥和证书，则创建自签名的密钥和证书，也会导致每个节点的根证书不一样(如果 kubeadm init/join 没有其他配置，默认都是这种情况)，Kubelet 每次重启都会创建证书和私钥
- 通过 CSR API 从集群服务器请求服务证书

前面两种情况就会导致每个节点的 Kubelet 的根 CA 可能都不一样，这就导致客户端组件，如 metric-server ，Kube-apiserver 都没办法校验 Kubelet 的服务端证书。为了应对这种情况，metric-server 需要添加 *`--kubelet-insecure-tls`* 来跳过服务端证书的校验，而 Kube-apiserver 默认不校验 Kubelet 服务端证书。

第三种情况是 CSR 签发者统一用集群的根 CA 为各 Kubelet 签发服务端证书，Kube-apiserver 和其他组件就可以通过配置集群根 CA 来实现 HTTPS 的服务端证书校验了。我们可以在 Kubelet 配置文件配置 *`serverTLSBootstrap = true`* 就可以启用这项特性，使用 CSR 来申请服务端证书。这项配置同样也会开启服务端证书的自动轮换功能。不过这个过程并不是全自动的，在 CSR(**CertificateSigningRequest)** 章节中提到，Kubelet 的服务端证书 CSR 请求，即 *`singerName`* 为 *`kubernetes.io/kubelet-serving`* 的 CSR 请求，不会被 Kube-controller-manager 自动批准，也就是说我们需要手动批准这些 CSR，或者使用第三方控制器。

为什么 Kubernetes 不自动批准 Kubelet 的服务端证书呢？这样不是很方便吗？原因是出于安全考量—— Kubernetes 没有足够的能力来辨别该 CSR 是否应该被批准。

HTTPS 服务端证书的重要作用就是向客户端证明“我是我”，防止有人冒充“我”跟客户端通信，也就是防止中间人攻击。在向权威 CA 机构申请证书时，我们要提供一系列证明材料，证明这个站点是我的，包括要证明我是该站点域名的所有者，CA 审核通过后才会签发证书。但 K8S 集群本身是没有足够的能力来辨别 Kubelet 身份的，因为节点 IP，DNS 名称可能发生变化，K8S 自身没有足够的能力判断哪些 IP，哪些 DNS 是合法的，这属于基础设施管理者的职责范围。如果你的集群是云厂商提供，那么你的云厂商可以提供对应的控制器来判断 CSR 请求的合法性，批准合法的 CSR 请求。如果是自建集群，那么只有集群管理员才能判断 CSR 请求中包含的节点 IP，DNS 名称是不是真实有效的。如果 Kube-controller-manager 自动签发这些证书，则会产生中间人攻击的风险。

假设节点 A 上的服务 `bar` 使用 HTTPS 暴露服务，并且服务端证书是通过 CSR 请求申请的，由集群根 CA 签发。假设有入侵者获取了节点 A 的权限，那他可以很方便的利用 Kubelet 的客户端证书的权限，创建一个 CSR 请求来申请一份 IP 为 `bar` service IP，DNS 名称为 `bar` service DNS 的服务端证书。如果 Kube-controller-manager 自动通过并签发这个证书，那入侵者就可以使用这个证书，配合节点上的 Kube-proxy，劫持所有经过 `bar` 服务的流量。

## **Service Account 认证**

在 Kubernetes 集群内部访问 Kube-apiserver 使用的是 Service Account ，如 pod 访问 Kube-apiserver

在 /etc/kubernetes/pki 目录下，还有 sa.pub，sa.key 这两个文件没有讲解。这两个就是用于 ServiceAccount 认证的，这两个文件是一对密钥对，sa.pub 代表公钥，sa.key 代表私钥。

Kubernetes 集群中还有个重要的系统组件 Kube-proxy，它也需要访问 Kube-apiserver，但是它和 Kube-controller-manager，Kube-scheduler 不一样，它就是使用 ServiceAccount 来与 Kube-apiserver 进行认证，下面详细看看。

当 Kube-proxy pod 在集群中创建时，如果 Pod 没有指定 ServiceAccount，kube-controller-manager 会默认创建一个没有任何权限的 ServiceAccount，同时 Kube-controller-manager 为该 ServiceAccount 生成一个 JWT token，并使用 secret 将该 token 挂载到 Pod 内部。

```bash
$ kubectl get  pod kube-proxy-6bf2t -n kube-system -o yaml
.....
  containers:
  - command:
    - /usr/local/bin/kube-proxy
    - --config=/var/lib/kube-proxy/config.conf
    - --hostname-override=$(NODE_NAME)
    ...
    volumeMounts:
    ...
		// token 文件在 pod 的路径
    - mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      name: kube-proxy-token-rd92l
      readOnly: true
  dnsPolicy: ClusterFirst
  .....
  volumes:
  ...
  - name: kube-proxy-token-rd92l
    secret:
      defaultMode: 420
      secretName: kube-proxy-token-rd92l
```

下面看看 secret 的内容

```bash
$ kubectl get secret -n kube-system kube-proxy-token-rd92l -o yaml
apiVersion: v1
data:
	// 该 ca 就是 Kubernetes 集群中的 CA, 用于 pod 校验 Kube-apiserver 的服务端证书
  ca.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUN5RENDQWJDZ0F3SUJBZ0lCQURBTkJna3Foa2lHOXcwQkFRc0ZBREFWTVJNd0VRWURWUVFERXdwcmRXSmwKY201bGRHVnpNQjRYRFRJd01EZ3lNREF5TXpBd05Wb1hEVE13TURneE9EQXlNekF3TlZvd0ZURVRNQkVHQTFVRQpBeE1LYTNWaVpYSnVaWFJsY3pDQ0FTSXdEUVlKS29aSWh2Y05BUUVCQlFBRGdnRVBBRENDQVFvQ2dnRUJBSndoCmw4ZVd5SlBsSWpwajlTN09VSWRSTWVxV0Mwb2crN3hQemJQZDhzS2NTemZqWjdHc0ttUXlvQjhoQnNlaVVDdUwKai9teVl5Tk02MkxIa0ZKbDI3MXNFWVdmOEtiWS81Y210UmFjRnlMOEpyaTNLQi91eHZnZlEvMXhMK2c3UmRBcQpGQllWRzNtaSs1T1orTExyZlVMUU5qemtoTVllaEhDdHNDRmZJMGF5amJpYk1UUGJLT3lobjV3cHVMZzgvOVdlClNTSnI1TmtnK2R0WHJSZ05YelNpc1JMQVF5MmdEczdOaTN0SklaNjRuRGdIakpyS21HR2dqbEljN1RFdGFUdWcKcnltKy92akVZZ2NxTlhHakY2ekJlT1FXNW5NdUh0K1plYXphZ1QyQTNkUDhGY3lEWVZrSFJVd0RESDBZOVZlcwpOUFAyZnhURzVVZlhWOUV0WVJNQ0F3RUFBYU1qTUNFd0RnWURWUjBQQVFIL0JBUURBZ0trTUE4R0ExVWRFd0VCCi93UUZNQU1CQWY4d0RRWUpLb1pJaHZjTkFRRUxCUUFEZ2dFQkFEajZLYXVQR2dvVnlGQmdNUzFZYlVFRXFHQmoKN3IwaG5vclNuOVp4dlUxZkM1UkZ0UEd0OEI0YU40T3RMa1REUno5ZmdFc1ZidFdoMXRXWURIWUF6N2FDYkVZawpMRTArRzZQMkpxR043SHlrd05BZFp1QS96emhOdVFKZnhjZG5qVHlIRWZXZyt5OEd1S2JqSU1QdFJVOU45bFpoCkZTeUxsYjNvektYbURDK2RuSHhHMXhNbnpCM05TQStYeGk3ZDVHakExemUzYXFxZXM2bWVONTNYWnFkeDE2N0gKLzNBNld6NjZ4UE9nOHlsUFNVa3R5bU1HNTFkOTFsdTFiZWJYUExtdmc0K3BBeFdhZGJGZ21MR0Z0UE1URXcrWgpIRHZzK3E2NDBIOWJpeitPV2Rld0hjUXE0TW9oQ1dubDhhVzVJYWVSYW1mWS9zZy8xd1NXMkZteGViQT0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=
  namespace: a3ViZS1zeXN0ZW0=
	// kube-contoller-manager 生成的 token
  token: ZXlKaGJHY2lPaUpTVXpJMU5pSXNJbXRwWkNJNklpSjkuZXlKcGMzTWlPaUpyZFdKbGNtNWxkR1Z6TDNObGNuWnBZMlZoWTJOdmRXNTBJaXdpYTNWaVpYSnVaWFJsY3k1cGJ5OXpaWEoyYVdObFlXTmpiM1Z1ZEM5dVlXMWxjM0JoWTJVaU9pSnJkV0psTFhONWMzUmxiU0lzSW10MVltVnlibVYwWlhNdWFXOHZjMlZ5ZG1salpXRmpZMjkxYm5RdmMyVmpjbVYwTG01aGJXVWlPaUpyZFdKbExYQnliM2g1TFhSdmEyVnVMWEprT1RKc0lpd2lhM1ZpWlhKdVpYUmxjeTVwYnk5elpYSjJhV05sWVdOamIzVnVkQzl6WlhKMmFXTmxMV0ZqWTI5MWJuUXVibUZ0WlNJNkltdDFZbVV0Y0hKdmVIa2lMQ0pyZFdKbGNtNWxkR1Z6TG1sdkwzTmxjblpwWTJWaFkyTnZkVzUwTDNObGNuWnBZMlV0WVdOamIzVnVkQzUxYVdRaU9pSmhOemRrTjJKaE1TMW1Zek5pTFRRM1lUTXRZV00wWkMweVpXRmtPVEV6WkRVd09ESWlMQ0p6ZFdJaU9pSnplWE4wWlcwNmMyVnlkbWxqWldGalkyOTFiblE2YTNWaVpTMXplWE4wWlcwNmEzVmlaUzF3Y205NGVTSjkuSTRuR0UxOVhJakFPU0lKcWZyb3A2azhHcXBickxBeVFzQ3NoeFhxMEc3RklTZmJudS1TTW9xV1pHUjU0S2hwREdlaGd6WkQwMGVGZG14bEM1ZzBIc2ZzZE40V0tmVFI1ZjY1b3kzTnVvWUxxcUIzUzgySUxLelJHREVBNHpwWmFXeG1lRmtzdU1mdl9UWDRjSGdtYUI3V0ZQZzJ5RWtxV0VPa3kwT0hOWnIxNmd4Mzl3S1owWDRhQ29FOVd0cGlZU1BKYU5SdmtVbENfNTlPZHJTYnBCYnlkd2JOaWVaRjdhcWRBbFdWQ3JXQkRfWmlCaHNnZklVYUpEcVg5TWtRbUpjVS1Yb2pzWUpXNFpNejZ3OEZFTHY4THpCazRLTUc5V185aG5Jc3FfVlFUM2xDek5iSHlNSktWeXZ1VlVrblo5X3AwaTJGQlpDeGVVdlpVazdrd01R
kind: Secret
metadata:
  annotations:
    kubernetes.io/service-account.name: kube-proxy
    kubernetes.io/service-account.uid: a77d7ba1-fc3b-47a3-ac4d-2ead913d5082
  creationTimestamp: "2020-08-20T02:30:48Z"
  name: kube-proxy-token-rd92l
  namespace: kube-system
  resourceVersion: "196"
  selfLink: /api/v1/namespaces/kube-system/secrets/kube-proxy-token-rd92l
  uid: c9ff07a0-4176-4053-a93c-11c7d0aff285
type: kubernetes.io/service-account-token
```

Kube-controller-manager 用 sa.key 即私钥对该 token 进行签名。当 Pod 需要访问 Kube-apiserver 的时候，认证逻辑如下：

- Pod 使用 secret 的 ca.crt 来校验 Kube-apiserver 的服务端证书
- Kube-apiserver 使用 sa.pub 即公钥对 Pod 的 token 进行验证，如果验证成功，则认证通过

这样就达到了 Pod 与 Kube-apiserver 双向认证(这里不是双向 TLS 认证)，所以 ServiceAccount 这种认证方式属于 Kube-apiserver 的 Token 认证。

下面是 ServiceAccout 认证流程图：

![k8s-crt](serviceAccount.jpg "service-account 认证关系图")

sa.pub 和 sa.key 分别被配置到了 Kube-apiserver 和 Kube-controller-manager 的命令行参数中，如下所示：

```bash
/usr/local/bin/kube-apiserver \\ 
  --service-account-key-file=/etc/kubernetes/pki/sa.pub \\          # 用于验证 service account token 的公钥
  ...
  
 /usr/local/bin/kube-controller-manager \\
 --service-account-private-key-file=/etc/kubernetes/pki/sa.key      # 用于对 service account token 进行签名的私钥
 ...
```

## 总结

Kubernetes 证书系统还是比较复杂的，主要是涉及到双向 TLS 认证，但是只要能够弄清楚组件之间相互调用的关系以及双向 TLS 认证原理，就比较容易弄明白 Kubernetes 证书了。

以上主要是分析了 Kubernetes 集群中所有的证书和组件如何使用证书的，对于 Kube-apiserver 来说，我们只分析了 Kube-apiserver 如何根据证书进行认证，后续如何根据证书进行鉴权还没说。由于本篇篇幅较大，证书鉴权内容留到下一篇~

## 引用

https://juejin.cn/post/7016472622246395934