---
author: sn0rt
comments: true
date: 2017-10-09
layout: post
tag: tips
title: to explore c va arg
---

之前写 go 语言时候发现 go 语言支持可变长参数，且写法与 c 语言类似，就好奇了 c 语言是如何实现可变长参数的。这里参考了[^this]。

>C 语言可变参数通过三个宏（va_start、va_end、va_arg）和一个类型（va_list）实现的，
>
>void va_start(va_list ap, paramN);
>参数:
>ap: 可变参数列表地址 
>paramN: 确定的参数
>功能：初始化可变参数列表(把函数在 paramN 之后的参数地址放到 ap 中)。
>
>void va_end(va_list ap);
>功能：关闭初始化列表(将 ap 置空)。
>
>type va_arg(va_list ap, type);
>功能：返回下一个参数的值。
>
>va_list：存储参数的类型信息。
>
>综合上面 3 个宏和一个类型可以猜出如何实现 C 语言可变长参数函数：用 va_start 获取参数列表(的地址)存储到 ap 中，用 va_arg 逐个获取值，最后用 va_arg 将 ap 置空。


# 使用

使用范例，计算一组 int 数的和：

```c
#include <stdio.h>
#include <stdarg.h>

#define END -1

int va_sum(int first_num, ...)
{
  va_list ap;
  va_start(ap, first_num);
  int result = first_num;
  int temp = 0;
  while ((temp = va_arg(ap, int)) != END)
    result += temp;
  va_end(ap);
  return result;
}

int main()
{
  int sum_val = va_sum(1, 2, 3, 4, 5, END);
  printf("%d", sum_val);
  return 0;
}

```

# 分析

其实可变长参数的实现还是比较简单：不断从栈上根据参数字长取数据，因此不知道边界。

这一点在反汇编之下非常清楚！按照 x64 的约定传入参数

caller：

```
(gdb) disassemble main
Dump of assembler code for function main:
   0x00000000004005f4 <+0>:	push   %rbp
   0x00000000004005f5 <+1>:	mov    %rsp,%rbp
   0x00000000004005f8 <+4>:	sub    $0x10,%rsp
   0x00000000004005fc <+8>:	mov    $0xffffffff,%r9d
   0x0000000000400602 <+14>:	mov    $0x5,%r8d
   0x0000000000400608 <+20>:	mov    $0x4,%ecx
   0x000000000040060d <+25>:	mov    $0x3,%edx
   0x0000000000400612 <+30>:	mov    $0x2,%esi
   0x0000000000400617 <+35>:	mov    $0x1,%edi
   0x000000000040061c <+40>:	mov    $0x0,%eax
   0x0000000000400621 <+45>:	callq  0x4004d7 <va_sum>
```

callee：

```
(gdb) disassemble va_sum
Dump of assembler code for function va_sum:
   0x00000000004004d7 <+0>:	push   %rbp
   0x00000000004004d8 <+1>:	mov    %rsp,%rbp
=> 0x00000000004004db <+4>:	sub    $0xf0,%rsp
   0x00000000004004e2 <+11>:	mov    %edi,-0xe4(%rbp) // 1
   0x00000000004004e8 <+17>:	mov    %rsi,-0xa8(%rbp) // 2
   0x00000000004004ef <+24>:	mov    %rdx,-0xa0(%rbp) // 3
   0x00000000004004f6 <+31>:	mov    %rcx,-0x98(%rbp) // 4
   0x00000000004004fd <+38>:	mov    %r8,-0x90(%rbp)  // 5
   0x0000000000400504 <+45>:	mov    %r9,-0x88(%rbp)  // ?
```

根据参数的类型的字长从栈上取值。

[^this]: [深度探索 C 语言函数可变长参数](http://www.cnblogs.com/chinazhangjie/archive/2012/08/18/2645475.html)
