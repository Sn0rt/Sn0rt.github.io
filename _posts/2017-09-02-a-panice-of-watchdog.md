---
author: sn0rt
comments: true
date: 2017-09-02
layout: post
title: a panic of watchdog hard lockup
tag: linux
---


这个周一早上来工作被告知上周有 4 台物理 crash 了，需要诊断修复，

表象：
```
 #0 [ffff88103fbc59f0] machine_kexec at ffffffff81059beb
 #1 [ffff88103fbc5a50] __crash_kexec at ffffffff81105822
 #2 [ffff88103fbc5b20] panic at ffffffff81680541
 #3 [ffff88103fbc5ba0] nmi_panic at ffffffff81085abf
 #4 [ffff88103fbc5bb0] watchdog_overflow_callback at ffffffff8112f879
 #5 [ffff88103fbc5bc8] __perf_event_overflow at ffffffff81174d2e
 #6 [ffff88103fbc5c00] perf_event_overflow at ffffffff81175974
 #7 [ffff88103fbc5c10] intel_pmu_handle_irq at ffffffff81009d88
 #8 [ffff88103fbc5e38] perf_event_nmi_handler at ffffffff8168ed6b
 #9 [ffff88103fbc5e58] nmi_handle at ffffffff816901b7
#10 [ffff88103fbc5eb0] do_nmi at ffffffff816903c3
#11 [ffff88103fbc5ef0] end_repeat_nmi at ffffffff8168f5d3
    [exception RIP: update_curr+15]
    RIP: ffffffff810ce3cf  RSP: ffff88103fbc3db8  RFLAGS: 00000002
    RAX: 0000000000000001  RBX: ffff88092b2ed200  RCX: 0000000000000001
    RDX: 0000000000000001  RSI: ffff88092b2ed200  RDI: ffff880f6afb8600
    RBP: ffff88103fbc3dd0   R8: ffff88103d2b7500   R9: 0000000000000001
    R10: 0000000000000000  R11: 0000000000000000  R12: ffff880f6afb8600
    R13: 0000000000000001  R14: 0000000000000003  R15: ffff8813bf7f5548
    ORIG_RAX: ffffffffffffffff  CS: 0010  SS: 0018
--- <NMI exception stack> ---
#12 [ffff88103fbc3db8] update_curr at ffffffff810ce3cf
#13 [ffff88103fbc3dd8] enqueue_entity at ffffffff810d042d
#14 [ffff88103fbc3e20] unthrottle_cfs_rq at ffffffff810d16f4
#15 [ffff88103fbc3e58] distribute_cfs_runtime at ffffffff810d1932
#16 [ffff88103fbc3ea0] sched_cfs_period_timer at ffffffff810d1acf
#17 [ffff88103fbc3ed8] __hrtimer_run_queues at ffffffff810b4d72
#18 [ffff88103fbc3f30] hrtimer_interrupt at ffffffff810b5310
#19 [ffff88103fbc3f80] local_apic_timer_interrupt at ffffffff81051037
#20 [ffff88103fbc3f98] smp_apic_timer_interrupt at ffffffff81699f0f
#21 [ffff88103fbc3fb0] apic_timer_interrupt at ffffffff8169845d
--- <IRQ stack> ---
#22 [ffff8801699a3de8] apic_timer_interrupt at ffffffff8169845d
    [exception RIP: native_safe_halt+6]
    RIP: ffffffff81060fe6  RSP: ffff8801699a3e98  RFLAGS: 00000286
    RAX: 00000000ffffffed  RBX: ffff88103fbcd080  RCX: 0100000000000000
    RDX: 0000000000000000  RSI: 0000000000000000  RDI: 0000000000000046
    RBP: ffff8801699a3e98   R8: 0000000000000000   R9: 0000000000000000
    R10: 0000000000000000  R11: 0000000000000000  R12: 00099b9bb0645f00
    R13: ffff88103fbcfde0  R14: f21bf8c4662d3c34  R15: 0000000000000082
    ORIG_RAX: ffffffffffffff10  CS: 0010  SS: 0018
#23 [ffff8801699a3ea0] default_idle at ffffffff810347ff
#24 [ffff8801699a3ec0] arch_cpu_idle at ffffffff81035146
#25 [ffff8801699a3ed0] cpu_startup_entry at ffffffff810e82f5
#26 [ffff8801699a3f28] start_secondary at ffffffff8104f0da
```

影响范围：

	确认的范围有 Linux 3.10.0-514.26.2.el7

解决方案：

	等待上游合并 patch c06f04c70489b9deea3212af8375e2f0c2f0b184

原因[^patch]：

> distribute_cfs_runtime() intentionally only hands out enough runtime to bring each cfs_rq to 1 ns of runtime, expecting the cfs_rqs to then take the runtime they need only once they actually get to run. However, if they get to run sufficiently quickly, the period timer is still in distribute_cfs_runtime() and no runtime is available, causing them to throttle. Then distribute has to handle them again, and this can go on until distribute has handed out all of the runtime 1ns at a time, which takes far too long.

诊断过程：

```
crash> bt
PID: 0      TASK: ffff880169986dd0  CPU: 7   COMMAND: "swapper/7"
 #0 [ffff88103fbc59f0] machine_kexec at ffffffff81059beb
 #1 [ffff88103fbc5a50] __crash_kexec at ffffffff81105822
 #2 [ffff88103fbc5b20] panic at ffffffff81680541
 #3 [ffff88103fbc5ba0] nmi_panic at ffffffff81085abf
 #4 [ffff88103fbc5bb0] watchdog_overflow_callback at ffffffff8112f879
 #5 [ffff88103fbc5bc8] __perf_event_overflow at ffffffff81174d2e
 #6 [ffff88103fbc5c00] perf_event_overflow at ffffffff81175974
 #7 [ffff88103fbc5c10] intel_pmu_handle_irq at ffffffff81009d88
 #8 [ffff88103fbc5e38] perf_event_nmi_handler at ffffffff8168ed6b
 #9 [ffff88103fbc5e58] nmi_handle at ffffffff816901b7
#10 [ffff88103fbc5eb0] do_nmi at ffffffff816903c3
#11 [ffff88103fbc5ef0] end_repeat_nmi at ffffffff8168f5d3
    [exception RIP: update_curr+15]
    RIP: ffffffff810ce3cf  RSP: ffff88103fbc3db8  RFLAGS: 00000002
    RAX: 0000000000000001  RBX: ffff88092b2ed200  RCX: 0000000000000001
    RDX: 0000000000000001  RSI: ffff88092b2ed200  RDI: ffff880f6afb8600
    RBP: ffff88103fbc3dd0   R8: ffff88103d2b7500   R9: 0000000000000001
    R10: 0000000000000000  R11: 0000000000000000  R12: ffff880f6afb8600
    R13: 0000000000000001  R14: 0000000000000003  R15: ffff8813bf7f5548
    ORIG_RAX: ffffffffffffffff  CS: 0010  SS: 0018
--- <NMI exception stack> ---
#12 [ffff88103fbc3db8] update_curr at ffffffff810ce3cf
#13 [ffff88103fbc3dd8] enqueue_entity at ffffffff810d042d
#14 [ffff88103fbc3e20] unthrottle_cfs_rq at ffffffff810d16f4
#15 [ffff88103fbc3e58] distribute_cfs_runtime at ffffffff810d1932
#16 [ffff88103fbc3ea0] sched_cfs_period_timer at ffffffff810d1acf
#17 [ffff88103fbc3ed8] __hrtimer_run_queues at ffffffff810b4d72
#18 [ffff88103fbc3f30] hrtimer_interrupt at ffffffff810b5310
#19 [ffff88103fbc3f80] local_apic_timer_interrupt at ffffffff81051037
#20 [ffff88103fbc3f98] smp_apic_timer_interrupt at ffffffff81699f0f
#21 [ffff88103fbc3fb0] apic_timer_interrupt at ffffffff8169845d
--- <IRQ stack> ---
#22 [ffff8801699a3de8] apic_timer_interrupt at ffffffff8169845d
    [exception RIP: native_safe_halt+6]
    RIP: ffffffff81060fe6  RSP: ffff8801699a3e98  RFLAGS: 00000286
    RAX: 00000000ffffffed  RBX: ffff88103fbcd080  RCX: 0100000000000000
    RDX: 0000000000000000  RSI: 0000000000000000  RDI: 0000000000000046
    RBP: ffff8801699a3e98   R8: 0000000000000000   R9: 0000000000000000
    R10: 0000000000000000  R11: 0000000000000000  R12: 00099b9bb0645f00
    R13: ffff88103fbcfde0  R14: f21bf8c4662d3c34  R15: 0000000000000082
    ORIG_RAX: ffffffffffffff10  CS: 0010  SS: 0018
#23 [ffff8801699a3ea0] default_idle at ffffffff810347ff
#24 [ffff8801699a3ec0] arch_cpu_idle at ffffffff81035146
#25 [ffff8801699a3ed0] cpu_startup_entry at ffffffff810e82f5
#26 [ffff8801699a3f28] start_secondary at ffffffff8104f0da
```

看 bt 的长相，推断系统死亡之前应该没啥事情，然后开始处理一个时钟中断，正在处理时钟中断的过程中发生一个 NMI 异常，然后进入异常处理,然后在异常处理里 panic 了。在异常栈中选择多看了两眼的函数是 watchdog_overflow_callback，是因为后面的打印信息和 panic 操作都在这个函数里面进行的，关于 watchdog_overflow_callback 这个函数描述[^watchdog]：

>This function is invoked from Non-Maskable Interrupt (NMI) context. If a CPU is busy, this function executes periodically and it checks whether watchdog_timer_fn has incremented the CPU-specific counter during the past interval. If the counter has not been incremented, watchdog_overflow_callback assumes that the CPU is 'locked up' in a section of kernel code where interrupts are disabled, and a panic occurs unless 'panic on hard lockup' is explicitly disabled via the nmi_watchdog=nopanic parameter on the kernel command line.

分析 watchdog_overflow_callback 函数的实现，其中 is_hardlockup 后面对应的代码块中具体是对比如下的两个值：

```
crash> px hrtimer_interrupts_saved:7
per_cpu(hrtimer_interrupts_saved, 7) = $14 = 0xa50fb
crash> px hrtimer_interrupts:7
per_cpu(hrtimer_interrupts, 7) = $15 = 0xa50fb
```

其中 hrtimer_interrupts 是 pre-cpu 变量，它会被 call_timer_fn 更新(根据外部信息)，也就是说 watchdog 发现 cpu #7 locked up 在一块内核代码里了。回头注意看一下 bt 注意其中两次 RFLAGS 的变化，在中断栈之前 00000286 是即 IF 标志位置位，进入异常栈过后发现 00000002 即 IF 未置位，一个典型中断被 NMI 抢占的现象，这现象可能是 ISR 占用了太久了触发了 watchdog。

IRQ stack 如下：

```
    [exception RIP: update_curr+15]
    RIP: ffffffff810ce3cf  RSP: ffff88103fbc3db8  RFLAGS: 00000002
    RAX: 0000000000000001  RBX: ffff88092b2ed200  RCX: 0000000000000001
    RDX: 0000000000000001  RSI: ffff88092b2ed200  RDI: ffff880f6afb8600
    RBP: ffff88103fbc3dd0   R8: ffff88103d2b7500   R9: 0000000000000001
    R10: 0000000000000000  R11: 0000000000000000  R12: ffff880f6afb8600
    R13: 0000000000000001  R14: 0000000000000003  R15: ffff8813bf7f5548
    ORIG_RAX: ffffffffffffffff  CS: 0010  SS: 0018
--- <NMI exception stack> ---
#12 [ffff88103fbc3db8] update_curr at ffffffff810ce3cf
#13 [ffff88103fbc3dd8] enqueue_entity at ffffffff810d042d
#14 [ffff88103fbc3e20] unthrottle_cfs_rq at ffffffff810d16f4
#15 [ffff88103fbc3e58] distribute_cfs_runtime at ffffffff810d1932
#16 [ffff88103fbc3ea0] sched_cfs_period_timer at ffffffff810d1acf
#17 [ffff88103fbc3ed8] __hrtimer_run_queues at ffffffff810b4d72
#18 [ffff88103fbc3f30] hrtimer_interrupt at ffffffff810b5310
#19 [ffff88103fbc3f80] local_apic_timer_interrupt at ffffffff81051037
#20 [ffff88103fbc3f98] smp_apic_timer_interrupt at ffffffff81699f0f
#21 [ffff88103fbc3fb0] apic_timer_interrupt at ffffffff8169845d
--- <IRQ stack> ---
```

已知 apic_timer_interrupt 会禁用中断，而且在 hrtimer_interrupt 函数注释也重复说明了这一点，就在一定程度上强化了之前猜想 ISR（apic_timer_interrupt）触发 NMI watchdog 的想法。

```
crash> dis -s hrtimer_interrupt|head -n 10
FILE: kernel/hrtimer.c
LINE: 1292

  1287	/*
  1288	 * High resolution timer interrupt
  1289	 * Called with interrupts disabled
  1290	 */
  1291	void hrtimer_interrupt(struct clock_event_device *dev)
* 1292	{
  1293		struct hrtimer_cpu_base *cpu_base = this_cpu_ptr(&hrtimer_bases);
```

通过 backtrace 梳理函数的调用关系 update_curr<-enqueue_entity<-unthrottle_cfs_rq<-distribute_cfs_runtime<-sched_cfs_period_timer
猜测这个可能与 CFS Bandwidth Control [^cfs_bandwidth] 特性有点关系(通过 dis -s unthrottle_cfs_rq 确认)，下面就是利基于 x86_64 上 caller 与 callee 约定以及函数原型看参数，去参数的值对比。


第一组：distribute_cfs_runtime 函数
原型：

```
crash> dis -s distribute_cfs_runtime
  3423  static u64 distribute_cfs_runtime(struct cfs_bandwidth *cfs_b,
  3424                  u64 remaining, u64 expires)
```

caller:

```
#16 [ffff88103fbc3ea0] sched_cfs_period_timer at ffffffff810d1acf
```

```
crash> dis 0xffffffff810d1acf -r |tail
...
0xffffffff810d1ac1 <sched_cfs_period_timer+193>:	mov    %r13,%rsi
0xffffffff810d1ac4 <sched_cfs_period_timer+196>:	mov    %r15,%rdx
0xffffffff810d1ac7 <sched_cfs_period_timer+199>:	mov    %r12,%rdi
0xffffffff810d1aca <sched_cfs_period_timer+202>:	callq  0xffffffff810d1840 <distribute_cfs_runtime>
```

callee:

```
crash> dis distribute_cfs_runtime|head -n 20
0xffffffff810d1840 <distribute_cfs_runtime>:	nopl   0x0(%rax,%rax,1) [FTRACE NOP]
0xffffffff810d1845 <distribute_cfs_runtime+5>:	push   %rbp
0xffffffff810d1846 <distribute_cfs_runtime+6>:	mov    %rsp,%rbp
0xffffffff810d1849 <distribute_cfs_runtime+9>:	push   %r15  // 3rd
0xffffffff810d184b <distribute_cfs_runtime+11>:	push   %r14
0xffffffff810d184d <distribute_cfs_runtime+13>:	mov    %rdx,%r14
0xffffffff810d1850 <distribute_cfs_runtime+16>:	push   %r13  // 2nd
0xffffffff810d1852 <distribute_cfs_runtime+18>:	push   %r12  // 1st
0xffffffff810d1854 <distribute_cfs_runtime+20>:	mov    %rsi,%r12
0xffffffff810d1857 <distribute_cfs_runtime+23>:	push   %rbx
0xffffffff810d1858 <distribute_cfs_runtime+24>:	sub    $0x10,%rsp
```

```
crash> bt -f
...
#15 [ffff88103fbc3e58] distribute_cfs_runtime at ffffffff810d1932
    ffff88103fbc3e60: ffff88103d2b7500 f21bf8c4662d3c34
    ffff88103fbc3e70: ffff8813bf7f5580 ffff8813bf7f5548
    ffff88103fbc3e80: 0000000002625a00 ffff8813bf7f5640
    ffff88103fbc3e90: 00099ba6210dc705 ffff88103fbc3ed0
    ffff88103fbc3ea0: ffffffff810d1acf
```

根据栈顺序：
cfs_bandwidth *cfs_b 是 ffff8813bf7f5548,
u64 remaining 是 0000000002625a00,
u64 expires 是 00099ba6210dc705。

第二组数 unthrottle_cfs_rq 函数

原型：unthrottle_cfs_rq(struct cfs_rq *cfs_rq)

caller:

```
crash> dis -r ffffffff810d1932 | tail
...
0xffffffff810d192a <distribute_cfs_runtime+234>:	mov    %r15,%rdi
0xffffffff810d192d <distribute_cfs_runtime+237>:	callq  0xffffffff810d1610 <unthrottle_cfs_rq>
```

callee:
```
crash> dis -r ffffffff810d16f4 | head -n 20
0xffffffff810d1610 <unthrottle_cfs_rq>:	nopl   0x0(%rax,%rax,1) [FTRACE NOP]
0xffffffff810d1615 <unthrottle_cfs_rq+5>:	push   %rbp
0xffffffff810d1616 <unthrottle_cfs_rq+6>:	mov    %rsp,%rbp
0xffffffff810d1619 <unthrottle_cfs_rq+9>:	push   %r15
```

```
#14 [ffff88103fbc3e20] unthrottle_cfs_rq at ffffffff810d16f4
    ffff88103fbc3e28: ffff88103fe56c40 00000000008cc0b3
    ffff88103fbc3e38: ffff8813bf7f5640 00099ba6210dc705
    ffff88103fbc3e48: ffff88103d2b7400 ffff88103fbc3e98
    ffff88103fbc3e58: ffffffff810d1932
```

则 struct cfs_rq *cfs_rq 是 `ffff88103d2b7400`

查看结构体字段的值：

```
crash> cfs_rq.runtime_remaining,runtime_expires ffff88103d2b7400
  runtime_remaining = 1
  runtime_expires = 2704412611823365
```

获取 cfs_rq.throttled_list 链表的地址：

```
crash> cfs_rq.throttled_list ffff88103d2b7400 -ox
struct cfs_rq {
  [ffff88103d2b7500] struct list_head throttled_list;
}
```

确认 rq 的剩余运行时间总量：

```
crash> list -H ffff88103d2b7500 -o cfs_rq.throttled_list -s cfs_rq.runtime_remaining | grep -c runtime_remaining
22

crash> list -H ffff88103d2b7500 -o cfs_rq.throttled_list -s cfs_rq.throttled,runtime_remaining
ffff88103d2b6200
  throttled = 1
  runtime_remaining = -2535
ffff88103d2b6800
  throttled = 1
  runtime_remaining = -2337
ffff88103d2b7e00
  throttled = 1
  runtime_remaining = -2706
ffff880f30f33e00
  throttled = 1
  runtime_remaining = -2441
ffff88103d2b5600
  throttled = 1
  runtime_remaining = -2356
ffff88103d2b6a00
  throttled = 1
  runtime_remaining = -2365
ffff88103d2b7a00
  throttled = 1
  runtime_remaining = -2260
ffff88103d2b5400
  throttled = 1
  runtime_remaining = -2404
ffff88103d2b6c00
  throttled = 1
  runtime_remaining = -2421
ffff88103d2b7600
  throttled = 1
  runtime_remaining = -2429
ffff88103d2b4200
  throttled = 1
  runtime_remaining = -2357
ffff88103d2b7800
  throttled = 1
  runtime_remaining = -2359
ffff88103d2b6000
  throttled = 1
  runtime_remaining = -2416
ffff88103d2b7200
  throttled = 1
  runtime_remaining = -2353
ffff88103d2b6e00
  throttled = 1
  runtime_remaining = -2263
ffff8813be33a800
  throttled = 1
  runtime_remaining = -3394
ffff880f30f33c00
  throttled = 1
  runtime_remaining = -2599
ffff880f30f31000
  throttled = 1
  runtime_remaining = -2546
ffff8813be33ae00
  throttled = 1
  runtime_remaining = -3157
ffff88103d2b4c00
  throttled = 1
  runtime_remaining = -2337
ffff88103d2b6600
  throttled = 1
  runtime_remaining = -2284
ffff8813bf7f5540
  throttled = 1767994478
  runtime_remaining = 0
```

看到一组异常的值明显和上面的 cfs_rq 的不一样。

```
crash> struct cfs_rq.throttled,runtime_remaining ffff8813bf7f5540
  throttled = 1767994478
  runtime_remaining = 0
```
> 感谢 wuzhouhui 的指正 ffff8813bf7f5540 是一个 cfs_bandwidth 结构体，所以值看上去非常诡异。

累加 remaining 的值计算一共多少时间。

```
crash> pd 2535+2337+2706+2441+2356+2365+2260+2404+2421+2429+2357+2359+2416+2353+2263+3394+2599+2546+3157+2337+2284+0
$2 = 52319
```

如法炮制，来取得 static u64 distribute_cfs_runtime(struct cfs_bandwidth *cfs_b, u64 remaining, u64 expires)中 remaining 参数经过处理过后的值：

```
/usr/src/debug/kernel-3.10.0-514.26.2.el7/linux-3.10.0-514.26.2.el7.x86_64/kernel/sched/fair.c: 3438
0xffffffff810d190e <distribute_cfs_runtime+206>:        sub    %rcx,%rdx
0xffffffff810d1911 <distribute_cfs_runtime+209>:        cmp    %rdx,%r12
0xffffffff810d1914 <distribute_cfs_runtime+212>:        cmovbe %r12,%rdx
/usr/src/debug/kernel-3.10.0-514.26.2.el7/linux-3.10.0-514.26.2.el7.x86_64/kernel/sched/fair.c: 3441
0xffffffff810d1918 <distribute_cfs_runtime+216>:        sub    %rdx,%r12
/usr/src/debug/kernel-3.10.0-514.26.2.el7/linux-3.10.0-514.26.2.el7.x86_64/kernel/sched/fair.c: 3443
0xffffffff810d191b <distribute_cfs_runtime+219>:        add    %rcx,%rdx
/usr/src/debug/kernel-3.10.0-514.26.2.el7/linux-3.10.0-514.26.2.el7.x86_64/kernel/sched/fair.c: 3447
0xffffffff810d191e <distribute_cfs_runtime+222>:        test   %rdx,%rdx
/usr/src/debug/kernel-3.10.0-514.26.2.el7/linux-3.10.0-514.26.2.el7.x86_64/kernel/sched/fair.c: 3443
0xffffffff810d1921 <distribute_cfs_runtime+225>:        mov    %rdx,0xd8(%r15)
/usr/src/debug/kernel-3.10.0-514.26.2.el7/linux-3.10.0-514.26.2.el7.x86_64/kernel/sched/fair.c: 3447
0xffffffff810d1928 <distribute_cfs_runtime+232>:        jle    0xffffffff810d18bf <distribute_cfs_runtime+127>
/usr/src/debug/kernel-3.10.0-514.26.2.el7/linux-3.10.0-514.26.2.el7.x86_64/kernel/sched/fair.c: 3448
0xffffffff810d192a <distribute_cfs_runtime+234>:        mov    %r15,%rdi
0xffffffff810d192d <distribute_cfs_runtime+237>:        callq  0xffffffff810d1610 <unthrottle_cfs_rq>
```

```
crash> l 3438
3433
3434                    raw_spin_lock(&rq->lock);
3435                    if (!cfs_rq_throttled(cfs_rq))
3436                            goto next;
3437
3438                    runtime = -cfs_rq->runtime_remaining + 1;
3439                    if (runtime > remaining)
3440                            runtime = remaining;
3441                    remaining -= runtime;
3442
3443                    cfs_rq->runtime_remaining += runtime;
```

可以看到 remaining 的值放在 r12 里面，且下面的汇编指令都没有修改 r12,就调用了 unthrottle_cfs_rq。

```
crash> dis unthrottle_cfs_rq
0xffffffff810d1610 <unthrottle_cfs_rq>: nopl   0x0(%rax,%rax,1) [FTRACE NOP]
0xffffffff810d1615 <unthrottle_cfs_rq+5>:       push   %rbp
0xffffffff810d1616 <unthrottle_cfs_rq+6>:       mov    %rsp,%rbp
0xffffffff810d1619 <unthrottle_cfs_rq+9>:       push   %r15
0xffffffff810d161b <unthrottle_cfs_rq+11>:      push   %r14
0xffffffff810d161d <unthrottle_cfs_rq+13>:      push   %r13
0xffffffff810d161f <unthrottle_cfs_rq+15>:      push   %r12
```

```
#14 [ffff88103fbc3e20] unthrottle_cfs_rq at ffffffff810d16f4
    ffff88103fbc3e28: ffff88103fe56c40 00000000008cc0b3 // r12
    ffff88103fbc3e38: ffff8813bf7f5640 00099ba6210dc705
    ffff88103fbc3e48: ffff88103d2b7400 ffff88103fbc3e98 // r15 | rbp
    ffff88103fbc3e58: ffffffff810d1932

crash> pd 0x00000000008cc0b3
$3 = 9224371
```

在 unthrottle_cfs_rq 中取得 distribute_cfs_runtime 的 remaining 的值为 9224371。

```
crash> cfs_bandwidth.throttled_cfs_rq ffff8813bf7f5548
  throttled_cfs_rq = {
    next = 0xffff88103d2b6300,
    prev = 0xffff88103d2b6700
  }

crash> list 0xffff88103d2b6300 | wc -l
22
```

之前计算在地址为 ffff88103d2b7400 的 cfs_rq 中的 runtime_remaining 的值为 52319。distribute_cfs_runtime 中的本地变量的 remaining 为 9224371 远大于 cfs_rq 中的 remaining 为 52319，这就是使得 kernel 在下面 while 的循环中出不来：

```
crash> l do_sched_cfs_period_timer
3471
...
3513
3514            /*
3515             * This check is repeated as we are holding onto the new bandwidth
3516             * while we unthrottle.  This can potentially race with an unthrottled
3517             * group trying to acquire new bandwidth from the global pool.
3518             */
3519            while (throttled && runtime > 0) {
3520                    raw_spin_unlock(&cfs_b->lock);
3521                    /* we can't nest cfs_b->lock while distributing bandwidth */
3522                    runtime = distribute_cfs_runtime(cfs_b, runtime,
3523                                                     runtime_expires);
3524                    raw_spin_lock(&cfs_b->lock);
3525
3526                    throttled = !list_empty(&cfs_b->throttled_cfs_rq);
3527            }
3528
3529            /* return (any) remaining runtime */
3530            cfs_b->runtime = runtime;
3531            /*
3532             * While we are ensured activity in the period following an
3533             * unthrottle, this also covers the case in which the new bandwidth is
3534             * insufficient to cover the existing bandwidth deficit.  (Forcing the
3535             * timer to remain active while there are any throttled entities.)
3536             */
3537            cfs_b->idle = 0;
3538
3539            return 0;
3540
3541    out_deactivate:
3542            cfs_b->timer_active = 0;
3543            return 1;
3544    }
```

referece：

[^patch]: [fix-patch](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git/commit/?id=c06f04c70489b9deea3212af8375e2f0c2f0b184)
[^watchdog]: [watchdog](http://linuxperf.com/?p=83)
[^cfs_bandwidth]: [CFS Bandwidth Control](https://lwn.net/Articles/385055/)
