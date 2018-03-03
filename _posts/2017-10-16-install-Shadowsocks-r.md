---
author: sn0rt
comments: true
date: 2017-10-16
layout: post
title: quick install ShadowsocksR + tcp_bbr
tag: tips
---

昨天凌晨到今天早上上班前梯子挂了，这里重新搭建一个。

DO 上入了一个$5/M 的 Ubuntu 17.04 x32，下面就是刷脚本的事情。

安装 shadowsocksR,需要注意的事情就是不要选客户端不支持的 obfs，一开始选错了可以在`/etc/shadowsocks.json` 中修改，保持和客户端兼容。重启在`/etc/init.d/shadowsocks restart`

```
wget https://raw.githubusercontent.com/teddysun/shadowsocks_install/master/shadowsocksR.sh
chmod a+x shadowsocksR.sh
./shadowsocksR.sh
```

上 tcp bbr，脚本重新安装了一个内核。

```
wget --no-check-certificate https://github.com/teddysun/across/raw/master/bbr.sh
chmod +x bbr.sh
./bbr.sh
```

记得 /etc/sysctl.conf 配置调整。

```
net.core.default_qdisc = fq
fs.file-max = 51200
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mem = 25600 51200 102400
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = bbr
```

MAC 客户端推荐[shadowsocksX-NG-R](https://github.com/qinyuhang/ShadowsocksX-NG-R/releases)，野外下载的包在需要 mac 开放任意开发者 `sudo spctl --master-disable`，然后在 GUI 里面配置。
