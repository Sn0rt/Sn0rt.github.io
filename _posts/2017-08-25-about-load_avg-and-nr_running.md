---
author: sn0rt
comments: true
date: 2017-08-25
layout: post
tag: linux
title: a question which about load_avg
---

写这个这个 post 的原因我们之前的线上主机(3.10.0-229.el7)的 load 非常非常诡异高达`4294967293.49, 4294967293.43, 4294967259.67`,众所周知 Linux 下影响 load 的两个重要指标是`running queue 的大小`，和 `不可中断睡眠`。

然后看了一下 ps 没有 D 状态的进程，那么也就是说系统 rq 非常非常大，`vmstat`一看果然如此，然后进入系统的调度器的 debug 信息一看，发现一个 cpu 上的 nr_running 过于夸张。

```
$ cat /proc/sched_debug | grep cpu#2 -A 10
cpu#2, 2599.996 MHz
  .nr_running : 4294967293
  .load : 0
  .nr_switches : 31613974
  .nr_load_updates : 125150154
  .nr_uninterruptible : -480
  .next_balance : 4462.218862
  .curr->pid : 0
  .clock : 167551354.006710
  .cpu_load[0] : 0
  .cpu_load[1] : 0
```

判断数值非常可能是某个路径导致了溢出。

```
$ipython
In [2]: hex(4294967293)
Out[2]: '0xfffffffd'
```

问题在重启后暂时消失了,目前没复现,也就是说没有找到 root cause，在一番尝试下不仅没有解决问题还产生了新的疑惑如下：

```systemtap
#!/usr/bin/env stap

global traced_cpu;
probe begin {
   traced_cpu = $1
   printf("Tracing CPU%d...\n", traced_cpu);
}

probe kernel.function("inc_nr_running") {
   if(cpu() != traced_cpu) next;
   printf("current is inc_nr and nr is %d \n", @var("rq")->nr_running);
}
```

负责产生 load 触发 enqueue 操作的代码。

```c
int main()
{
int var = 0;
while(1){
var = 1+1 ;
}
return 0;
}
```
我开了 tmux，在另一个窗口运行如下代码，然后切好换回产生 enqueue 的代码，反复运行。

```systemtap
# stap -v 1.stp 6
```

在另一个 terminal 里面观察 nr_running 有时候会变成 0。

```
current is inc_nr and nr is 9
current is inc_nr and nr is 9
current is inc_nr and nr is 9
current is inc_nr and nr is 9
current is inc_nr and nr is 10
current is inc_nr and nr is 0
current is inc_nr and nr is 10
current is inc_nr and nr is 0
current is inc_nr and nr is 9
current is inc_nr and nr is 9
current is inc_nr and nr is 9
current is inc_nr and nr is 9
current is inc_nr and nr is 9
current is inc_nr and nr is 9
current is inc_nr and nr is 9
```

等哪天有时间再追杀，或者哪个大佬知道原因帮忙讲一下，拜谢！
