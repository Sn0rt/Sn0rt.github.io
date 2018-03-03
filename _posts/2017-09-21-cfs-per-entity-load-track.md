---
author: sn0rt
comments: true
date: 2017-09-21
layout: post
tag: linux
title: cfs per entity load track
---

# 0x00 what and why

之前公司遇到了一个系统 load avg 异常，一路追杀的过程中学习了 CFS 并发现了 cfs per entity load track 特性，凑巧的是 lwn [^lwn]的文章被阿里内核日报围绕着原来系统有什么问题，如何解决的，达到了什么成果的方法阐述了一遍:

>  文章首先回顾了一下任务调度器和为什么有了 CPU 利用率还需要衡量“load”。后面的内容更有意思一些：Paul Turner 的 per-entity load tracking 已经合并到 3.8 内核里。
>
>  之前的 CFS 以每个 CPU 上的运行队列(per cpu runqueue)为单位计算 load，但使用了 group scheduler 之后，每个 cgroup 都有一个自己的 per CPU 运行队列，而如果内核需要了解每个 cgroup 对系统整体 load 的贡献情况，原来的方案就不能满足需要了，而且基于 per CPU runqueue 的方法也有结果波动过大的缺点。
>
>  per-entity load 的方法则是把 cgroup 内的所有任务都串接到一个队列上。计算 load 时，时间以一个毫秒（准确地说是 1024µs）为单位向前滚动。一个 entity 在周期 $$p_{i}$$ 对系统 load 的贡献就是该周期内可运行部分时间（任务正在运行，或者处于就绪状态）。周期越旧，对当前 load 影响越小，具体地，令 Li 为周期$$p_{i}$$对当前负载的贡献，则当前 load 为：
>
>$$L = L0 + L1*y + L2*y^2 + L3*y^3$$
>
>  这个公式的优点是计算当前 load 不需要保存完整的历史数据，只需要累加就行了。其中，y 是小于 1 的衰减因子。目前取值为使 y32=0.5 的值（当然计算进程是以定点方式进行的），即 32ms 之前的 load 对当前 load 有 50%的贡献。3.8 内核里，会对阻塞掉的任务，也使用相同的计算方法，然后将"阻塞 load"与以上"CPU load"相加得到完整的 per-entity load。当然如果一个阻塞任务之后进入就绪状态，就会算入上面的 CPU load 公式里。此外，load 计算还跳过了在 CPU bandwidth controller 控制下的 throttled processes。对这些 per-entity load 求和就可以得到整个系统的 load 了。

这里补充一下特性的实现细节(v4.14-rc2)：

# 0x01 cfs overview

总所周知 Linux 的设计是非常优秀，非常核心的调度子系统也在代码层面做了模块化封装，简要关注一下 cfs 调度类的实现(其它调度类也是要实现结构体中的大多数方法的)。

```c
/*
 * All the scheduling class methods:
 */
const struct sched_class fair_sched_class = {
	.next			= &idle_sched_class,
	.enqueue_task		= enqueue_task_fair, // here
    ...
#endif
};
```

 上面代码摘录自 cfs 调度类，关注入队操作 enqueue_task_fair 流程中 load 的计算细节，不关注 dequeu_task_fair 的是因为它们非常类似。

```c
/*
 * The enqueue_task method is called before nr_running is
 * increased. Here we update the fair scheduling stats and
 * then put the task into the rbtree:
 */
static void
enqueue_task_fair(struct rq *rq, struct task_struct *p, int flags)
{
        struct cfs_rq *cfs_rq;
        struct sched_entity *se = &p->se;

        /*
         * If in_iowait is set, the code below may not trigger any cpufreq
         * utilization updates, so do it here explicitly with the IOWAIT flag
         * passed.
         */
        if (p->in_iowait)
                cpufreq_update_util(rq, SCHED_CPUFREQ_IOWAIT);
        ...

        for_each_sched_entity(se) {
                cfs_rq = cfs_rq_of(se);
                cfs_rq->h_nr_running++;

                if (cfs_rq_throttled(cfs_rq))
                        break;

                update_load_avg(se, UPDATE_TG); // here
...
```

以上是入队操作的实现的部分，cfs 是的操作的时间复杂度是利用 rbtree 的数据结构的优势，cfs 以 vruntime 为 value 组织 rbtree，每次选择调度实体(se)从最左取，更多细节参考[^LKDe3]。

```c
/* Update task and its cfs_rq load average */
static inline void update_load_avg(struct sched_entity *se, int flags)
{
        struct cfs_rq *cfs_rq = cfs_rq_of(se);
        u64 now = cfs_rq_clock_task(cfs_rq);
        struct rq *rq = rq_of(cfs_rq);
        int cpu = cpu_of(rq);
        int decayed;

        /*
         * Track task load average for carrying it to new CPU after migrated, and
         * track group sched_entity load average for task_h_load calc in migration
         */
        if (se->avg.last_update_time && !(flags & SKIP_AGE_LOAD))
                __update_load_avg_se(now, cpu, cfs_rq, se); // here
...
}
```
上述函数准备一些参数来计算 se 的 load 值，实现还是非常好理解的。

```c
static int
__update_load_avg_se(u64 now, int cpu, struct cfs_rq *cfs_rq, struct sched_entity *se)
{
        return ___update_load_avg(now, cpu, &se->avg,
                                  se->on_rq * scale_load_down(se->load.weight),
                                  cfs_rq->curr == se, NULL);
}
```

一个 wrapper, 传入第三个参数 se->avg 是如下见的不多的结构体：

```c
struct sched_avg {
        u64                             last_update_time;  // Last load update time
        u64                             load_sum; 
        u32                             util_sum;
        u32                             period_contrib; // 
        unsigned long                   load_avg; // runnable% * scale_load_down(load) * freq%
        unsigned long                   util_avg; // running% * SCHED_CAPACITY_SCALE * freq% * capacity%
};
```

下面有如何初始化一个 se->avg 的函数对上面结构体解释非常到位。

```c
/* Give new sched_entity start runnable values to heavy its load in infant time */
void init_entity_runnable_average(struct sched_entity *se)
{
        struct sched_avg *sa = &se->avg;

        sa->last_update_time = 0;
        /*
         * sched_avg's period_contrib should be strictly less then 1024, so
         * we give it 1023 to make sure it is almost a period (1024us), and
         * will definitely be update (after enqueue).
         */
        sa->period_contrib = 1023;
        /*
         * Tasks are intialized with full load to be seen as heavy tasks until
         * they get a chance to stabilize to their real load level.
         * Group entities are intialized with zero load to reflect the fact that
         * nothing has been attached to the task group yet.
         */
        if (entity_is_task(se))
                sa->load_avg = scale_load_down(se->load.weight);
        sa->load_sum = sa->load_avg * LOAD_AVG_MAX;
        /*
         * At this point, util_avg won't be used in select_task_rq_fair anyway
         */
        sa->util_avg = 0;
        sa->util_sum = 0;
        /* when this task enqueue'ed, it will contribute to its cfs_rq's load_avg */
}
```

# 0x02 core path: ___update_load_avg

这是 per entity load track 重要的入口函数，在 4.12 之前实现与之前不一样，优化方法是在 patch[^Optimize]中引入的，但是思路一致。开发者用几何级数来表示历史上 se 贡献的 runnable average，这样做首先需要把 runable 的全部时间切分成近似 1024 us (约 1ms) 的时间片，并标记时间片为 N-ms 之前为 $$p_N$$, 比如 $$p_0$$ 就表示当前的时间片，示意图如下：

> |<- 1024us ->|<- 1024us ->|<- 1024us ->|
> |    p0      |      p1    |       p2   |
> |  (now)     | (~1ms ago) |  (~2ms ago)|

 
 让 $$u_i$$ 表示 $$p_i$$ 中调度实体可以运行的的一部分。
 
 然后我们指定$$u_i$$为系数，则产生如下计算之前负载的等式：
   
  $$u_0 + u_1*y + u_2*y^2 + u_3*y^3 + ...$$
 
 基于合理的调度周期选择 y，修正公式如下：
 
   $$y^{32} = 0.5$$
 
 这意味大约 32ms $$u_{32}$$ 之前的负载贡献经过加权后计算大约是当前一毫秒 $$u_0$$ 的一半。
 
 如果发生了时间片的 rolls over 现象，会产生了新$${u_0}'$$,这时用新的$${u_0}'$$加上 y 乘以之前的和就可以解决这个问题。
 
 $$
 \begin{align*}
 load_avg &= {u_0}' + y*(u_0 + u_1*y + u_2*y^2 + ... ) \\
 &= u_0 + u_1*y + u_2*y^2 + ... [re-labeling u_i -> u_{i+1}]
 \end{align*}
 $$
 
 而 __update_load_avg 函数本身除了做了一些异常检查，最最核心的部分就是调用 accumulate_sum 计算 load，然后更新 sched_avg。
 
 ```c
static __always_inline int
___update_load_avg(u64 now, int cpu, struct sched_avg *sa,
                  unsigned long weight, int running, struct cfs_rq *cfs_rq)
{
        u64 delta;

        delta = now - sa->last_update_time; // 计算新采样周期的值
        /*
         * This should only happen when time goes backwards, which it
         * unfortunately does during sched clock init when we swap over to TSC.
         */
        if ((s64)delta < 0) {
                sa->last_update_time = now;
                return 0;
        }

        /*
         * Use 1024ns as the unit of measurement since it's a reasonable
         * approximation of 1us and fast to compute.
         */
        delta >>= 10; // 把周期值由 ns 转化为 us
        if (!delta)
                return 0;

        sa->last_update_time += delta << 10; // 上一步的逆操作并更新 sa->last_update_time

        /*
         * running is a subset of runnable (weight) so running can't be set if
         * runnable is clear. But there are some corner cases where the current
         * se has been already dequeued but cfs_rq->curr still points to it.
         * This means that weight will be 0 but not running for a sched_entity
         * but also for a cfs_rq if the latter becomes idle. As an example,
         * this happens during idle_balance() which calls
         * update_blocked_averages()
         */
        if (!weight)
                running = 0;

        /*
         * Now we know we crossed measurement unit boundaries. The *_avg
         * accrues by two steps:
         *
         * Step 1: accumulate *_sum since last_update_time. If we haven't
         * crossed period boundaries, finish.
         */
        if (!accumulate_sum(delta, cpu, sa, weight, running, cfs_rq)) // look here !!! 计算累计出来的 load
                return 0;                
        /*
         * Step 2: update *_avg.
         */
        sa->load_avg = div_u64(sa->load_sum, LOAD_AVG_MAX - 1024 + sa->period_contrib);
        if (cfs_rq) {
                cfs_rq->runnable_load_avg =
                        div_u64(cfs_rq->runnable_load_sum, LOAD_AVG_MAX - 1024 + sa->period_contrib);
        }
        sa->util_avg = sa->util_sum / (LOAD_AVG_MAX - 1024 + sa->period_contrib);

        return 1;
}
```

下面这个函数 accumulate_sum  非常核心，它通过累加三个部分的总和来计算 se 的负载影响；d1 是离当前时间最远（不完整的）period 的剩余部分，d2 是完整 period 的而 d3 是（不完整的）当前 period 的剩余部分。d1，d2，d3 的示意图如下：

```
            d1          d2           d3
            ^           ^            ^
            |           |            |
          |<->|<----------------->|<--->|
  ... |---x---|------| ... |------|-----x (now)
```

计算公式如下：

$$
\begin{align*}
{u}' &= (u + d1) y^{p} + 1024 \sum_{n=1}^{p-1}y^{n} + d3\times y^0 \\
& = u\times y^{p} + d1\times y^{p} + 1024 \sum_{n=1}^{p-1} y^{n} + d3\times y^{0}
\end{align*}
$$

拆分上述公式为$$u\times y^{p}$$ 为 step 1， $$d1\times y^{p} + 1024 \sum_{n=1}^{p-1} y^{n} + d3\times y^{0}$$为 step 2 如下：
 
```c
static __always_inline u32
accumulate_sum(u64 delta, int cpu, struct sched_avg *sa,
               unsigned long weight, int running, struct cfs_rq *cfs_rq)
{
        unsigned long scale_freq, scale_cpu;
        u32 contrib = (u32)delta; /* p == 0 -> delta < 1024 */
        u64 periods;

        scale_freq = arch_scale_freq_capacity(NULL, cpu);
        scale_cpu = arch_scale_cpu_capacity(NULL, cpu);
        
        // 参考前面的 sched_avg 的第一次介绍，上述两个是计算需要的参数。

        delta += sa->period_contrib;
        periods = delta / 1024; /* A period is 1024us (~1ms), 这边求出的就是上述图的 d2 的大小 */

        /*
         * Step 1: decay old *_sum if we crossed period boundaries.
         */
        if (periods) {
                sa->load_sum = decay_load(sa->load_sum, periods); // 衰减 se->sa->load_sum， 现在要根据指数衰减老的值。
                if (cfs_rq) {
                        cfs_rq->runnable_load_sum =
                                decay_load(cfs_rq->runnable_load_sum, periods); // 如果 se 在 cfs_rq 上，衰减 cfs_rq 的 load。
                }
                sa->util_sum = decay_load((u64)(sa->util_sum), periods); // 衰减 se->sa->util_sum

                /*
                 * Step 2
                 * commit: 05296e7535d67ba4926b543a09cf5d430a815cb6 
                 */
                delta %= 1024; // delta 表示 d3 的时间长度。
                contrib = __accumulate_pelt_segments(periods,
                                1024 - sa->period_contrib, delta); // 这个函数是核心计算方法，参数：d2，d1，d3
        }
        sa->period_contrib = delta;
        
        contrib = cap_scale(contrib, scale_freq); // #define cap_scale(v, s) ((v)*(s) >> SCHED_CAPACITY_SHIFT)
        if (weight) {
                sa->load_sum += weight * contrib;
                if (cfs_rq) // se 在 cfs_rq 上也要更新 rq->runnable_load_sum
                        cfs_rq->runnable_load_sum += weight * contrib;
        }
        if (running)
                sa->util_sum += contrib * scale_cpu;

        return periods;
}
```

下面几个函数是计算细节 $$c1 = d1 \times y^{p}$$, $$c2 = 1024 (\sum_{n=0}^{inf} y^{n} - \sum_{n-p}^{inf} y^{n} - y^{0})$$, $$c3 = d3$$：

```c
static u32 __accumulate_pelt_segments(u64 periods, u32 d1, u32 d3)
{
        u32 c1, c2, c3 = d3; /* y^0 == 1 */
        c1 = decay_load((u64)d1, periods);
        c2 = LOAD_AVG_MAX - decay_load(LOAD_AVG_MAX, periods) - 1024;
        return c1 + c2 + c3;
}
```

```c
/*
 * Approximate:
 *   val * y^n,    where y^32 ~= 0.5 (~1 scheduling period)
 */
static u64 decay_load(u64 val, u64 n)
{
        unsigned int local_n;

        if (unlikely(n > LOAD_AVG_PERIOD * 63))
                return 0;

        /* after bounds checking we can collapse to 32-bit */
        local_n = n;

        /*
         * As y^PERIOD = 1/2, we can combine
         *    y^n = 1/2^(n/PERIOD) * y^(n%PERIOD)
         * With a look-up table which covers y^n (n<PERIOD)
         *
         * To achieve constant time decay_load.
         */
        if (unlikely(local_n >= LOAD_AVG_PERIOD)) {
                val >>= local_n / LOAD_AVG_PERIOD;
                local_n %= LOAD_AVG_PERIOD;
        }

        val = mul_u64_u32_shr(val, runnable_avg_yN_inv[local_n], 32);
        return val;
}
```

使用常量 runnable_avg_yN_inv 数组使得计算 load 衰减加速，数组生成代码位于 Documentation/scheduler/sched-pelt.c，计算公式如下

$$runnable\_avg\_yN\_inv[k] = y^{k}\times 2^{32}, 1\leq k \leq 32$$

```c
/* Generated by Documentation/scheduler/sched-pelt; do not modify. */

static const u32 runnable_avg_yN_inv[] = {
	0xffffffff, 0xfa83b2da, 0xf5257d14, 0xefe4b99a, 0xeac0c6e6, 0xe5b906e6,
	0xe0ccdeeb, 0xdbfbb796, 0xd744fcc9, 0xd2a81d91, 0xce248c14, 0xc9b9bd85,
	0xc5672a10, 0xc12c4cc9, 0xbd08a39e, 0xb8fbaf46, 0xb504f333, 0xb123f581,
	0xad583ee9, 0xa9a15ab4, 0xa5fed6a9, 0xa2704302, 0x9ef5325f, 0x9b8d39b9,
	0x9837f050, 0x94f4efa8, 0x91c3d373, 0x8ea4398a, 0x8b95c1e3, 0x88980e80,
	0x85aac367, 0x82cd8698,
};
```

[^lwn]: [Per-entity load tracking](https://lwn.net/Articles/531853/)
[^LKDe3]: [Linux Kernel Development](https://book.douban.com/subject/3291901/)
[^Optimize]: [sched/fair: Optimize __update_sched_avg()](https://patchwork.kernel.org/patch/9655969/)
