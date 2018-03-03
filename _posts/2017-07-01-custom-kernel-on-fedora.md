---
author: sn0rt
comments: true
date: 2017-04-10
layout: post
title: how to custom kernel on fedora
tag: tips
---

因为工作需要需要折腾一下，所以在这里备忘一下如何在 fedora 26上测试 upstream 的代码。

```shell
sudo dnf install fedpkg fedora-packager rpmdevtools ncurses-devel pesign elfutils-libelf-devel 
git clone git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
```

进入 Linux 源码目录，捡出需要的版本对应的 tag，然后准备一个 kernel 的编译配置文件。

```shell
cd linux
git checkout v4.11.0-rc8
cp /boot/config-4.11.9-300.fc26.x86_64 .config
```

编译-j的选项是多个编译进程同时工作，取决于你的 core 数量。完成过后安装压缩 kernel image，然后安装 kernel module。

```shell
make -j4
make install
make modules_install
```

利用 dracut 生成一个 initramfs，加个`--force`意思是说即使存在一个可以覆盖掉。最后更新一下grub2的配置文件。

```shell
dracut "" `make kernelrelease` --force
grub2-mkconfig -o /boot/grub2/grub.cfg
```
