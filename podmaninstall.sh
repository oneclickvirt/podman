#!/bin/bash
# from
# https://github.com/oneclickvirt/podman
# 2026.03.01

_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
export DEBIAN_FRONTEND=noninteractive

WITHOUT_CDN=false
case "${WITHOUTCDN:-}" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Yy]) WITHOUT_CDN=true ;;
esac

utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
    _yellow "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
fi

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi
if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi

# ======== 系统检测 ========
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch" "Alpine")
PACKAGE_UPDATE=(
    "! apt-get update && apt-get --fix-broken install -y && apt-get update"
    "apt-get update"
    "yum -y update"
    "yum -y update"
    "yum -y update"
    "pacman -Sy"
    "apk update"
)
PACKAGE_INSTALL=(
    "apt-get -y install"
    "apt-get -y install"
    "yum -y install"
    "yum -y install"
    "yum -y install"
    "pacman -Sy --noconfirm"
    "apk add --no-cache"
)

CMD=(
    "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)"
    "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)"
    "$(lsb_release -sd 2>/dev/null)"
    "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)"
    "$(grep . /etc/redhat-release 2>/dev/null)"
    "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')"
    "$(grep . /etc/alpine-release 2>/dev/null)"
)
SYS="${CMD[0]}"
[[ -n $SYS ]] || SYS="${CMD[1]}"
[[ -n $SYS ]] || SYS="${CMD[2]}"
[[ -n $SYS ]] || SYS="${CMD[3]}"
[[ -n $SYS ]] || SYS="${CMD[4]}"
[[ -n $SYS ]] || SYS="${CMD[5]}"
[[ -n $SYS ]] || SYS="${CMD[6]}"
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done
if [[ -z $SYSTEM ]]; then
    _red "ERROR: The script does not support the current system!"
    exit 1
fi

# ======== 架构检测 ========
ARCH_UNAME=$(uname -m)
case "$ARCH_UNAME" in
    x86_64)  ARCH_TYPE="amd64" ;;
    aarch64) ARCH_TYPE="arm64" ;;
    armv7l)  ARCH_TYPE="arm"   ;;
    *)
        _red "Unsupported arch: $ARCH_UNAME"
        exit 1
        ;;
esac

_blue "Detected system: $SYSTEM  arch: $ARCH_TYPE"

# ======== CDN 检测 ========
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
cdn_success_url=""

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls
    shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}"))
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
        if curl -4 -sL -k "${cdn_url}${o_url}" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

check_cdn_file() {
    if [[ "$WITHOUT_CDN" == "true" ]]; then
        export cdn_success_url=""
        _yellow "WITHOUTCDN enabled, CDN acceleration disabled, using direct connection"
        return
    fi
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _yellow "CDN available, using CDN: $cdn_success_url"
    else
        _yellow "No CDN available, using direct connection"
    fi
}

check_cdn_file

# ======== 工具函数 ========
update_sysctl() {
    local key="${1%%=*}"
    local val="${1##*=}"
    if grep -q "^${key}" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s|^${key}.*|${key}=${val}|g" /etc/sysctl.conf
    else
        echo "${key}=${val}" >> /etc/sysctl.conf
    fi
    sysctl -w "${key}=${val}" >/dev/null 2>&1 || true
}

is_private_ipv6() {
    local addr="$1"
    [[ "$addr" =~ ^fd ]] && return 0
    [[ "$addr" =~ ^fc ]] && return 0
    [[ "$addr" =~ ^fe[89ab] ]] && return 0
    [[ "$addr" =~ ^::1$ ]] && return 0
    return 1
}

# ======== 存储驱动检测与 btrfs 配置 ========
check_storage_driver_support() {
    local driver="$1"
    case "$driver" in
        "btrfs")
            if command -v btrfs >/dev/null 2>&1; then
                modprobe btrfs 2>/dev/null || true
                return 0
            fi
            return 1
            ;;
        *) return 1 ;;
    esac
}

setup_podman_btrfs_loop() {
    local pool_size_gb="$1"
    local loop_file="$2"
    local mount_point="$3"
    _yellow "Setting up Podman btrfs loop filesystem..."
    local loop_dir
    loop_dir=$(dirname "$loop_file")
    [[ ! -d "$loop_dir" ]] && mkdir -p "$loop_dir"

    # 若 loop 文件已存在且已挂载，跳过格式化
    if [[ -f "$loop_file" ]] && losetup -j "$loop_file" 2>/dev/null | grep -q "$loop_file"; then
        _green "Loop file $loop_file already exists and is attached, skipping creation."
        local loop_device
        loop_device=$(losetup -j "$loop_file" | cut -d: -f1)
        mkdir -p "$mount_point"
        mount "$loop_device" "$mount_point" 2>/dev/null || true
        echo "$loop_device" > /usr/local/bin/podman_loop_device
        echo "$loop_file"   > /usr/local/bin/podman_loop_file
        echo "$mount_point" > /usr/local/bin/podman_mount_point
        return 0
    fi

    if [[ -d "$mount_point" ]] && [[ "$(ls -A "$mount_point" 2>/dev/null)" ]]; then
        _yellow "Backing up existing Podman data..."
        mv "$mount_point" "${mount_point}.backup.$(date +%Y%m%d-%H%M%S)"
    fi

    _yellow "Creating ${pool_size_gb}GB loop file at $loop_file..."
    fallocate -l "${pool_size_gb}G" "$loop_file"
    local loop_device
    loop_device=$(losetup --find --show "$loop_file")
    _green "Loop device created: $loop_device"

    _yellow "Formatting $loop_device as btrfs..."
    mkfs.btrfs -f "$loop_device"
    mkdir -p "$mount_point"
    mount "$loop_device" "$mount_point"
    if ! grep -q "$loop_file" /etc/fstab; then
        echo "$loop_file $mount_point btrfs loop,defaults 0 0" >> /etc/fstab
    fi
    chmod 755 "$mount_point"
    _green "Podman btrfs loop filesystem setup completed"
    echo "$loop_device" > /usr/local/bin/podman_loop_device
    echo "$loop_file"   > /usr/local/bin/podman_loop_file
    echo "$mount_point" > /usr/local/bin/podman_mount_point
}

try_podman_storage_drivers() {
    podman_need_disk_limit="false"
    if [[ -f /usr/local/bin/podman_need_disk_limit ]]; then
        podman_need_disk_limit=$(cat /usr/local/bin/podman_need_disk_limit)
    fi
    if [[ "$podman_need_disk_limit" != "true" ]]; then
        echo "overlay" > /usr/local/bin/podman_storage_driver
        _green "Using overlay storage driver (standard, no disk size limitation)"
        return 0
    fi

    # 安装 btrfs 工具
    _yellow "Installing btrfs-progs for disk size limitation support..."
    case $SYSTEM in
        Debian|Ubuntu) ${PACKAGE_INSTALL[int]} btrfs-progs 2>/dev/null || true ;;
        CentOS|Fedora) ${PACKAGE_INSTALL[int]} btrfs-progs 2>/dev/null || true ;;
        Alpine)        apk add --no-cache btrfs-progs 2>/dev/null || true ;;
        Arch)          pacman -Sy --noconfirm btrfs-progs 2>/dev/null || true ;;
    esac
    modprobe btrfs 2>/dev/null || true

    if check_storage_driver_support "btrfs"; then
        echo "btrfs" > /usr/local/bin/podman_storage_driver
        _green "btrfs storage driver available, disk size limitation is supported"
    else
        _yellow "btrfs module could not be loaded; a reboot may be required."
        echo "btrfs" > /usr/local/bin/podman_storage_reboot
        echo "overlay" > /usr/local/bin/podman_storage_driver
        _yellow "Falling back to overlay for now. Reboot and re-run to activate btrfs."
    fi
}

# ======== 网络接口检测 ========
detect_interface() {
    # 优先用 ip route get 8.8.8.8 获取出口网卡（最精准）
    interface=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    # 回退：默认路由
    if [[ -z "$interface" ]]; then
        interface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    fi
    # 再回退：第一个非 lo 接口
    if [[ -z "$interface" ]]; then
        interface=$(ip link show | awk '/^[0-9]+: /{gsub(":","",$2); if($2!="lo") {print $2; exit}}')
    fi
    _blue "Detected interface: ${interface:-unknown}"
    echo "${interface:-}" > /usr/local/bin/podman_main_interface

    # 保存宿主机公网 IPv4（供容器创建脚本展示 SSH 连接信息用）
    if [[ ! -f /usr/local/bin/podman_main_ipv4 ]]; then
        local main_ipv4
        main_ipv4=$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
        echo "${main_ipv4:-}" > /usr/local/bin/podman_main_ipv4
    fi
}

# ======== IPv6 检测 ========
check_ipv6() {
    IPV6=""
    IPV6_ENABLED=false
    # 先从本地网卡检测公网 IPv6
    local candidates
    candidates=$(ip -6 addr show scope global 2>/dev/null | grep "inet6" | awk '{print $2}' | cut -d/ -f1 || true)
    for addr in $candidates; do
        if ! is_private_ipv6 "$addr"; then
            IPV6="$addr"
            IPV6_ENABLED=true
            break
        fi
    done
    # 本地未检测到时，向外部 API 查询（处理部分 VPS IPv6 无 global scope 的情况）
    if [[ -z "$IPV6" ]]; then
        _yellow "No public IPv6 on local interfaces, trying external APIs..."
        local API_NET=("ipv6.ip.sb" "https://ipget.net" "ipv6.ping0.cc" "https://api.my-ip.io/ip" "https://ipv6.icanhazip.com")
        for p in "${API_NET[@]}"; do
            local response
            response=$(curl -sLk6m8 "$p" 2>/dev/null | tr -d '[:space:]')
            if [[ $? -eq 0 ]] && [[ -n "$response" ]] && ! echo "$response" | grep -qi "error"; then
                # 验证是否为合法 IPv6 地址
                if python3 -c "import ipaddress; ipaddress.IPv6Address('${response}')" 2>/dev/null; then
                    if ! is_private_ipv6 "$response"; then
                        IPV6="$response"
                        IPV6_ENABLED=true
                        break
                    fi
                fi
            fi
            sleep 1
        done
    fi
    if [[ "$IPV6_ENABLED" == true ]]; then
        _green "Public IPv6 detected: $IPV6"
        # 保存 IPv6 地址供容器创建脚本使用
        echo "$IPV6" > /usr/local/bin/podman_check_ipv6
    else
        _yellow "No public IPv6 found, skipping IPv6 network setup"
        echo "" > /usr/local/bin/podman_check_ipv6
    fi
}

# ======== 安装基础依赖 ========
install_base_deps() {
    _yellow "Installing base dependencies..."
    case $SYSTEM in
        Debian|Ubuntu)
            eval "${PACKAGE_UPDATE[int]}" 2>/dev/null || true
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates iptables iproute2 \
                socat unzip tar jq 2>/dev/null || true
            ;;
        CentOS|Fedora)
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates iptables iproute \
                socat unzip tar jq 2>/dev/null || true
            ;;
        Alpine)
            ${PACKAGE_UPDATE[int]} 2>/dev/null || true
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates iptables iproute2 \
                socat unzip tar jq 2>/dev/null || true
            ;;
    esac
    _green "Base dependencies installed"
}

# ======== 安装 Podman ========
install_podman() {
    _yellow "Installing Podman..."

    if command -v podman >/dev/null 2>&1; then
        local _pver
        _pver=$(podman --version 2>/dev/null || true)
        if [[ -n "$_pver" ]]; then
            _green "Podman already installed: ${_pver}"
        else
            _green "Podman already installed (version check skipped before storage init)"
        fi
        return 0
    fi

    case $SYSTEM in
        Ubuntu)
            eval "${PACKAGE_UPDATE[int]}" 2>/dev/null || true
            # Ubuntu 22.04+ 直接有 podman
            ${PACKAGE_INSTALL[int]} podman 2>/dev/null || true
            # 若版本过旧则添加 kubic 源
            if ! command -v podman >/dev/null 2>&1; then
                . /etc/os-release
                echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/ /" \
                    > /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
                curl -L "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/Release.key" | apt-key add - 2>/dev/null || true
                apt-get update 2>/dev/null || true
                ${PACKAGE_INSTALL[int]} podman 2>/dev/null || true
            fi
            ;;
        Debian)
            eval "${PACKAGE_UPDATE[int]}" 2>/dev/null || true
            ${PACKAGE_INSTALL[int]} podman 2>/dev/null || true
            if ! command -v podman >/dev/null 2>&1; then
                . /etc/os-release
                echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/Debian_${VERSION_ID}/ /" \
                    > /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
                curl -L "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/Debian_${VERSION_ID}/Release.key" | apt-key add - 2>/dev/null || true
                apt-get update 2>/dev/null || true
                ${PACKAGE_INSTALL[int]} podman 2>/dev/null || true
            fi
            ;;
        CentOS)
            # RHEL/AlmaLinux/Rocky/CentOS 8+
            dnf install -y podman 2>/dev/null || yum install -y podman 2>/dev/null || true
            ;;
        Fedora)
            dnf install -y podman 2>/dev/null || true
            ;;
        Alpine)
            apk update 2>/dev/null || true
            apk add --no-cache podman fuse-overlayfs 2>/dev/null || true
            ;;
        Arch)
            pacman -Sy --noconfirm podman 2>/dev/null || true
            ;;
    esac

    if command -v podman >/dev/null 2>&1; then
        _green "Podman installed: $(podman --version)"
    else
        _red "Podman installation failed, please install manually"
        exit 1
    fi
}

# ======== 配置 Podman 存储 ========
configure_podman_storage() {
    _yellow "Configuring Podman storage..."
    mkdir -p /etc/containers

    # 读取存储驱动配置（由 try_podman_storage_drivers 写入）
    local storage_driver="overlay"
    if [[ -f /usr/local/bin/podman_storage_driver ]]; then
        storage_driver=$(cat /usr/local/bin/podman_storage_driver)
    fi

    # 读取 btrfs 挂载点（存储根目录）
    local graph_root="/var/lib/containers/storage"
    if [[ "$storage_driver" == "btrfs" ]] && [[ -f /usr/local/bin/podman_mount_point ]]; then
        local _mp
        _mp=$(cat /usr/local/bin/podman_mount_point)
        [[ -n "$_mp" ]] && graph_root="$_mp"
    fi

    # 配置 containers.conf
    if [[ ! -f /etc/containers/containers.conf ]]; then
        cat > /etc/containers/containers.conf <<'EOF'
[containers]
default_capabilities = [
    "CHOWN",
    "DAC_OVERRIDE",
    "FOWNER",
    "FSETID",
    "KILL",
    "MKNOD",
    "NET_BIND_SERVICE",
    "SETFCAP",
    "SETGID",
    "SETPCAP",
    "SETUID",
    "SYS_CHROOT",
    "NET_RAW",
    "NET_ADMIN",
]

[network]
network_backend = "netavark"

[engine]
cgroup_manager = "systemd"
events_logger = "journald"
EOF
    fi

    # 配置 storage.conf（覆盖写入，确保驱动与路径正确）
    cat > /etc/containers/storage.conf <<EOF
[storage]
driver = "${storage_driver}"
runroot = "/run/containers/storage"
graphRoot = "${graph_root}"

[storage.options]
additionalimagestores = []

[storage.options.overlay]
mountopt = "nodev"
EOF

    if [[ "$storage_driver" == "btrfs" ]]; then
        _green "Podman storage configured: driver=btrfs, graphRoot=${graph_root}  (disk size limitation ENABLED)"
    else
        _green "Podman storage configured: driver=overlay (standard, no disk size limitation)"
    fi

    # 配置 registries.conf（添加默认搜索路径）
    if [[ ! -f /etc/containers/registries.conf ]]; then
        cat > /etc/containers/registries.conf <<'EOF'
unqualified-search-registries = ["docker.io", "ghcr.io", "quay.io"]

[[registry]]
prefix = "docker.io"
insecure = false
blocked = false

[[registry]]
prefix = "ghcr.io"
insecure = false
blocked = false
EOF
    fi

    # 确保 overlay 内核模块加载
    modprobe overlay 2>/dev/null || true

    _green "Podman storage configured"
}

# ======== 配置内核参数 ========
configure_kernel() {
    _yellow "Configuring kernel parameters..."
    modprobe overlay 2>/dev/null || true
    modprobe br_netfilter 2>/dev/null || true
    update_sysctl "net.ipv4.ip_forward=1"
    update_sysctl "net.bridge.bridge-nf-call-iptables=1"
    update_sysctl "net.bridge.bridge-nf-call-ip6tables=1"
    update_sysctl "kernel.unprivileged_userns_clone=1"
    sysctl --system >/dev/null 2>&1 || true
    _green "Kernel parameters configured"
}

# ======== 创建 Podman IPv4 网络 ========
create_podman_network() {
    _yellow "Creating Podman IPv4 network (podman-net)..."

    if podman network exists podman-net 2>/dev/null; then
        _green "podman-net already exists"
        return 0
    fi

    podman network create \
        --driver bridge \
        --interface-name podman-br0 \
        --subnet 172.20.0.0/16 \
        --gateway 172.20.0.1 \
        podman-net 2>/dev/null || \
    podman network create \
        --driver bridge \
        --subnet 172.20.0.0/16 \
        --gateway 172.20.0.1 \
        podman-net 2>/dev/null || true

    if podman network exists podman-net 2>/dev/null; then
        _green "podman-net created (172.20.0.0/16)"
    else
        _yellow "Warning: podman-net creation may have failed, check manually"
    fi
}

# ======== 配置 IPv6 内核参数 ========
adapt_ipv6() {
    _yellow "Configuring IPv6 kernel parameters..."
    update_sysctl "net.ipv6.conf.all.forwarding=1"
    update_sysctl "net.ipv6.conf.default.proxy_ndp=1"
    update_sysctl "net.ipv6.conf.all.proxy_ndp=1"
    if [[ -n "$interface" ]]; then
        update_sysctl "net.ipv6.conf.${interface}.proxy_ndp=1"
    fi
    sysctl --system >/dev/null 2>&1 || true
}

# ======== 创建 Podman IPv6 双栈网络 ========
create_ipv6_network() {
    local ipv6_addr="$1"
    _yellow "Creating Podman IPv6 dual-stack network (podman-ipv6)..."

    if podman network exists podman-ipv6 2>/dev/null; then
        _green "podman-ipv6 already exists"
        return 0
    fi

    # 依次尝试 /96 → /80 → /64，选取 netavark 支持的最小前缀
    local prefix=""
    for _plen in 96 80 64; do
        if command -v python3 >/dev/null 2>&1; then
            prefix=$(python3 -c "
import ipaddress, sys
try:
    addr = ipaddress.ip_address('${ipv6_addr}')
    net = ipaddress.ip_network(str(addr) + '/${_plen}', strict=False)
    print(str(net))
except Exception:
    sys.exit(1)
" 2>/dev/null || true)
        fi
        if [[ -z "$prefix" ]]; then
            # awk 回退：取前4段作为前缀
            local _seg4
            _seg4=$(echo "$ipv6_addr" | awk -F: '{print $1":"$2":"$3":"$4}')
            prefix="${_seg4}::/${_plen}"
        fi
        [[ -n "$prefix" ]] && break
    done

    echo "$prefix" > /usr/local/bin/podman_ipv6_subnet
    _yellow "IPv6 subnet for podman-ipv6: ${prefix}"

    # 尝试1：带 interface-name，--ipv6 先于 subnet（netavark 推荐顺序）
    if podman network create \
        --driver bridge \
        --ipv6 \
        --interface-name podman-br1 \
        --subnet 172.21.0.0/16 \
        --gateway 172.21.0.1 \
        --subnet "${prefix}" \
        podman-ipv6 2>/tmp/podman_net_err; then
        _green "podman-ipv6 created (attempt 1): IPv4=172.21.0.0/16, IPv6=${prefix}"
        return 0
    fi
    _yellow "Attempt 1 failed: $(cat /tmp/podman_net_err 2>/dev/null)"

    # 尝试2：不带 interface-name
    if podman network create \
        --driver bridge \
        --ipv6 \
        --subnet 172.21.0.0/16 \
        --gateway 172.21.0.1 \
        --subnet "${prefix}" \
        podman-ipv6 2>/tmp/podman_net_err; then
        _green "podman-ipv6 created (attempt 2): IPv4=172.21.0.0/16, IPv6=${prefix}"
        return 0
    fi
    _yellow "Attempt 2 failed: $(cat /tmp/podman_net_err 2>/dev/null)"

    # 尝试3：仅 IPv6 子网（不含 IPv4 双栈）
    if podman network create \
        --driver bridge \
        --ipv6 \
        --subnet "${prefix}" \
        podman-ipv6 2>/tmp/podman_net_err; then
        _green "podman-ipv6 created (attempt 3, IPv6-only): IPv6=${prefix}"
        return 0
    fi
    _yellow "Attempt 3 failed: $(cat /tmp/podman_net_err 2>/dev/null)"

    _yellow "Warning: podman-ipv6 creation failed, check manually"
    return 1
}

# ======== 启动 NDP Responder ========
start_ndpresponder() {
    _yellow "Starting NDP responder for IPv6..."
    local arch_tag
    case "$ARCH_TYPE" in
        amd64) arch_tag="x86" ;;
        arm64) arch_tag="arm64" ;;
        *)     arch_tag="x86" ;;
    esac

    local ndp_image="spiritlhl/ndpresponder_${arch_tag}"

    podman rm -f ndpresponder 2>/dev/null || true

    # 预先拉取镜像，避免 podman run 超时
    _yellow "Pulling ndpresponder image: ${ndp_image}"
    if ! podman pull "${ndp_image}" 2>/dev/null; then
        # 尝试带 CDN 的 docker.io 路径
        podman pull "docker.io/${ndp_image}" 2>/dev/null || true
    fi

    # 确认 podman-ipv6 网络存在后再启动
    if ! podman network exists podman-ipv6 2>/dev/null; then
        _yellow "podman-ipv6 network not found, skipping ndpresponder"
        return 1
    fi

    podman run -d \
        --restart always \
        --cpus 0.02 \
        --memory 64m \
        --cap-drop=ALL \
        --cap-add=NET_RAW \
        --cap-add=NET_ADMIN \
        --network host \
        --name ndpresponder \
        "${ndp_image}" \
        -i "${interface}" -N podman-ipv6 2>/dev/null \
    && _green "NDP responder started" \
    || _yellow "ndpresponder start failed; IPv6 may require manual NDP configuration"
}

# ======== 配置 podman.socket 服务（可选，供 API 使用） ========
setup_podman_socket() {
    if systemctl list-unit-files podman.socket >/dev/null 2>&1; then
        systemctl enable --now podman.socket 2>/dev/null || true
        _green "podman.socket enabled"
    fi
}

# ======== DNS 保活服务 ========
setup_dns_check() {
    _yellow "Setting up DNS liveness check service..."
    cat > /usr/local/bin/check-dns-podman.sh <<'EOF'
#!/bin/bash
# DNS liveness check for Podman containers
while true; do
    if ! nslookup github.com >/dev/null 2>&1; then
        if [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
            ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
        fi
        grep -q "8.8.8.8" /etc/resolv.conf || echo "nameserver 8.8.8.8" >> /etc/resolv.conf
        grep -q "1.1.1.1" /etc/resolv.conf || echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    fi
    sleep 60
done
EOF
    chmod +x /usr/local/bin/check-dns-podman.sh

    if [[ "$SYSTEM" != "Alpine" ]]; then
        cat > /etc/systemd/system/check-dns-podman.service <<'EOF'
[Unit]
Description=DNS Liveness Check for Podman
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/check-dns-podman.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable check-dns-podman 2>/dev/null || true
        systemctl start check-dns-podman 2>/dev/null || true
    fi
    _green "DNS check service configured"
}

# ======== 验证安装 ========
verify_install() {
    _yellow "Verifying installation..."
    if command -v podman >/dev/null 2>&1; then
        local _ver
        _ver=$(podman --version 2>/dev/null || true)
        if [[ -n "$_ver" ]]; then
            _green "  ✓ ${_ver}"
        else
            _green "  ✓ podman: installed (run 'podman --version' to verify)"
        fi
        # 尝试读取 OCI 运行时（不影响主流程）
        local _oci
        _oci=$(podman info --format '{{.Host.OCIRuntime.Name}}' 2>/dev/null || true)
        [[ -n "$_oci" ]] && _green "  ✓ OCI runtime: ${_oci}"
    else
        _red "  ✗ podman not found"
    fi
    if podman network exists podman-net 2>/dev/null; then
        _green "  ✓ podman-net network exists"
    fi
    if [[ "$(cat /usr/local/bin/podman_ipv6_enabled 2>/dev/null)" == "true" ]]; then
        if podman network exists podman-ipv6 2>/dev/null; then
            _green "  ✓ podman-ipv6 network exists"
        fi
    fi
}

# ======== 主流程 ========
main() {
    _blue "======================================================"
    _blue "  Podman 容器运行时一键安装脚本"
    _blue "  from https://github.com/oneclickvirt/podman"
    _blue "  2026.03.01"
    _blue "======================================================"
    echo

    # 重新计算 int（系统类型索引）
    for ((int = 0; int < ${#REGEX[@]}; int++)); do
        if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
            break
        fi
    done

    detect_interface
    check_ipv6
    install_base_deps

    # ======== 硬盘限制支持询问 ========
    _green "是否需要支持容器硬盘大小限制的Podman环境？（支持btrfs存储驱动）"
    _green "Do you need Podman with container disk size limitation? (Support btrfs storage driver)"
    _blue "如果选择 'y'，可以为每个容器限制磁盘空间 / If 'y', you can limit the disk space for each container"
    _blue "如果选择 'n'，则为标准Podman安装，无磁盘限制 / If 'n', standard Podman installation without disk limits"
    reading "Do you need container disk size limitation? ([n]/y): " _need_disk_limit_input
    _green "Where do you want to install Podman storage? (Enter to default: /var/lib/containers/storage):"
    reading "Podman存储路径？（回车则默认：/var/lib/containers/storage）：" _podman_install_path
    if [[ -z "$_podman_install_path" ]]; then
        _podman_install_path="/var/lib/containers/storage"
    fi
    echo "$_podman_install_path" > /usr/local/bin/podman_install_path

    if [[ "$_need_disk_limit_input" == "y" || "$_need_disk_limit_input" == "Y" ]]; then
        echo "true" > /usr/local/bin/podman_need_disk_limit
        while true; do
            _green "How large a Podman storage pool is needed? (unit: GB, e.g., enter 20 for 20G):"
            reading "需要多大的Podman存储池？（单位GB，例如输入20表示20G）：" _podman_pool_size
            if [[ "$_podman_pool_size" =~ ^[1-9][0-9]*$ ]]; then
                break
            else
                _yellow "Invalid input, please enter a positive integer. / 输入无效，请输入一个正整数。"
            fi
        done
        _green "Where do you want to store the Podman loop file? (Enter to default: /opt/podman-pool.img):"
        reading "Podman循环文件存储位置？（回车则默认：/opt/podman-pool.img）：" _podman_loop_file
        if [[ -z "$_podman_loop_file" ]]; then
            _podman_loop_file="/opt/podman-pool.img"
        fi
        _green "将安装支持容器磁盘大小限制的Podman环境（btrfs存储驱动）"
        _green "Will install Podman with container disk size limitation support (btrfs storage driver)"
    else
        echo "false" > /usr/local/bin/podman_need_disk_limit
        _podman_pool_size=""
        _podman_loop_file=""
        _green "将安装标准Podman，无容器磁盘大小限制功能"
        _green "Will install standard Podman without container disk size limitation"
    fi

    try_podman_storage_drivers

    # 若需要 btrfs loop 且存储驱动写入了 btrfs，则建立 loop 文件系统
    _podman_need_disk=$(cat /usr/local/bin/podman_need_disk_limit 2>/dev/null || echo "false")
    _current_driver=$(cat /usr/local/bin/podman_storage_driver 2>/dev/null || echo "overlay")
    if [[ "$_podman_need_disk" == "true" ]] && [[ "$_current_driver" == "btrfs" ]] && \
       [[ -n "$_podman_pool_size" ]] && [[ -n "$_podman_loop_file" ]]; then
        setup_podman_btrfs_loop "$_podman_pool_size" "$_podman_loop_file" "$_podman_install_path"
    fi

    configure_podman_storage
    install_podman
    configure_kernel
    create_podman_network
    setup_podman_socket
    setup_dns_check

    if [[ "$IPV6_ENABLED" == true ]]; then
        adapt_ipv6
        create_ipv6_network "$IPV6"
        start_ndpresponder
        echo "true" > /usr/local/bin/podman_ipv6_enabled
    else
        echo "false" > /usr/local/bin/podman_ipv6_enabled
    fi

    # 保存架构信息
    echo "$ARCH_TYPE" > /usr/local/bin/podman_arch

    verify_install

    echo
    _green "======================================================"
    _green "  ✓ Podman 安装完成！"
    _green "======================================================"
    echo
    _blue "常用命令:"
    _yellow "  查看容器:  podman ps -a"
    _yellow "  拉取镜像:  podman pull ubuntu:22.04"
    _yellow "  开设容器:  bash scripts/onepodman.sh <name> <cpu> <mem_mb> <passwd> <sshport> <startport> <endport>"
    _yellow "  批量开设:  bash scripts/create_podman.sh"
    _yellow "  项目地址:  https://github.com/oneclickvirt/podman"
    echo
}

main "$@"
