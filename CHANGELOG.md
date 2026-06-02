2026.06.02
- 统一使用 `noninteractive=true` 作为安装、批量创建、卸载的无交互开关
- 批量创建支持环境变量传参，并一次性收集容器名与端口占用，避免重复查询
- 修复批量创建失败后仍写入 ctlog 的问题
- 修复镜像 tar 加载后可能错误标记本地其他镜像的问题
- 加强单容器创建的参数、端口、容器名、密码传递边界校验
- 修复 btrfs loop 重跑安装时可能覆盖已有 loop 文件的问题
- 修正 IPv6 网络 `/96`、`/80`、`/64` 前缀回退逻辑
- 调整安装流程，先安装基础依赖再检测网络与 IPv6，并兼容 `python`/`python3`
- 修复 IPv6 网络或 NDP responder 启动失败时仍写入启用状态的问题
- 卸载时保留非 Podman iptables 规则，仅持久化 Podman 网络删除后的当前状态

2026.03.10
- 新增环境变量 WITHOUTCDN=TRUE：可完全禁用 CDN 加速
- 覆盖 podmaninstall.sh、scripts/onepodman.sh、scripts/create_podman.sh
- 设置后脚本执行过程中不再进行 CDN 探测与 CDN 地址请求，统一走直连地址

2026.03.01
- 初始化仓库，对应 oneclickvirt/containerd 实现 podman 版本
- 实现 podmaninstall.sh：一键安装 podman + 配置网络、内核参数、DNS保活服务
- 实现 scripts/onepodman.sh：单个容器开设脚本，支持 ubuntu/debian/alpine/almalinux/rockylinux/openeuler
- 实现 scripts/create_podman.sh：交互式批量容器开设脚本，记录至 ctlog 日志
- 实现 scripts/ssh_bash.sh：容器内 SSH 初始化（bash 系统，Debian/Ubuntu/RHEL 系）
- 实现 scripts/ssh_sh.sh：容器内 SSH 初始化（sh，Alpine 专用）
- 实现 dockerfiles/ 各系统 Dockerfile + entrypoint 脚本，支持 amd64 和 arm64 双架构
- 实现 .github/workflows/podman_build.yml：使用 Buildah 自动构建镜像 tar 并发布到 GitHub Releases 及 ghcr.io
- 支持公网 IPv6 检测，自动创建 podman-ipv6 双栈网络，启动 NDP Responder 实现独立 IPv6
- 支持国内 CDN 镜像加速（cdn.spiritlhl.net）
- 支持 lxcfs 挂载（若宿主机安装了 lxcfs，提供容器内真实 /proc 视图）
- 支持磁盘限制参数（需 overlay on xfs 支持 storage-opt）
- Podman daemonless 架构，无需 containerd/Docker 守护进程
