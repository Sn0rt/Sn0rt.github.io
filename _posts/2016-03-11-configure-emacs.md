---
author: sn0rt
comments: true
date: 2016-03-11
layout: post
tag: tips
title: emacs tips
---
# 0x00 catalog

linux 下面一般安装 gnu/emacs:

```shell
dnf install emacs -y
```

mac 下面推荐 emacs-mac:

```shell
brew tap railwaycat/emacsmacport
brew install emacs-mac --with-spacemacs-icon
```

配置文件使用`spacemacs`,它主要功能通过 layer 来切分配置单元, 帮助节省配置时间.
我目前常用的 layer 有:

```lisp
c-c++
osx
html
go
docker
dash
chinese
haskell
shell-scripts
python
auto-completion
javascript
ycmd
gtags
better-defaults
emacs-lisp
git
colors
markdown
org
lua
latex
(shell :variables
        shell-default-height 30
        shell-default-position 'bottom)
spell-checking
syntax-checking
cscope
```

## 0x10 keybind[^faq]

之前上课习惯使用 vs 的 F5 去编译运行程序，emacs 的默认配置里面不提供这样的功能, emacs 当提供类似的命令叫`compile`调用`makefile`来完成。
可以通过 c mode hook bind F5 到`compile`命令:

```lisp
(add-hook 'c-mode-hook'
          (lambda ()
            (local-set-key (quote [f5]) (quote compile))))
```

## 0x20 auto complete

不同语言的补全记录.

### 0x21 C/C++

layer 里面对 C/C++ 的补全提供了 ycmd-client, 这个插件服务器端还是需要自己编译安装, 且 ycmd 每一个 project 都有一个叫`.ycm_extra_conf.py`的配置文件, 其可以通过 YCM-Generator 来生成.

### 0x22 python

python 补全有个非常棒的插件 elpy! 也已经集成到 spacemacs 了!

>It aims to provide an easy to install, fully-featured environment for Python development.[^elpy]

* 被动技能 -PEP8 风格检查
* 语法检查
* 自动补全
* 项目管理
...

### 0x23 go

在`.spacemacs`里面开启`go-mode`的 layer 并且安装相关命令行工具，go 开发环境就基本能用了。

```shell
go get golang.org/x/tools/cmd/govendor
go get golang.org/x/tools/cmd/goimports
go get golang.org/x/tools/cmd/gorename
go get github.com/rogpeppe/godef
go get golang.org/x/tools/cmd/guru
go get -u github.com/nsf/gocode
go get golang.org/x/tools/cmd/godoc
```

go 的环境变量

```shell
...
GOPATH="/Users/sn0rt/workspace/go"
...
```

默认安装遇到一个小坑就是不能补全第三方库, 通过 gocode 的的设置可以修改`autobuild` 和 `propose-builtins`

```shell
# gocode set
propose-builtins true
lib-path ""
custom-pkg-prefix ""
custom-vendor-dir ""
autobuild true
force-debug-output ""
package-lookup-mode "go"
close-timeout 1800
unimported-packages false
```

在 spacemacs 里面也已经集成了, 且静态分析工具换成了`guru`了! 简直太棒了!

## 0x30 latex

在.spacemacs 里面开启 latex, 可以通过 bindkey 进行直接编译与查看页方便, 不过对 ctex 宏包支持相对一般.

## 0x40 utils

### 0x41 irc

spacemacs 自带`erc`的 layer, 修改一行代码就能自动跑起来 irc 客户端, 很是方便. 而且可以 emacs 变成服务一直在后台这样 irc 就不用下线了 (记得 AFK).

### 0x42 git

>Magit is an interface to the version control system Git, implemented as an Emacs package. Magit aspires to be a complete Git porcelain. While we cannot (yet) claim that Magit wraps and improves upon each and every Git command, it is complete enough to allow even experienced Git users to perform almost all of their daily version control tasks directly from within Emacs. While many fine Git clients exist, only Magit and Git itself deserve to be called porcelains.

上面是介绍, 非常值得尝试一下。

[^faq]: [Emacs FAQ](https://www.gnu.org/software/emacs/manual/html_node/efaq/Binding-keys-to-commands.html)
[^elpy]: [Elpy](http://elpy.readthedocs.io/en/latest/concepts.html)
