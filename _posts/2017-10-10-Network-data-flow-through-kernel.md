---
author: sn0rt
comments: true
date: 2017-10-10
layout: post
title: Linux kernel IPv4 overview
tag: tips
---

一直想找机会梳理一下 kernel 的网络子系统，不如现在开始动手做，在梳理 kernel 前，先回顾一下操作系统提供的网络编程 API。

* API
说接口就必须要先说的是 socket API，自 bsd 4.2 引入到如今已经 30 多年了，核心 api 是非常稳定的。
>
|------------|----------------------------------------------------|
| C/S        | API                                                |
|------------|----------------------------------------------------|
| 服务器端： | `socket`,`bind`,`listen`,`accept`,`shutdown`等       |
|------------|----------------------------------------------------|
| 客户端:    | `socket`, `connect`, `recv`,`close`等               |
|------------|----------------------------------------------------|

几个简单的接口有效的分隔网络编程的复杂，这些 api 围绕着一个 socket 文件操作，这个文件挂载在相对简单的 sockfs 文件系统下面(在 socket.c 中实现)，下面这个文件操作符结构体实现描述了这个类型文件支持的文件操作。

```c
static const struct file_operations socket_file_ops = {
        .owner =        THIS_MODULE,
        .llseek =       no_llseek,
        .read_iter =    sock_read_iter,
        .write_iter =   sock_write_iter,
        .poll =         sock_poll,
        .unlocked_ioctl = sock_ioctl,
#ifdef CONFIG_COMPAT
        .compat_ioctl = compat_sock_ioctl,
#endif
        .mmap =         sock_mmap,
        .release =      sock_close,
        .fasync =       sock_fasync,
        .sendpage =     sock_sendpage,
        .splice_write = generic_splice_sendpage,
        .splice_read =  sock_splice_read,
};
```

### tcp linux 实现[^TCP_Implementation]



更多描述参考[^wiki].

[^wiki]: [kernel_flow](https://wiki.linuxfoundation.org/networking/kernel_flow)
[^TCP_Implementation]: [TCP Implementation in Linux: A Brief Tutorial](../media/paper/TCPlinux.pdf)
