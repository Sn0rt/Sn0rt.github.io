---
author: sn0rt
comments: true
date: 2019-11-20
layout: post
title:  amzone aws cni 踩坑
tag: k8s
---

最近要把 aws vpc cni 适配到 cluster api 已经适配完成了, 发现节点重启过后 aws-node 在重启的节点上不能正常 running 导致节点上的 pod 不能正常运行.

而且使用过在 master 上使用 `kubectl logs` 获取 pod 运行信息失败.

```bash
root@ip-10-0-10-69:/home/admin# kubectl -n kube-system logs aws-node-lm9nx
Error from server: Get https://10.0.10.207:10250/containerLogs/kube-system/aws-node-lm9nx/aws-node: dial tcp 10.0.10.207:10250: i/o timeout
```
也就是说 apiserver 链接不上 `10.0.10.207` 的 `kubelet`.

```bash
admin@ip-10-0-10-69:~$ telnet 10.0.10.207 10250
Trying 10.0.10.207...
^C
```

使用 telnet 确认一下

登陆到 `10.0.10.207`  node 发现节点是收到 master 发起到 10250 的请求的, 但是至少在网络层没有发现应答.

```bash
root@ip-10-0-10-207:/home/admin# tcpdump -i eth0 port 10250                         tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), capture size 262144 bytes
02:37:59.749261 IP ip-10-0-10-137.ec2.internal.48148 > ip-10-0-10-207.ec2.internal.10250: Flags [S], seq 3114509118, win 26883, options [mss 8961,sackOK,TS val 145034504 ecr 0,nop,wscale 7], length 0
02:38:00.166263 IP ip-10-0-10-69.ec2.internal.36450 > ip-10-0-10-207.ec2.internal.10250: Flags [S], seq 3957291899, win 26883, options [mss 8961,sackOK,TS val 145204104 ecr 0,nop,wscale 7], length 0
02:38:00.934330 IP ip-10-0-10-69.ec2.internal.36458 > ip-10-0-10-207.ec2.internal.10250: Flags [S], seq 3138969954, win 26883, options [mss 8961,sackOK,TS val 145204296 ecr 0,nop,wscale 7], length 0
02:38:01.765288 IP ip-10-0-10-137.ec2.internal.48148 > ip-10-0-10-207.ec2.internal.10250: Flags [S], seq 3114509118, win 26883, options [mss 8961,sackOK,TS val 145035008 ecr 0,nop,wscale 7], length 0
02:38:04.234328 IP ip-10-0-10-69.ec2.internal.36450 > ip-10-0-10-207.ec2.internal.10250: Flags [S], seq 3957291899, win 26883, options [mss 8961,sackOK,TS val 145205120 ecr 0,nop,wscale 7], length 0
02:38:04.998242 IP ip-10-0-10-69.ec2.internal.36458 > ip-10-0-10-207.ec2.internal.10250: Flags [S], seq 3138969954, win 26883, options [mss 8961,sackOK,TS val 145205312 ecr 0,nop,wscale 7], length 0
02:38:05.861341 IP ip-10-0-10-137.ec2.internal.48148 > ip-10-0-10-207.ec2.internal.10250: Flags [S], seq 3114509118, win 26883, options [mss 8961,sackOK,TS val 145036032 ecr 0,nop,wscale 7], length 0
```

发现问题不能一下子撸清楚, 只能慢慢探索链路.

`ip-10-0-10-69` 是 master 节点

```bash
kubectl -n kube-system logs aws-node-lm9nx
Error from server: Get https://10.0.10.207:10250/containerLogs/kube-system/aws-node-lm9nx/aws-node: dial tcp 10.0.10.207:10250: i/o timeout
```

发现只有出的数据包, 并没有回来的数据包.

```bash
root@ip-10-0-10-69:/home/admin# tcpdump -i any host 10.0.10.207 and port 10250 -n
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on any, link-type LINUX_SLL (Linux cooked), capture size 262144 bytes
06:59:45.926815 IP 10.0.10.69.60944 > 10.0.10.207.10250: Flags [S], seq 65945781, win 26883, options [mss 8961,sackOK,TS val 149130544 ecr 0,nop,wscale 7], length 0
06:59:49.318816 IP 10.0.10.69.60934 > 10.0.10.207.10250: Flags [S], seq 1568373055, win 26883, options [mss 8961,sackOK,TS val 149131392 ecr 0,nop,wscale 7], length 0
06:59:50.086848 IP 10.0.10.69.60944 > 10.0.10.207.10250: Flags [S], seq 65945781, win 26883, options [mss 8961,sackOK,TS val 149131584 ecr 0,nop,wscale 7], length 0
06:59:54.164908 IP 10.0.10.69.32788 > 10.0.10.207.10250: Flags [S], seq 1174539368, win 26883, options [mss 8961,sackOK,TS val 149132603 ecr 0,nop,wscale 7], length 0
06:59:55.174808 IP 10.0.10.69.32788 > 10.0.10.207.10250: Flags [S], seq 1174539368, win 26883, options [mss 8961,sackOK,TS val 149132856 ecr 0,nop,wscale 7], length 0
06:59:57.124514 IP 10.0.10.69.32814 > 10.0.10.207.10250: Flags [S], seq 1241021276, win 26883, options [mss 8961,sackOK,TS val 149133343 ecr 0,nop,wscale 7], length 0
06:59:57.190814 IP 10.0.10.69.32788 > 10.0.10.207.10250: Flags [S], seq 1174539368, win 26883, options [mss 8961,sackOK,TS val 149133360 ecr 0,nop,wscale 7], length 0
06:59:57.891175 IP 10.0.10.69.32822 > 10.0.10.207.10250: Flags [S], seq 1819028184, win 26883, options [mss 8961,sackOK,TS val 149133535 ecr 0,nop,wscale 7], length 0
06:59:58.150818 IP 10.0.10.69.32814 > 10.0.10.207.10250: Flags [S], seq 1241021276, win 26883, options [mss 8961,sackOK,TS val 149133600 ecr 0,nop,wscale 7], length 0
06:59:58.918835 IP 10.0.10.69.32822 > 10.0.10.207.10250: Flags [S], seq 1819028184, win 26883, options [mss 8961,sackOK,TS val 149133792 ecr 0,nop,wscale 7], length 0
```

在 ip-10-0-10-207 节点观察,登陆判断数据流向

```bash
root@ip-10-0-10-207:/home/admin# ip addr show eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9001 qdisc mq state UP group default qlen 1000
    link/ether 02:00:ba:2b:02:3f brd ff:ff:ff:ff:ff:ff
    inet 10.0.10.207/24 brd 10.0.10.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::baff:fe2b:23f/64 scope link
       valid_lft forever preferred_lft forever
```

```bash
root@ip-10-0-10-207:/home/admin# ip addr show eth1
3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9001 qdisc mq state UP group default qlen 1000
    link/ether 02:e1:30:86:0d:35 brd ff:ff:ff:ff:ff:ff
    inet 10.0.10.190/24 brd 10.0.10.255 scope global eth1
       valid_lft forever preferred_lft forever
    inet6 fe80::e1:30ff:fe86:d35/64 scope link
       valid_lft forever preferred_lft forever
```

```bash
root@ip-10-0-10-207:/home/admin# tcpdump -n -i eth0  host 10.0.10.69 and port 10250
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), capture size 262144 bytes
07:03:15.143334 IP 10.0.10.69.34162 > 10.0.10.207.10250: Flags [S], seq 1951564140, win 26883, options [mss 8961,sackOK,TS val 149182848 ecr 0,nop,wscale 7], length 0
07:03:15.911228 IP 10.0.10.69.34172 > 10.0.10.207.10250: Flags [S], seq 1628830348, win 26883, options [mss 8961,sackOK,TS val 149183040 ecr 0,nop,wscale 7], length 0
07:03:18.472285 IP 10.0.10.69.34218 > 10.0.10.207.10250: Flags [S], seq 1626614180, win 26883, options [mss 8961,sackOK,TS val 149183680 ecr 0,nop,wscale 7], length 0
07:03:19.239186 IP 10.0.10.69.34162 > 10.0.10.207.10250: Flags [S], seq 1951564140, win 26883, options [mss 8961,sackOK,TS val 149183872 ecr 0,nop,wscale 7], length 0
07:03:19.499242 IP 10.0.10.69.34218 > 10.0.10.207.10250: Flags [S], seq 1626614180, win 26883, options [mss 8961,sackOK,TS val 149183937 ecr 0,nop,wscale 7], length 0
07:03:20.007198 IP 10.0.10.69.34172 > 10.0.10.207.10250: Flags [S], seq 1628830348, win 26883, options [mss 8961,sackOK,TS val 149184064 ecr 0,nop,wscale 7], length 0
07:03:21.511227 IP 10.0.10.69.34218 > 10.0.10.207.10250: Flags [S], seq 1626614180, win 26883, options [mss 8961,sackOK,TS val 149184440 ecr 0,nop,wscale 7], length 0
07:03:25.639190 IP 10.0.10.69.34218 > 10.0.10.207.10250: Flags [S], seq 1626614180, win 26883, options [mss 8961,sackOK,TS val 149185472 ecr 0,nop,wscale 7], length 0
```

```bash
root@ip-10-0-10-207:/home/admin# tcpdump -n -i eth1  host 10.0.10.69 and port 10250
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on eth1, link-type EN10MB (Ethernet), capture size 262144 bytes
07:04:56.488272 IP 10.0.10.207.10250 > 10.0.10.69.34908: Flags [S.], seq 2079765709, ack 3299090550, win 26847, options [mss 8961,sackOK,TS val 492099 ecr 149208184,nop,wscale 7], length 0
07:04:57.124636 IP 10.0.10.207.10250 > 10.0.10.69.34924: Flags [S.], seq 899903279, ack 2422028185, win 26847, options [mss 8961,sackOK,TS val 492258 ecr 149208343,nop,wscale 7], length 0
07:04:57.499734 IP 10.0.10.207.10250 > 10.0.10.69.34812: Flags [S.], seq 3175686817, ack 1025375908, win 26847, options [mss 8961,sackOK,TS val 492352 ecr 149204593,nop,wscale 7], length 0
07:04:57.499757 IP 10.0.10.207.10250 > 10.0.10.69.34908: Flags [S.], seq 2079765709, ack 3299090550, win 26847, options [mss 8961,sackOK,TS val 492352 ecr 149208184,nop,wscale 7], length 0
07:04:57.511095 IP 10.0.10.207.10250 > 10.0.10.69.34908: Flags [S.], seq 2079765709, ack 3299090550, win 26847, options [mss 8961,sackOK,TS val 492354 ecr 149208184,nop,wscale 7], length 0
07:04:57.892015 IP 10.0.10.207.10250 > 10.0.10.69.34932: Flags [S.], seq 449930065, ack 724857165, win 26847, options [mss 8961,sackOK,TS val 492450 ecr 149208535,nop,wscale 7], length 0
07:04:58.139725 IP 10.0.10.207.10250 > 10.0.10.69.34924: Flags [S.], seq 899903279, ack 2422028185, win 26847, options [mss 8961,sackOK,TS val 492512 ecr 149208343,nop,wscale 7], length 0
07:04:58.151092 IP 10.0.10.207.10250 > 10.0.10.69.34924: Flags [S.], seq 899903279, ack 2422028185, win 26847, options [mss 8961,sackOK,TS val 492514 ecr 149208343,nop,wscale 7], length 0
07:04:58.267760 IP 10.0.10.207.10250 > 10.0.10.69.34822: Flags [S.], seq 3998514543, ack 1418773910, win 26847, options [mss 8961,sackOK,TS val 492544 ecr 149204785,nop,wscale 7], length 0
07:04:58.907735 IP 10.0.10.207.10250 > 10.0.10.69.34932: Flags [S.], seq 449930065, ack 724857165, win 26847, options [mss 8961,sackOK,TS val 492704 ecr 149208535,nop,wscale 7], length 0
```

```bash
root@ip-10-0-10-207:/home/admin# ip rout get 10.0.10.69/24
10.0.10.69 dev eth1 src 10.0.10.190
    cache
```

发现出现接受流量的是 eth0, 但是发送的响应的 eth1.

咨询网络同事, 发现这个现象已经有专有词汇了叫`火星包`,  配置内核参数
```
root@ip-10-0-10-207:/home/admin# sysctl -w net.ipv4.conf.all.log_martians=1
net.ipv4.conf.all.log_martians = 1
root@ip-10-0-10-207:/home/admin# sysctl -w net.ipv4.conf.default.log_martians=1
net.ipv4.conf.default.log_martians = 1
```
可以看到 kernel 已经打出来日志了.

```
[ 5210.822567] ll header: 00000000: 02 00 ba 2b 02 3f 02 62 68 47 23 a1 08 00        ...+.?.bhG#...
[ 5211.652509] IPv4: martian source 10.0.10.207 from 10.0.10.137, on dev eth0
[ 5211.652547] ll header: 00000000: 02 00 ba 2b 02 3f 02 bd a6 b6 aa 3f 08 00        ...+.?.....?..
[ 5211.830836] IPv4: martian source 10.0.10.115 from 10.0.0.224, on dev eth0
[ 5211.830875] ll header: 00000000: 02 00 ba 2b 02 3f 02 bd a6 b6 aa 3f 08 00        ...+.?.....?..
[ 5211.869305] IPv4: martian source 10.0.10.115 from 10.0.0.209, on dev eth0
[ 5211.869338] ll header: 00000000: 02 00 ba 2b 02 3f 02 bd a6 b6 aa 3f 08 00        ...+.?.....?..
[ 5232.836561] IPv4: host 10.0.10.115/if3 ignores redirects for 10.0.0.224 to 10.0.10.1
```

目前的修复方案, 将来响应请求和接受请求通过修改路由表的方式都换成eth0.

```
root@ip-10-0-10-207:/home/admin# ip route
default via 10.0.10.1 dev eth1
10.0.10.0/24 dev eth1 proto kernel scope link src 10.0.10.190
10.0.10.0/24 dev eth0 proto kernel scope link src 10.0.10.207
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown
admin@ip-10-0-10-207:~$ sudo ip route del 10.0.10.0/24 dev eth1 proto kernel scope link src 10.0.10.190
```

只要将 eth1 的明细路由删除, 影响路由决策让来的数据包走原来的网络接口回去.

