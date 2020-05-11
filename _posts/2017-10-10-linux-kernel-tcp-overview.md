---
author: sn0rt
comments: true
date: 2017-10-10
layout: post
title: Linux kernel tcp overview
tag: tips
---

一直想找机会梳理一下 kernel 的网络子系统，不如现在开始动手做，在梳理 kernel 前，先回顾一下操作系统提供的网络编程 API。


## 0x00 用户如何使用

想了解一下 Linux 下的 tcp 个人认为 socket API 是肯定要介绍的，自 bsd 4.2 引入到如今已经 30 多年了，核心 api 是非常稳定见如下表格

| C/S        | API                                                |
|------------|----------------------------------------------------|
| 服务器端： | `socket`,`bind`,`listen`,`accept`,`shutdown`等       |
|------------|----------------------------------------------------|
| 客户端:    | `socket`, `connect`, `recv`,`close`等               |
|------------|----------------------------------------------------|

几个简单的接口有效的控制了网络编程的复杂度。

这些 api 围绕着一个 socket 文件操作，这个文件挂载在相对简单的 sockfs 文件系统下面(在 socket.c 中实现)，下面这个文件操作符结构体实现描述了这个类型文件支持的文件操作。

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

上面这个就是体现 unix 哲学 `Everything is a file` 的体现，通过 vfs 抽象将函数指针放到结构体中，当对对应的文件调用就回调这个文件系统实现的回调函数，比如说我对 socket 文件进行  `mmap` 调用，到具体的文件系统中就是调用了 `sock_mmap` 这个文件系统实现。

这个 struct 已经暴露了能对 socket 的操作了，不过并不打算对这个 struct 上纠结太多。

一般的使用场景是，首先用户通过 socket 系统调用创建 ipv4 面向字节流套接字，也就是指的 TCP 套接字，当套接字创建完成过后就可以像操作文件一样操作套接字。

我们这里关注的是 ipv4 tcp 套接字是如何建立的，如何传输数据的，如何关闭的，这三个问题。

## tcp linux 实现[^TCP_Implementation]

tcp 虚链路的建立，有效的关闭是学习 TCP 的基础中的基础。

多场景下高效率的传输学习和研究的难点，多场景的例子有卫星链路，其特点是带宽大延迟高；广域网，其特点是背景丢包率，IDC内部，低延迟高带宽。

### tcp 套接字的建立

众所周知的三次握手，客户端发起 syn，服务端 ack + syn，服务端 ack。这里一共三次，为什么是三次是因为 2 次不能进行双向确认，4次显的没有效率多一次发包。

系统调用 `socket`, 通过两天函数，对应内核函数 `__sock_create`

```c
int __sock_create(struct net *net, int family, int type, int protocol,
			 struct socket **res, int kern)
{
	int err;
	struct socket *sock;
	const struct net_proto_family *pf;
...	
	pf = rcu_dereference(net_families[family]);
	err = -EAFNOSUPPORT;
	if (!pf)
		goto out_release;
...
	err = pf->create(net, sock, protocol, kern);
	if (err < 0)
		goto out_module_put;
...
```

看上面代码是`__sock_create`调用已经在系统中注册的协议提供的`create`方法创建`sock`函数。

```c
/**
 *	sock_register - add a socket protocol handler
 *	@ops: description of protocol
 *
 *	This function is called by a protocol handler that wants to
 *	advertise its address family, and have it linked into the
 *	socket interface. The value ops->family corresponds to the
 *	socket system call protocol family.
 */
int sock_register(const struct net_proto_family *ops)
{
	int err;

	if (ops->family >= NPROTO) {
		pr_crit("protocol %d >= NPROTO(%d)\n", ops->family, NPROTO);
		return -ENOBUFS;
	}

	spin_lock(&net_family_lock);
	if (rcu_dereference_protected(net_families[ops->family],
				      lockdep_is_held(&net_family_lock)))
		err = -EEXIST;
	else {
		rcu_assign_pointer(net_families[ops->family], ops);
		err = 0;
	}
	spin_unlock(&net_family_lock);

	pr_info("NET: Registered protocol family %d\n", ops->family);
	return err;
}
EXPORT_SYMBOL(sock_register);
```

```c

static int __init inet_init(void)
{
	struct inet_protosw *q;
	struct list_head *r;
	int rc = -EINVAL;

	sock_skb_cb_check_size(sizeof(struct inet_skb_parm));

	rc = proto_register(&tcp_prot, 1);
	if (rc)
		goto out;

	rc = proto_register(&udp_prot, 1);
	if (rc)
		goto out_unregister_tcp_proto;

	rc = proto_register(&raw_prot, 1);
	if (rc)
		goto out_unregister_udp_proto;

	rc = proto_register(&ping_prot, 1);
	if (rc)
		goto out_unregister_raw_proto;

	/*
	 *	Tell SOCKET that we are alive...
	 */

	(void)sock_register(&inet_family_ops);

#ifdef CONFIG_SYSCTL
	ip_static_sysctl_init();
#endif

	/*
	 *	Add all the base protocols.
	 */

	if (inet_add_protocol(&icmp_protocol, IPPROTO_ICMP) < 0)
		pr_crit("%s: Cannot add ICMP protocol\n", __func__);
	if (inet_add_protocol(&udp_protocol, IPPROTO_UDP) < 0)
		pr_crit("%s: Cannot add UDP protocol\n", __func__);
	if (inet_add_protocol(&tcp_protocol, IPPROTO_TCP) < 0)
		pr_crit("%s: Cannot add TCP protocol\n", __func__);
#ifdef CONFIG_IP_MULTICAST
	if (inet_add_protocol(&igmp_protocol, IPPROTO_IGMP) < 0)
		pr_crit("%s: Cannot add IGMP protocol\n", __func__);
#endif

	/* Register the socket-side information for inet_create. */
	for (r = &inetsw[0]; r < &inetsw[SOCK_MAX]; ++r)
		INIT_LIST_HEAD(r);

	for (q = inetsw_array; q < &inetsw_array[INETSW_ARRAY_LEN]; ++q)
		inet_register_protosw(q);

	/*
	 *	Set the ARP module up
	 */

	arp_init();

	/*
	 *	Set the IP module up
	 */

	ip_init();

	/* Setup TCP slab cache for open requests. */
	tcp_init();

	/* Setup UDP memory threshold */
	udp_init();

	/* Add UDP-Lite (RFC 3828) */
	udplite4_register();

	raw_init();

	ping_init();

	/*
	 *	Set the ICMP layer up
	 */

	if (icmp_init() < 0)
		panic("Failed to create the ICMP control socket.\n");

	/*
	 *	Initialise the multicast router
	 */
#if defined(CONFIG_IP_MROUTE)
	if (ip_mr_init())
		pr_crit("%s: Cannot init ipv4 mroute\n", __func__);
#endif

	if (init_inet_pernet_ops())
		pr_crit("%s: Cannot init ipv4 inet pernet ops\n", __func__);
	/*
	 *	Initialise per-cpu ipv4 mibs
	 */

	if (init_ipv4_mibs())
		pr_crit("%s: Cannot init ipv4 mibs\n", __func__);

	ipv4_proc_init();

	ipfrag_init();

	dev_add_pack(&ip_packet_type);

	ip_tunnel_core_init();

	rc = 0;
out:
	return rc;
out_unregister_raw_proto:
	proto_unregister(&raw_prot);
out_unregister_udp_proto:
	proto_unregister(&udp_prot);
out_unregister_tcp_proto:
	proto_unregister(&tcp_prot);
	goto out;
}

fs_initcall(inet_init);
```

```c

```

### tcp 的终止

众所周知的四次挥手，为什么是四次挥手关闭呢？其实这里的四次挥手的关闭指的是两个套接字两个方向的关闭，两个套接字指的是客户端和服务端，两个方向分别是发送方和接收方。

经典正确场景：当客户端 c 准备结束数据发送了，首先发起 FIN，服务端 s 收到客户端发来 FIN 信息并返回 ACK，当前阶段 c 客户端不发送数据但是还可以接收服务端发来的数据。当 s 把数据发送完成过后准备关闭这个客户的套接字，发送 FIN 给 c，这时候服务端不能发送数据。当 c 接受接收到 s 发来的 FIN，会回复一下 ACK，当 s 收到了 ack 套接字被正常关闭。


```c

```

更多描述参考[^wiki].

[^wiki]: [kernel_flow](https://wiki.linuxfoundation.org/networking/kernel_flow)
[^TCP_Implementation]: [TCP Implementation in Linux: A Brief Tutorial](../media/paper/TCPlinux.pdf)
