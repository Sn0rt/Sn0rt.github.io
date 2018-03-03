---
author: sn0rt
comments: true
date: 2016-07-21
layout: post
title: netlink route
tag: linux
---

# 0x00 NETLINK_ROUTE

`rtnetlink`基于`netlink`, 它允许 kernel 的路由表被读或者修改, 它常被 kernel 用来和其他的子系统的用户态程序通讯.

## 0x01 introduction

虽然被称为"Linux IPv4 routing socket", 不过目前这个`protocol`已经支持了`ipv6`, 这个类型`protocol`主要提供了网络相关的信息. 对于这个协议,Linux 声明了大量的子消息, 更多的信息可以参考 manual[^tcwiki]:

| 名称 | 消息类型
|------|----
|链路层 | RTM_NEWLINK, RTM_DELLINK, RTM_GETLINK, RTM_SETLINK
|地址设定 | RTM_NEWADDR, RTM_DELADDR, RTM_GETADDR
|路由表 | RTM_NEWROUTE, RTM_DELROUTE, RTM_GETROUTE
|邻居缓存 | TM_NEWNEIGH, RTM_DELNEIGH, RTM_GETNEIGH
|路由规则 | RTM_NEWRULE, RTM_DELRULE, RTM_GETRULE
|Queuing Discipline Settings | RTM_NEWQDISC, RTM_DELQDISC, RTM_GETQDISC
|Traffic Classes used with Queues | RTM_NEWTCLASS, RTM_DELTCLASS, RTM_GETTCLASS
|流量过滤 | RTM_NEWTFILTER, RTM_DELTFILTER, RTM_GETTFILTER
|其它 | RTM_NEWACTION, RTM_DELACTION, RTM_GETACTION, RTM_NEWPREFIX, RTM_GETPREFIX, RTM_GETMULTICAST, RTM_GETANYCAST, RTM_NEWNEIGHTBL,RTM_GETNEIGHTBL, RTM_SETNEIGHTBL

## 0x02 Network Route Service Module[^rfc]

这个服务提供了网络路由的创建, 移除与接收网络路由, 这个服务的`messages`模板如下, 字段的更多信息参考`RFC3549`的 3.1.1.

    0                   1                   2                   3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-+
    |   Family    |  Src length   |  Dest length  |     TOS       |
    +-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-+
    |  Table ID   |   Protocol    |     Scope     |     Type      |
    +-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-+
    |                          Flags                              |
    +-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-+

## 0x03 Neighbor Setup Service Module

这个服务提供增加, 移除和接受邻居信息的能力, 这个服务`messages`模板如下, 字段的更多信息参考`RFC3549`的 3.1.2.

    0                   1                   2                   3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-+
    |   Family    |    Reserved1  |           Reserved2           |
    +-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-+
    |                     Interface Index                         |
    +-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-+
    |           State             |     Flags     |     Type      |
    +-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-+
    
## 0x03 Traffic Control Service

这个服务提供了供给, 查询与侦听支持流量控制事件的能力,linux 下面流量控制是非常具有弹性 (复杂), 字段的更多信息参考`RFC3549`的 3.1.3.

    0                   1                   2                   3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-+
    |   Family    |  Reserved1    |         Reserved2             |
    +-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-+
    |                     Interface Index                         |
    +-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-+
    |                      Qdisc handle                           |
    +-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-+
    |                     Parent Qdisc                            |
    +-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-+
    |                        TCM Info                             |
    +-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-+
        
# 0x20 demo

>API to the configuration interfaces of the NETLINK_ROUTE family including network interfaces, routes, addresses, neighbours, and traffic control.

引用在`libnl-route`介绍, 对照 RFC 定义的`ip service`部分还是都支持的, 着也是主流的`NETLINK_ROUTE`的使用途径.

## 0x21 emulateing wide network

`vishvananda`封装了`golang`的`netlink`的库, 可以做`ip service`中`traffic control`的事情, 比如去模拟广域网.

```go
package main

import (
    "fmt"
    "github.com/vishvananda/netlink"
    "os/exec"
    )

func main() {
    // 毁坏测试
    fmt.Println("\n 包毁坏测试")
    NetCorruption(20)
    check_interface_status()
    StopNetCorruption()
    check_interface_status()

}

// 检查状态
func check_interface_status() {
    output, err := exec.Command("/sbin/tc", "qdisc").Output()
    if err != nil {
        fmt.Println("error in cmd.start()")
    }
    fmt.Printf("%v", string(output))
}

// 获得网卡的 Index
func get_interface_list() []int {
    interfaces, _ := netlink.LinkList()
    var interface_index []int
    for _, name := range interfaces[1:] {
        interface_index = append(interface_index, name.Attrs().Index)
    }
    return interface_index
}

// 构造出每网卡 qdisc 属性, 类似 dev inferface_name root netem
func constructor_qdiscattrs() []netlink.QdiscAttrs {
    linkindexs := get_interface_list()
    var netems []netlink.QdiscAttrs
    for _, indexs := range linkindexs {
        var qdisc_attrs = netlink.QdiscAttrs{
            Parent:    netlink.HANDLE_ROOT,
            LinkIndex: indexs,
        }
        netems = append(netems, qdisc_attrs)
    }
    return netems
}

// 具体的 do 执行
func traffic_control(nattrs netlink.NetemQdiscAttrs) error {
    var netems = constructor_qdiscattrs()
    for _, netem := range netems {
        err := netlink.QdiscAdd(netlink.NewNetem(netem, nattrs))
        if err != nil {
            fmt.Printf("traffic_control %v \n", err)
            return err
        }
    }
    return nil
}

// 具体的 undo 执行
func undo_traffic_control() error {
    fmt.Println("undo operation")
    links, _ := netlink.LinkList()
    for _, link := range links {
        netems, _ := netlink.QdiscList(link)
        for _, netem := range netems {
            err := netlink.QdiscDel(netem)
            if err != nil {
                fmt.Printf("undo_traffic_control %v \n", err)
                return err
            }
        }
    }
    return nil
}

// 实参单位是 %, 例如实参是 80, 表示损坏率 80%
func NetCorruption(precents float32) {
    var nattrs netlink.NetemQdiscAttrs
    nattrs.CorruptProb = precents
    traffic_control(nattrs)
}

func StopNetCorruption() {
    undo_traffic_control()
}
```

## 0x21 monitor routing table

当然可以直接使用系统自带的`rtnetlink.h`来监控路由表.

```c
#include <sys/socket.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <arpa/inet.h>
#include <unistd.h>

#define ERR_RET(x) do { perror(x); return EXIT_FAILURE; } while (0);
#define BUFFER_SIZE 4095

int  loop (int sock, struct sockaddr_nl *addr)
{
    int     received_bytes = 0;
    struct  nlmsghdr *nlh;
    char    destination_address[32];
    char    gateway_address[32];
    struct  rtmsg *route_entry;  /* This struct represent a route entry in the routing table */
    struct  rtattr *route_attribute; /* This struct contain route attributes (route type) */
    int     route_attribute_len = 0;
    char    buffer[BUFFER_SIZE];
    
    bzero(destination_address, sizeof(destination_address));
    bzero(gateway_address, sizeof(gateway_address));
    bzero(buffer, sizeof(buffer));

    /* Receiving netlink socket data */
    while (1) {
        received_bytes = recv(sock, buffer, sizeof(buffer), 0);
        if (received_bytes < 0)
            ERR_RET("recv");
        /* cast the received buffer */
            nlh = (struct nlmsghdr *) buffer;
        /* If we received all data ---> break */
        if (nlh->nlmsg_type == NLMSG_DONE)
            break;
        /* We are just intrested in Routing information */
        if (addr->nl_groups == RTMGRP_IPV4_ROUTE)
            break;
        }

/* Reading netlink socket data */
/* Loop through all entries */
/* For more informations on some functions :
 * http://www.kernel.org/doc/man-pages/online/pages/man3/netlink.3.html
 * http://www.kernel.org/doc/man-pages/online/pages/man7/rtnetlink.7.html
 */

for ( ; NLMSG_OK(nlh, received_bytes); nlh = NLMSG_NEXT(nlh, received_bytes))
{
    /* Get the route data */
    route_entry = (struct rtmsg *) NLMSG_DATA(nlh);

    /* We are just intrested in main routing table */
    if (route_entry->rtm_table != RT_TABLE_MAIN)
        continue;

    /* Get attributes of route_entry */
    route_attribute = (struct rtattr *) RTM_RTA(route_entry);

    /* Get the route atttibutes len */
    route_attribute_len = RTM_PAYLOAD(nlh);
    
    /* Loop through all attributes */
    for ( ; RTA_OK(route_attribute, route_attribute_len); route_attribute = RTA_NEXT(route_attribute, route_attribute_len))
    {
        /* Get the destination address */
        if (route_attribute->rta_type == RTA_DST)
        {
            inet_ntop(AF_INET, RTA_DATA(route_attribute), destination_address, sizeof(destination_address));
        }
        /* Get the gateway (Next hop) */
        if (route_attribute->rta_type == RTA_GATEWAY)
        {
            inet_ntop(AF_INET, RTA_DATA(route_attribute), gateway_address, sizeof(gateway_address));
        }
    }

    /* Now we can dump the routing attributes */
    if (nlh->nlmsg_type == RTM_DELROUTE)
        fprintf(stdout, "Deleting route to destination --> %s and gateway %s\n", destination_address, gateway_address);
    if (nlh->nlmsg_type == RTM_NEWROUTE)
        printf("Adding route to destination --> %s and gateway %s\n", destination_address, gateway_address);
}
    return 0;
}

int main(int argc, char **argv)
{
    int sock = -1;
    struct sockaddr_nl addr;

    /* Zeroing addr */
    bzero (&addr, sizeof(addr));
    
    if ((sock = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE)) < 0)
        ERR_RET("socket");

    addr.nl_family = AF_NETLINK;
    addr.nl_groups = RTMGRP_IPV4_ROUTE;
    
    if (bind(sock,(struct sockaddr *)&addr,sizeof(addr)) < 0)
        ERR_RET("bind");
        
    while (1)
        loop (sock, &addr);
        
    /* Close socket */
    close(sock);
    return 0;
}
```

可以通过下面参数看见:

```shell
# route add -host 10.113.0.0 gw localhost
Adding route to destination --> 10.113.0.0 and gateway 127.0.0.1
# route del -host 10.113.0.0 gw localhost
Deleting route to destination --> 10.113.0.0 and gateway 127.0.0.1
```

[^rfc]: [rfc3549](http://www.faqs.org/rfcs/rfc3549.html)
[^tcwiki]: [wikipedia TC](https://en.wikipedia.org/wiki/Tc_(Linux))
