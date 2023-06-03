---
weight: 15
title: "Golang 枚举的使用"
date: 2022-04-28T21:57:40+08:00
lastmod: 2022-04-28T16:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "enum-home.jpg"

tags: ["Golang"]
categories: ["Golang"]

lightgallery: true
---

# golang 枚举

## 什么是枚举

枚举（Enumeration）是一种常见的编程概念，它定义了一组命名常量。我们知道在 Go 语言中定义常量是这样的形式：

```go
const (
	A = "a"
	B = "b"
）
```

开发者可以使用枚举创建复杂的、**有限的**常量集，这些常量集具有有意义的名称和唯一的值。

## 枚举语法示例

在 Go 语言中，没有提供枚举类型，在 python、java、C++ 等语言中，提供了 *`enum`* 关键字来创建枚举类型。

但是 Go 语言可以利用 *`const`* + *`iota`* 实现枚举的效果，*`const`* 用来定义常量，*`[iota](https://github.com/golang/go/wiki/Iota)`* 是一个增数器，生成连续整数序列。

下面看看如何使用 *`const`* + *`iota`* 实现枚举

```go
const (
	 Monday int = iota      // Monday  = 0
	 Tuesday               // Tuesday = 1
	 Wednesday             // Wednesday = 2
	 Thursday              // Thursday = 3
	 Friday                // Friday = 4
	 Saturday              // Saturday =5
	 Sunday                // Sunday = 6
)
```

可以发现 *`iota`* 生成了从 0 - 6 的整数序列分别作为常量名称的值。

## 枚举的使用疑问

对于刚接触枚举的，应该会有以下疑问：

### 枚举与常量的区别

从上面那个例子可以看出枚举好像就是定义了一堆整形常量而已。既然枚举就是定义常量，那为什么不直接使用 *`const`* 来定义常量呢？

首先看一下使用 *`const`* 来定义上面枚举实现的常量集：

```go
const (
	 Monday     int = 0            // Monday  = 0
	 Tuesday    int = 1            // Tuesday = 1
	 Wednesday  int = 2            // Wednesday = 2
	 Thursday   int = 3            // Thursday = 3
	 Friday     int = 4            // Friday = 4
	 Saturday   int = 5            // Saturday =5
	 Sunday     int = 6            // Sunday = 6
)
```

可以发现使用 *`const`* 同样可以实现枚举的效果，但是没有枚举优雅。而且 *`const`* 并不能保证常量集的值是唯一的，比如 *`Wednesday  int = 1`* 编译器也不会报错，但是程序可能会出现 Bug。通过使用枚举(*`const + iota`*)，编译器层面保证了常量集里不会有相同的值。

### 枚举值的作用

通过上面枚举示例发现枚举包括：枚举名称( *`Monday`* )、枚举类型( *`int`* )、枚举值( *`0`* )，枚举名称、枚举类型很好理解，枚举值在编程中的有什么作用：

枚举本身的值没有什么意义，它是用来模拟现实中的某些只能取固定值的变量的，对应一个值只是在计算机中比较好处理。

### 枚举值只能为整形?

在枚举示例章节看到使用 *`iota`* 生成枚举值都是整数，在 Go 语言中枚举只能使用 *`iota`* ，所以枚举值只能是整数。

下面看一个 C++ 枚举示例：

```cpp
//枚举类型必须是整形吗，不能是浮点数或是别的类型?
enum E
    {
        monday=-2,
        tuesday=1.5//有么有非int类型的枚举?
    };
```

上面的枚举值定义为负数、浮点数，这种写法是错误的。在任何语言中，枚举值只能是整形。

## 枚举高级用法

### 从 1 开始枚举

如果不希望枚举值从 0 开始，从1 开始，可以在 Go 这样实现：

```go
const (
	 Monday = iota + 1     // Monday  = 1
	 Tuesday               // Tuesday = 2
	 Wednesday             // Wednesday = 3
	 Thursday              // Thursday = 4
	 Friday                // Friday = 5
	 Saturday              // Saturday = 6
	 Sunday                // Sunday = 7
)
```

### 自定义枚举值

*`iota`* 默认从 0 开始且依次递增 1，同时也可以使用数学运算自定义枚举值

```go
const (
	 Monday = iota + 1     // Monday = 0 + 1 = 1
	 Tuesday = iota + 2    // Tuesday = 1 + 2 = 3
	 Wednesday = iota * 2  // Wednesday = 2 * 2 = 2
	 Thursday              // Thursday = 3
	 Friday                // Friday = 4
	 Saturday              // Saturday =5
	 Sunday                // Sunday = 6
)
```

> 通常不建议这么做，因为容易导致枚举值混乱且重复。
那么可能会有疑问，枚举不是说保证枚举值唯一吗？在其他语言中可以保证唯一，但是 Go 语言没有 *`enum`* 关键字，只能使用 *`iota`* 来模拟枚举，如果自己使用不当也会导致枚举值重复，比如上面的例子。
> 

### 跳过值的枚举

如果想要跳过某个值，可以使用 _ 字符，即忽略的意思

```go
const (
	 Monday = iota         // Monday = 0 
   _                     // 1 被跳过
	 Tuesday               // Tuesday = 2
	 Wednesday             // Wednesday = 3
	 Thursday              // Thursday = 4
   _                     // 5 被跳过
	 Friday                // Friday = 6
	 Saturday              // Saturday = 7
	 Sunday                // Sunday = 8
)
```

## 枚举使用场景

下面举例几个枚举的使用场景，加深枚举的作用和使用。

### 限制参数类型

当处理状态码时，如果不使用枚举

```go
const (
	Normal       = 200
	Forbid       = 403
	NetworkError = 502
)

// 该函数形参是整形
func HandlerStatus(statusCode int) {
	fmt.Println(statusCode)
}

// 调用 HandlerStatus 随便什么整数都可以
func main() {
	HandlerStatus(Normal)
	HandlerStatus(404)
}

结果：
200
404
```

*`HandlerStatus`* 这个函数应该只能传 *`Normal`*、 *`Forbid`*、*`NetworkError`* 这三个常量，可以发现常量集之外的值也可以被正常调用，会使得程序不严谨。

下面看看使用枚举是否能达到效果？

虽然 Go 中并没有 *`enum`* 关键字来定义枚举类型，但是 Go 使用类型别名来定义枚举类型

```go
// int 别名
type Code int

const (
	Normal Code = iota
	Forbid
	NetworkError
)

func HandlerStatus(statusCode Code) {
	fmt.Println(statusCode)
}

func main() {
	HandlerStatus(Normal)
	var notFount int = 1
	// 这里会导致程序编译失败，因为 notFount 不是 Code 类型
	HandlerStatus(notFount)
}
```

通过枚举就可以限制 *`HandlerStatus`* 的入参类型，保证程序的严谨。

### 使用 string 作为枚举值

我们知道 Go 语言使用 *`iota`* 生成连续整数作为枚举值，但是有的时候希望能描述枚举常量的意思，这个时候除了看枚举常量名称，也可以将枚举值转成 string 来达到效果。下面通过例子看看：

```go
// 声明一个 week 类型
type week int

const (
	 Monday week = iota    // Monday  = 0
	 Tuesday               // Tuesday = 1
	 Wednesday             // Wednesday = 2
	 Thursday              // Thursday = 3
	 Friday                // Friday = 4
	 Saturday              // Saturday =5
	 Sunday                // Sunday = 6
)

func main() {
	var w week = Monday
	switch w {
	case Monday:
		fmt.Println(Monday)
	case Tuesday:
		fmt.Println(Tuesday)
	}
}

输出结果：
0
```

可以发现直接打印出了该枚举常量的枚举值 0，但是 0 并不是很容易理解该枚举常量的意义。

下面借助 Go 中 `String` 方法的默认约定，针对于定义了 `String` 方法的类型，默认输出的时候会调用该方法。

```go
// 声明一个 week 类型
type week int

const (
	 Monday week = iota    // Monday  = 0
	 Tuesday               // Tuesday = 1
	 Wednesday             // Wednesday = 2
	 Thursday              // Thursday = 3
	 Friday                // Friday = 4
	 Saturday              // Saturday =5
	 Sunday                // Sunday = 6
)

// 实现 week 类型的 String() 方法
func (w week) String() string {
		return [...]string{"星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"}[w]
}

func main() {
	var w week = Monday
	switch w {
	case Monday:
		fmt.Println(Monday)
	case Tuesday:
		fmt.Println(Tuesday)
	}
}

输出结果：
星期一
```

通过对枚举类型重写 *`String`* 方法，可以对枚举值进行自定义，可以清晰地描述该枚举变量的意义和作用。

## 总结

枚举定义了一组有限的常量集，像 C++、java 等语言有 *`enum`* 关键字来定义枚举类型，但是 Go 并没有提供枚举关键字来定义枚举类型，我们可以利用 *`const`* + *`iota`* 来达到枚举的效果。

同时很多开发者会忽略枚举的使用，因为枚举并不是必须使用的，完全可以直接常量来替代。但是枚举的使用提高程序可读性，严谨性等，所以在项目中使用枚举最好能够了解枚举的使用场景以及一些特定用法。