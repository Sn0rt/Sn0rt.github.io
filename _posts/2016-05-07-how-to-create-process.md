---
author: sn0rt
comments: true
date: 2016-05-7
layout: post
tag: linux
title: how to create a process
---

在操作系统教科书中进程是一个非常重要的概念，书中定义为“系统进行资源分配和调度的基本单位”,初步接触 Linux kernel 准备进程概念开始。

# 0x00 process descriptor

在 Linux 中表示 PCB（进程控制块）的结构体叫 task_struct. task_strcut 相关的信息放在 include/linux/sched.h 中,而单独看 task_struct 意义不是很大，很难把握到 Linux 的进程工作原理，所以才有了本文来梳理 Linux 进程管理的信息。

# 0x01 how to crate a process ?

可以通过 fork 系统调用创建一个进程

```cpp
#include <stdio.h>
#include <unistd.h>

int main(void)
{
    pid_t pid;
    pid = fork();
    if (pid == 0)  {
        printf("child ");
    } else {
        printf("parent ");
    }
    return 0;
}
```
Linux 下创建进程会完全复制它的父进程，所以 fork 调用成功返回两次，在父进程中范围子进程 pid，子进程中返回 0。

# 0x02 what happened in kernel ?

这里需要引入`系统调用`的概念，简而言之系统调用是用户通过 API 和系统沟通的方式。上述源代码会通过系统调用在 Linux 中创建进程。
观察系统调用有个好工具`strace`, `-f`是继续跟踪子进程。

```shell
# strace -f ./a.out
...
clone(strace: Process 2035 attached
child_stack=NULL, flags=CLONE_CHILD_CLEARTID|CLONE_CHILD_SETTID|SIGCHLD, child_tidptr=0x7fd18ba619d0) = 2035
[pid  2034] fstat(1,  <unfinished ...>
[pid  2035] fstat(1,  <unfinished ...>
[pid  2034] <... fstat resumed> {st_mode=S_IFCHR|0620, st_rdev=makedev(136, 5), ...}) = 0
[pid  2035] <... fstat resumed> {st_mode=S_IFCHR|0620, st_rdev=makedev(136, 5), ...}) = 0
[pid  2034] brk(NULL)                   = 0xd73000
[pid  2034] brk(0xd94000 <unfinished ...>
[pid  2035] brk(NULL <unfinished ...>
[pid  2034] <... brk resumed> )         = 0xd94000
[pid  2034] brk(NULL)                   = 0xd94000
[pid  2034] write(1, "parent ", 7 <unfinished ...>
[pid  2035] <... brk resumed> )         = 0xd73000
parent [pid  2034] <... write resumed> )       = 7
[pid  2034] exit_group(0)               = ?
[pid  2035] brk(0xd94000 <unfinished ...>
[pid  2034] +++ exited with 0 +++
<... brk resumed> )                     = 0xd94000
brk(NULL)                               = 0xd94000
write(1, "child ", 6child )                   = 6
exit_group(0)                           = ?
+++ exited with 0 +++
```

可以看到在 x86_64 下 fork 函数创建一个进程是通过系统调用 clone (在调用 clone 之前的东西可以在 glibc)来做的，通过一些看上起奇怪的 flags 的组合来达到创建一个进程的目的。系统调用层面之下就是 Linux kernel 了。

下面通过 kernel 4.12-rc2 源代码跟踪一下 clone 系统调用的过程（大体流程依然和 ^ulk 说的类似但是，细节有点不同，参考`1d4b4b2994b5fc208963c0b795291f8c1f18becf`），clone 在系统调用表中的 stub_clone 实现，stub_clone 由 sys_clone 定义，而 sys_clone 在 64 位下`# define __ARCH_WANT_SYS_CLONE`，后在 fork.c 里面进行条件编译：

```
#ifdef __ARCH_WANT_SYS_CLONE
#ifdef CONFIG_CLONE_BACKWARDS
SYSCALL_DEFINE5(clone, unsigned long, clone_flags, unsigned long, newsp,
                 int __user *, parent_tidptr,
                 unsigned long, tls,
                 int __user *, child_tidptr)
#elif defined(CONFIG_CLONE_BACKWARDS2)
SYSCALL_DEFINE5(clone, unsigned long, newsp, unsigned long, clone_flags,
                 int __user *, parent_tidptr,
                 int __user *, child_tidptr,
                 unsigned long, tls)
#elif defined(CONFIG_CLONE_BACKWARDS3)
SYSCALL_DEFINE6(clone, unsigned long, clone_flags, unsigned long, newsp,
                int, stack_size,
                int __user *, parent_tidptr,
                int __user *, child_tidptr,
                unsigned long, tls)
#else
SYSCALL_DEFINE5(clone, unsigned long, clone_flags, unsigned long, newsp,
                 int __user *, parent_tidptr,
                 int __user *, child_tidptr,
                 unsigned long, tls)
#endif
{
        return _do_fork(clone_flags, newsp, 0, parent_tidptr, child_tidptr, tls);
}
#endif
```

看到 sys_clone 实现是配置相关的，参数不同，最后调用 _do_fork (不同于之前调用 do_fork)进入下一个流程:

```c
/*
 *  Ok, this is the main fork-routine.
 *
 * It copies the process, and if successful kick-starts
 * it and waits for it to finish using the VM if required.
 */
long _do_fork(unsigned long clone_flags,
              unsigned long stack_start,
              unsigned long stack_size,
              int __user *parent_tidptr,
              int __user *child_tidptr,
              unsigned long tls)
{
        struct task_struct *p;
        int trace = 0;
        long nr;

        /*
         * Determine whether and which event to report to ptracer.  When
         * called from kernel_thread or CLONE_UNTRACED is explicitly
         * requested, no event is reported; otherwise, report if the event
         * for the type of forking is enabled.
         */
        if (!(clone_flags & CLONE_UNTRACED)) {
                if (clone_flags & CLONE_VFORK)
                        trace = PTRACE_EVENT_VFORK;
                else if ((clone_flags & CSIGNAL) != SIGCHLD)
                        trace = PTRACE_EVENT_CLONE;
                else
                        trace = PTRACE_EVENT_FORK;

                if (likely(!ptrace_event_enabled(current, trace)))
                        trace = 0;
        }

        p = copy_process(clone_flags, stack_start, stack_size,
                         child_tidptr, NULL, trace, tls, NUMA_NO_NODE);
        add_latent_entropy();
        /*
         * Do this prior waking up the new thread - the thread pointer
         * might get invalid after that point, if the thread exits quickly.
         */
        if (!IS_ERR(p)) {
                struct completion vfork;
                struct pid *pid;

                trace_sched_process_fork(current, p);

                pid = get_task_pid(p, PIDTYPE_PID);
                nr = pid_vnr(pid);

                if (clone_flags & CLONE_PARENT_SETTID)
                        put_user(nr, parent_tidptr);

                if (clone_flags & CLONE_VFORK) {
                        p->vfork_done = &vfork;
                        init_completion(&vfork);
                        get_task_struct(p);
                }

                wake_up_new_task(p);

                /* forking complete and child started to run, tell ptracer */
                if (unlikely(trace))
                        ptrace_event_pid(trace, pid);

                if (clone_flags & CLONE_VFORK) {
                        if (!wait_for_vfork_done(p, &vfork))
                                ptrace_event_pid(PTRACE_EVENT_VFORK_DONE, pid);
                }

                put_pid(pid);
        } else {
                nr = PTR_ERR(p);
        }
        return nr;
}
```

`_do_fork`函数不是很长，主要做了几件事情(因为没有 vfork 所以不关注它的处理路径)：

* copy_process 函数准备进进程的地址空间。
* 如果 p 有效，通过 get_task_pid 分配 pid，通过 wake_up_new_task 将新 p 加入调度器。


这里需要引入`systemtap`来观察 kernel，工作原理简而言之就是在通过调试信息在内核函数调用之前或之后插入一些预定义的代码。

```systemtap
probe kernel.function("_do_fork").return {
  printf("sys_clone hit\n");
  printf("do_frok return pid: %d\n", $return);
}
```

可以看_do_fork 代码看到返回值是新进程的 pid，我们可以在它的换回点验证一下和用户态对比。

systemtap 输出：

```
stap -v fork.stp
Pass 1: parsed user script and 468 library scripts using 245968virt/45604res/7552shr/38236data kb, in 100usr/10sys/108real ms.
Pass 2: analyzed script: 1 probe, 1 function, 0 embeds, 0 globals using 296808virt/97496res/8480shr/89076data kb, in 830usr/80sys/811real ms.
Pass 3: using cached /root/.systemtap/cache/e4/stap_e4791a38e6be5d0d214949ecb8993460_1754.c
Pass 4: using cached /root/.systemtap/cache/e4/stap_e4791a38e6be5d0d214949ecb8993460_1754.ko
Pass 5: starting run.
sys_clone hit
do_fork return pid: 3584
sys_clone hit
do_fork return pid: 3585
sys_clone hit
do_fork return pid: 3586
sys_clone hit
do_fork return pid: 3587
sys_clone hit
do_fork return pid: 3588
sys_clone hit
do_fork return pid: 3589
sys_clone hit
do_fork return pid: 3590
sys_clone hit
do_fork return pid: 3591
sys_clone hit
do_fork return pid: 3592
^CPass 5: run completed in 0usr/90sys/21392real ms.
```

strace 输出：

```
strace ./a.out
execve("./a.out", ["./a.out"], 0x7ffe513d4180 /* 32 vars */) = 0
brk(NULL)                               = 0x9fa000
mmap(NULL, 8192, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0) = 0x7f7c33df3000
access("/etc/ld.so.preload", R_OK)      = -1 ENOENT (No such file or directory)
open("/etc/ld.so.cache", O_RDONLY|O_CLOEXEC) = 3
fstat(3, {st_mode=S_IFREG|0644, st_size=67254, ...}) = 0
mmap(NULL, 67254, PROT_READ, MAP_PRIVATE, 3, 0) = 0x7f7c33de2000
close(3)                                = 0
open("/lib64/libc.so.6", O_RDONLY|O_CLOEXEC) = 3
read(3, "\177ELF\2\1\1\3\0\0\0\0\0\0\0\0\3\0>\0\1\0\0\0 \6\2\0\0\0\0\0"..., 832) = 832
fstat(3, {st_mode=S_IFREG|0755, st_size=2163016, ...}) = 0
mmap(NULL, 4000032, PROT_READ|PROT_EXEC, MAP_PRIVATE|MAP_DENYWRITE, 3, 0) = 0x7f7c337fe000
mprotect(0x7f7c339c5000, 2097152, PROT_NONE) = 0
mmap(0x7f7c33bc5000, 24576, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_FIXED|MAP_DENYWRITE, 3, 0x1c7000) = 0x7f7c33bc5000
mmap(0x7f7c33bcb000, 14624, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_FIXED|MAP_ANONYMOUS, -1, 0) = 0x7f7c33bcb000
close(3)                                = 0
mmap(NULL, 12288, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0) = 0x7f7c33ddf000
arch_prctl(ARCH_SET_FS, 0x7f7c33ddf700) = 0
mprotect(0x7f7c33bc5000, 16384, PROT_READ) = 0
mprotect(0x600000, 4096, PROT_READ)     = 0
mprotect(0x7f7c33df5000, 4096, PROT_READ) = 0
munmap(0x7f7c33de2000, 67254)           = 0
clone(child_stack=NULL, flags=CLONE_CHILD_CLEARTID|CLONE_CHILD_SETTID|SIGCHLD, child_tidptr=0x7f7c33ddf9d0) = 3587
child fstat(1, {st_mode=S_IFCHR|0620, st_rdev=makedev(136, 2), ...}) = 0
--- SIGCHLD {si_signo=SIGCHLD, si_code=CLD_EXITED, si_pid=3587, si_uid=0, si_status=0, si_utime=0, si_stime=0} ---
brk(NULL)                               = 0x9fa000
brk(0xa1b000)                           = 0xa1b000
brk(NULL)                               = 0xa1b000
write(1, "parent ", 7parent )                  = 7
exit_group(0)                           = ?
+++ exited with 0 +++
```

可以看到`clone`系统调用的返回值和`_do_fork`返回值一致，只是中间多生成了其他进程。

[^ulk]: <<UnderStanding The Linux Kernel 3rd Edition>>
