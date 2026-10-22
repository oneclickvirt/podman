# podman

[![Hits](https://hits.spiritlhl.net/podman.svg)](https://hits.spiritlhl.net/podman)

基于 Podman 的容器环境一键安装与管理脚本

支持一键安装 Podman 运行时，并开设基于本仓库编译镜像的各种 Linux 容器（提供 SSH 访问），支持 IPv6、端口映射、资源限制等。

## 更新

[更新日志](CHANGELOG.md)

## 说明文档

国内(China Docs)：

[https://virt.spiritlhl.net/guide/podman/podman_precheck.html](https://virt.spiritlhl.net/guide/podman/podman_precheck.html)

国际(English Docs)：

[https://www.spiritlhl.net/en/guide/podman/podman_precheck.html](https://www.spiritlhl.net/en/guide/podman/podman_precheck.html)

说明文档中 Podman 分区内容

## 说明

- 使用各发行版官方软件包安装 Podman（无守护进程，daemonless 架构）
- 使用本仓库自编译的基础镜像，优先从 ghcr.io 拉取，无法获取时回退到 GitHub Releases 离线包
- 支持系统：Ubuntu 22.04、Debian 12、Alpine、AlmaLinux 9、RockyLinux 9、OpenEuler 22.03
- 支持架构：amd64、arm64
