---
author: sn0rt
comments: true
date: 2018-07-11
layout: post
tag: 容器
title: kube-proxy iptables规则生成
---

​	做容器也有半年了，写需求的过程中发现当我创建`LoaderBalancer`类型的`service`时候`kube-proxy iptables`模式会产生一条公网规则的同步到集群中的全部节点上。当时我就很奇怪为啥公网lb还要生成`iptables`规则。

​	在梳理iptables规则之前先看一下`loadBalancer`类型的`kuberntes service`的流量链路，以腾讯云为例看一下腾讯云`TKE`下的流量链路，通过咨询的方式知道了，腾讯云的公网方案实际是`k8s`的去`clb`去买了一个lb，结合`clb`的官方产品文档，理解出来的流量的入链路如下:

```yaml
traffic in -> clb(TGW->GRE tunnel->vm) -> iptables -> pod
```

​	在腾讯云下通过腾讯云`clb`的产品文档，知道流量最后会到节点上，后面就是流量交给`iptables`（kuberntes 1.10 ipvs特性就stable了）规则将流量转发到pod里面。

在腾讯云的TKE控制台创建了一个服务并选择了公网地址，并登录node上查看`kuberntes`的`service`信息：

```shell
ubuntu@VM-0-42-ubuntu:~$ kubectl get svc
NAME         TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)        AGE
kubernetes   ClusterIP      10.123.63.1    <none>           443/TCP        3h
sleep        LoadBalancer   10.123.63.85   118.24.224.100   80:30392/TCP   6m
```

## 入流量的探索

​	通过get svc知道了申请到的公网ip是`118.24.224.100`。`iptables -j` 选项后面的参数叫`target`,其实`-j`的意思是`jump`，可以感性的理解为转跳到这个`target`上继续处理。使用这个地址在`iptables`里面搜索一下发现如下一个规则(规则的跟入遵循广度优先原则):

```shell
ubuntu@VM-0-42-ubuntu:~$ sudo iptables-save |grep 118.24.224.100
-A KUBE-SERVICES -d 118.24.224.100/32 -p tcp -m comment --comment "default/sleep:tcp-80-80-8r4el loadbalancer IP" -m tcp --dport 80 -j KUBE-FW-KHFRG3HD2BG7I4YD
```

​	以`target`名字作为关键字搜索如下,发现`KUBE-FW-`开头的其实是`forward`的意思不是`firewall`😄，发现三个新的规则第一个转跳的`target`叫`KUBE-MARK-MASQ`,第二个叫`KUBE-SVC-KHFRG3HD2BG7I4YD`,第三个叫`KUBE-MARK-DROP`。具体这些`target`到这个阶段是做什么的还不清楚。而且`review`全部的`iptables-save`的输出发现绝大多数的`kuberntes`的规则都在`nat`表里面。

```shell
ubuntu@VM-0-42-ubuntu:~$ sudo iptables-save |grep KUBE-FW-KHFRG3HD2BG7I4YD
:KUBE-FW-KHFRG3HD2BG7I4YD - [0:0]
-A KUBE-FW-KHFRG3HD2BG7I4YD -m comment --comment "default/sleep:tcp-80-80-8r4el loadbalancer IP" -j KUBE-MARK-MASQ
-A KUBE-FW-KHFRG3HD2BG7I4YD -m comment --comment "default/sleep:tcp-80-80-8r4el loadbalancer IP" -j KUBE-SVC-KHFRG3HD2BG7I4YD
-A KUBE-FW-KHFRG3HD2BG7I4YD -m comment --comment "default/sleep:tcp-80-80-8r4el loadbalancer IP" -j KUBE-MARK-DROP
-A KUBE-SERVICES -d 118.24.224.100/32 -p tcp -m comment --comment "default/sleep:tcp-80-80-8r4el loadbalancer IP" -m tcp --dport 80 -j KUBE-FW-KHFRG3HD2BG7I4YD
```

​	探索一下`KUBE-MARK-MASQ`,发现其实就是`kube-proxy`调用`iptables`给流量做个`0x4000/0x4000`的标记。

```shell
ubuntu@VM-0-42-ubuntu:~$ sudo iptables-save | grep KUBE-MARK-MASQ
:KUBE-MARK-MASQ - [0:0]
-A KUBE-FW-KHFRG3HD2BG7I4YD -m comment --comment "default/sleep:tcp-80-80-8r4el loadbalancer IP" -j KUBE-MARK-MASQ
-A KUBE-MARK-MASQ -j MARK --set-xmark 0x4000/0x4000
```

​	探索一下`KUBE-SVC-KHFRG3HD2BG7I4YD`,发现又有一次转跳到`KUBE-SEP-GZIIAEF444AZU3YY`,目前目前这个阶段还不知道这个`target`是干嘛的。

```shell
ubuntu@VM-0-42-ubuntu:~$ sudo iptables-save |grep KUBE-SVC-KHFRG3HD2BG7I4YD
:KUBE-SVC-KHFRG3HD2BG7I4YD - [0:0]
-A KUBE-FW-KHFRG3HD2BG7I4YD -m comment --comment "default/sleep:tcp-80-80-8r4el loadbalancer IP" -j KUBE-SVC-KHFRG3HD2BG7I4YD
-A KUBE-NODEPORTS -p tcp -m comment --comment "default/sleep:tcp-80-80-8r4el" -m tcp --dport 30392 -j KUBE-SVC-KHFRG3HD2BG7I4YD
-A KUBE-SERVICES -d 10.123.63.85/32 -p tcp -m comment --comment "default/sleep:tcp-80-80-8r4el cluster IP" -m tcp --dport 80 -j KUBE-SVC-KHFRG3HD2BG7I4YD
-A KUBE-SVC-KHFRG3HD2BG7I4YD -m comment --comment "default/sleep:tcp-80-80-8r4el" -j KUBE-SEP-GZIIAEF444AZU3YY
```

​	探索一下`KUBE-MARK-DROP`,发现其实就是`kube-proxy`调用`iptables`给流量做个`0x8000/0x8000`的标记。

```shell
ubuntu@VM-0-42-ubuntu:~$ sudo iptables-save | grep KUBE-MARK-DROP
:KUBE-MARK-DROP - [0:0]
-A KUBE-FW-KHFRG3HD2BG7I4YD -m comment --comment "default/sleep:tcp-80-80-8r4el loadbalancer IP" -j KUBE-MARK-DROP
-A KUBE-MARK-DROP -j MARK --set-xmark 0x8000/0x8000
```

​	通过`KUBE-SVC-KHFRG3HD2BG7I4YD`转跳到`-j DNAT --to-destination 10.123.32.5:80`,这里做了流量的实际转发。

```shell
ubuntu@VM-0-42-ubuntu:~$ sudo iptables-save |grep KUBE-SEP-GZIIAEF444AZU3YY
:KUBE-SEP-GZIIAEF444AZU3YY - [0:0]
-A KUBE-SEP-GZIIAEF444AZU3YY -s 10.123.32.5/32 -m comment --comment "default/sleep:tcp-80-80-8r4el" -j KUBE-MARK-MASQ
-A KUBE-SEP-GZIIAEF444AZU3YY -p tcp -m comment --comment "default/sleep:tcp-80-80-8r4el" -m tcp -j DNAT --to-destination 10.123.32.5:80
-A KUBE-SVC-KHFRG3HD2BG7I4YD -m comment --comment "default/sleep:tcp-80-80-8r4el" -j KUBE-SEP-GZIIAEF444AZU3YY
```

​	通过`kuberntes`的`get endpoint`我看到了我创建的`pod`的`endpoint`了。

```shell
ubuntu@VM-0-42-ubuntu:~$ kubectl get ep
NAME         ENDPOINTS              AGE
kubernetes   169.254.128.13:60002   3h
sleep        10.123.32.5:80         8m
```

## 为什么公网也需要生成规则？

​	目前理解是”如果pod或集群中节点也需要去访问这个公网的ip地址，可以避免流量的走公网绕一圈“。

## 被打了标记的流量处理方式

​	看一下被做标记的流量的处理方式：

```
-A KUBE-FIREWALL -m comment --comment "kubernetes firewall for dropping marked packets" -m mark --mark 0x8000/0x8000 -j DROP
-A KUBE-FORWARD -m comment --comment "kubernetes forwarding rules" -m mark --mark 0x4000/0x4000 -j ACCEPT
```

