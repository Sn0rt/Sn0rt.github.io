---
author: sn0rt
comments: true
date: 2016-12-03
layout: post
tag: linux
title: linux MM performance test
--- 

之前学习内存管理的换页算法与 workload 类型之间关系，其中的性能测试使用了[vm-scalability](https://git.kernel.org/pub/scm/linux/kernel/git/wfg/vm-scalability.git/)项目，项目的 maintainer 非常耐心解答我关于项目使用的问题。

看项目的名字非常容易理解这个项目是为了解决测试内存管理子系统的拓展性问题的，之前我只是关注了换页算法 LRU 实现：

```
-rwxr-xr-x	case-lru-file-mmap-read	366	logstatsplain
-rwxr-xr-x	case-lru-file-mmap-read-rand	375	logstatsplain
-rwxr-xr-x	case-lru-file-readonce	555	logstatsplain
-rwxr-xr-x	case-lru-file-readtwice	863	logstatsplain
-rwxr-xr-x	case-lru-memcg	694	logstatsplain
-rwxr-xr-x	case-lru-shm	539	logstatsplain
-rwxr-xr-x	case-lru-shm-rand	348	logstatsplain
```

用它测试了[mm: vmscan: move dirty pages out of the way until they're flushed](https://marc.info/?l=linux-mm&m=148519543602582&w=2)这个 patch，`case-lru-file-readonce`在 64 G 内存机器下面提示大约 3%，而 32G 下面提升非常有限了。

搜索了一下 mm 邮件列表可以看到有 kernel 开发者拿这个做性能回归测试的一个另一个例子[^regression]。

[^regression]: [mm: fix vm-scalability regression in cgroup-aware workingset code](https://marc.info/?l=linux-kernel&m=146679082705539&w=2)
