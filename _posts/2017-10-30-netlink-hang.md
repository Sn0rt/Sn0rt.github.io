---
author: sn0rt
comments: true
date: 2017-10-30
layout: post
tag: linux
title: the issue of netlink hang
---

我以为我以后用不到 netlink 了呢，今天又踩坑了。

公司的基础架构监控进程的一个线程通过 netlink 去获取内核数据，阻塞 IO 不返回，导致数据丢点。

```golang
goroutine 18735 [syscall, 42 minutes]:
syscall.Syscall6(0x2d, 0x15, 0xc4206be000, 0x1000, 0x0, 0xc420345990, 0xc420345984, 0x2b, 0x7fd1b8a30ac0, 0x4535f0)
	/usr/local/go/src/syscall/asm_linux_amd64.s:44 +0x5
syscall.recvfrom(0x15, 0xc4206be000, 0x1000, 0x1000, 0x0, 0xc420345990, 0xc420345984, 0x0, 0xc4205a0c00, 0x48)
	/usr/local/go/src/syscall/zsyscall_linux_amd64.go:1712 +0x99
syscall.Recvfrom(0x15, 0xc4206be000, 0x1000, 0x1000, 0x0, 0x1000, 0x0, 0x103ea00, 0xc4201b1720, 0x0)
	/usr/local/go/src/syscall/syscall_unix.go:252 +0xaf
github.com/eleme/netlink.(*NetlinkSocket).Receive(0xc4201b1700, 0xc4202ebe00, 0x0, 0x0, 0x1, 0xc4201649d0)
	/go/src/github.com/eleme/netlink/socket.go:70 +0x86
github.com/eleme/esm-agent/collector.readStats(0x0, 0x0, 0x0, 0x0, 0x0)
	/go/src/github.com/eleme/esm-agent/collector/tcpstat.go:133 +0x372
github.com/eleme/esm-agent/collector.(*TcpStatCollector).Collect(0x109c8c8, 0x7fd1b8a2c4f8, 0xc4206adc80, 0x1, 0x2)
	/go/src/github.com/eleme/esm-agent/collector/tcpstat.go:209 +0x26
github.com/eleme/esm-agent/collector/basic.(*collectorService).Start.func1(0xc4202242a0, 0x7fd1b8a2c4f8, 0xc4206adc80, 0xc4204cb0e0)
	/go/src/github.com/eleme/esm-agent/collector/basic/basic.go:36 +0x15f
created by github.com/eleme/esm-agent/collector/basic.(*collectorService).Start
	/go/src/github.com/eleme/esm-agent/collector/basic/basic.go:45 +0x5d
```


上面是 calltrace，下半部分的 calltrace 是监控程序内置的分析工具。

根据 io 模型推测，并找到内核代码入口（代码参考的是 upstream 的 v3.10-rc1,线上 3.10.0-229.el7.x86_64)：
```c
2130 static int netlink_recvmsg(struct kiocb *kiocb, struct socket *sock,
2131                            struct msghdr *msg, size_t len,
2132                            int flags)
2133 {
2134         struct sock_iocb *siocb = kiocb_to_siocb(kiocb);
2135         struct scm_cookie scm;
2136         struct sock *sk = sock->sk;
2137         struct netlink_sock *nlk = nlk_sk(sk);
2138         int noblock = flags&MSG_DONTWAIT;
2139         size_t copied;
2140         struct sk_buff *skb, *data_skb;
2141         int err, ret;
2142
2143         if (flags&MSG_OOB)
2144                 return -EOPNOTSUPP;
2145
2146         copied = 0;
2147
2148         skb = skb_recv_datagram(sk, flags, noblock, &err);
2149         if (skb == NULL)
2150                 goto out;
2151
2152         data_skb = skb;
2153
2154 #ifdef CONFIG_COMPAT_NETLINK_MESSAGES
2155         if (unlikely(skb_shinfo(skb)->frag_list)) {
2156                 /*
2157                  * If this skb has a frag_list, then here that means that we
2158                  * will have to use the frag_list skb's data for compat tasks
2159                  * and the regular skb's data for normal (non-compat) tasks.
2160                  *
2161                  * If we need to send the compat skb, assign it to the
2162                  * 'data_skb' variable so that it will be used below for data
2163                  * copying. We keep 'skb' for everything else, including
2164                  * freeing both later.
2165                  */
2166                 if (flags & MSG_CMSG_COMPAT)
2167                         data_skb = skb_shinfo(skb)->frag_list;
2168         }
2169 #endif
2170
2171         msg->msg_namelen = 0;
2172
2173         copied = data_skb->len;
2174         if (len < copied) {
2175                 msg->msg_flags |= MSG_TRUNC;
2176                 copied = len;
2177         }
2178
2179         skb_reset_transport_header(data_skb);
2180         err = skb_copy_datagram_iovec(data_skb, 0, msg->msg_iov, copied);
2181
2182         if (msg->msg_name) {
2183                 struct sockaddr_nl *addr = (struct sockaddr_nl *)msg->msg_name;
2184                 addr->nl_family = AF_NETLINK;
2185                 addr->nl_pad    = 0;
2186                 addr->nl_pid    = NETLINK_CB(skb).portid;
2187                 addr->nl_groups = netlink_group_mask(NETLINK_CB(skb).dst_group);
2188                 msg->msg_namelen = sizeof(*addr);
2189         }
2190
2191         if (nlk->flags & NETLINK_RECV_PKTINFO)
2192                 netlink_cmsg_recv_pktinfo(msg, skb);
2193
2194         if (NULL == siocb->scm) {
2195                 memset(&scm, 0, sizeof(scm));
2196                 siocb->scm = &scm;
2197         }
2198         siocb->scm->creds = *NETLINK_CREDS(skb);
2199         if (flags & MSG_TRUNC)
2200                 copied = data_skb->len;
2201
2202         skb_free_datagram(sk, skb);
2203
2204         if (nlk->cb && atomic_read(&sk->sk_rmem_alloc) <= sk->sk_rcvbuf / 2) {
2205                 ret = netlink_dump(sk);
2206                 if (ret) {
2207                         sk->sk_err = ret;
2208                         sk->sk_error_report(sk);
2209                 }
2210         }
2211
2212         scm_recv(sock, msg, siocb->scm, flags);
2213 out:
2214         netlink_rcv_wake(sk);
2215         return err ? : copied;
2216 }

```

😄凭着直觉开始插桩：

```
# cat l.stp

global call
global ret
probe kernel.function("netlink_recvmsg").return {
  printf("netlink_recvmsg ret %d\n", ret++);
}

probe kernel.function("netlink_recvmsg"){
  printf("netlink_recvmsg call %d\n", call++);
}
```

多次重启业务的监控进程在另外一个终端观察，重启进程 5 次，发现计数稳定一段时间后（大约每 1/30000 个调用一个回不来），出现差值。推测有个调用没有返回。

```
netlink_recvmsg ret 893447
netlink_recvmsg call 893449
netlink_recvmsg ret 893448
netlink_recvmsg call 893450
netlink_recvmsg ret 893449
netlink_recvmsg call 893451
netlink_recvmsg ret 893450
netlink_recvmsg call 893452
netlink_recvmsg ret 893451
netlink_recvmsg call 893453
netlink_recvmsg ret 893452
netlink_recvmsg call 893454
netlink_recvmsg ret 893453
netlink_recvmsg call 893455
netlink_recvmsg ret 893454

```


发现内核 bug？ 有待进一步验证，思路分析 229 内核 netlink 子系统 netlink_recvmsg 的调用细节，可能有调用没有返回。


