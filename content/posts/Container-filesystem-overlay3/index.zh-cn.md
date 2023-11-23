---
weight: 33
title: "容器的文件系统(二): 存储挂载原理"
date: 2023-11-21T08:57:40+08:00
lastmod: 2023-11-21T08:45:40+08:00
draft: false
author: "孙峰"
resources:
- name: "featured-image"
  src: "closure-home.jpg"

tags: ["Docker", "Container"]
categories: ["Docker", "Container"]

lightgallery: true
---

## 容器的存储卷

前两篇讲解了容器如何使用 **OverlayFS**，那么容器在运行时需要将数据持久化，或者容器内的数据能够进行共享等其他需求，就需要将容器里的文件或者目录与外界进行绑定。这里就涉及到容器的存储挂载，而容器的存储挂载并不是在容器启动时利用 **OverlayFS** 挂载实现的，Docker 为此实现了三种挂载类型：**volume、bvind mount、tmpfs mount。**

下图简单描述了三个挂载类型的区别：

![Untitled](https://prod-files-secure.s3.us-west-2.amazonaws.com/3106f477-4195-4489-a530-4ddcfa60dc35/e8f5cebc-6aaa-4d23-8ca9-914590fa7be8/Untitled.png)

容器使用 **volume** 和 **bind mount** 都可以将容器内的文件或者目录挂载宿主机上，但是 **volume** 可由 Docker 来管理，**bind mount** 是直接与 Linux 原生文件系统对接。**tmpfs** 与 **volume**、**bind mount** 不同的是 **tmpfs** 是将容器内的文件、目录挂载到内存中，不会将数据存放在文件系统中。下面详细看看这三种挂载类型的使用。

## Volumes

使用 **Volume** 持久化数据，那么容器目录对应的宿主机目录是由 Docker 创建和管理的，且数据目录存放在 `/var/lib/docker/volumes` 下面。

### 单机 volume

下面通过示例讲解。

使用 **volume** 创建一个容器。`-v or --volume  volumeName:containerDataPath` 

```bash
$ docker run -d \
	  --name devtest \
	  -v myvol:/app \
	  nginx:latest
```

查看容器信息，可以发现挂载类型是 **volume**。

```bash
$ docker inspect devtest

	"Mounts": [
	    {
	        "Type": "volume",
	        "Name": "myvol",
	        "Source": "/var/lib/docker/volumes/myvol/_data",
	        "Destination": "/app",
	        "Driver": "local",
	        "Mode": "",
	        "RW": true,
	        "Propagation": ""
	    }
	],
```

同时上面容器创建命令也会创建一个名称为 `my-volume` 的 **volume**，该 **volume** 表示容器数据对应的宿主机数据目录存储，存放在 `/var/lib/docker/volumes` 

```bash
$ docker volume ls

	local               myvol
```

查看 **volume** 元数据，我们可以发现这里的 `volume scope` 是 `local`，也就是数据都是持久化在本地。

```bash
$ docker volume inspect myvol
	[
	    {
	        "Driver": "local",
	        "Labels": {},
	        "Mountpoint": "/var/lib/docker/volumes/myvol/_data",
	        "Name": "myvol",
	        "Options": {},
	        "Scope": "local"
	    }
	]
```

**volume** 不仅仅可以实现**单机容器**的数据的持久化，同样也可以实现**跨节点容器**的数据共享。

### 跨节点数据共享

当多个容器运行在不同节点上需要实现数据共享( 这里不考虑 Kubernetes )。在开发应用程序时，有几种方法可以实现这一点。

- 一种是为应用程序添加逻辑，将文件存储在类似 AmazonS3 的云对象存储系统上。
- 另一种方法是使用支持将文件写入 NFS 或 AmazonS3 等外部存储系统的驱动程序创建卷。

**volume driver** 允许从应用程序逻辑中抽象底层存储系统。例如，如果服务使用带有 NFS 驱动程序的卷，则可以更新服务以使用不同的驱动程序。即在不更改应用程序逻辑的情况下将数据存储在云中。

![Untitled](https://prod-files-secure.s3.us-west-2.amazonaws.com/3106f477-4195-4489-a530-4ddcfa60dc35/0a1537bf-37fd-4afb-ab52-bd821c2193a5/Untitled.png)

Docker 支持多种 **volume driver** 来对接不同的存储，下面以 `vieux/sshfs` 为例举例：

首先需要在每个 Docker 节点安装 `vieux/sshfs` 插件

```bash
$ docker plugin install --grant-all-permissions vieux/sshfs
```

创建 `vieux/sshfs` 类型的 **volume driver**。

```bash
$ docker volume create --driver vieux/sshfs \
	  -o sshcmd=test@node2:/home/test \
	  -o password=testpassword \
	  sshvolume
```

使用上面的 **volume** 创建容器

```bash
$ docker run -d \
	  --name sshfs-container \
	  --volume-driver vieux/sshfs \
	  --mount src=sshvolume,target=/app,volume-opt=sshcmd=test@node2:/home/test,volume-opt=password=testpassword \
	  nginx:latest
```

Docker 也支持 `NFS、CIFS、Samba、Block devices` 等其他类型的 **volume driver**。详情可参考 [Docker 官网](https://docs.docker.com/storage/volumes/#use-a-volume-driver)

## Bind mounts

**bind mount** 也是将宿主机上的文件或者目录挂载到容器上。**volume** 底层实现的原理就是用 Linux 的 **bind mount**，只不过 Docker 会帮助用户来管理 **volume** 的存储目录。

使用 **bind mount** 创建一个容器，`-v or --volume  absolutePath:containerDataPath` ，注意 **bind mount** 需要使用宿主机目录路径是**绝对路径**

```bash
$ docker run -d \
	--name volume-test \
	-v "$(pwd)"/data:/data \
	nginx:latest
```

查看容器信息，可以发现挂载类型是 `bind`。

```bash
$ docker inspect devtest

	"Mounts": [
	    {
	        "Type": "bind",
	        "Source": "/tmp/source/target",
	        "Destination": "/app",
	        "Mode": "",
	        "RW": true,
	        "Propagation": "rprivate"
	    }
	],
```

## Tmpfs mounts

**volume** 和 **bind mount** 挂载允许在主机和容器之间共享文件，这样即使在容器停止后也可以持久保存数据。如果容器内某些数据比较敏感，涉及到安全性，不宜存放在容器内或者宿主机的文件系统上，那么可以使用 **tmpfs mount** 将容器的文件数据挂载内存中。

**tmpfs mount** 也是 Linux 中的一种挂载类型，这样这些文件并不会出现在容器的读写层，**tmpfs** 是临时的，并且只保留在主机内存中。当容器停止时，**tmpfs** 挂载将被删除，写入其中的文件将不会持久化。

下面使用 **tmspfs mount** 创建一个容器，`-- tmpfs containerDataPath`

```bash
$ docker run -d \
	  -it \
	  --name tmptest \
	  --tmpfs /app \
	  nginx:latest
```

查看容器挂载信息，发现挂载类型是 **tmpfs**

```bash
$ docker inspect tmptest --format '{{ json .Mounts }}'
[{"Type":"tmpfs","Source":"","Destination":"/app","Mode":"","RW":true,"Propagation":""}]
```

## Volumes 与 Bind mounts 区别

其实 **volume** 底层利用的就是 **bind mount** 技术，最终都是由 Linux bind mount 挂载的。由于 **volume** 可由 Docker 管理，那么 **volume** 相对来说会有更多优势。

- **volume** 的存储目录由 Docker 管理，存储在 `/var/lib/docker/volumes` ，**bind mount** 的存储目录由用户自行指定
- **volume** 可供多个容器共享使用，**bind mount** 对应的存储目录只能由一个容器使用
- **volume** 支持 **volume driver**，**volume driver** 允许在远程主机或云提供商上存储卷，**bind mount** 只作用 Docker 本机
- **volume** 更加容易进行备份和迁移
- 绑定容器中非空目录时，**volume** 可以保留容器中非空目录，然而 **bind mount** 的方式，容器中的非空目录会被覆盖。

对于上面最后一个区别使用例子讲述会比较容易理解。

### **volume 挂载**

使用 **volume** 挂载，如果对应容器中的目录原来就存在文件或者子目录，那么挂在之后，该文件或者子目录依然存在。

这里 `nginx:latest` 镜像中 `/etc/nginx/` 是非空的，发现 **volume** 并没有覆盖 **/etc/nginx** 

```bash
$ docker run -d \
	  -it \
	  --name volume-test \
	  -v /tmp/nginx:/etc/nginx \
	  nginx:latest  
$ docker exec -it volume-test ls /etc/nginx/
conf.d                  koi-utf             nginx.conf.default
fastcgi.conf            koi-win             scgi_params
fastcgi.conf.default    mime.types          scgi_params.default
fastcgi_params          mime.types.default  uwsgi_params
fastcgi_params.default  modules             uwsgi_params.default
html                    nginx.conf          win-utf
```

### **bind mount**

使用 **bind mount**，如果对应容器中的目录原来就存在文件或者子目录，那么挂在之后，该文件或者子目录会被挂载目录**覆盖**。

这里 `nginx:latest` 镜像中 `/usr/share/nginx/html` 是非空的

```bash
$ docker run -d \
	  -it \
	  --name bind-mount-test \
	  -v /tmp/nginx:/etc/nginx \
	  nginx:latest  
```

会发现该容器无法启动，报错信息：`无法找到 /etc/nginx/nginx.conf`，说明 `/etc/nginx` 下已经被 **bind mount** 覆盖了。

## Bind mount 与 OverlayFS

前面说到容器使用 **OverlayFS** 实现文件系统，上面说的 **volume** 底层用到了 **bind mount** 将宿主机文件或者目录挂载到容器中，那么 **bind mount** 和 **OverlayFS** 有什么区别和联系？

我们知道 Linux 有很多种类型的 mount，**bind mount** 和 **OverlayFS** 都属于 Linux mount 类型。

在 Docker 使用 **volume** 或者 **bind mount** 创建一个容器时，会经历以下挂载流程：

- 使用 **OverlayFS** 挂载将各层镜像联合挂载起来，并形成容器层；
- 使用 **bind mount** 技术将宿主机存储目录挂载到容器内部；

所以说容器 **volume** 的挂载并不是在镜像联合挂载时实现的，而是在其之后使用 **bind mount** 进行挂载。

## 总结

本篇文章讲解了 Docker 三种存储挂载类型：**volume，bind mount，tmpfs mount** 的使用、原理，同时也分别阐述了三种挂载类型的使用场景和区别。

对于 **volume** 和 **bind mount** 两种类型底层原理是一样的，但是 **volume** 比 **bind mount** 具有更多优势，所以在实际使用中建议使用 **volume** 类型。

最后对 **bind mount** 和 **OverlayFS** 进行了比较，这两个都是 Linux 的**挂载类型**，Docker 使用 **OverlayFS** 将镜像联合挂载形成容器，而使用 **bind mount** 对容器进行数据挂载实现数据持久化和数据共享。