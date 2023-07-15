---
weight: 11
title: "Client-go 客户端 使用"
date: 2022-05-24T09:57:40+08:00
lastmod: 2022-05-24T10:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "k8s-dev.jpg"

tags: ["Kubernetes-dev"]
categories: ["Kubernetes-dev"]

lightgallery: true
---

## 简介

Client-Go 共提供了 4 种与 Kubernetes APIServer 交互的客户端。分别是 RESTClient、DiscoveryClient、ClientSet、DynamicClient。

- RESTClient：最基础的客户端，主要是对 HTTP 请求进行了封装，支持 Json 和 Protobuf 格式的数据。
- DiscoveryClient：发现客户端，负责发现 APIServer 支持的资源组、资源版本和资源信息的。
- ClientSet：负责操作 Kubernetes 内置的资源对象，例如：Pod、Service等。
- DynamicClient：动态客户端，可以对任意的 Kubernetes 资源对象进行通用操作，包括 CRD。

![client-go.jpg](https://s3-us-west-2.amazonaws.com/secure.notion-static.com/3d8971a4-3b48-4ae7-b242-7bea46dd8813/client-go.jpg)

## ****RESTClient****

上图可以看出 RESTClient 是所有 Client 的父类

它就是对 HTTP Request 进行了封装，实现了 RESTFul 风格的 API，可以直接通过 RESTClient 提供的 RESTful 方法 GET()，PUT()，POST()，DELETE() 操作数据

- 同时支持 json 和 protobuf
- 支持所有原生资源和 CRD

### 示例

使用 RESTClient 获取 k8s 集群 pod 资源

```go
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
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
	var err error
	var config *rest.Config

	// 获取 kubeconfig 文件路径
	if h := homeDir(); h != "" {
		kubeConfig = flag.String("kubeConfig", filepath.Join(h, ".kube", "config"), "use kubeconfig to access kube-apiserver")
	} else {
		kubeConfig = flag.String("kubeConfig", "", "use kubeconfig to access kube-apiserver")
	}
	flag.Parse()

	// 获取 kubeconfig
	config, err = clientcmd.BuildConfigFromFlags("", *kubeConfig)
	if err != nil {
		panic(err.Error())
	}

	// 使用 RESTClient 需要开发者自行设置资源 URL
	// pod 资源没有 group，在核心组，所以前缀是 api
	config.APIPath = "api"
	// 设置 corev1 groupVersion
	config.GroupVersion = &corev1.SchemeGroupVersion
	// 设置解析器，用于用于解析 scheme
	config.NegotiatedSerializer = scheme.Codecs.WithoutConversion()
	// 初始化 RESTClient
	restClient, err := rest.RESTClientFor(config)
	if err != nil {
		panic(err.Error())
	}
	// 调用结果用 podList 解析
	result := &corev1.PodList{}
	// 获取 kube-system 命名空间的 pod
	namespace := "kube-system"
	// 链式调用 RESTClient 方法获取，并将结果解析到 corev1.PodList{}
	err = restClient.Get().Namespace(namespace).Resource("pods").Do(context.TODO()).Into(result)
	if err != nil {
		panic(err.Error())
	}

	// 打印结果
	for _, pod := range result.Items {
		fmt.Printf("namespace: %s, pod: %s\n", pod.Namespace, pod.Name)
	}
}
```

程序结果如下：

```bash
namespace: kube-system, pod: coredns-697ddfb55c-5lk74
namespace: kube-system, pod: coredns-697ddfb55c-nnkhp
namespace: kube-system, pod: etcd-master-172-31-97-104
namespace: kube-system, pod: kube-apiserver-master-172-31-97-104
namespace: kube-system, pod: kube-controller-manager-master-172-31-97-104
namespace: kube-system, pod: kube-lvscare-node-172-31-97-105
namespace: kube-system, pod: kube-proxy-49k8k
namespace: kube-system, pod: kube-proxy-fvf57
namespace: kube-system, pod: kube-scheduler-master-172-31-97-104
namespace: kube-system, pod: metrics-server-7f6f9649f9-qvvj8
```

### RESTClient 原理

初始化 RESTClient，可以发现对原生 HTTP 库进行了封装了

```go
func RESTClientFor(config *Config) (*RESTClient, error) {
	if config.GroupVersion == nil {
		return nil, fmt.Errorf("GroupVersion is required when initializing a RESTClient")
	}
	if config.NegotiatedSerializer == nil {
		return nil, fmt.Errorf("NegotiatedSerializer is required when initializing a RESTClient")
	}

	// Validate config.Host before constructing the transport/client so we can fail fast.
	// ServerURL will be obtained later in RESTClientForConfigAndClient()
	_, _, err := defaultServerUrlFor(config)
	if err != nil {
		return nil, err
	}

	// 获取原生 http client
	httpClient, err := HTTPClientFor(config)
	if err != nil {
		return nil, err
	}
	
	// 初始化 RESTClient
	return RESTClientForConfigAndClient(config, httpClient)
}
```

RESTClient 实现了 Interface 接口

```go
type Interface interface {
	GetRateLimiter() flowcontrol.RateLimiter
	Verb(verb string) *Request
	Post() *Request
	Put() *Request
	Patch(pt types.PatchType) *Request
	Get() *Request
	Delete() *Request
	APIVersion() schema.GroupVersion
}
```

RESTClient 的链式调用主要是设置 namespace，资源 name，一些选择器等，最终调用 Do() 方法网络调用

```go
func (r *Request) Do(ctx context.Context) Result {
	var result Result
	err := r.request(ctx, func(req *http.Request, resp *http.Response) {
		result = r.transformResponse(resp, req)
	})
	if err != nil {
		return Result{err: err}
	}
	return result
}

func (r *Request) request(ctx context.Context, fn func(*http.Request, *http.Response)) error {
	//Metrics for total request latency
	start := time.Now()
	defer func() {
		metrics.RequestLatency.Observe(ctx, r.verb, r.finalURLTemplate(), time.Since(start))
	}()

	if r.err != nil {
		klog.V(4).Infof("Error in request: %v", r.err)
		return r.err
	}

	if err := r.requestPreflightCheck(); err != nil {
		return err
	}

	client := r.c.Client
	if client == nil {
		client = http.DefaultClient
	}

	// Throttle the first try before setting up the timeout configured on the
	// client. We don't want a throttled client to return timeouts to callers
	// before it makes a single request.
	if err := r.tryThrottle(ctx); err != nil {
		return err
	}

	if r.timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, r.timeout)
		defer cancel()
	}

	// Right now we make about ten retry attempts if we get a Retry-After response.
	var retryAfter *RetryAfter
	for {
		// 初始化网络请求
		req, err := r.newHTTPRequest(ctx)
		if err != nil {
			return err
		}

		r.backoff.Sleep(r.backoff.CalculateBackoff(r.URL()))
		if retryAfter != nil {
			// We are retrying the request that we already send to apiserver
			// at least once before.
			// This request should also be throttled with the client-internal rate limiter.
			if err := r.tryThrottleWithInfo(ctx, retryAfter.Reason); err != nil {
				return err
			}
			retryAfter = nil
		}
		// 发起网络调用
		resp, err := client.Do(req)
		updateURLMetrics(ctx, r, resp, err)
		if err != nil {
			r.backoff.UpdateBackoff(r.URL(), err, 0)
		} else {
			r.backoff.UpdateBackoff(r.URL(), err, resp.StatusCode)
		}

		done := func() bool {
			defer readAndCloseResponseBody(resp)

			// if the the server returns an error in err, the response will be nil.
			f := func(req *http.Request, resp *http.Response) {
				if resp == nil {
					return
				}
				fn(req, resp)
			}

			var retry bool
			retryAfter, retry = r.retry.NextRetry(req, resp, err, func(req *http.Request, err error) bool {
				// "Connection reset by peer" or "apiserver is shutting down" are usually a transient errors.
				// Thus in case of "GET" operations, we simply retry it.
				// We are not automatically retrying "write" operations, as they are not idempotent.
				if r.verb != "GET" {
					return false
				}
				// For connection errors and apiserver shutdown errors retry.
				if net.IsConnectionReset(err) || net.IsProbableEOF(err) {
					return true
				}
				return false
			})
			if retry {
				err := r.retry.BeforeNextRetry(ctx, r.backoff, retryAfter, req.URL.String(), r.body)
				if err == nil {
					return false
				}
				klog.V(4).Infof("Could not retry request - %v", err)
			}

			f(req, resp)
			return true
		}()
		if done {
			return err
		}
	}
}
```

## ClientSet

ClientSet 在调用 Kubernetes 内置资源非常常用，但是无法操作自定义资源(需要实现自定义资源的 ClientSet 才能操作)。

ClientSet 是在 RESTClient 的基础上封装了对 Resource 和 Version 的管理方法，Client-go 对 Kubernetes 每一个内置资源都封装了 Client，而 ClientSet 就是多个 Client 的集合。

### 示例

使用 ClientSet 获取 k8s 集群 pod 资源

```go
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

func homeDir() string {
	if h := os.Getenv("HOME"); h != "" {
		return h
	}

	return os.Getenv("USERROFILE")
}

func main() {
	var kubeConfig *string

	if h := homeDir(); h != "" {
		kubeConfig = flag.String("kubeConfig", filepath.Join(h, ".kube", "config"), "use kubeconfig to access kube-apiserver")
	} else {
		kubeConfig = flag.String("kubeConfig", "", "use kubeconfig to access kube-apiserver")
	}
	flag.Parse()

	config, err := clientcmd.BuildConfigFromFlags("", *kubeConfig)
	if err != nil {
		panic(err.Error())
	}

	// 获取 clientSet
	clientSet, err := kubernetes.NewForConfig(config)
	if err != nil {
		panic(err.Error())
	}

	namespace := "kube-system"
	// 链式调用 ClientSet 获取 pod 列表
	podList, err := clientSet.CoreV1().Pods(namespace).List(context.TODO(), metav1.ListOptions{})
	if err != nil {
		panic(err.Error())
	}

	for _, pod := range podList.Items {
		fmt.Printf("namespace: %s, pod: %s\n", pod.Namespace, pod.Name)
	}
}
```

### ClientSet 原理

NewForConfig 获取 ClientSet

```go
// k8s.io/client-go/kubernetes/clientset.go:413
func NewForConfig(c *rest.Config) (*Clientset, error) {
	configShallowCopy := *c

	// share the transport between all clients
	httpClient, err := rest.HTTPClientFor(&configShallowCopy)
	if err != nil {
		return nil, err
	}

	return NewForConfigAndClient(&configShallowCopy, httpClient)
}
```

NewForConfigAndClient 获取每个 groupVersion 下的资源 Client

```go
func NewForConfigAndClient(c *rest.Config, httpClient *http.Client) (*Clientset, error) {
	configShallowCopy := *c
	if configShallowCopy.RateLimiter == nil && configShallowCopy.QPS > 0 {
		if configShallowCopy.Burst <= 0 {
			return nil, fmt.Errorf("burst is required to be greater than 0 when RateLimiter is not set and QPS is set to greater than 0")
		}
		configShallowCopy.RateLimiter = flowcontrol.NewTokenBucketRateLimiter(configShallowCopy.QPS, configShallowCopy.Burst)
	}

	var cs Clientset
	var err error
	cs.admissionregistrationV1, err = admissionregistrationv1.NewForConfigAndClient(&configShallowCopy, httpClient)
	if err != nil {
		return nil, err
	}
	cs.admissionregistrationV1beta1, err = admissionregistrationv1beta1.NewForConfigAndClient(&configShallowCopy, httpClient)
	if err != nil {
		return nil, err
	}
	...
	return &cs, nil
}
```

拿 admissionregistrationv1.NewForConfigAndClient 介绍

```go
func NewForConfigAndClient(c *rest.Config, h *http.Client) (*AdmissionregistrationV1Client, error) {
	config := *c
	// 设置 client 参数
	if err := setConfigDefaults(&config); err != nil {
		return nil, err
	}
	// 最终调用 RESTClientForConfigAndClient 生成 RESTClient
	client, err := rest.RESTClientForConfigAndClient(&config, h)
	if err != nil {
		return nil, err
	}
	return &AdmissionregistrationV1Client{client}, nil
}

// 可以发现，这些参数跟上面 RESTClient 差不多
func setConfigDefaults(config *rest.Config) error {
	gv := v1.SchemeGroupVersion
	config.GroupVersion = &gv
	config.APIPath = "/apis"
	config.NegotiatedSerializer = scheme.Codecs.WithoutConversion()

	if config.UserAgent == "" {
		config.UserAgent = rest.DefaultKubernetesUserAgent()
	}

	return nil
}

```

pod 资源实现了一系列方法，比如 List()，可以发现最终调用 RESTClient 的方法

```go
func (c *pods) List(ctx context.Context, opts metav1.ListOptions) (result *v1.PodList, err error) {
	var timeout time.Duration
	if opts.TimeoutSeconds != nil {
		timeout = time.Duration(*opts.TimeoutSeconds) * time.Second
	}
	result = &v1.PodList{}
	err = c.client.Get().
		Namespace(c.ns).
		Resource("pods").
		VersionedParams(&opts, scheme.ParameterCodec).
		Timeout(timeout).
		Do(ctx).
		Into(result)
	return
}
```

## DynamicClient

DynamicClient 见名之义，是一种动态客户端，通过动态指定资源组，资源版本和资源信息，来操作任意的 Kubernetes 资源对象。DynamicClient 不仅能操作 Kubernetes 内置资源，还能操作 CRD 。

DynamicClient 与 ClientSet 都是对 RESTClient 进行了封装

### 示例

DynamicClient 返回的结果不像 ClientSet 那样返回具体资源类型，它返回的是一个动态数据即 map 结构，所以需要将结果进行解析到具体资源类型

```go
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/tools/clientcmd"
)

func homeDir() string {
	if h := os.Getenv("HOME"); h != "" {
		return h
	}

	return os.Getenv("USERROFILE")
}

func main() {
	var kubeConfig *string

	if h := homeDir(); h != "" {
		kubeConfig = flag.String("kubeConfig", filepath.Join(h, ".kube", "config"), "use kubeconfig to access kube-apiserver")
	} else {
		kubeConfig = flag.String("kubeConfig", "", "use kubeconfig to access kube-apiserver")
	}
	flag.Parse()

	config, err := clientcmd.BuildConfigFromFlags("", *kubeConfig)
	if err != nil {
		panic(err.Error())
	}

	// 初始化 DynamicClient
	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		panic(err.Error())
	}

	// 提供 pod 的 gvr，因为是动态调用，dynamicClient 不知道需要操作哪个资源，所以需要自己提供
	gvr := schema.GroupVersionResource{
		Group:    "",
		Version:  "v1",
		Resource: "pods",
	}
	//链式调用 dynamicClient 获取数据
	result, err := dynamicClient.Resource(gvr).Namespace("kube-system").List(context.TODO(), metav1.ListOptions{})
	if err != nil {
		panic(err.Error())
	}
	podList := &corev1.PodList{}
	// 将结果解析到 podList scheme 中
	err = runtime.DefaultUnstructuredConverter.FromUnstructured(
		result.UnstructuredContent(), podList)

	for _, pod := range podList.Items {
		fmt.Printf("namespace: %s, pod: %s\n", pod.Namespace, pod.Name)
	}

}
```

### DynamicClient 原理

dynamic.NewForConfig(config) 初始化 dynamicClient

```go
func NewForConfig(inConfig *rest.Config) (Interface, error) {
	config := ConfigFor(inConfig)

	httpClient, err := rest.HTTPClientFor(config)
	if err != nil {
		return nil, err
	}
	return NewForConfigAndClient(config, httpClient)
}

func NewForConfigAndClient(inConfig *rest.Config, h *http.Client) (Interface, error) {
	config := ConfigFor(inConfig)
	// for serializing the options
	config.GroupVersion = &schema.GroupVersion{}
	config.APIPath = "/if-you-see-this-search-for-the-break"
	// 初始化 RESTClient
	restClient, err := rest.RESTClientForConfigAndClient(config, h)
	if err != nil {
		return nil, err
	}
	return &dynamicClient{client: restClient}, nil
}
```

可以看出 dynamicClient 与 ClientSet 一样都是封装了 RESTClient

dynamicClient.Resource(gvr).Namespace("kube-system").List(context.TODO(), metav1.ListOptions{})

dynamicClient 链式调用中，Resource() 需要传入需要操作对象的 gvr

最终也是调用 RESTClient 来获取数据

```go
func (c *dynamicResourceClient) List(ctx context.Context, opts metav1.ListOptions) (*unstructured.UnstructuredList, error) {
	result := c.client.client.Get().AbsPath(c.makeURLSegments("")...).SpecificallyVersionedParams(&opts, dynamicParameterCodec, versionV1).Do(ctx)
	if err := result.Error(); err != nil {
		return nil, err
	}
	retBytes, err := result.Raw()
	if err != nil {
		return nil, err
	}
	uncastObj, err := runtime.Decode(unstructured.UnstructuredJSONScheme, retBytes)
	if err != nil {
		return nil, err
	}
	if list, ok := uncastObj.(*unstructured.UnstructuredList); ok {
		return list, nil
	}

	list, err := uncastObj.(*unstructured.Unstructured).ToList()
	if err != nil {
		return nil, err
	}
	return list, nil
}
```

DynamicClient 返回的结果是 *unstructured.UnstructuredList

Unstructured 是非结构化数据，用 map[string]interface{} 存储。

```go
type UnstructuredList struct {
	Object map[string]interface{}

	// Items is a list of unstructured objects.
	Items []Unstructured `json:"items"`
}

type Unstructured struct {
	// Object is a JSON compatible map with string, float, int, bool, []interface{}, or
	// map[string]interface{}
	// children.
	Object map[string]interface{}
}
```

所以拿到结果需要 decode 成结构化数据类型

```go
// 将 result decode 到 podList 
podList := &corev1.PodList{}
	err = runtime.DefaultUnstructuredConverter.FromUnstructured(
		result.UnstructuredContent(), podList)
```

## DiscoveryClient

DiscoveryClient 是发现客户端，用于发现 Kube-apiserver 支持的资源组、资源版本、资源类型等。

kubectl api-resources 和 kubectl api-versions 命令就是通过 DiscoveryClient 实现的。

DiscoveryClient 支持本地目录缓存，一般在 ~/.kube/cache 会存储集群所有 gvr 信息，避免每次访问 kube-apiserver

### 示例

通过 DiscoveryClient 查询集群所有的 gvr

```go
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/tools/clientcmd"
)

func homeDir() string {
	if h := os.Getenv("HOME"); h != "" {
		return h
	}

	return os.Getenv("USERROFILE")
}

func main() {
	var kubeConfig *string

	if h := homeDir(); h != "" {
		kubeConfig = flag.String("kubeConfig", filepath.Join(h, ".kube", "config"), "use kubeconfig to access kube-apiserver")
	} else {
		kubeConfig = flag.String("kubeConfig", "", "use kubeconfig to access kube-apiserver")
	}
	flag.Parse()

	config, err := clientcmd.BuildConfigFromFlags("", *kubeConfig)
	if err != nil {
		panic(err.Error())
	}

	// 初始化 DiscoveryClient
	discoveryClient, err := discovery.NewDiscoveryClientForConfig(config)
	if err != nil {
		panic(err.Error())
	}
	// 获取集群所有资源
	_, apiResourceList, err := discoveryClient.ServerGroupsAndResources()
	if err != nil {
		panic(err.Error())
	}

	for _, resources := range apiResourceList {
		gv, err := schema.ParseGroupVersion(resources.GroupVersion)
		if err != nil {
			panic(err.Error())
		}
		for _, resource := range resources.APIResources {
			fmt.Printf("group: %s, version: %s, resource: %s\n", gv.Group, gv.Version, resource.Name)
		}

	}
}
```

结果如下：

```go
group: , version: v1, resource: bindings
group: , version: v1, resource: componentstatuses
group: , version: v1, resource: configmaps
group: , version: v1, resource: endpoints
group: , version: v1, resource: events
group: , version: v1, resource: limitranges
group: , version: v1, resource: namespaces
group: , version: v1, resource: namespaces/finalize
group: , version: v1, resource: namespaces/status
group: , version: v1, resource: nodes
group: , version: v1, resource: nodes/proxy
group: , version: v1, resource: nodes/status
group: , version: v1, resource: persistentvolumeclaims
group: , version: v1, resource: persistentvolumeclaims/status
group: , version: v1, resource: persistentvolumes
group: , version: v1, resource: persistentvolumes/status
group: , version: v1, resource: pods
group: , version: v1, resource: pods/attach
group: , version: v1, resource: pods/binding
group: , version: v1, resource: pods/ephemeralcontainers
group: , version: v1, resource: pods/eviction
group: , version: v1, resource: pods/exec
group: , version: v1, resource: pods/log
group: , version: v1, resource: pods/portforward
group: , version: v1, resource: pods/proxy
group: , version: v1, resource: pods/status
group: , version: v1, resource: podtemplates
group: , version: v1, resource: replicationcontrollers
group: , version: v1, resource: replicationcontrollers/scale
group: , version: v1, resource: replicationcontrollers/status
group: , version: v1, resource: resourcequotas
group: , version: v1, resource: resourcequotas/status
group: , version: v1, resource: secrets
group: , version: v1, resource: serviceaccounts
group: , version: v1, resource: services
group: , version: v1, resource: services/proxy
group: , version: v1, resource: services/status
group: apiregistration.k8s.io, version: v1, resource: apiservices
group: apiregistration.k8s.io, version: v1, resource: apiservices/status
group: apiregistration.k8s.io, version: v1beta1, resource: apiservices
group: apiregistration.k8s.io, version: v1beta1, resource: apiservices/status
group: extensions, version: v1beta1, resource: ingresses
group: extensions, version: v1beta1, resource: ingresses/status
group: apps, version: v1, resource: controllerrevisions
group: apps, version: v1, resource: daemonsets
group: apps, version: v1, resource: daemonsets/status
group: apps, version: v1, resource: deployments
group: apps, version: v1, resource: deployments/scale
group: apps, version: v1, resource: deployments/status
group: apps, version: v1, resource: replicasets
group: apps, version: v1, resource: replicasets/scale
group: apps, version: v1, resource: replicasets/status
group: apps, version: v1, resource: statefulsets
group: apps, version: v1, resource: statefulsets/scale
...
```

### DiscoveryClient 原理

discovery.NewDiscoveryClientForConfig(config) 初始化 DsicoveryClient，与 ClientSet 和 DynamicClient 原理类似，都是封装了 RESTClient，这里不再赘述。

discoveryClient.ServerGroupsAndResources() 返回集群所有的资源对象，这里可能会有疑问，这些资源是什么时候存储到 etcd 中的，猜想是 kube-apiserver 启动时将这些资源类型存储到 etcd 中。，需要看 kube-apiserver 来佐证。

## 总结

Client-go 四种客户端，在平时开发中 ClientSet 使用频率最高，其他三种了解原理一般就行。