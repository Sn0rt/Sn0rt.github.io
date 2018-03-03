---
author: sn0rt
comments: true
date: 2016-03-10
layout: post
tag: linux
title: From a bootable floppy to booting
---
# 0x00 foreword

制作可启动软盘是为了弄明白 hurlex 项目里面那个软盘其制作过程 [^ubwiki], 后来想到启动是一个完成的过程便对这个笔记进行拓展, 也就有了后面的软硬件启动过程.

# 0x01 install grub 0.97

网上 wiki 太老, 都是 base grub 1 的, 所以使用 grub 0.97 节约时间, 我系统是 fedora23 安装 grub 存在版本冲突, 所以暂时卸载了 grub2. 具体的 rpm 可以在 [^download] 下载.

# 0x02 starting

制作一个 1.44M 软盘, 然后格式化成 ext2, 复制必要的文件, 注意其中包含 menu.lst,grub.conf.
上面两个文件可能在新安装 grub 0 的时候是没有. 你需要自己 touch 一个同名文件, 否则在交互模式的 setup (fd0) 的 install 阶段会出现严重错误导致指令失败.

```shell
dd if=/dev/zero of=floppy.img count=1 bs=1440k
mke2fs floppy.img
mount floppy.img /mount/point
mkdir -p /mount/point/boot/grub
cd /boot/grub
cp stage1 stage2 menu.lst grub.conf /mount/point/boot/grub
```
进入 grub 0.97 的交互模式:

```shell
device (fd0) floppy.img
root (fd0)
setup (fd0)
quit
```

# 0x03 testing

安装 qemu 模拟器.

    qemu-system-i386 floppy.img

![test-in-qemu](/media/pic/grub/grub_install_test.png)
现在记得要把 grub0 卸载, 安装回 grub2.

# 0x04 hardware booting[^ulk]

1. 系统刚加电时候这个电脑的电路状态处于一片混沌 (不可预知). 北桥控制芯片向 cpu 引脚产生一个 RESET 的逻辑值, 带电压稳定时候控制芯片撤销 reset 信号, 就把处理器设置成特殊的值, 并执行在 0xfffffff0 处的指令, 从这里开始 cpu 就进入了"取指令 (IF)- 指令执行 (ID)- 循环", 所以我要做的就说在各个阶段为 cpu 提供相关的数据.
这个地址一般被映射到固定的 ROM 中,ROM 中存放着程序集在 x86 中通常被称为 BIOS, 因为 BIOS 里面包含几个中断驱动的低级过程, 所有操作系统在启动时候都依赖这些过程对计算机进行设备初始化.

2. 紧接着是 POST 过程,BIOS 对计算机各个部件进行初始化, 这个阶段会显示一些信息, 列如 bios 的版本, 不过如今的计算机使用高级配置和开机界面 (ACPI) 标准, 在 ACPI 兼容的 bios 中启动代码会简历几个表来描述当期系统的硬件设备. 这些表的格式独立于设备生成商, 而且可由操作系统读取以获得如何调用这些设备的信息.

3. 初始化硬件设备, 这个阶段在现代基于 PCI 的体系结构中相当重要, 他保证了所有的硬件设备操作不会引起 IRQ 与 I/O 端口的冲突, 完成本阶段可以显示一个本系统中所有 PCI 设备的列表.

4. 根据 BIOS 配置来搜索外部存储设备的第一个扇区来启动一个操作系统.

5. 只要找到一个有效设备 (第一个扇区最后两个字节是 0x55,0xaa), 将其第一个扇区的内容拷贝到物理地址 0x00007c00 的开始位置, 然后 ip 指向这里.


# 0x05 bootloader stage

复制第一个扇区到指定内存地址, 然后从那开始执行, 惯例做法是在第一个扇区放上一个加载操作系统的程序等待被复制执行.
早期的 linux 2.4 之前第一个扇区往往就是放着一个 bootloader, 以此在第一个扇区拷贝一个内核镜像就可以使软盘可启动.
grub 就是这样一个加载操作系统的程序. 下面这个指令就是 grub 交互模式中构造第一个扇区的指令的命令, 讲 stage1 写入分区头部.

    setup (fd0)
    
不同于现在, 因为现在的内核规模变大第一个扇区放不下, 所有交由专门的 bootloader 负载加载内核.

硬盘的第一个扇区是主引导记录 (MBR), 这个扇区包含一个小程序 (446bytes) 和一个分区表 (64bytes), 这个小程序用来装载被启动的操作系统所在分区的第一个扇区, 下面 mbr 内存布局可以看见 0xaa55(小端字节序).

```shell
#dd if=floopy.img of=temp bs=1 count=512
#hexdump -x temp
00001b0 0000 0000 0000 0000 0000 0000 0000 1224
00001c0 090f be00 7dbd c031 13cd 8a46 800c 00f9
00001d0 0f75 dabe e87d ffcf 9deb 6c46 706f 7970
00001e0 bb00 7000 01b8 b502 b600 cd00 7213 b6d7
00001f0 b501 e94f fee6 0000 0000 0000 0000 aa55
```

不同于 lilo,grub 可以从文件系统 ext2 和 ext3 中加载 Linux, 它是通过两个阶段的引导加载程序转换成三个阶段的引导加载程序来实现的.
阶段 1(MBR) 引导一个阶段 1.5 的引导加载器, 可以理解包含 linux 内核映像的特殊文件系统, 当 stage1_5 被加载过后,stage2 就可以被接着加载了.

当阶段 2 加载之后,GRUB 就可以在请求时显示可用内核列表 (在 /etc/grub.conf 中定义, 还有几个符号链接), 我们可以在那定制 grub 来控制启动.
stage2 被加载到内存后, 就可以对文件系统进行查询了, 并将默认的 initrd 加载到内存中,stage2 的引导加载程序就可以调用内核映像了.

# 0x06 os booting[^linuxboot]

当内核映像被加载到内存中, 并且阶段 2 的引导加载程序释放控制权之后, 内核阶段就开始. 内核映像并不是一个可执行的内核, 而是一个压缩过的内核映像. 通常它是一个 zImage(压缩映像, 小于 512KB 或一个 bzImage(较大的压缩映像, 大于 512KB), 它是提前使用 zlib 进行压缩过的. 在这个内核映像前面是一个例程, 它实现少量硬件设置, 并对内核映像中包含的内核进行解压, 然后将其放入高端内存中, 如果有初始 RAM 磁盘映像, 就会将它移动到内存中, 并标明以后使用. 然后该例程会调用内核, 并开始启动内核引导的过程.
    
当 bzImage(用于 i386 映像) 被调用时, 我们从./arch/i386/boot/head.S 的 start 汇编例程开始执行. 这个例程会执行一些基本的硬件设置, 并调用`./arch/i386/boot/compressed/head.S`中的 startup_32 例程. 此例程会设置一个基本的环境 (堆栈等), 并清除 Block Started by Symbol(BSS). 然后调用一个叫做 decompress_kernel 的 C 函数 (在./arch/i386/boot/compressed/misc.c 中) 来解压内核. 当内核被解压到内存中之后, 就可以调用它了. 这是另外一个 startup_32 函数, 但是这个函数在./arch/i386/kernel/head.S 中.

在这个新的 startup_32 函数 (也称为清除程序或进程 0) 中, 会对页表进行初始化, 并启用内存分页功能. 然后会为任何可选的浮点单元 (FPU) 检测 CPU 的类型, 并将其存储起来供以后使用. 然后调用 start_kernel 函数 (在 init/main.c 中), 它会将您带入与体系结构无关的 Linux 内核部分. 实际上, 这就是 Linux 内核的 main 函数.

通过调用 start_kernel, 会调用一系列初始化函数来设置中断, 执行进一步的内存配置, 并加载初始 RAM 磁盘. 最后, 要调用 kernel_thread(在 arch/i386/kernel/process.c 中) 来启动 init 函数, 这是第一个用户空间进程 (user-space process). 最后, 启动空任务, 现在调度器就可以接管控制权了 (在调用 cpu_idle 之后). 通过启用中断, 抢占式的调度器就可以周期性地接管控制权, 从而提供多任务处理能力.

在内核引导过程中, 初始 RAM 磁盘 (initrd) 是由阶段 2 引导加载程序加载到内存中的, 它会被复制到 RAM 中并挂载到系统上. 这个 initrd 会作为 RAM 中的临时根文件系统使用, 并允许内核在没有挂载任何物理磁盘的情况下完整地实现引导. 由于与外围设备进行交互所需要的模块可能是 initrd 的一部分, 因此内核可以非常小, 但是仍然需要支持大量可能的硬件配置. 在内核引导之后, 就可以正式装备根文件系统了 (通过 pivot_root)：此时会将 initrd 根文件系统卸载掉, 并挂载真正的根文件系统.

initrd 函数让我们可以创建一个小型的 Linux 内核, 包括作为可加载模块编译的驱动程序. 这些模块为内核提供了访问磁盘和磁盘上的文件系统的方法, 并为其他硬件提供了驱动程序. 由于根文件系统是磁盘上的一个文件系统, 因此 initrd 函数会提供一种启动方法来获得对磁盘的访问, 并挂载真正的根文件系统.

# 0x07 user interface

当内核被引导并进行初始化之后, 内核就可以启动自己的第一个用户空间应用程序了. 这是第一个调用的使用标准 C 库编译的程序.
在桌面 Linux 系统上, 第一个启动的程序通常是 /sbin/init, 不过这是可选择的 (/etc/inittab).

### reference:

[^ubwiki]: [ubuntu wiki](https://help.ubuntu.com/community/GrubHowto/BootFloppy)
[^ulk]: [深入理解 Linux 操作系统](https://book.douban.com/subject/1767120/)
[^linuxboot]: [Linux 引导过程内幕](http://www.ibm.com/developerworks/cn/linux/l-linuxboot/index.html)
[^download]: [download](ftp://ftp.pbone.net/mirror/archive.fedoraproject.org/fedora/linux/releases/17/Everything/x86_64/os/Packages/g/grub-0.97-93.fc17.x86_64.rpm)
