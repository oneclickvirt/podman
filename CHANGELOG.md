2026.07.23
- 修复批量创建在 btrfs 环境传递 `--storage-opt size=...` 导致 Podman 报 `unknown option size` 的问题
- 单容器和批量创建统一改用 btrfs qgroup 设置容器 rootfs 磁盘上限，配额应用失败时自动删除未启动容器
- 批量创建每次原子刷新缓存的 `onepodman.sh`，避免服务器残留旧脚本导致修复未生效

2026.06.04
- 调整容器镜像获取顺序为 GHCR/自定义镜像仓库优先，失败后回退 GitHub Releases 离线包
- 修复 `PODMAN_INSTALL_PATH` 未写入 root Podman `storage.conf` 的问题，并使用 `graphroot` 键对齐 containers/storage 配置
- 在 systemd 环境缺失 `podman-restart.service` 时创建兜底服务，确保 `--restart always` 容器在 daemonless 模式下可随系统启动
- 修复兜底 `podman-restart.service` 的 `$id` 引用，卸载时仅停用并清理本项目生成的 unit，避免影响发行版自带 unit
- 批量创建时校验 `onepodman.sh` 下载/复制结果，避免 rootless 失败路径误落到 `/root`
- 单容器和批量创建统一规范化系统参数，支持 `debian12`、`debian/12`、`ubuntu22.04` 等版本写法，避免已支持镜像被误判为无效
- CDN 探测在缺少 `shuf` 时回退到固定顺序，DNS 保活在缺少 `nslookup` 时回退到 `getent`/`ping`
- 单容器创建增加 SSH 端口与公网端口范围重叠校验，并修正 pod join 场景的宿主端口冲突检查
- 单容器和批量创建脚本移除 Bash 4 专用关联数组与小写展开，提升旧 Bash 环境下的可验证性

2026.06.03
- 新增 `.gitignore`，排除环境变量、数据库、密钥、密码文件、截图、容器记录和构建产物
- 移除单容器创建的固定默认弱密码，未传或传空字符串时自动生成随机密码
- 移除容器内 SSH 初始化脚本的固定弱密码兜底，缺少密码时直接失败
- 密码写入统一使用 `printf | chpasswd`，避免 `echo` 对特殊字符处理不一致
- 批量创建密码升级为随机生成，保持 ctlog 可解析
- GitHub Actions 增加 `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24`、workflow/job concurrency 和 timeout-minutes
- GitHub Actions 升级 `actions/checkout@v6`、`docker/setup-qemu-action@v4` 与 `softprops/action-gh-release@v3`
- 移除安装脚本中的 `eval` 包管理更新路径，改为显式函数
- 单容器创建默认写入 `ctlog`，批量创建使用临时记录文件后立即归档，减少密码记录散落
- 镜像 tar 下载与 IPv6 网络创建错误日志改为进程隔离临时文件，避免并发复用污染
- 新增 `PODMAN_RELEASE_BASE_URL`、`PODMAN_GHCR_IMAGE`、`PODMAN_SCRIPT_BASE_URL` 自定义源配置
- 新增受控 `PODMAN_ROOTLESS` 创建模式与安装阶段 `PODMAN_ROOTLESS_USER` rootless 预配置
- 新增 `PODMAN_POD_NAME` / `PODMAN_POD_JOIN_EXISTING` 可选 Podman pod 网络支持
- README 增加 5 步快速开始、Mermaid 架构图和补充环境变量说明

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
- 支持 btrfs qgroup 容器磁盘限制参数
- Podman daemonless 架构，无需 containerd/Docker 守护进程
