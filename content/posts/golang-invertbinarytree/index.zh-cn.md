---
weight: 18
title: "用 Golang 实现二叉树反转"
date: 2023-06-06T21:57:40+08:00
lastmod: 2023-06-06T16:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "tree-home.jpg"

tags: ["Golang"]
categories: ["Golang"]

lightgallery: true
---

要想实现二叉树反转，首先得清楚什么是二叉树，但是这不在本篇文章的范畴，其次就是知道利用算法实现反转。

二叉树反转有两种实现方式：递归、循环遍历

## 要求

要求如下：

```go
输入：

     0
   /   \
  1     2
 / \   / \
3   4 5   6

输出：

     0
   /   \
  2     1
 / \   / \
6   5 4   3
```

## 递归

使用递归的方法比较容易理解，代码也比较简洁。

```go
// 定义二叉树
type BinaryTree struct {
	Data  int
	Left  *BinaryTree
	Right *BinaryTree
}

// 递归反转
func InvertBinaryTree(root *BinaryTree) *BinaryTree {
	// 递归退出条件
	if root == nil {
		return nil
	}
	// 反转左右结点的值
	root.Left, root.Right = root.Right, root.Left
	// 递归左子树
	InvertBinaryTree(root.Left)
	// 递归右子树
	InvertBinaryTree(root.Right)

	return root
}
```

时间复杂度：`O(n)`，其中 `n` 是二叉树中节点的数量。因为在递归过程中，每个节点都只被遍历一次，所以时间复杂度是线性的。

递归调用有以下弊端：

- 由于不断压栈操作，内存消耗过大
- 递归退出条件写的有问题，会导致程序永不对出
- 如果递归次数太深，会导致栈溢出，进而程序内存溢出

## 循环遍历

循环遍历需要借助栈的思想来实现，栈是一个先进后出的数据结构。

每次遍历出栈一个元素，即栈顶元素，交换该结点的左右结点，再将交换后的左右结点入栈；

重复运行至栈为空。

```go
type BinaryTree struct {
	Data  int
	Left  *BinaryTree
	Right *BinaryTree
}

func InvertBinaryTree(root *BinaryTree) *BinaryTree {
	if root == nil {
		return nil
	}
	// 用切片代替栈
	queue := []*BinaryTree{root}
	for len(queue) > 0 {
		// 出栈一个元素
		node := queue[0]
		// 新的栈就是包含后面所有元素，除了栈顶元素
		queue = queue[1:]
		// 交换左右结点的值
		node.Left, node.Right = node.Right, node.Left
		// 如果当前结点左结点不为空, 则压栈
		if node.Left != nil {
			queue = append(queue, node.Left)
		}
		// 如果当前结点右结点不为空, 则压栈
		if node.Right != nil {
			queue = append(queue, node.Right)
		}
	}

	return root
}
```

时间复杂度：`O(n)`，其中 `n` 是二叉树中节点的个数。因为需要遍历每个节点并交换其左右子节点，所以时间复杂度与节点个数成正比。

循环反转二叉树也许手动维护一个栈数据结构辅助实现，每次遍历都出栈顶结点，再压入该结点的左右结点。

## 总结

循环反转二叉树和递归反转二叉树的区别在于实现方式不同，但它们的本质是相同的。

循环反转二叉树使用迭代的方式，通过一个栈或队列来存储节点，依次遍历先出栈顶结点，再压该结点的左右结点；栈每个节点并交换其左右子节点。

而递归反转二叉树则是通过递归函数来实现，其底层也是通过栈实现，先递归交换左子树，再递归交换右子树，最后交换根节点的左右子节点；

递归是一个先不断压栈，再依次出栈的过程。

所以说循环的效率会高于递归的实现，且内存消耗也少。