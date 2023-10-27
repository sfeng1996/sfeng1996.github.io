---
weight: 26
title: "如何压缩镜像体积(增加 Nginx 第三方模块)"
date: 2023-10-26T11:57:40+08:00
lastmod: 2023-10-26T12:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "closure-home.jpg"

tags: ["kubernetes-ops", "Docker"]
categories: ["Kubernetes-ops", "Docker"]

lightgallery: true
---

# 如何压缩镜像体积(增加 Nginx 第三方模块)

## 简介

一般我们自己构建完 OCI 镜像，体积可能都会超过我们预期，压缩镜像体积对于后期更新、维护就显得非常有必要。我们以 Nginx 编译增加第三方模块为例来讲解如何压缩镜像的体积。

一般使用 nginx 镜像，我们直接从 [Docker 镜像仓库](https://hub.docker.com/) 直接白嫖就行，基本上对应 Nginx 版本都有。但是如果我们需要增加 Nginx 模块，这时候 Docker镜像仓库可能会没有，那么就需要我们自行构建。

我们在物理机或者虚拟机上部署 Nginx，一般使用编译安装的方式，这样对后期增加第三方模块会更加方便。

下面介绍使用编译安装的方式构建 Nginx 镜像，同时会增加第三方模块 nginx-module-vts，该模块用于获取 Nginx 状态，可以结合 Prometheus 对其进行监控。但是构建完成后镜像产物比

较大，应为编译 Nginx 需要安装一些 Linux 依赖包，所以我们会结合 Docker 的一些属性来精简镜像。

## 构建镜像

这里的构建环境是：

操作系统：`CentOS 7.9，3.10.0-957.el7.x86_64`

Docker：`19.03.14`

以下是 Dockerfile：

```docker
# 这里选择已存在 nginx:1.21.3 作为 base 镜像，这样编译过程不会存在依赖包的问题
FROM nginx:1.21.3 
# Nginx 版本
ENV NGINX_VERSION nginx-1.21.3

# wget -O nginx-module-vts.tar.gz https://github.com/vozlt/nginx-module-vts/archive/refs/tags/v0.2.1.tar.gz 
# wget http://nginx.org/download/${NGINX_VERSION}.tar.gz

# 提前下载好 Nginx、nginx-vts 包
ADD ${NGINX_VERSION}.tar.gz .
WORKDIR ${NGINX_VERSION}
ADD nginx-module-vts-0.2.1.tar.gz .

RUN echo "deb http://mirrors.ustc.edu.cn/debian buster main contrib non-free" > /etc/apt/sources.list && \
    echo "deb http://mirrors.ustc.edu.cn/debian buster-updates main contrib non-free" >> /etc/apt/sources.list && \
    echo "deb http://mirrors.ustc.edu.cn/debian buster-backports main contrib non-free"  >>  /etc/apt/sources.list && \
    echo "deb http://mirrors.ustc.edu.cn/debian-security/ buster/updates main contrib non-free" >> /etc/apt/sources.list && \
    rm -rf /etc/apt/sources.list.d && \
    apt-get update && apt-get install -y build-essential wget libpcre3 libpcre3-dev zlib1g-dev openssl libssl-dev libxml2 libxml2-dev libxslt-dev && \
    ./configure \
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
        --with-compat \
        --with-file-aio \
        --with-threads \
        --with-http_addition_module \
        --with-pcre-jit \
        --with-http_ssl_module \
        --with-http_stub_status_module \
        --with-http_realip_module \
        --with-http_auth_request_module \
        --with-http_v2_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_slice_module \
        --with-threads \
        --with-http_addition_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_mp4_module \
        --with-http_random_index_module \
        --with-http_sub_module \
        --with-http_xslt_module=dynamic \
        --with-http_secure_link_module \
        --with-http_slice_module \
        --with-stream=dynamic \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --with-cc-opt='-g -O2 -fdebug-prefix-map=/data/builder/debuild/nginx-1.21.3/debian/debuild-base/nginx-1.21.3=. -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC' --with-ld-opt='-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie' \
        --with-mail=dynamic \
        --with-mail_ssl_module \
        --add-module=nginx-module-vts-0.2.1 && \
    make && \
    make install && \
    rm -rf /var/cache/apk/*

WORKDIR /etc/nginx
EXPOSE 80 443
STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]
```

使用以下命令构建镜像：

```bash
$ docker build -t nginx-vts:1.21.3.1 -f Dockerfile .
```

查看镜像大小，发现该镜像非常大，比起在 Docker 镜像仓库拉下来的大了好几倍。

```bash
$ docker images
nginx-vts      v1.21.3.1          3396e0d19b67        36 minutes ago        568MB
```

下面看看如何压缩镜像大小

## 镜像瘦身

使用 Docker 构建镜像，有以下方式来压缩镜像的大小：

- 减小镜像层数
- 多阶段构建
- 选用精简的 Base 镜像

### 减小镜像层数

Docker 镜像是由很多镜像层( Layers ) 组成的( 最多 127 层 )，Dockerfile 中的每条指令都会创建镜像层，不过只有 RUN、ADD、COPY 会使镜像体积增加。所以可以将 RUN 指令合并，上面的 Dockerfile 已经进行了合并。

可以通过 `docker history <image_id>` 查看镜像每一层的大小

```bash
$ docker history 089e707b3861
IMAGE               CREATED             CREATED BY                                      SIZE                COMMENT
089e707b3861        24 hours ago        /bin/sh -c #(nop)  CMD ["nginx" "-g" "daemon…   0B                  
d8bc04cb05a7        24 hours ago        /bin/sh -c #(nop)  STOPSIGNAL SIGQUIT           0B                  
7388b67070a9        24 hours ago        /bin/sh -c #(nop)  EXPOSE 443 80                0B                  
0cf11e749869        24 hours ago        /bin/sh -c #(nop) WORKDIR /etc/nginx            0B                  
0f080ff3627b        24 hours ago        /bin/sh -c tar -zxvf nginx-module-vts-0.2.1.…   48.7MB              
8c64b5d68a92        24 hours ago        /bin/sh -c #(nop) COPY file:352c32d047bc68c9…   180kB               
65ea8f040696        24 hours ago        /bin/sh -c #(nop) WORKDIR /nginx-1.21.3         0B                  
449d353aeb9f        24 hours ago        /bin/sh -c wget http://nginx.org/download/${…   7.49MB              
8d1908b98ca4        24 hours ago        /bin/sh -c mkdir /tmp/src &&     cd /tmp/src    0B                  
699dec93c071        24 hours ago        /bin/sh -c apt-get update && apt-get install…   379MB               
67cd9449b22b        25 hours ago        /bin/sh -c echo "deb http://mirrors.ustc.edu…   304B                
c1a8f5f26eeb        25 hours ago        /bin/sh -c #(nop)  ENV NGINX_VERSION=nginx-1…   0B                  
ad4c705f24d3        2 years ago         /bin/sh -c #(nop)  CMD ["nginx" "-g" "daemon…   0B                  
<missing>           2 years ago         /bin/sh -c #(nop)  STOPSIGNAL SIGQUIT           0B                  
<missing>           2 years ago         /bin/sh -c #(nop)  EXPOSE 80                    0B                  
<missing>           2 years ago         /bin/sh -c #(nop)  ENTRYPOINT ["/docker-entr…   0B                  
<missing>           2 years ago         /bin/sh -c #(nop) COPY file:09a214a3e07c919a…   4.61kB              
<missing>           2 years ago         /bin/sh -c #(nop) COPY file:0fd5fca330dcd6a7…   1.04kB              
<missing>           2 years ago         /bin/sh -c #(nop) COPY file:0b866ff3fc1ef5b0…   1.96kB              
<missing>           2 years ago         /bin/sh -c #(nop) COPY file:65504f71f5855ca0…   1.2kB               
<missing>           2 years ago         /bin/sh -c set -x     && addgroup --system -…   64MB                
<missing>           2 years ago         /bin/sh -c #(nop)  ENV PKG_RELEASE=1~buster     0B                  
<missing>           2 years ago         /bin/sh -c #(nop)  ENV NJS_VERSION=0.6.2        0B                  
<missing>           2 years ago         /bin/sh -c #(nop)  ENV NGINX_VERSION=1.21.3     0B                  
<missing>           2 years ago         /bin/sh -c #(nop)  LABEL maintainer=NGINX Do…   0B                  
<missing>           2 years ago         /bin/sh -c #(nop)  CMD ["bash"]                 0B                  
<missing>           2 years ago         /bin/sh -c #(nop) ADD file:4ff85d9f6aa246746…   69.3MB
```

### 多阶段构建

多阶段构建是指将镜像的编译和运行放在不同的阶段，第一阶段用于编译 Nginx，第二阶段将 Nginx 运行和依赖的包拷贝到该 Base 镜像中。

因为第二阶段只会存在 Nginx 运行和依赖包，所以镜像体积会很小。

但是 Nginx 运行时不仅仅需要编译后的运行二进制、配置文件，同时也需要一些系统依赖包，这些在第二阶段也需要安装。

以下是多阶段构建的 Dockerfile：

```docker
FROM nginx:1.21.3 AS builder
ENV NGINX_VERSION nginx-1.21.3

# wget -O nginx-module-vts.tar.gz https://github.com/vozlt/nginx-module-vts/archive/refs/tags/v0.2.1.tar.gz 
# wget http://nginx.org/download/${NGINX_VERSION}.tar.gz

ADD ${NGINX_VERSION}.tar.gz .
WORKDIR ${NGINX_VERSION}
ADD nginx-module-vts-0.2.1.tar.gz .

RUN echo "deb http://mirrors.ustc.edu.cn/debian buster main contrib non-free" > /etc/apt/sources.list && \
    echo "deb http://mirrors.ustc.edu.cn/debian buster-updates main contrib non-free" >> /etc/apt/sources.list && \
    echo "deb http://mirrors.ustc.edu.cn/debian buster-backports main contrib non-free"  >>  /etc/apt/sources.list && \
    echo "deb http://mirrors.ustc.edu.cn/debian-security/ buster/updates main contrib non-free" >> /etc/apt/sources.list && \
    rm -rf /etc/apt/sources.list.d && \
    apt-get update && apt-get install -y build-essential wget libpcre3 libpcre3-dev zlib1g-dev openssl libssl-dev libxml2 libxml2-dev libxslt-dev && \
    ./configure \
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
        --with-compat \
        --with-file-aio \
        --with-threads \
        --with-http_addition_module \
        --with-pcre-jit \
        --with-http_ssl_module \
        --with-http_stub_status_module \
        --with-http_realip_module \
        --with-http_auth_request_module \
        --with-http_v2_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_slice_module \
        --with-threads \
        --with-http_addition_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_mp4_module \
        --with-http_random_index_module \
        --with-http_sub_module \
        --with-http_xslt_module=dynamic \
        --with-http_secure_link_module \
        --with-http_slice_module \
        --with-stream=dynamic \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --with-cc-opt='-g -O2 -fdebug-prefix-map=/data/builder/debuild/nginx-1.21.3/debian/debuild-base/nginx-1.21.3=. -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC' --with-ld-opt='-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie' \
        --with-mail=dynamic \
        --with-mail_ssl_module \
        --add-module=nginx-module-vts-0.2.1 && \
    make && \
    make install && \
    rm -rf /var/cache/apk/*

# 第二阶段的 base 镜像选择更加精简的镜像
FROM debian:buster-slim
RUN echo "deb http://mirrors.ustc.edu.cn/debian buster main contrib non-free" > /etc/apt/sources.list && \
    echo "deb http://mirrors.ustc.edu.cn/debian buster-updates main contrib non-free" >> /etc/apt/sources.list && \
    echo "deb http://mirrors.ustc.edu.cn/debian buster-backports main contrib non-free"  >>  /etc/apt/sources.list && \
    echo "deb http://mirrors.ustc.edu.cn/debian-security/ buster/updates main contrib non-free" >> /etc/apt/sources.list && \
    rm -rf /etc/apt/sources.list.d && \
    # 安装 nginx 运行的依赖包
    apt-get update && apt-get install -y openssl libssl-dev --no-install-recommends && \
    mkdir -p /var/log/nginx/ && ln -sf /dev/stdout /var/log/nginx/access.log && ln -sf /dev/stderr /var/log/nginx/error.log && \
    useradd -M -s /sbin/nologin nginx && \
    mkdir /var/cache/nginx && \
    rm -rf /var/lib/apt/lists/*

# 从第一阶段拷贝运行包、配置文件
COPY --from=builder /etc/nginx /etc/nginx
COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=builder /usr/lib/nginx/modules /usr/lib/nginx/modules

WORKDIR /etc/nginx
EXPOSE 80 443
STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]
```

构建完会发现体积小几倍

```docker
$ docker images
nginx-vts      v1.21.3.2          3396e0d19b67        1 minutes ago         94.9MB
nginx-vts      v1.21.3.1          3396e0d19b67        36 minutes ago        568MB
```

### 选择精简基础镜像

选择精简的基础镜像会使得镜像非常小，但是也会带来构建过程中缺少依赖包的问题，所以一般选择精简基础镜像会和多阶段构建同时使用。在多阶段构建的第一阶段选择经典的基础镜像，比如：CentOS、Ubuntu 等，然后第二阶段选择精简的基础镜像。

### 启用 squash 特性

通过启用squash特性（实验性功能）`docker build --squash -t curl:v3 .` 可以构建的镜像压缩为一层。但是为了充分发挥容器镜像层共享的优越设计，这种方法不被推荐。

### 编写 .dockerignore

我们经常在编写 Dockerfile 会用到的 COPY 指令

```docker
COPY . /server/dir
```

这个指令会把**整个构建上下文**复制到镜像中，并生产新的缓存层。但是我们也可以使用 COPY 详细文件路径，避免拷贝构建上下文的所有文件。

为了不必要的文件如日志、缓存文件、Git 历史记录被加载到构建上下文，我们最好添加 **.dockerignore** 用于忽略非必须文件。这也是精简镜像关键一步，

**.dockerignore** 写法和 **.gitignore** 差不多

```docker
passphrase.txt
logs/
.git
*.md
.cache
```

**.dockerignore** 实际上和 docker build 后面的 **.** 关系非常大，可以查看 **docker build .** 的作用详细了解

### 及时清理

我们有如下 Dockerfile

```docker

..
WORKDIR /tmp
RUN curl -LO https://docker.com/download.zip && tar -xf download.zip -C /var/www
RUN rm  -f download.zip
...

```

我们虽然使用了`rm` 删除 download.zip 包，由于镜像分层的问题，download.zip 是在新的一层被删除，上一层仍然存在。

我们要在一层中及时清理下载

```docker

RUN curl -LO https://docker.com/download.zip && tar -xf download.zip -C /var/www &&  rm  -f download.zip

```

另外在安装软件时应及时使用包管理工具清除你下载的软件依赖及缓存，比如在我们 Dockerfile 中使用 apt 包管理工具做清理。

## 总结

我们已构建 Nginx 镜像为例，不仅讲解了如何在已有的 Nginx 镜像基础上再次增加第三方模块，同时也讲解了如何精简编译后的镜像体积。以上内容涉及的知识非常干货，在日常工作中使用也很频繁。

减少处理容器镜像时所需的存储空间和带宽的方法有很多，其中最直接的方法就是减小容器镜像本身的大小。在使用容器的过程中，要经常留意容器镜像是否体积过大，根据不同的情况采用

上述提到的清理缓存、压缩到一层、将二进制文件加入在空白镜像中等不同的方法，将容器镜像的体积缩减到一个有效的大小。

但是也不要太过去追求精简镜像的体积，因为会导致镜像的软件包非常少，后面运行过程中排错，运维也会导致很多麻烦。所以只要在能接受范围内即可。

下一篇文章讲讲 “**如何根据 Docker 缓存特性，减少构建时间**” 。