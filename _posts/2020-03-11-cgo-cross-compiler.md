---
author: sn0rt
comments: true
date: 2020-03-11
layout: post
title:  cgo 交叉编译
tag: go
---

日常工作是写golang，在  mac 上开发代码，通过 `GOOS` 指定操作系统进行交叉编译发布到 Linux 环境。

但是在这一次的需求中在 golang 的项目中引用了 C 代码，带来的后果就是指定 `GOOS` 进行交叉编译失败。

C 代码是 `inline` 的方式引入的，形式如下

```go
package test


import (
	"fmt"
	"unsafe"
)
//#include <stdio.h>
//#include <stdint.h>
//#include <math.h>
//#include <string.h>
//#include <stdlib.h>
... some code
import "C"
```

正确的进行含 cgo 代码的交叉编译需要 2 步，首先安装 mac 下 Linux 平台交叉编译工具链  `brew install FiloSottile/musl-cross/musl-cross`，需要相当一段时间才能安装好。

其次指定 makefile 或者 其他形式的编译参数 `CC="x86_64-linux-musl-gcc"`, 与 `CGO_LDFLAGS="-static"`。

makefile 是我工作的正常编译管理工具，修改如下。

```makefile
go-build:
	CGO_ENABLED=1 \
	GO111MODULE=off \
	GOOS="linux" \
	GOARCH="amd64" \
	CC="x86_64-linux-musl-gcc" \
	CGO_LDFLAGS="-static" \
	go build -a -v -ldflags $(LDFLAGS) main.go
```
