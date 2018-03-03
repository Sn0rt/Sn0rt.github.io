---
author: sn0rt
comments: true
date: 2016-09-09
layout: post
title: docker usage
tag: docker
---

# 0x00 starting

公司准备开容器项目且我被分到了项目组, 但对容器技术一无所知, 所以这个 post 来记录目前工业界主流容器技术 --docker 的实践过程.

## 0x01 what's docker?

>Docker is the world's leading software containerization platform.

## 0x02 why docker?

>Docker's commercial solutions provide an out of the box CaaS environment that gives IT Ops teams security and control over their environment, while enabling developers to build applications in a self service way. With a clear separation of concerns and robust tooling, organizations are able to innovate faster, reduce costs and ensure security.

## 0x03 docker component

* client/server: docker 是一个 c/s 架构的服务.server 提供一套完整 RESTful API.
* image: image 是 docker 创建容器的基础, 相当于源码对于程序.
* registry: 用来做镜像管理, 相当于源码与 git repo 的关系.
* containers: 运行起来的实体, 相当于多个程序.

## 0x04 review container

容器发展到现在逐步进入了标准化过程, 目前有工业界广泛是用的 docker; 还有 coreos 定制的 [appc](https://github.com/appc/spec), 目前遵循的 appc 的容器技术有 freebsd 平台的 Jet Pack 和 Linux 平台通过 C++ 实现的 Nose Cone.

# 0x10 bases usage

这里记录一下 docker 在命令行下面最近基本的用法.

## 0x11 install & configure

### install

fedora24 下面安装如此容易.

```shell
# sudo dnf install docker -y
# sudo systemctl enable docker
# sudo systemctl start docker
```

### http proxy[^systemd]

因为公司网络安全策略所以需要配置代理服务器.

```shell
# sudo mkdir /etc/systemd/system/docker.service.d
cat << EOF >> /etc/systemd/system/docker.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=http://username:password@10.0.58.88:8080/"
EOF
# sudo systemctl daemon-reload
# sudo systemctl show --property=Environment docker
# sudo systemctl restart docker
```

## 0x12 containers management

### create container

运行一个名字叫 sn0rt 的容器且进入 bash.

```shell
# sudo docker run -i --name sn0rt -t ubuntu:14.04 /bin/bash
exit
```
    
### status

查看当前服务器的容器状态.

```shell
# sudo docker ps -a
CONTAINER ID        IMAGE               COMMAND                  CREATED             STATUS                          PORTS               NAMES
ca06ea65dda8        ubuntu:14.04        "/bin/bash"              30 minutes ago      Exited (0) About a minute ago                       sn0rt
```

### attach to container

开始曾经停止的容器, 附加上去:

```shell
# sudo docker start sn0rt
# sudo docker attach sn0rt
```
    
### create demon container

```shell
# sudo docker run --name sn0rt -d ubuntu:14.04 /bin/sh -c "while true;
do echo hello word; sleep 1; done"
51b1a48d762441717cec525e42022328417f1c5ff9b18c456dbde0a925db7d57
# sudo docker ps -a
CONTAINER ID        IMAGE               COMMAND                  CREATED             STATUS                      PORTS               NAMES
51b1a48d7624        ubuntu:14.04        "/bin/sh -c 'while tr"   10 seconds ago      Up 7 seconds                                    sn0rt
```

### show logs

```shell
# sudo docker logs -ft sn0rt
2016-09-09T03:30:47.986708000Z hello word
2016-09-09T03:30:49.233008000Z hello word
```

### exec in container

在容器中运行个非交互式进程后在运行交互式进程.

```shell
# sudo docker ps
CONTAINER ID        IMAGE               COMMAND                  CREATED             STATUS              PORTS               NAMES
51b1a48d7624        ubuntu:14.04        "/bin/sh -c 'while tr"   About an hour ago   Up About an hour                        sn0rt
# sudo docker exec -d sn0rt touch /tmp/linux
# sudo docker exec -t -i sn0rt /bin/bash
root@51b1a48d7624:/# ls /tmp/linux 
/tmp/linux
root@51b1a48d7624:/# 
```

### inspect container

获取更多的信息以 json 格式展示, 省略部分以`...`代替.

```shell
# sudo docker inspect sn0rt
[
    {
        "Id": "51b1a48d762441717cec525e42022328417f1c5ff9b18c456dbde0a925db7d57",
        "Created": "2016-09-09T03:28:16.986340741Z",
        "Path": "/bin/sh",
        "Args": [
            "-c",
            "while true;\ndo echo hello word; sleep 1; done"
        ],
    ...
    }
]
```

### stop and remove

不能移除一个在运行的容器.

```shell
# sudo docker stop sn0rt
sn0rt
# sudo docker ps
CONTAINER ID        IMAGE               COMMAND             CREATED             STATUS              PORTS               NAMES
# sudo docker rm sn0rt
sn0rt
# sudo docker rm `docker ps -a -q`
```
    
## 0x13 image management

容器镜像的管理, 名字叫法类似于 git.

### pull

```shell
# sudo docker pull ubuntu:14.04
Trying to pull repository docker.io/library/ubuntu ... 
14.04: Pulling from docker.io/library/ubuntu
Digest: sha256:5b5d48912298181c3c80086e7d3982029b288678fccabf2265899199c24d7f89
Status: Image is up to date for docker.io/ubuntu:14.04
```

### list

```shell
# sudo docker images
REPOSITORY          TAG                 IMAGE ID            CREATED             SIZE
test                latest              d373bc5e4a77        20 hours ago        340.4 MB
docker.io/ubuntu    14.04               4a725d3b3b1c        13 days ago         187.9 MB
```

### search

需要先通过`docker login`登录 docker.io.

```shell
# sudo docker search kali
INDEX       NAME                                                DESCRIPTION                                     STARS     OFFICIAL   AUTOMATED
docker.io   docker.io/kalilinux/kali-linux-docker               Kali Linux Rolling Distribution Base Image      216                  [OK]
```

### remove

```shell
# sudo docker images
REPOSITORY          TAG                 IMAGE ID            CREATED             SIZE
test                latest              d373bc5e4a77        20 hours ago        340.4 MB
docker.io/ubuntu    14.04               4a725d3b3b1c        13 days ago         187.9 MB
# sudo docker rmi test
Untagged: test:latest
# sudo docker images
REPOSITORY          TAG                 IMAGE ID            CREATED             SIZE
docker.io/ubuntu    14.04               4a725d3b3b1c        13 days ago         187.9 MB
```

### create(commit)

有几种方法可以创建自己的 image, 这里纪录一下 commit 的使用.

```shell
# sudo docker run -i --name sn0rt -t ubuntu:14.04 /bin/bash
root@41f815d96b7a:/# apt-get update -yqq
root@41f815d96b7a:/# exit
# docker ps -a
CONTAINER ID        IMAGE               COMMAND             CREATED             STATUS                      PORTS               NAMES
41f815d96b7a        ubuntu:14.04        "/bin/bash"         4 minutes ago       Exited (0) 12 seconds ago                       sn0rt
# docker commit -m="update finshed" --author="Sn0rt@abc.shop.edu.cn" 41f815d96b7a sn0rt/ubuntu_updated
sha256:92ae626c3fb58ad14b621d831bc8c1529357824ebbbdf1b2b4691b4d9e84814c
# docker images
REPOSITORY                  TAG                 IMAGE ID            CREATED             SIZE
sn0rt/ubuntu_updated   latest              92ae626c3fb5        58 seconds ago      210.1 MB
docker.io/ubuntu            14.04               4a725d3b3b1c        13 days ago         187.9 MB
```

### export

有时候网络不好, 或者某些限制导致你不能通过 pull 来安装 image.docker 提供一个导出的功能可以使用.

```shell
# docker save -o kubedns-amd64.tar gcr.io/google_containers/kubedns-amd64
```

### import

上面的导出文件你可以通过下面这个命令把这个文件导入进自己的 docker image.

```shell
# docker load --input kubedns-amd64.tar
```

# 0x20 dockerfile[^dockerfile]

这是另一种构建自己 image 的方法, 也是官方推荐的 (高度可定制).
利用 dockerfile 构建三个 images, 命名为 ubuntu,apache 与 mysql.
其中 apache 与 mysql 基于 ubuntu_updated, 而 ubuntu_updated 是基于 ubuntu:14.04.

## ubuntu

基本 ubuntu 镜像做一个 update 操作后 build 一下, 如果不做的话其实 docker 也会帮你缓存,docker 每命令每镜像

```dockerfile
FROM ubuntu:14.04
MAINTAINER Sn0rt <Sn0rt@abc.shop.edu.cn>

ENV http_proxy="http://username:password@10.0.58.88:8080/"
ENV https_proxy="http://username:password@10.0.58.88:8080/"

RUN apt-get update -yqq
```

如果写错了可以修改`Dockerfile`重新 build, 它会自最近一次正确 image 开始继续 build.

```shell
➜  ubuntu docker build -t="sn0rt/ubuntu" . 
Sending build context to Docker daemon 2.048 kB
Step 1 : FROM ubuntu:14.04
 ---> 4a725d3b3b1c
...
Step 5 : RUN apt-get update -yqq
 ---> Running in 91e8e54e3be5
 ---> 8aae246f5e4c
Removing intermediate container 91e8e54e3be5
Successfully built 8aae246f5e4c
```

## mysql

```dockerfile
FROM sn0rt/ubuntu
MAINTAINER Sn0rt <Sn0rt@abc.shop.edu.cn>

ENV http_proxy="http://username:password@10.0.58.88:8080/"
ENV https_proxy="http://username:password@10.0.58.88:8080/"

RUN apt-get install mysql-server -yqq
COPY my.cnf /etc/mysql/my.cnf
WORKDIR /root
COPY init.sql init.sql
RUN /etc/init.d/mysql restart && mysql < init.sql
```

### building:

```shell
# sudo docker build -t="sn0rt/mysql:v1" .
Sending build context to Docker daemon 7.168 kB
Step 1 : FROM sn0rt/ubuntu
 ---> 8aae246f5e4c
...
Step 9 : RUN /etc/init.d/mysql restart && mysql < init.sql
 ---> Running in 73fd2bc50964
 * Stopping MySQL database server mysqld
   ...done.
 * Starting MySQL database server mysqld
   ...done.
 * Checking for tables which need an upgrade, are corrupt or were 
not closed cleanly.
 ---> 5d3c0a4fa4ed
Removing intermediate container 73fd2bc50964
Successfully built 5d3c0a4fa4ed
```

## apache

利用`Dockerfile`来安装`phpmyadmin`.

```dockerfile
FROM sn0rt/ubuntu
MAINTAINER Sn0rt <Sn0rt@abc.shop.edu.cn>

ENV http_proxy="http://username:password@10.0.58.88:8080/"
ENV https_proxy="http://username:password@10.0.58.88:8080/"

RUN apt-get install apache2 -yqq
RUN apt-get install php5 libapache2-mod-php5 php5-mcrypt php5-mysql -yqq
COPY dir.conf /etc/apache2/mods-available/dir.conf

ADD phpMyAdmin-4.6.4-all-languages.tar.gz /var/www/html/
WORKDIR /var/www/html/phpMyAdmin-4.6.4-all-languages/
RUN mv * ..

COPY config.inc.php /var/www/html/config.inc.php

ENTRYPOINT ["apachectl"]
CMD ["-X"]
```

### building:

```shell
➜  apache docker build -t="sn0rt/apache:v1" .           
Sending build context to Docker daemon 10.38 MB
Step 1 : FROM sn0rt/ubuntu
 ---> 8aae246f5e4c
...
Step 13 : CMD -X
 ---> Running in 45fa01e8ac4c
 ---> 366ef630e06f
Removing intermediate container 45fa01e8ac4c
Successfully built 366ef630e06f
```

## checking history

通过 history 命令可以查看到历史命令.

```shell
# sudo docker images                           
REPOSITORY          TAG                 IMAGE ID            CREATED             SIZE
sn0rt/apache   v1                  366ef630e06f        3 minutes ago       324.8 MB
sn0rt/mysql    v1                  5d3c0a4fa4ed        2 hours ago         345.7 MB
sn0rt/ubuntu   latest              8aae246f5e4c        2 hours ago         210.1 MB
docker.io/ubuntu    14.04               4a725d3b3b1c        2 weeks ago         187.9 MB
# sudo docker history sn0rt/mysql:v1
IMAGE               CREATED             CREATED BY                                      SIZE                COMMENT
5d3c0a4fa4ed        20 minutes ago      /bin/sh -c /etc/init.d/mysql restart && mysql   5.252 MB            
92dba0a2acb2        20 minutes ago      /bin/sh -c #(nop) COPY file:77fac40c1774c2ad4   172 B               
c3df7fa0d3d1        20 minutes ago      /bin/sh -c #(nop) WORKDIR /root                 0 B                 
ca7a6756a3c7        20 minutes ago      /bin/sh -c #(nop) COPY file:30489e5e5529ad833   3.506 kB            
d06d1ddad673        20 minutes ago      /bin/sh -c apt-get install mysql-server -yqq    130.3 MB            
91190a6c9e32        22 minutes ago      /bin/sh -c #(nop) ENV https_proxy=http://fnst   0 B                 
7d8936b1f833        22 minutes ago      /bin/sh -c #(nop) ENV http_proxy=http://fnsts   0 B                 
f08d8e1643b3        22 minutes ago      /bin/sh -c #(nop) MAINTAINER Sn0rt <Sn0rt@abc   0 B                 
8aae246f5e4c        48 minutes ago      /bin/sh -c apt-get update -yqq                  22.16 MB            
091e0ec51c90        50 minutes ago      /bin/sh -c #(nop) ENV https_proxy=http://fnst   0 B                 
43bff3143ad4        50 minutes ago      /bin/sh -c #(nop) ENV http_proxy=http://fnsts   0 B                 
913e5f034797        50 minutes ago      /bin/sh -c #(nop) MAINTAINER Sn0rt <Sn0rt@abc   0 B       
```

## using

需要一个前台进程, 如果以 apache 以服务在后台启动的话, 容器会变成退出状态.

### mysql

```shell
# sudo docker run -d -p 3306:3306 --name mysql sn0rt/mysql:v1 mysqld_safe
b946792318652c2d405406e66fbbaa7472a6a5a8dc281c71abe6fd8651070d46
# sudo docker ps
CONTAINER ID        IMAGE                 COMMAND             CREATED             STATUS              PORTS                    NAMES
b94679231865        sn0rt/mysql:v1   "mysqld_safe"       5 seconds ago       Up 2 seconds        0.0.0.0:3306->3306/tcp   mysql
```

### apache

对外服务提供以一直的 ip 地址 (宿主机器的地址),apache 以前台进程在运行.

```shell
# docker run -d -p 80:80 --name apache sn0rt/apache:v1
# sudo docker ps -a
CONTAINER ID        IMAGE                  COMMAND             CREATED             STATUS              PORTS                    NAMES
a478f202f3bf        sn0rt/apache:v1   "apachectl -X"      47 seconds ago      Up 44 seconds       0.0.0.0:80->80/tcp       apache
b94679231865        sn0rt/mysql:v1    "mysqld_safe"       3 minutes ago       Up 3 minutes        0.0.0.0:3306->3306/tcp   mysql
```

### testing

在宿主机器上面进行测试 apache 与 mysql 的端口绑定.

```shell
# sudo curl -I localhost
HTTP/1.1 200 OK
Date: Mon, 12 Sep 2016 03:23:31 GMT
Server: Apache/2.4.7 (Ubuntu)
X-Powered-By: PHP/5.5.9-1ubuntu4.19
Set-Cookie: pmaCookieVer=5; expires=Wed, 12-Oct-2016 03:23:31 GMT; Max-Age=2592000; path=/; httponly
Set-Cookie: phpMyAdmin=npcfgt7puqs2cmld1ttk2k3naa7pv54a; path=/; HttpOnly
Expires: Mon, 12 Sep 2016 03:23:31 +0000
...
# sudo mysql -u root -p -h 172.17.0.1
Enter password: 
Welcome to the MariaDB monitor.  Commands end with ; or \g.
Your MySQL connection id is 3
Server version: 5.5.50-0ubuntu0.14.04.1 (Ubuntu)

Copyright (c) 2000, 2016, Oracle, MariaDB Corporation Ab and others.

# sudo docker logs mysql
160912 03:17:34 mysqld_safe Can't log to error log and syslog at the same time.  Remove all --log-error configuration options for --syslog to take effect.
160912 03:17:34 mysqld_safe Logging to '/var/log/mysql/error.log'.
160912 03:17:34 mysqld_safe Starting mysqld daemon with databases from /var/lib/mysql
# sudo docker logs apache
AH00558: apache2: Could not reliably determine the server's fully qualified domain name, using 172.17.0.3. Set the 'ServerName' directive globally to suppress this message
```

# 0x30 dockerhub

测试完成没有问题, 且打算分享你的容器这个时候就可以把它推送到 dockerhub(记得`docker login`).

```shell
# sudo docker push sn0rt/ubuntu
The push refers to a repository [docker.io/sn0rt/ubuntu]
54da5869939f: Pushed 
ffb6ddc7582a: Mounted from library/ubuntu 
344f56a35ff9: Mounted from library/ubuntu 
530d731d21e1: Mounted from library/ubuntu 
24fe29584c04: Mounted from library/ubuntu 
102fca64f924: Mounted from library/ubuntu 
latest: digest: sha256:703fec1e8c32ebc0da29d12be2515f640b9022e45c38df62a48145851ad651b6 size: 1549
# sudo docker search sn0rt/ubuntu
INDEX       NAME                          DESCRIPTION   STARS     OFFICIAL   AUTOMATED
docker.io   docker.io/sn0rt/ubuntu                 1                    
```

# 0x40 summary[^docker-hype]

* layer: 初步接触 docker 发现 layer 这样的设计放到环境部署里面非常实用. 但是算不上完全创新, 至少我之前 vmware 有尝试过类似的概念, 我基于虚拟机的某个配置对其进行快照, 然后以快照为基础进行不同的修改, 这样自己用起来是没有太多问题的.
* dockerfile: docker 官方提供的 dockerfile 组织过于原始, 退回了 shell 部署时代, 而且 dockerfile build 的依赖关系层级划分是通过多个 docker image 来实现的, 这样至少目前可能是需要手工解决依赖 (安装镜像).
* security: docker 的 Linux 实现依赖于 namespace 与 cgroup,namepsace 本身的安全性 (CVE) 与 cgroup 的颗粒度本身都是不完善的 (cgroup 对网络限制), 从容器中逸出也不是没有可能.
* performance: KVM 在运行基于模板生成的虚拟机可以合并相同内存的, 容器是共享内核的可以想象一下是节约一点内存;cpu 不需要在 guest 和 host 之间来回切换可能节约一点 cpu 时间.
* limit: 作为一个软件安全爱好者有时候对 kernel 本身感兴趣, 这时候 docker 就不行了.

[^systemd]: [systemd configure](https://docs.docker.com/engine/admin/systemd/)
[^dockerfile]: [dockfile manual](https://docs.docker.com/engine/reference/builder/)
[^docker-hype]: [docker-hype](http://iops.io/blog/docker-hype)
