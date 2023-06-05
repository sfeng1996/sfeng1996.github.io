---
weight: 16
title: "Golang 为 Http 请求设置 Host 不生效"
date: 2023-06-05T21:57:40+08:00
lastmod: 2023-06-05T16:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "httpHost-home.jpg"

tags: ["Golang"]
categories: ["Golang"]

lightgallery: true
---

## 背景

一般服务端以域名形式提供服务，那么客户端一般需要使用域名访问，或者设置 *`Host`* 进行访问，否则会被拦截。

通过 curl 或者 postman 测试的时候，都是在请求头加上 *`Host`* 字段，比如 *`curl -H "Host: xxxxx.com" 10.10.10.1/api/xxxxx`*。

但是如果在代码里，直接在请求头里设置 *`Host`* 没有效果。

## 示例

通过在 Go 客户端代码设置 *`Host Header`* 来验证

```go
import (
	"fmt"
	"io/ioutil"
	"net/http"
)

func main() {
	httpClient := http.DefaultClient
	// 服务端 API, 以 IP 的形式访问
	srv := "http://172.31.132.95:30001/apis/test/v1/"
	req, err := http.NewRequest("POST", srv, nil)
	if err != nil {
		panic(err.Error())
	}
	// 给请求设置 host header, test-host.com 为服务端域名
	req.Header.Add("Host", "test-host.com")
	resp, err := httpClient.Do(req)
	if err != nil {
		panic(err.Error())
	}
	defer resp.Body.Close()
	respBody, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		panic(err)
	}
	fmt.Println(string(respBody))
}
```

运行客户端代码，实际上无法访问，会被拦截，因为 *`Host`* 并没有生效。

但是用 curl 来模拟请求，分别设置 *`Host`* 和不设置 *`Host`* 

```bash
$ curl  http://172.31.132.95:30001/apis/test/v1/
结果：
404 page not found

$ curl -H "Host: test-host.com" http://172.31.132.95:30001/apis/test/v1/
结果：
{"error":{"message":"The request header does not carry the Token ","reason":""}}
```

可以发现设置 *`Host`* header 可以收到服务端返回结果。很明显上面的 curl 也是通过在 header 设置 *`Host`* ，那同样的原理在代码里怎么就不生效。

## 解决

实际上，在 Go 里面 *`http request`* 里有个 *`Host`* 字段专门用于设置 *`Host`*，而不是在 header 里设置，很多人都被 post 或者 curl 给迷惑了。

下面看看代码

```go
import (
	"fmt"
	"io/ioutil"
	"net/http"
)

func main() {
	httpClient := http.DefaultClient
	// 服务端 API, 以 IP 的形式访问
	srv := "http://172.31.132.95:30001/apis/test/v1/"
	req, err := http.NewRequest("POST", srv, nil)
	if err != nil {
		panic(err.Error())
	}
	// 给请求设置 host 
	req.Host = "test-host.com"
	resp, err := httpClient.Do(req)
	if err != nil {
		panic(err.Error())
	}
	defer resp.Body.Close()
	respBody, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		panic(err)
	}
	fmt.Println(string(respBody))
}

运行结果：
{"error":{"message":"The request header does not carry the Token ","reason":""}}
```

其实不仅仅是 Go 语言的 http 有这种特点，其他语言也是，比如 Java 的 *`resttemplate`*。