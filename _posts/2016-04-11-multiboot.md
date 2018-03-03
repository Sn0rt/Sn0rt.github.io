---
author: sn0rt
comments: true
date: 2016-04-11
layout: post
tag: specification
title: multiboot specification
---

### 0x00 background

准备写一个玩具操作系统, 所以启动过程少不了, 不过启动过程周期只有一次, 且细节繁复, 单调.
因为玩具系统是基于 x86 的, 引用社区解决方案 multiboot[^multiboot] 可以模糊 x86 架构系统相关细节.

### 0x01 OS image format

Small OS 被设计为基于 IA32 且是 multiboot os 这样它可能被链接到一个非默认加载地址以避开 PC 的 I/O 区域或者其它的保留区域, 但作为 multiboot OS 必须具有一个被称为 multiboot header 的头部信息, 且必须完整的包含在 OS 的前 8192 字节内且 4 字节对齐.

```x86asm
MBOOT_PAGE_ALIGN    equ     1 << 0      ; Bit 0
MBOOT_MEM_INFO      equ     1 << 1
MBOOT_HEADER_MAGIC  equ     0x1BADB002  ; Magic number from mboot standar
MBOOT_HEADER_FLAGS  equ     MBOOT_PAGE_ALIGN | MBOOT_MEM_INFO
MBOOT_HEADER_CHECKSUM      equ     -(MBOOT_HEADER_MAGIC+MBOOT_HEADER_FLAGS)

section .text
dd MBOOT_HEADER_MAGIC
dd MBOOT_HEADER_FLAGS
dd MBOOT_HEADER_CHECKSUM
```

* Magic
  Magic 域是标志头的魔数, 它必须等于十六进制值 0x1BADB002.
* Flags
  Flags 域指出 OS 映像需要引导程序提供或支持的特性.
  0-15 位指出需求：如果引导程序发现某些值被设置但出于某种原因不理解或不能不能满足相应的需求, 它必须告知用户并宣告引导失败.
      16-31 位指出可选的特性：如果引导程序不能支持某些位, 它可以简单的忽略它们并正常引导. 所有 flags 字中尚未定义的位必须被置为 0. 这样,flags 域既可以用于版本控制也可以用于简单的特性选择.
  如果设置了 flags 字中的 0 位, 所有的引导模块将按页（4KB）边界对齐. 有些操作系统能够在启动时将包含引导模块的页直接映射到一个分页的地址空间, 因此需要引导模块是页对齐的.
  如果设置了 flags 字中的 1 位, 则必须通过 Multiboot 信息结构的 mem_*域包括可用内存的信息. 如果引导程序能够传递内存分布并且它确实存在, 则也包括它.
  如果设置了 flags 字中的 2 位, 有关视频模式表的信息必须对内核有效.
  如果设置了 flags 字中的 16 位, 则 Multiboot 头中偏移量 8-24 的域有效, 引导程序应该使用它们而不是实际可执行头中的域来计算将 OS 映象载入到那里. 内核映象为 ELF 格式则不必提供这样的信息.
* Checksum
  Checksum 域 checksum 是一个 32 位的无符号值, 当与其他的 magic 域（也就是 magic 和 flags）相加时, 结果必须是 32 位的无符号值 0（即 magic + flags + checksum = 0）.
* The address fields of Multiboot header
所有由 flags 的第 16 位开启的地址域都是物理地址. 它们的意义如下:
* header_addr
  包含对应于 Multiboot 头的开始处的地址——这也是 magic 值的物理地址. 这个域用来同步 OS 映象偏移量和物理内存之间的映射.
* load_addr
  包含 text 段开始处的物理地址. 从 OS 映象文件中的多大偏移开始载入由头位置的偏移量定义, 相减（header_addr - load_addr）.load_addr 必须小于等于 header_addr.
* load_end_addr, 包含 data 段结束处的物理地址.
  （load_end_addr - load_addr）指出了引导程序要载入多少数据. 这暗示了 text 和 data 段必须在 OS 映象中连续；现有的 a.out 可执行格式满足这个条件. 如果这个域为 0, 引导程序假定 text 和 data 段占据整个 OS 映象文件.
* bss_end_addr, 包含 bss 段结束处的物理地址.
  引导程序将这个区域初始化为 0, 并保留这个区域以免将引导模块和其他的于查系统相关的数据放到这里. 如果这个域为 0, 引导程序假定没有 bss 段.
* entry_addr
  操作系统的入口点, 引导程序最后将跳转到那里. 

### 0x02 Machine state

当引导程序调用 32 位操作系统时, 机器状态必须如下：

* EAX 必须包含魔数 0x2BADB002；这个值指出操作系统是被一个符合 Multiboot 规范的引导程序载入的（这样就算是另一种引导程序也可以引导这个操作系统）.
* EBX 必须包含由引导程序提供的 Multiboot 信息结构的物理地址.
* CS 必须是一个偏移量位于 0 到 0xFFFFFFFF 之间的 32 位可读 / 可执行代码段. 这里的精确值未定义.
* Others register(DS,ES,FS,GS,SS), 必须是一个偏移量位于 0 到 0xFFFFFFFF 之间的 32 位可读 / 可执行代码段. 这里的精确值未定义.
* A20 gate, 必须已经开启.
* CR0 第 31 位（PG）必须为 0. 第 0 位（PE）必须为 1. 其他位未定义.
* EFLAGS 第 17 位（VM）必须为 0. 第 9 位（IF）必须为 1. 其他位未定义. 所有其他的处理器寄存器和标志位未定义. 这包括：
* ESP 当需要使用堆栈时,OS 映象必须自己创建一个.
* GDTR 尽管段寄存器像上面那样定义了,GDTR 也可能是无效的, 所以 OS 映象决不能载入任何段寄存器（即使是载入相同的值也不行！）直到它设定了自己的 GDT.
* IDTR OS 映象必须在设置完它的 IDT 之后才能开中断.
  尽管如此, 其他的机器状态应该被引导程序留做正常的工作顺序, 也就是同 BIOS（或者 DOS, 如果引导程序是从那里启动的话）初始化的状态一样. 换句话说, 操作系统应该能够在载入后进行 BIOS 调用, 直到它自己重写 BIOS 数据结构之前. 还有, 引导程序必须将 PIC 设定为正常的 BIOS/DOS 状态, 尽管它们有可能在进入 32 位模式时改变它们.
 
```c
/* 启动后, 在 32 位内核进入点, 机器状态如下
 * 1. cs 指向基地址 0x00000000, 限长 1-4G 的代码段描述符
 * 2. ds, ss, es, fs, gs 指向基地址 0x00000000, 限长 1-4G 的数据段描述符
 * 3. A20 地址线已经被打开
 * 4. 页机制被禁止
 * 5. 中断被禁止
 * 6. EAX = 0x2BADB002
 * 7. 系统信息和启动信息块的线性地址保存在 ebx 中.
 */
```

### 0x03 Boot information

在进入操作系统时 [^example],EBX 寄存器包含 Multiboot 信息数据结构的物理地址, 引导程序通过它将重要的引导信息传递给操作系统. 操作系统可以按自己的需要使用或者忽略任何部分；所有的引导程序传递的信息只是建议性的.
Multiboot 信息结构和它的相关的子结构可以由引导程序放在任何位置（当然, 除了保留给内核和引导模块的区域）. 如何在利用之前保护它是操作系统的责任.
Multiboot 信息结构的格式如下:

```c
typedef struct multiboot_t {
  /* multiboot version info 且是必须的 */
  uint32_t flags;

  /* 如果 flags[0] 被置位则出现
   * mem_lower 和 mem_upper 分别指出低端和高端内存的大小, 单位是 k
   * 低端内存的首地址是 0, 高端内存首地址是 1M
   * 低端内存的最大值可能是 640k
   * 高端内存的最大值可能是最大值 -1M, 但并不保证是这个值.
   */
  uint32_t mem_lower;
  uint32_t mem_upper;

  /* 如果 flags[1] 被置位则出现, 并指出引导程序从哪个 BIOS 磁盘设备载入的 OS 映像.
   * 如果 OS 映像不是从一个 BIOS 磁盘载入的, 这个域就决不能出现 (第 3 位必须是 0).
   * 操作系统可以使用这个域来帮助确定它的 root 设备, 但并不一定要这样做. 
   */
  uint32_t boot_device;

  /* 如果 flags[2] 被置位则出现, 如果设置了 flags longword 的第 2 位,
   * 则 cmdline 域有效, 并包含要传送给内核的命令行参数的物理地址.
   * 命令行参数是一个正常 C 风格的以 0 终止的字符串.
   */
  uint32_t cmdline;

  /* 如果 flags[3] 被置位则出现, 则 mods 域指出了同内核一同载入的有哪些引导模块,
   * 以及在哪里能找到它们.mods_count 包含了载入的模块的个数,
   * mods_addr 包含了第一个模块结构的物理地址. 
   */
  uint32_t mods_count;
  uint32_t mods_addr;

  /* offset 28-30 syms
   * 如果 flags[4] 或 flags[5] 被置位则出现 (互斥), 这里是 5 被置位.
   * ELF format section head, 参见 i386 ELF 文档以得到如何读取 section 头的更多的细节
   */
  uint32_t num;
  uint32_t size;
  uint32_t addr;
  uint32_t shndx;

  /* 如果 flags[6] 被置位则出现, 指出保存由 BIOS 提供的内存分布的缓冲区的地址和长度.
   * mmap_addr 是缓冲区的地址,mmap_length 是缓冲区的总大小.
   */
  uint32_t mmap_length;
  uint32_t mmap_addr;

  /* 如果 flags[7] 被置位则出现, 则 drives_*域是有效的,
   * 指出第一个驱动器结构的物理地址和这个结构的大小.
   * drives_addr 是地址,drives_length 是驱动器结构的总大小. 
   */
  uint32_t drives_length;
  uint32_t drives_addr;

  /* 如果 flags[8] 被置位则出现, 则 config_table 域有效,
   * 指出由 GET CONFIGURATION BIOS 调用返回的 ROM 配置表的物理地址.
   * 如果这个 BIOS 调用失败了, 则这个表的大小必须是 0.
   */
  uint32_t config_table;

  /* 如果 flags[9] 则 boot_loader_name 域有效,
   * 包含了引导程序名字在物理内存中的地址.
   * 引导程序名字是正常的 C 风格的以 0 中止的字符串 
   */
  uint32_t boot_loader_name;
  uint32_t apm_table;

  /* 如果 flags[11] 被置位则 apm_table 域有效,
  包含了如下 APM(高级电源管理) 表的物理地址: */
  uint32_t vbe_control_info;
  uint32_t vbe_mode_info;
  uint32_t vbe_mode;
  uint32_t vbe_interface_seg;
  uint32_t vbe_interface_off;
  uint32_t vbe_interface_len;
} __attribute__((packed)) multiboot_t;
```

在 flags[6] 被置位时候, 则 mmap_*域有效, 指出保存由 BIOS 提供的内存分布的缓冲区的地址和长度, 缓冲区的结构:

```c
/* size: 是相关结构的大小, 单位是字节, 它可能大于最小值 20.
 * base_addr_low: 是启动地址的低 32 位,
 * base_addr_high: 是高 32 位, 启动地址总共有 64 位.
 * length_low: length_low 是内存区域大小的低 32 位.
 * length_high: 是内存区域大小的高 32 位, 总共是 64 位.
 * type: 是内存可用信息 1 代表可用, 其他的代表保留区域
 */
 
typedef struct mmap_entry_t {
  uint32_t size;
  uint32_t base_addr_low;
  uint32_t base_addr_high;
  uint32_t length_low;
  uint32_t length_high;
  uint32_t type;
} __attribute__((packed)) mmap_entry_t;
```

[^multiboot]: [multiboot specification](https://www.gnu.org/software/grub/manual/multiboot/multiboot.html)
[^example]: [example OS Code](https://www.gnu.org/software/grub/manual/multiboot/multiboot.html#Example-OS-code)
