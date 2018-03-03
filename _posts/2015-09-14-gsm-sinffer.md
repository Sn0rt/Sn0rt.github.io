---
author: sn0rt
comments: true
date: 2015-09-14
layout: post
tag: security
title: gsm sniffer
---

# 0x00 provision

一个 Linux 系统, 摩托罗拉 c118,T 型 minusb 数据线,Motorola c118/c123 数据连接线,FT232 USB 转串口 TTL,Motorola C118/c123 滤波器套件 (这个需要焊接技能, 换滤波器可以捕获 uplink 信号), 感谢曾哥赞助这些玩具, 可以到淘宝店一次买全.

# 0x01 software

```shell
mkdir gprs_sniffer
cd gprs_sniffer
git clone git://git.osmocom.org/osmocom-bb.git
git clone git://git.osmocom.org/libosmocore.git
git clone git://git.srlabs.de/gprsdecode.git
```
下载交叉编译环境 [here](http://pan.baidu.com/share/link?shareid=739532605&uk=2955852660), 某些 64 位的 linux 需要安装 32 的 glibc 的库.
实验环境准备好, 目录是这个样子
![dir](/media/pic/GSM/file_ready.png)

# 0x02 debug environment

```shell
tar xf bu-2.15_gcc-3.4.3-c-c++-java_nl-1.12.0_gi-6.1.tar.bz2
export PATH=$PATH:/root/gprs_sniffer/gnuarm-3.4.3/bin
```
解压交叉编译环境准备设置变量.

```shell
cd libosmocore
autoreconf -i
./configure
make
sudo make install
```
autoreconf 工具由 automake 的包提供的.

```shell
cd gprsdecode
make
```
这个模块并没有注意到什么地方用, 是按照参考文档上的敲的 [^52].

```shell
cd osmocom-bb
git checkout --track origin/luca/gsmmap
vim /root/gprs_sniffer/osmocom-bb/src/target/firmware/Makefile 	# 把 CFLAGS += -DCONFIG_TX_ENABLE 前的注释符号去掉
cd src
make -j8
```

处理 OsmocomBB 分支问题, 亲测 luca/gsmmap 可编译通过, 而且需要把 mocom-bb/src/target/firmwire/ 下的 Makefile 中的 CONFIG_TX_ENABLE 宏注释取消掉, 不然一直在扫描没有结果.

# 0x03 sniffing

```shell
cd host/osmocon/
sudo ./osmocon -p /dev/ttyUSB0 -m c123xor ../../target/firmware/board/compal_e88/layer1.compalram.bin
```
先把 c118 关机, 然后确认和电脑的连接正常, 输入上面的命令, 按一下 c118 的红色电源键, 刷入 layer1 的固件, 会看到 c118 的手机屏幕显示.

```shell
cd osmocom-bb/src/host/layer23/src/misc
sudo ./cell_log -O
```
扫描基站信息,PWR 数值越大信号越好, 注意是负数.

```shell
sudo ./ccch_scan -i 127.0.0.1 -a 56
```
然后使用 ccch_scan 进行抓包,-a 参数为指定 ARFCN 号

```shell
sudo wireshark -k -i lo -f 'port 4729'
```
注意 wireshark 的 filiter 的写成 GSM_SMS.

# 0x04 demo

![sms](/media/pic/GSM/gsm.png)

[^52]: [52pojie](http://www.52pojie.cn/thread-315571-1-1.html)
