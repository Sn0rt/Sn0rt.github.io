---
author: sn0rt
comments: true
date: 2016-07-29
layout: post
title: cgroups II - cgroup implementation overview
tag: linux
---

# 0x00 cgroups implementation

因为`cgroups`其他子系统的应用远比`net_cls`要简单的多, 所以后面不是介绍其他子系统使用, 而是分析一下`cgroups`的实现 (base kernel 3.10).
在正式切入实现之前回顾一下,`cgroups`子系统的介绍 [^lwn].

>
* blkio — 这个子系统为块设备设定输入 / 输出限制，比如物理设备（磁盘，固态硬盘，USB 等等）。
* cpu — 这个子系统使用调度程序提供对 CPU 的 cgroup 任务访问。
* cpuacct — 这个子系统自动生成 cgroup 中任务所使用的 CPU 报告。
* cpuset — 这个子系统为 cgroup 中的任务分配独立 CPU（在多核系统）和内存节点。
* devices — 这个子系统可允许或者拒绝 cgroup 中的任务访问设备。
* freezer — 这个子系统挂起或者恢复 cgroup 中的任务。
* memory — 这个子系统设定 cgroup 中任务使用的内存限制，并自动生成内存资源使用报告。
...

省略掉一部分不是特别关注的子系统 (因为相对应用场景小, 背景知识多!).
这个 post 行文逻辑参考了 [^wangjiefeng], 各个子系统的实现位置可以参考 [^netlec].

## 0x10 init cgroups

`cgroup`是一个树状结构分布, 系统在启动时候会创建一个`cgroup`系统, 在`start_kernel`调用`cgroup_init()`, 这个函数实现在`kernel/cgroup.c`中.

```c
int __init cgroup_init(void)
{
    ...
    bdi_init(&cgroup_backing_dev_info);
    ...
	for (i = 0; i < CGROUP_SUBSYS_COUNT; i++) {
        ...
			cgroup_init_subsys(ss);
		...
			cgroup_init_idr(ss, init_css_set.subsys[ss->subsys_id]);
	}

	key = css_set_hash(init_css_set.subsys);
	hash_add(css_set_table, &init_css_set.hlist, key);

	kobject_create_and_add("cgroup", fs_kobj);
        register_filesystem(&cgroup_fs_type);
	proc_create("cgroups", 0, NULL, &proc_cgroupstats_operations);
    ...
}
```
`bdi_init`参数是 kernel 用来控制回写的结构体`backing_dev_info`, 其中有控制有控制 I/O 带宽和被谁使用等重要参数.
其主要工作是在利用`for (i < CGROUP_SUBSYS_COUNT)`后面语句块为了每一个子系统调用`cgroup_init_subsys()`来初始化子系统, 调用`cgroup_init_idr()`[^idr] 来创建`Integer ID Management`, 后利用`css_set_hash`与`hash_add`创建一个 hash 表, 以此提高系统对一个已经存在的`css_set`的查找时性能, 又利用`kobject_create_and_add("cgroup", fs_kobj)`创建一个`kobject`对象, 利用`register_filesystem(&cgroup_fs_type)`注册了`cgroup`文件系统, 用`proc_create("cgroups", 0, NULL, &proc_cgroupstats_operations)`在`proc`下创建了`cgroup`开关 [^source].


## 0x20 mainly data structures

因为每一个`hierarchy`中都有一个`task`文件, 里面放置着 PID, 可以猜测进程是`cgroup`中重要的纽带, 所以从`task_struct`结构来切入`cgroup`有关的主要代码.

```c
#ifdef CONFIG_CGROUPS
/* Control Group info protected by css_set_lock */
    struct css_set __rcu *cgroups;
/* cg_list protected by css_set_lock and tsk->alloc_lock */
    struct list_head cg_list;
#endif
```
可以看见`cgroups`是个`css_set`(cgroups subsystem status) 指针, 而`css_set`存储了与进程相关的`cgroups`信息,`cg_list`是一个链表头指针, 包含所有链接到同一个`css_set`的 task.

`css_set`的结构如下:

```c
struct css_set {

	/* 当前 css_set 引用计数器, 因为 css_set 可以多个进程共用, 只要这些进程的 cgroups 信息相同. */
	atomic_t refcount;

	/* hlist 是 hash 表中的节点, 用于把所有 css_set 组织成一个 hash 表, 方便内核快速查找特定的 css_set. */
	struct hlist_node hlist;

	/* task 指向所有连接到此 css_set 的进程组成的链表. */
	struct list_head tasks;

	/* cg_links 变量自当前的 css_set 指向 cg_group_link 组成的链表. */
	struct list_head cg_links;

	/* 子系统的状态集合, 它由 init_css_set 的在系统启动和子系统模块载入和卸载时创建, 且之后不能改变. */
	struct cgroup_subsys_state *subsys[CGROUP_SUBSYS_COUNT];

	/* 利用 rcu 保证删除一致性 */
	struct rcu_head rcu_head;
};
```
`css_set->subsys`是`cgroup_subsys_state`指针数组, 它记录进程与特定子系统相关的信息, 通过这个指针数组, 进程可以获得相应的 cgroup 的控制信息.

`cgroup_subsys_state`结构如下:

```c
/* 由系统维护的每进程 / 每 cgroup 的状态 */
struct cgroup_subsys_state {
	/*
	 * The cgroup that this subsystem is attached to. Useful
	 * for subsystems that want to know about the cgroup
	 * hierarchy structure
	 */
	struct cgroup *cgroup;

	/*
	 * State maintained by the cgroup system to allow subsystems
	 * to be "busy". Should be accessed via css_get(),
	 * css_tryget() and css_put().
	 */
	atomic_t refcnt;

	unsigned long flags;
	/* ID for this css, if possible */
	struct css_id __rcu *id;

	/* Used to put @cgroup->dentry on the last css_put() */
	struct work_struct dput_work;
}
```
`cgroup_subsys_state`里面最重要的就是`*cgroup`字段,cgroup 指针指向一个 cgroup 结构, 也就是进程所属的 cgroup. 进程收到特定子系统的控制就是加入特定的 cgroup 实现的.
因为 cgroup 在特定 hierarchy 上面, 而子系统有事附加到层级上的, 这样结构就完整了梳理出来了`task_struct->css_set->cgroup_state->cgroup`.
虽然注释写的是"由系统维护的每进程 / 每 cgroup 的状态", 但是在结构体里面并没有看见控制信息, 知识定义了各个子系统都需要的共同信息, 比如该 cgroup_subsys_state 从属的 cgroup. 其实各子系统在根据各自的实际需求实现自己的控制信息, 最后在各自的结构体中将`cgroup_subsys_state`包含进去. 这样 kernel 就可以用宏通过`cgroup_subsys_state`来获取相应的信息.[^wangjiefeng]

`cgroup_subsys_state->cgroup`结构如下:

```c
struct cgroup {
	unsigned long flags;		/* "unsigned long" so bitops work */

	/*
	 * count users of this cgroup. >0 means busy, but doesn't
	 * necessarily indicate the number of tasks in the cgroup
	 */
	atomic_t count;

	int id;				/* ida 分配的层级内的 ID 号 */

	/* sibling, children, parent 利用兄弟孩子表示法将层级的 cgroup 构成一颗树.
	 * We link our 'sibling' struct into our parent's 'children'.
	 * Our children link their 'sibling' into our 'children'.
	 */
     
	struct list_head sibling;	/* my parent's children */
	struct list_head children;	/* my children */
	struct list_head files;		/* my files */

	struct cgroup *parent;		/* my parent */
	struct dentry *dentry;		/* cgroup 的 fs entry */

	/*
	 * This is a copy of dentry->d_name, and it's needed because
	 * we can't use dentry->d_name in cgroup_path().
	 *
	 * You must acquire rcu_read_lock() to access cgrp->name, and
	 * the only place that can change it is rename(), which is
	 * protected by parent dir's i_mutex.
	 *
	 * Normally you should use cgroup_name() wrapper rather than
	 * access it directly.
	 */
	struct cgroup_name __rcu *name;

	/* subsys 中指针指向每一个已注册子系统的指针,root 指向所在层级的 cgroup 的 cgroup_root 结构体 */
	struct cgroup_subsys_state *subsys[CGROUP_SUBSYS_COUNT];

	struct cgroupfs_root *root;

	/*
	 * List of cg_cgroup_links pointing at css_sets with
	 * tasks in this cgroup. Protected by css_set_lock
	 */
	struct list_head css_sets;

	struct list_head allcg_node;	/* cgroupfs_root->allcg_list */
	struct list_head cft_q_node;	/* used during cftype add/rm */

	/*
	 * Linked list running through all cgroups that can
	 * potentially be reaped by the release agent. Protected by
	 * release_list_lock
	 */
	struct list_head release_list;

	/*
	 * list of pidlists, up to two for each namespace (one for procs, one
	 * for tasks); created on demand.
	 */
	struct list_head pidlists;
	struct mutex pidlist_mutex;

	/* For RCU-protected deletion */
	struct rcu_head rcu_head;
	struct work_struct free_work;

	/* 用户态期望收到的事件列表 */
	struct list_head event_list;
	spinlock_t event_list_lock;

	/* 目录的 xattrs */
	struct simple_xattrs xattrs;
}
```
`cgroup->css_sets`是一个头指针, 指向由`cg_cgroup_link`(包含 cgroup 于 task 之间多对多关系的信息) 形成的链表. 由此每一个`cg_cgroup_link`都包含一个指向`css_set *cg`指向每一个`task`的`css_set`.`css_set`结构中则包含`tasks`头指针. 指向所有链接此`css_set`的 task 进程构成的链表.

`cgroup->root`是指向`cgroupfs_root`的指针, 这就是 cgroup 所在层级对应的结构体.

`cgroupfs_root`结构如下:

```c
struct cgroupfs_root {
	struct super_block *sb;

	/* bitmask 记录将要附加到层级的子系统
	 */
	unsigned long subsys_mask;

	/* 当前层级的 id 号 (唯一) */
	int hierarchy_id;

	/* 当前已经附加到层级的子系统掩码 */
	unsigned long actual_subsys_mask;

	/* A list running through the attached subsystems */
	struct list_head subsys_list;

	/* 指向当前层级的根 cgroup, 也就是创建层级自动创建的 cgroup */
	struct cgroup top_cgroup;

	/* 追踪当前层级对应的 cgroup 数量 */
	int number_of_cgroups;

	/* A list running through the active hierarchies */
	struct list_head root_list;

	/* All cgroups on this root, cgroup_mutex protected */
	struct list_head allcg_list;

	/* 层级详细的 flags */
	unsigned long flags;

	/* IDs for cgroups in this hierarchy */
	struct ida cgroup_ida;

	/* The path to use for release notifications. */
	char release_agent_path[PATH_MAX];

	/* 层级的名字 (也许是空的) */
	char name[MAX_CGROUP_ROOT_NAMELEN];
};
```
`cgroupfs_root->sb`是指向该层级关联的文件系统的超级块.
之所以`cgroup`与`css_set`之间多了一个`cgroup_state`结构体, 是因为`cgroup`于`css_set`是一个多对多的关系需要一个中间结构将他们联系起来,

## 0x02 cgroup filesystem

cgroups 是用户态接口是用文件系统实现的, 在 linux 上实现文件系统必然要知道一些`VFS`相关的知识.

* 超级块对象 (superblock object): 存放已安装文件系统相关信息.
* 索引节点对象 (inode object): 存放关于文件的一般信息.
* 文件对象 (file object): 存放打开文件与进程直接的信息.
* 目录项对象 (dentry object): 存放目录项与对应文件进行链接的有关信息.

cgroup 文件系统的定义:

```c
static struct file_system_type cgroup_fs_type = {
	.name = "cgroup",
	.mount = cgroup_mount, // mount
	.kill_sb = cgroup_kill_sb, // umount
};
```

超级块定义:

```c
static const struct super_operations cgroup_ops = {
	.statfs = simple_statfs,
	.drop_inode = generic_delete_inode,
	.show_options = cgroup_show_options,
	.remount_fs = cgroup_remount,
};
```

文件操作定义:

```c
static const struct file_operations cgroup_file_operations = {
	.read = cgroup_file_read,
	.write = cgroup_file_write,
	.llseek = generic_file_llseek,
	.open = cgroup_file_open,
	.release = cgroup_file_release,
};
```

索引块定义:

```c
static const struct inode_operations cgroup_dir_inode_operations = {
	.lookup = cgroup_lookup,
	.mkdir = cgroup_mkdir,
	.rmdir = cgroup_rmdir,
	.rename = cgroup_rename,
	.setxattr = cgroup_setxattr,
	.getxattr = cgroup_getxattr,
	.listxattr = cgroup_listxattr,
	.removexattr = cgroup_removexattr,
};
```

# 0x10 subsystems

子系统对应的实现在`cgroup_subsys`结构体中, 其实现:

```c
struct cgroup_subsys {
	struct cgroup_subsys_state *(*css_alloc)(struct cgroup *cgrp);
	int (*css_online)(struct cgroup *cgrp);
	void (*css_offline)(struct cgroup *cgrp);
	void (*css_free)(struct cgroup *cgrp);

	int (*can_attach)(struct cgroup *cgrp, struct cgroup_taskset *tset);
	void (*cancel_attach)(struct cgroup *cgrp, struct cgroup_taskset *tset);
	void (*attach)(struct cgroup *cgrp, struct cgroup_taskset *tset);
	void (*fork)(struct task_struct *task);
	void (*exit)(struct cgroup *cgrp, struct cgroup *old_cgrp, struct task_struct *task);
	void (*bind)(struct cgroup *root);

	int subsys_id;
	int disabled;
	int early_init;
	/* ... */
	bool use_id;

	/* ... */
	bool broken_hierarchy;
	bool warned_broken_hierarchy;

#define MAX_CGROUP_TYPE_NAMELEN 32
	const char *name;

	/* Link to parent, and list entry in parent's children. Protected by cgroup_lock() */
	struct cgroupfs_root *root;
	struct list_head sibling;
    
	/* used when use_id == true */
	struct idr idr;
	spinlock_t id_lock;

	/* list of cftype_sets */
	struct list_head cftsets;

	/* base cftypes, automatically [de]registered with subsys itself */
	struct cftype *base_cftypes;
	struct cftype_set base_cftset;

	/* should be defined only by modular subsystems */
	struct module *module;
};
```
结构体是各子系统的抽象, 其中包含各子系统操作的交集.
在实践具体子系统时候填充抽象中定义且需要的部分 (面向对象的 C 在 kernel 中大量使用).

## 0x14 blkio subsystem
blkio subsystem 是基于`CFQ`实现的.

```c
struct cgroup_subsyssu blkio_subsys = {
	.name = "blkio",
	.css_alloc = blkcg_css_alloc,
	.css_offline = blkcg_css_offline,
	.css_free = blkcg_css_free,
	.can_attach = blkcg_can_attach,
	.subsys_id = blkio_subsys_id,
	.base_cftypes = blkcg_files,
	.module = THIS_MODULE,
};
```

## 0x11 cpu subsystem

当运行 SCHED_NORMAL，SCHED_BATCH cpu subsystem 是基于`CFS`实现的，然后 dl_sched_class 调度类也是实现 fair_group_scheduling 但是两者之间差别目前还没有深究。

```c
struct cgroup_subsys cpu_cgroup_subsys = {
	.name		= "cpu",
	.css_alloc	= cpu_cgroup_css_alloc,
	.css_free	= cpu_cgroup_css_free,
	.css_online	= cpu_cgroup_css_online,
	.css_offline	= cpu_cgroup_css_offline,
	.can_attach	= cpu_cgroup_can_attach,
	.attach		= cpu_cgroup_attach,
	.exit		= cpu_cgroup_exit,
	.subsys_id	= cpu_cgroup_subsys_id,
	.base_cftypes	= cpu_files,
	.early_init	= 1,
};
```


## 0x12 cpuset subsystem

```c
struct cgroup_subsys cpuset_subsys = {
	.name = "cpuset",
	.css_alloc = cpuset_css_alloc,
	.css_online = cpuset_css_online,
	.css_offline = cpuset_css_offline,
	.css_free = cpuset_css_free,
	.can_attach = cpuset_can_attach,
	.cancel_attach = cpuset_cancel_attach,
	.attach = cpuset_attach,
	.subsys_id = cpuset_subsys_id,
	.base_cftypes = files,
	.early_init = 1,
}
```

## 0x13 memory subsystem

```c
struct cgroup_subsys mem_cgroup_subsys = {
	.name = "memory",
	.subsys_id = mem_cgroup_subsys_id,
	.css_alloc = mem_cgroup_css_alloc,
	.css_online = mem_cgroup_css_online,
	.css_offline = mem_cgroup_css_offline,
	.css_free = mem_cgroup_css_free,
	.can_attach = mem_cgroup_can_attach,
	.cancel_attach = mem_cgroup_cancel_attach,
	.attach = mem_cgroup_move_task,
	.bind = mem_cgroup_bind,
	.base_cftypes = mem_cgroup_files,
	.early_init = 0,
	.use_id = 1,
};
```

## 0x15 freezer subsystem

```c
struct cgroup_subsys freezer_subsys = {
	.name		= "freezer",
	.css_alloc	= freezer_css_alloc,
	.css_online	= freezer_css_online,
	.css_offline	= freezer_css_offline,
	.css_free	= freezer_css_free,
	.subsys_id	= freezer_subsys_id,
	.attach		= freezer_attach,
	.fork		= freezer_fork,
	.base_cftypes	= files,
};

```

## 0x16 drvices subsystem

```c
struct cgroup_subsys devices_subsys = {
	.name = "devices",
	.can_attach = devcgroup_can_attach,
	.css_alloc = devcgroup_css_alloc,
	.css_free = devcgroup_css_free,
	.css_online = devcgroup_online,
	.css_offline = devcgroup_offline,
	.subsys_id = devices_subsys_id,
	.base_cftypes = dev_cgroup_files,
}
```

[^wangjiefeng]: [王喆锋 Linux Cgroups 详解](http://files.cnblogs.com/files/lisperl/cgroups%E4%BB%8B%E7%BB%8D.pdf)
[^source]: [Cgroups 源码分析 1: 基本概念与框架](http://www.oenhan.com/cgroups-src-1)
[^lwn]: [LWN Writeback and control groups](http://lwn.net/Articles/648292/)
[^idr]: [idr - integer ID management](https://lwn.net/Articles/103209/)
[^netlec]: [netlec](http://www.haifux.org/lectures/299/netLec7.pdf)
