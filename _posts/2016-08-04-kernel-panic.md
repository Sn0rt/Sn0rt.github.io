---
author: sn0rt
comments: true
date: 2016-08-04
layout: post
title: analysis of kernel crash
tag: linux
---

> 基于回忆整理

# 0x00 beginning

昨天早上我还在吃早餐, 老大对我讲我们的服务器挂了,kernel 在临死前留下了一个 dump.

# 0x10 autopsy

然后, 尸检的活让我来!

## 0x11 kernel version

确认一下尸体信息, 以及死因.

```shell
      KERNEL: /usr/lib/debug/lib/modules/3.10.0-229.el7.x86_64/vmlinux
    DUMPFILE: vmcore  [PARTIAL DUMP]
        CPUS: 24
        DATE: Wed Aug  3 10:10:42 2016
      UPTIME: 95 days, 17:54:10
LOAD AVERAGE: 0.13, 0.13, 0.14
       TASKS: 544
     RELEASE: 3.10.0-229.el7.x86_64
     VERSION: #1 SMP Fri Mar 6 11:36:42 UTC 2015
     MACHINE: x86_64  (2394 Mhz)
      MEMORY: 95.6 GB
       PANIC: "divide error: 0000 [#1] SMP "
```

kernel 是 centos 的`3.10.0-229`, 除 0 导致了死亡.

## 0x12 log

知道了死于除 0, 利用 log 看一下凶手谁.

```x86asm
PID: 0      TASK: ffff88183d27e660  CPU: 19  COMMAND: "swapper/19"
 #0 [ffff88187fce3a90] machine_kexec at ffffffff8104c681
 #1 [ffff88187fce3ae8] crash_kexec at ffffffff810e2222
 #2 [ffff88187fce3bb8] oops_end at ffffffff8160d188
 #3 [ffff88187fce3be0] die at ffffffff810173eb
 #4 [ffff88187fce3c10] do_trap at ffffffff8160c860
 #5 [ffff88187fce3c60] do_divide_error at ffffffff81013f7e
 #6 [ffff88187fce3d10] divide_error at ffffffff816160ce
    [exception RIP: intel_pstate_timer_func+376]
    RIP: ffffffff814a9d28  RSP: ffff88187fce3dc8  RFLAGS: 00010206
    RAX: 0000000027100000  RBX: ffff880c3b059e00  RCX: 0000000000000000
    RDX: 0000000000000000  RSI: 0000000000000010  RDI: 000000002e5361f0
    RBP: ffff88187fce3e28   R8: ffff88183ca08038   R9: ffff88183ca08001
    R10: 0000000000000002  R11: 0000000000000005  R12: 000000000000513f
    R13: 0000000000271000  R14: 000000000000513f  R15: ffff880c3b059e00
    ORIG_RAX: ffffffffffffffff  CS: 0010  SS: 0018
 #7 [ffff88187fce3e30] call_timer_fn at ffffffff8107e046
 #8 [ffff88187fce3e68] run_timer_softirq at ffffffff8107fecf
 #9 [ffff88187fce3ee0] __do_softirq at ffffffff81077bf7
#10 [ffff88187fce3f50] call_softirq at ffffffff8161635c
#11 [ffff88187fce3f68] do_softirq at ffffffff81015de5
#12 [ffff88187fce3f80] irq_exit at ffffffff81077f95
#13 [ffff88187fce3f98] smp_apic_timer_interrupt at ffffffff81616fd5
#14 [ffff88187fce3fb0] apic_timer_interrupt at ffffffff8161569d
--- <IRQ stack> ---
#15 [ffff880c3db4bde8] apic_timer_interrupt at ffffffff8161569d
    [exception RIP: native_safe_halt+6]
    RIP: ffffffff81052dd6  RSP: ffff880c3db4be90  RFLAGS: 00000286
    RAX: 00000000ffffffed  RBX: ffffffff8109b938  RCX: 0100000000000000
    RDX: 0000000000000000  RSI: 0000000000000000  RDI: 0000000000000046
    RBP: ffff880c3db4be90   R8: 0000000000000000   R9: 0000000000000000
    R10: 0000000000000004  R11: 0000000000000005  R12: 0000000085099e00
    R13: 0000000000000013  R14: 00000002ed0ef7c8  R15: 001d63c002b695c0
    ORIG_RAX: ffffffffffffff10  CS: 0010  SS: 0018
#16 [ffff880c3db4be98] default_idle at ffffffff8101c93f
#17 [ffff880c3db4beb8] arch_cpu_idle at ffffffff8101d236
#18 [ffff880c3db4bec8] cpu_startup_entry at ffffffff810c6955
#19 [ffff880c3db4bf28] start_secondary at ffffffff810423ca
```

可以看见`intel_pstate_timer_func`函数直接导致了死亡, 后面开始了`kdump`收尸.

## 0x13 backtrace

既然能大体确认凶手了, 下面尝试看一下犯罪现场, 利用`bt`的`rip`值`ffffffff814a9d28`找一下代码.

```shell
/usr/src/debug/kernel-3.10.0-229.el7/linux-3.10.0-229.el7.x86_64/drivers/cpufreq/intel_pstate.c: 47
0xffffffff814a9d15 <intel_pstate_timer_func+357>:	movslq %r12d,%r14
/usr/src/debug/kernel-3.10.0-229.el7/linux-3.10.0-229.el7.x86_64/drivers/cpufreq/intel_pstate.c: 52
0xffffffff814a9d18 <intel_pstate_timer_func+360>:	movslq %r13d,%rax
/usr/src/debug/kernel-3.10.0-229.el7/linux-3.10.0-229.el7.x86_64/drivers/cpufreq/intel_pstate.c: 605
0xffffffff814a9d1b <intel_pstate_timer_func+363>:	shl    $0x8,%rdx
/usr/src/debug/kernel-3.10.0-229.el7/linux-3.10.0-229.el7.x86_64/drivers/cpufreq/intel_pstate.c: 52
0xffffffff814a9d1f <intel_pstate_timer_func+367>:	shl    $0x8,%rax
/usr/src/debug/kernel-3.10.0-229.el7/linux-3.10.0-229.el7.x86_64/include/linux/math64.h: 29
0xffffffff814a9d23 <intel_pstate_timer_func+371>:	movslq %edx,%rcx
/usr/src/debug/kernel-3.10.0-229.el7/linux-3.10.0-229.el7.x86_64/include/linux/math64.h: 30
0xffffffff814a9d26 <intel_pstate_timer_func+374>:	cqto   
0xffffffff814a9d28 <intel_pstate_timer_func+376>:	idiv   %rcx
```
结合 backtrace 发现`rcx`是 0 且`0xffffffff814a9d28`处指令`idiv   %rcx`,kernel 发生了除 0 异常.
且还可以初步断定问题是:`drivers/cpufreq/intel_pstate.c`中的函数调用了`include/linux/math64.h`30 行的指令.

## 0x14 cause

到底死亡背后的原因是什么?
`3.10.0-229.el7`对应着源码包是`3.10.0-229.el7.src.rpm`, 并不能对应着`upstream`代码直接看, 因为并不清楚 3.10 的哪个小版本.
其中对应着`intel_pstate_timer_func()`的实现, 且还利用的 log 的堆栈找出来 inline 函数的调用次序.

```c
static void intel_pstate_timer_func(unsigned long __data)
{
	struct cpudata *cpu = (struct cpudata *) __data;
	struct sample *sample;
	intel_pstate_sample(cpu);
	sample = &cpu->sample;
	intel_pstate_adjust_busy_pstate(cpu);  // 这里! 看函数名猜测是判断 busy 状态
    ...
}

```

```c
static inline void intel_pstate_adjust_busy_pstate(struct cpudata *cpu)
{
	int32_t busy_scaled;
	struct _pid *pid;
	signed int ctl;
	pid = &cpu->pid;
	busy_scaled = intel_pstate_get_scaled_busy(cpu); // 获取相关状态
    ...
}

```

```c
static inline int32_t intel_pstate_get_scaled_busy(struct cpudata *cpu)
{
	int32_t core_busy, max_pstate, current_pstate, sample_ratio;
	u32 duration_us;
	u32 sample_time;
    ...
	duration_us = (u32) ktime_us_delta(cpu->sample.time,
					   cpu->last_sample_time);
	if (duration_us > sample_time * 3) {
		sample_ratio = div_fp(int_tofp(sample_time), // 死前一刀,int_tofp 始 duration_us 是 0.
				      int_tofp(duration_us));
		core_busy = mul_fp(core_busy, sample_ratio);
	}

	return core_busy;
}
```

这个时候查看 struct cpudata 结构体的值（这个是每 cpu 变量可以 p cpu_info:17）:

```c
struct cpudata {
  cpu = 113,
  timer = {
    entry = {
      next = 0x0,
      prev = 0xdead000000200200
    },
    expires = 8357799745,
    base = 0xffff883fe84ec001,
    function = 0xffffffff814a9100 <intel_pstate_timer_func>,
    data = 18446612406765768960,
<snip>
    i_gain = 0,
    d_gain = 0,
    deadband = 0,
    last_err = 22489
  },
  last_sample_time = {
    tv64 = 4063132438017305
  },
  prev_aperf = 287326796397463,
  prev_mperf = 251427432090198,
  sample = {
    core_pct_busy = 23081,
    aperf = 2937407,
    mperf = 3257884,
    freq = 2524484,
    time = {
      tv64 = 4063149215234118
    }
  }
}
```

结合`duration_us = (u32) ktime_us_delta(cpu->sample.time, cpu->last_sample_time)`与上下文, 计算采样间隔是 131901387587754ns, 进行 (u32) 类型转换也溢出.
后面`int_tofp`实现为`#define int_tofp(X) ((int64_t)(X) << 8)`, 所以`int_tofp(duration_us))`调用导致其变成`duration_us`变成 0. 又因为`div_fp`的调用, 所以 crash 出现了.

```c
static inline int32_t div_fp(int32_t x, int32_t y)
{
	return div_s64((int64_t)x << FRAC_BITS, y);
}

```

出于完整性考虑, 这里贴出了 inline 函数的调用次序(基于源码阅读和 backtrace 凑出来的):

```c
/**
 * div_s64 - signed 64bit divide with 32bit divisor
 */
#ifndef div_s64
static inline s64 div_s64(s64 dividend, s32 divisor)
{
	s32 remainder;
	return div_s64_rem(dividend, divisor, &remainder); // 捅出了那一刀
}
#endif
```

到这里基本就和 log 显示调用栈一致了, 代码在 math.h 的 30 行.

```c
/**
 * div_s64_rem - signed 64bit divide with 32bit divisor with remainder
 */
static inline s64 div_s64_rem(s64 dividend, s32 divisor, s32 *remainder)
{
	*remainder = dividend % divisor;
	return dividend / divisor; // 30 行, 死亡!
}

```

google 一下, 看见了曾经有人遇到了这个问题:

>The kernel may delay interrupts for a long time which can result in timers being delayed.  If this occurs the intel_pstate driver will crash with a divide by zero error

# 0x20 background and solution

## 0x21 background

这个驱动是 intel 为"SandyBridge+"微架构 CPU 提供的调整频率的控制接口 [^pstate].

## 0x22 solution

通过 Google 找到这个 bug 已经存在 [^patch] 的, 所以目前最好方案是升级内核,centos 升级到 3.10.0-229.20.1.el7.

线上主机很多, 提供一个临时的解决方案是:**禁用 pstate**[^wiki].

> pstate 的新的功率驱动程序将会在以下的驱动程序之前自动为现代的 Intel CPU 启用。该驱动会优先于其他的驱动程序，因为它是内置驱动，而不是作为一个模块来加载。该驱动自动作用于 Sandy Bridge 和 Ivy Bridge 这两个类型的 CPU。如果您在使用这个驱动的时候遇到问题，建议您在 Grub 的内核参数中对其禁用（即修改 `/etc/default/grub` 文件，在`GRUB_CMDLINE_LINUX_DEFAULT=` 后添加`intel_pstate=disable`）。

## 0x23 The question of temporary solution

方案提出了还没有验证, 老大帮我验证了.

> 关闭了 P-State 后，内核层面失去了控制硬件 CPU 频率的接口，不再对 CPU 的频率进行控制。根据下图我们可以看到在我们禁用这个模块前，CPU 的频率受 P-State 的控制，同时 turbo 被打开，一直处于一个 2.6GHz 的水平。禁用后 CPU 频率不再受 P-State 控制，之前使用 P-State 打开的 turbo 也停止工作，最终频率稳定的工作在 CPU 的默认配置 2.4GHz。

还有一些问题有待以后验证.
1: `apic_timer_interrupt`抛出去的异常. 
2: 不完整的 patch 猜想, 准备和作者沟通一下描述这个问题. 

关于问题 2, 作者已经给出了表述.

>>
 and found last_sample_time = { tv64 = -131888820469800 }.
> 
 This doesn't make sense.  last_sample_time is a u64 field, so it can't be negative.

[^patch]: [[PATCH] cpufreq, Fix overflow in busy_scaled due to long delay](https://git.kernel.org/cgit/linux/kernel/git/torvalds/linux.git/commit/drivers/cpufreq/intel_pstate.c?id=7180dddf7c32c49975c7e7babf2b60ed450cb760)
[^wiki]: [archlinux wiki](https://wiki.archlinux.org/index.php/CPU_frequency_scaling_(%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87)#.E8.B0.83.E6.95.B4.E8.B0.83.E9.80.9F.E5.99.A8)
[^pstate]: [intel-pstate](https://www.kernel.org/doc/Documentation/cpu-freq/intel-pstate.txt)
