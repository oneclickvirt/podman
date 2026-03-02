# podman

[![Hits](https://hits.spiritlhl.net/podman.svg)](https://hits.spiritlhl.net/podman)

基于 Podman 的容器环境一键安装与管理脚本

支持一键安装 Podman 运行时，并开设基于本仓库编译镜像的各种 Linux 容器（提供 SSH 访问），支持 IPv6、端口映射、资源限制等。

## 说明

- 使用各发行版官方软件包安装 Podman（无守护进程，daemonless 架构）
- 使用本仓库自编译的基础镜像（存储在 GitHub Releases），优先离线加载，无法获取时回退到 ghcr.io 镜像
- 支持系统：Ubuntu 22.04、Debian 12、Alpine、AlmaLinux 9、RockyLinux 9、OpenEuler 22.03
- 支持架构：amd64、arm64

## 安装 Podman 环境

```bash
bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/podman/main/podmaninstall.sh)
```

## 开设单个容器

```bash
# 下载脚本
wget -q https://raw.githubusercontent.com/oneclickvirt/podman/main/scripts/onepodman.sh
chmod +x onepodman.sh

# 用法:
# ./onepodman.sh <name> <cpu> <memory_mb> <password> <sshport> <startport> <endport> [ipv6:y/n] [system] [disk_gb]

# 示例: 创建名为 ct1 的 Debian 容器，1核 512MB，SSH端口25000，额外端口34975-35000
./onepodman.sh ct1 1 512 MyPassword 25000 34975 35000 n debian 0
```

| 参数 | 说明 | 默认值 |
|------|------|--------|
| name | 容器名称 | test |
| cpu | CPU 核数（支持 0.5 等） | 1 |
| memory_mb | 内存限制（MB） | 512 |
| password | root 密码 | 123456 |
| sshport | SSH 端口（宿主机→容器 22） | 25000 |
| startport | 公网端口范围起始 | 34975 |
| endport | 公网端口范围结束 | 35000 |
| ipv6 | 是否分配独立 IPv6（y/n） | n |
| system | 镜像系统 | debian |
| disk_gb | 磁盘限制 GB（0=不限制） | 0 |

**支持的 system 参数：** `ubuntu` / `debian` / `alpine` / `almalinux` / `rockylinux` / `openeuler`

## 批量开设容器

```bash
wget -q https://raw.githubusercontent.com/oneclickvirt/podman/main/scripts/create_podman.sh
chmod +x create_podman.sh
./create_podman.sh
```

交互式脚本，自动递增容器名（ct1, ct2, ...）、SSH 端口、公网端口，容器信息记录到 `ctlog` 文件。

## 查看与管理容器

```bash
podman ps -a                  # 查看所有容器
podman exec -it <name> bash   # 进入容器（bash 系统）
podman exec -it <name> sh     # 进入容器（alpine）
podman logs <name>            # 查看容器日志
podman rm -f <name>           # 删除单个容器
podman images                 # 查看所有镜像
podman rmi <image>            # 删除镜像
```

## 卸载（完整清理）

一键卸载 Podman 全套环境，包括所有容器、镜像、网络、辅助文件：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/podman/main/podmanuninstall.sh)
```

脚本会在执行前要求输入 `yes` 确认，操作不可逆。

## 镜像说明

本仓库自编镜像通过 GitHub Actions 使用 Podman/Buildah 构建，发布到 Releases 及 ghcr.io：

| 系统 | amd64 | arm64 |
|------|-------|-------|
| Ubuntu 22.04 | spiritlhl_ubuntu_amd64.tar.gz | spiritlhl_ubuntu_arm64.tar.gz |
| Debian 12 | spiritlhl_debian_amd64.tar.gz | spiritlhl_debian_arm64.tar.gz |
| Alpine latest | spiritlhl_alpine_amd64.tar.gz | spiritlhl_alpine_arm64.tar.gz |
| AlmaLinux 9 | spiritlhl_almalinux_amd64.tar.gz | spiritlhl_almalinux_arm64.tar.gz |
| RockyLinux 9 | spiritlhl_rockylinux_amd64.tar.gz | spiritlhl_rockylinux_arm64.tar.gz |
| OpenEuler 22.03 | spiritlhl_openeuler_amd64.tar.gz | spiritlhl_openeuler_arm64.tar.gz |

同时推送至 ghcr.io，支持 multi-arch manifest：
- `ghcr.io/oneclickvirt/podman:<os>-amd64`
- `ghcr.io/oneclickvirt/podman:<os>-arm64`
- `ghcr.io/oneclickvirt/podman:<os>`（multi-arch manifest list）

## 网络说明

- IPv4 网络名: `podman-net`，bridge: `podman-br0`，subnet: `172.20.0.0/16`
- IPv6 双栈网络名: `podman-ipv6`，bridge: `podman-br1`，包含 172.21.0.0/16 + 公网 IPv6 /80 子网
- 与 containerd/docker 版本完全隔离，互不干扰

## 与 containerd/docker 版本对比

| 特性 | 本项目（Podman） | oneclickvirt/containerd | oneclickvirt/docker |
|------|----------------|------------------------|---------------------|
| 守护进程 | 无（daemonless） | containerd | Docker daemon |
| 运行时 | crun/runc | runc | runc |
| rootless 支持 | 原生支持 | 不支持 | 需配置 |
| 镜像格式 | OCI | OCI | OCI |
| 网络后端 | netavark/CNI | CNI | Docker bridge |
| 构建工具 | Buildah/podman-build | buildkitd | Docker buildx |
| 安装方式 | 系统包管理器 | nerdctl-full bundle | Docker 官方脚本 |