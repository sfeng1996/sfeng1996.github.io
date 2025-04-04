---
weight: 3
title: "golang channel 使用"
date: 2021-05-06T21:57:40+08:00
lastmod: 2021-05-06T16:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "go-channel.png"

tags: ["Golang"]
categories: ["Golang"]

lightgallery: true
---

### 简介

获取 channel 元素有多种，这里说使用遍历获取 channel 元素，当 channel 没有关闭时，遍历 channel 会出现阻塞或者死锁，下面分别看这两种情况

### 阻塞

运行一下程序，会发现 consume 函数里的 fmt.Println("end") 不会执行，因为channel 未关闭，一直在获取 channel 元素

```go
func main() {
	c := make(chan int, 3)
	product(c)

	go consume(c)
	time.Sleep(6 * time.Second)
}

func product(c chan int) {
	c <- 0
	c <- 1
	c <- 2
}

func consume(c chan int) {
	for mag := range c {
		fmt.Println(mag)
	}
	fmt.Println("end")
}
```

运行结果：

```go
0
1
2
```

但是当把生产者生产完后，关闭 channel，发现不会阻塞，会执行 fmt.Println("end")

```go
func main() {
	c := make(chan int, 3)
	product(c)
	go consume(c)
	time.Sleep(6 * time.Second)
}

func product(c chan int) {
	c <- 0
	c <- 1
	c <- 2
	close(c)
}

func consume(c chan int) {
	for mag := range c {
		fmt.Println(mag)
	}
	fmt.Println("end")
}
```

运行结果：

```go
0
1
2
end
```

### 死锁

当 channel 未关闭遍历 channel 且所有协程都阻塞时，会发生死锁，上面没发生死锁，是因为在必须所有协程都阻塞才会死锁，上面程序只是 consume() 阻塞了，主协程并没有阻塞，所以没有死锁。

```go
func main() {
	c := make(chan int, 3)
	product(c)
	go consume(c)
  // 使得主协程阻塞
	select {}
}

func product(c chan int) {
	c <- 0
	c <- 1
	c <- 2
	//close(c)
}

func consume(c chan int) {
	for mag := range c {
		fmt.Println(mag)
	}
	fmt.Println("end")
}
```

运行结果：

```go
0
1
2
fatal error: all goroutines are asleep - deadlock!
```

生产者关闭 channel，则正常运行

```go
func main() {
	c := make(chan int, 3)
	product(c)
	go consume(c)
	// 这里不能使用 select{}，因为主协程阻塞，其他协程都执行完了，最终死锁
	time.Sleep(3 * time.Second)
}

func product(c chan int) {
	c <- 0
	c <- 1
	c <- 2
	close(c)
}

func consume(c chan int) {
	for mag := range c {
		fmt.Println(mag)
	}
	fmt.Println("end")
}
```

### 正常

还有一种情况，当生产者与消费者都开启协程，即使 channel 没有关闭，也不会报错

```go
func main() {
	c := make(chan int, 3)
	go product(c)
	go consume(c)
	time.Sleep(3 * time.Second)
}

func product(c chan int) {
	c <- 0
	c <- 1
	c <- 2
	//close(c)
}

func consume(c chan int) {
	for mag := range c {
		fmt.Println(mag)
	}
	fmt.Println("end")
}
```

运行结果：

```go
0
1
2
```

### select

这里简单说下 select 用法，select 用于获取 channel 元素，也可以阻塞协程

```go
func main()  {
    bufChan := make(chan int)
    
    go func() {
        for{
            bufChan <-1
            time.Sleep(time.Second)
        }
    }()

    go func() {
        for{
            fmt.Println(<-bufChan)
        }
    }()
     
    select{}
}
```

这样主函数就永远阻塞住了，这里要注意**上面一定要有一直活动的goroutine**
,否则会报`deadlock`