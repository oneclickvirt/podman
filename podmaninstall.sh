#!/bin/bash
# from
# https://github.com/oneclickvirt/podman
# 2026.08.27
_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }
is_truthy() {
    case "${1:-}" in
        [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Yy]) return 0 ;;
        *) return 1 ;;
    esac
}
is_noninteractive() { is_truthy "${noninteractive:-${NONINTERACTIVE:-}}"; }
python_cmd() { command -v python3 2>/dev/null || command -v python 2>/dev/null || true; }
PODMAN_STATE_DIR="${PODMAN_STATE_DIR:-/usr/local/bin}"
podman_state_file() {
    printf '%s/%s\n' "${PODMAN_STATE_DIR%/}" "$1"
}
reading() {
    is_noninteractive && return 1
    read -rp "$(_green "$1")" "$2"
}
export DEBIAN_FRONTEND=noninteractive
WITHOUT_CDN=false
if is_truthy "${WITHOUTCDN:-}"; then
    WITHOUT_CDN=true
fi
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
emit_cdn_urls() {
    if command -v shuf >/dev/null 2>&1; then shuf -e "${cdn_urls[@]}"; else printf '%s\n' "${cdn_urls[@]}"; fi
}
check_cdn() {
    local o_url=$1
    local cdn_url
    while IFS= read -r cdn_url; do
        [[ -n "$cdn_url" ]] || continue
        if curl -4 -sL -k "${cdn_url}${o_url}" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done < <(emit_cdn_urls)
    export cdn_success_url=""
}
check_cdn_file() {
    if [[ "$WITHOUT_CDN" == "true" ]]; then
        export cdn_success_url=""
        _yellow "WITHOUTCDN enabled, CDN acceleration disabled, using direct connection"
        return
    fi
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then _yellow "CDN available, using CDN: $cdn_success_url"; else _yellow "No CDN available, using direct connection"; fi
}
check_cdn_file
# ======== 工具函数 ========
run_package_update() {
    case $SYSTEM in
        Debian)
            if ! apt-get update 2>/dev/null; then apt-get --fix-broken install -y 2>/dev/null || true; apt-get update 2>/dev/null || true; fi
            ;;
        Ubuntu) apt-get update 2>/dev/null || true ;;
        CentOS|Fedora) yum -y update 2>/dev/null || true ;;
        Alpine) apk update 2>/dev/null || true ;;
        Arch) pacman -Sy --noconfirm 2>/dev/null || true ;;
    esac
}
update_sysctl() {
    local key="${1%%=*}"
    local val="${1##*=}"
    local escaped_key="${key//./\\.}"
    if grep -qE "^${escaped_key}[[:space:]]*=" /etc/sysctl.conf 2>/dev/null; then
        sed -i -E "s|^${escaped_key}[[:space:]]*=.*|${key}=${val}|g" /etc/sysctl.conf
    else
        echo "${key}=${val}" >> /etc/sysctl.conf
    fi
    sysctl -w "${key}=${val}" >/dev/null 2>&1 || true
}
is_private_ipv6() {
    ! is_public_ipv6 "${1:-}"
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
    # 若 loop 文件已存在，优先尝试复用，避免重跑安装时覆盖已有容器数据。
    if [[ -f "$loop_file" ]]; then
        local loop_device
        local attached_now=false
        loop_device=$(losetup -j "$loop_file" 2>/dev/null | cut -d: -f1 | head -n 1)
        if [[ -z "$loop_device" ]]; then
            loop_device=$(losetup --find --show "$loop_file" 2>/dev/null || true)
            [[ -n "$loop_device" ]] && attached_now=true
        fi
        if [[ -n "$loop_device" ]]; then
            _green "Loop file $loop_file already exists, trying to reuse $loop_device."
            mkdir -p "$mount_point"
            if mountpoint -q "$mount_point" 2>/dev/null || mount "$loop_device" "$mount_point" 2>/dev/null; then
                if ! grep -Fq "$loop_file" /etc/fstab 2>/dev/null; then
                    echo "$loop_file $mount_point btrfs loop,defaults 0 0" >> /etc/fstab
                fi
                chmod 755 "$mount_point"
                echo "$loop_device" > /usr/local/bin/podman_loop_device
                echo "$loop_file"   > /usr/local/bin/podman_loop_file
                echo "$mount_point" > /usr/local/bin/podman_mount_point
                _green "Existing btrfs loop filesystem reused: $mount_point"
                return 0
            fi
            if [[ "$attached_now" == "true" ]] || ! findmnt -S "$loop_device" >/dev/null 2>&1; then
                losetup -d "$loop_device" 2>/dev/null || true
            fi
            _yellow "Existing loop file could not be mounted as btrfs; backing it up before recreation."
        else
            _yellow "Existing loop file could not be attached; backing it up before recreation."
        fi
        local backup_loop_file
        backup_loop_file="${loop_file}.backup.$(date +%Y%m%d-%H%M%S)"
        if ! mv "$loop_file" "$backup_loop_file" 2>/dev/null; then
            _red "Failed to back up existing loop file: $loop_file"
            return 1
        fi
        _yellow "Existing loop file backed up to: $backup_loop_file"
    fi
    if mountpoint -q "$mount_point" 2>/dev/null; then
        _green "Mount point $mount_point is already mounted, skipping creation."
        mkdir -p "$mount_point"
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
    if ! grep -Fq "$loop_file" /etc/fstab 2>/dev/null; then
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
# ======== IPv6 检测与子网选择 ========
is_public_ipv6() {
    local addr="$1"
    local py_bin
    py_bin=$(python_cmd)
    if [[ -n "$py_bin" ]]; then
        "$py_bin" - "$addr" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.IPv6Address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

global_unicast = ipaddress.IPv6Network("2000::/3")
non_public = (
    ipaddress.IPv6Network("2001::/32"),       # Teredo
    ipaddress.IPv6Network("2001:2::/48"),     # benchmarking
    ipaddress.IPv6Network("2001:10::/28"),    # ORCHID
    ipaddress.IPv6Network("2001:20::/28"),    # ORCHIDv2
    ipaddress.IPv6Network("2001:db8::/32"),   # documentation
    ipaddress.IPv6Network("2002::/16"),       # 6to4
    ipaddress.IPv6Network("3fff::/20"),       # documentation
)
usable = (
    address in global_unicast
    and address.is_global
    and not address.is_multicast
    and not address.is_private
    and not any(address in prefix for prefix in non_public)
)
raise SystemExit(0 if usable else 1)
PY
        return $?
    fi
    # Every allocation operation below needs Python's ipaddress module anyway.
    # Fail closed when it is unavailable instead of guessing from text prefixes.
    return 1
}

normalize_ipv6_subnet() {
    local subnet="$1"
    local py_bin
    py_bin=$(python_cmd)
    [[ -n "$py_bin" ]] || return 1
    "$py_bin" - "$subnet" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.IPv6Network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)

global_unicast = ipaddress.IPv6Network("2000::/3")
non_public = (
    ipaddress.IPv6Network("2001::/32"),
    ipaddress.IPv6Network("2001:2::/48"),
    ipaddress.IPv6Network("2001:10::/28"),
    ipaddress.IPv6Network("2001:20::/28"),
    ipaddress.IPv6Network("2001:db8::/32"),
    ipaddress.IPv6Network("2002::/16"),
    ipaddress.IPv6Network("3fff::/20"),
)
if (
    network.prefixlen >= 128
    or not network.subnet_of(global_unicast)
    or any(network.overlaps(prefix) for prefix in non_public)
):
    raise SystemExit(1)

print(network)
PY
}

# Generate small siblings of the host's assigned prefix.  The host address is
# deliberately excluded because Podman rejects a bridge subnet that contains it.
generate_ipv6_subnet_candidates() {
    local ipv6_cidr="$1"
    local py_bin
    py_bin=$(python_cmd)
    [[ -n "$py_bin" ]] || return 1
    "$py_bin" - "$ipv6_cidr" <<'PY'
import ipaddress
import sys

try:
    interface = ipaddress.IPv6Interface(sys.argv[1])
except ValueError:
    raise SystemExit(1)

address = interface.ip
parent = interface.network
if not address.is_global or parent.prefixlen >= 124:
    raise SystemExit(1)

if parent.prefixlen <= 96:
    target_prefix = 112
elif parent.prefixlen <= 112:
    target_prefix = 120
else:
    target_prefix = 124

if target_prefix <= parent.prefixlen:
    raise SystemExit(1)

child_size = 1 << (128 - target_prefix)
child_count = 1 << (target_prefix - parent.prefixlen)
host_child = (int(address) - int(parent.network_address)) // child_size

# Try adjacent children first.  This is deterministic and never includes the
# address configured on the uplink, while still staying inside its declared prefix.
for offset in range(1, min(16, child_count - 1) + 1):
    child_index = (host_child + offset) % child_count
    child_address = int(parent.network_address) + child_index * child_size
    print(ipaddress.IPv6Network((child_address, target_prefix)))
PY
}

ipv6_subnet_has_live_address() {
    local subnet="$1"
    local py_bin
    py_bin=$(python_cmd)
    [[ -n "$py_bin" ]] || return 1
    ip -6 -o addr show 2>/dev/null | awk '$0 !~ / tentative/ {print $4}' | \
        "$py_bin" -c '
import ipaddress
import sys

network = ipaddress.IPv6Network(sys.argv[1], strict=False)
for raw in sys.stdin:
    try:
        address = ipaddress.IPv6Interface(raw.strip()).ip
    except ValueError:
        continue
    if address.version == 6 and address in network:
        raise SystemExit(0)
raise SystemExit(1)
' "$subnet"
}

ipv6_subnet_overlaps_live_network() {
    local subnet="$1"
    local py_bin
    py_bin=$(python_cmd)
    [[ -n "$py_bin" ]] || return 1
    ip -6 -o addr show 2>/dev/null | awk '$0 !~ / tentative/ {print $4}' | \
        "$py_bin" -c '
import ipaddress
import sys

network = ipaddress.IPv6Network(sys.argv[1], strict=False)
for raw in sys.stdin:
    try:
        live = ipaddress.IPv6Interface(raw.strip()).network
    except ValueError:
        continue
    if network.overlaps(live):
        raise SystemExit(0)
raise SystemExit(1)
' "$subnet"
}

# A public child of an on-link host prefix is still part of the host route,
# even when no address has been assigned inside that child yet.  Netavark and
# the kernel reject that topology, so inspect both addresses and connected
# IPv6 routes before handing a subnet to a managed bridge.
ipv6_subnet_overlaps_host() {
    local subnet="$1"
    local py_bin
    py_bin=$(python_cmd)
    [[ -n "$py_bin" ]] || return 2
    {
        ip -6 -o addr show 2>/dev/null | awk '$0 !~ / tentative/ {print $4}'
        ip -6 route show table all 2>/dev/null | awk '$1 ~ /^[0-9A-Fa-f:]+\/[0-9]+$/ {print $1}'
    } | "$py_bin" -c '
import ipaddress
import sys

try:
    candidate = ipaddress.IPv6Network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(2)
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        network = ipaddress.IPv6Network(raw, strict=False)
    except ValueError:
        continue
    if candidate.overlaps(network):
        raise SystemExit(0)
raise SystemExit(1)
' "$subnet"
}

# Prefer a delegated bridge or tunnel prefix over a primary-uplink /128.
# The first address returned by iproute2 is not an allocation policy: PVE
# hosts commonly expose the /128 first and their usable /38 on vmbr2 later.
# A lone /128 remains a valid connectivity signal and is retained as a
# fallback for IPv6 modes that do not allocate public child addresses.
select_public_ipv6_cidr() {
    local candidate address prefix prefix_number best_cidr="" best_prefix=129
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        address="${candidate%/*}"
        prefix="${candidate##*/}"
        [[ "$prefix" =~ ^[0-9]+$ ]] || continue
        prefix_number=$((10#$prefix))
        (( prefix_number <= 128 )) || continue
        if is_public_ipv6 "$address" && (( prefix_number < best_prefix )); then
            best_cidr="$candidate"
            best_prefix=$prefix_number
        fi
    done < <(ip -6 -o addr show scope global 2>/dev/null | awk '$0 !~ / tentative/ {print $4}')
    [[ -n "$best_cidr" ]] || return 1
    printf '%s\n' "$best_cidr"
}

# The IPv6 default route identifies the NDP-facing uplink more reliably than
# the IPv4 default route. Fall back to the complete selected CIDR so delegated
# PVE bridges are not hidden by a separate /128 on another interface.
podman_ipv6_uplink_interface() {
    local uplink selected
    uplink=$(ip -6 route show default 2>/dev/null | awk '
        /^default / {
            for (i = 1; i < NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }
    ')
    if [[ -n "$uplink" ]] && ip link show dev "$uplink" >/dev/null 2>&1; then
        printf '%s\n' "$uplink"
        return 0
    fi

    selected=$(select_public_ipv6_cidr 2>/dev/null || true)
    [[ "$selected" == */* ]] || return 1
    uplink=$(ip -6 -o addr show scope global 2>/dev/null | awk -v cidr="$selected" '$4 == cidr {print $2; exit}')
    [[ -n "$uplink" ]] || return 1
    printf '%s\n' "$uplink"
}

podman_ipv6_uplink_supports_ndp() {
    local uplink="$1" link_info
    [[ -n "$uplink" ]] || return 1
    link_info=$(ip -d link show dev "$uplink" 2>/dev/null || ip link show dev "$uplink" 2>/dev/null || true)
    grep -q 'link/ether' <<<"$link_info"
}

# Record whether the current IPv6 topology really needs neighbor discovery.
# SIT, ip6tnl and other non-Ethernet tunnels route IPv6 directly, so requiring
# a raw-Ethernet responder there would disable an otherwise working network.
configure_podman_ipv6_ndp_state() {
    local network_mode uplink ndp_required=false
    network_mode=""
    if [[ -f "$(podman_state_file podman_ipv6_network_mode)" ]]; then
        network_mode=$(tr -d '[:space:]' <"$(podman_state_file podman_ipv6_network_mode)" 2>/dev/null || true)
    fi
    uplink=$(podman_ipv6_uplink_interface 2>/dev/null || true)
    if [[ -z "$uplink" ]]; then
        _yellow "Could not determine the IPv6 uplink; independent IPv6 will remain disabled"
        return 1
    fi
    if [[ "$network_mode" != "nat" ]] && podman_ipv6_uplink_supports_ndp "$uplink"; then
        ndp_required=true
    fi
    printf '%s\n' "$uplink" > "$(podman_state_file podman_ipv6_uplink)"
    printf '%s\n' "$ndp_required" > "$(podman_state_file podman_ipv6_ndp_required)"
    return 0
}

check_ipv6() {
    IPV6=""
    IPV6_CIDR=""
    IPV6_ENABLED=false
    local candidate
    candidate=$(select_public_ipv6_cidr || true)
    if [[ -n "$candidate" ]]; then
        IPV6_CIDR="$candidate"
        IPV6="${candidate%/*}"
        IPV6_ENABLED=true
    fi

    if [[ "$IPV6_ENABLED" == true ]]; then
        _green "Locally bound public IPv6 detected: $IPV6 ($IPV6_CIDR)"
        # An egress address returned by an external service is insufficient for
        # allocating container addresses, so only retain locally bound CIDRs.
        echo "$IPV6" > "$(podman_state_file podman_check_ipv6)"
        echo "$IPV6_CIDR" > "$(podman_state_file podman_check_ipv6_cidr)"
    else
        _yellow "No locally bound public IPv6 prefix found, skipping independent IPv6 setup"
        echo "" > "$(podman_state_file podman_check_ipv6)"
        echo "" > "$(podman_state_file podman_check_ipv6_cidr)"
    fi
}
# ======== 安装基础依赖 ========
install_base_deps() {
    _yellow "Installing base dependencies..."
    case $SYSTEM in
        Debian|Ubuntu)
            run_package_update
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates nftables iproute2 \
                socat unzip tar jq python3 2>/dev/null || true
            ;;
        CentOS|Fedora)
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates nftables iproute \
                socat unzip tar jq python3 2>/dev/null || true
            ;;
        Alpine)
            run_package_update
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates nftables iproute2 \
                socat unzip tar jq python3 2>/dev/null || true
            ;;
        Arch)
            run_package_update
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates nftables iproute2 \
                socat unzip tar jq python 2>/dev/null || true
            ;;
    esac
    _green "Base dependencies installed"
}
# ======== 检测防火墙后端 ========
detect_firewall_backend() {
    FIREWALL_BACKEND="nftables"
    if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
        FIREWALL_BACKEND="nftables"
        _green "Firewall backend: nftables (rules auto-persist)"
    else
        _yellow "nftables not functional, falling back to iptables"
        FIREWALL_BACKEND="iptables"
        case $SYSTEM in
            Debian|Ubuntu)
                ${PACKAGE_INSTALL[int]} iptables 2>/dev/null || true
                # iptables-persistent 同时处理 IPv4 和 IPv6 规则持久化
                _yellow "Installing iptables-persistent for rule persistence..."
                echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
                echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
                ${PACKAGE_INSTALL[int]} iptables-persistent 2>/dev/null || true
                systemctl enable netfilter-persistent 2>/dev/null || true
                ;;
            CentOS|Fedora)
                ${PACKAGE_INSTALL[int]} iptables iptables-services 2>/dev/null || true
                systemctl enable iptables 2>/dev/null || true
                systemctl enable ip6tables 2>/dev/null || true
                ;;
            Alpine)
                ${PACKAGE_INSTALL[int]} iptables ip6tables iptables-openrc 2>/dev/null || true
                rc-update add iptables default 2>/dev/null || true
                rc-update add ip6tables default 2>/dev/null || true
                ;;
            Arch)
                ${PACKAGE_INSTALL[int]} iptables 2>/dev/null || true
                systemctl enable iptables 2>/dev/null || true
                systemctl enable ip6tables 2>/dev/null || true
                ;;
        esac
        _green "Firewall backend: iptables (with persistent rules for IPv4/IPv6)"
    fi
    echo "$FIREWALL_BACKEND" > /usr/local/bin/podman_firewall_backend
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
            run_package_update
            # Ubuntu 22.04+ 直接有 podman
            ${PACKAGE_INSTALL[int]} podman 2>/dev/null || true
            # 若版本过旧则添加 kubic 源
            if ! command -v podman >/dev/null 2>&1; then
                # shellcheck disable=SC1091
                . /etc/os-release
                echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/ /" \
                    > /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
                curl -L "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/Release.key" | apt-key add - 2>/dev/null || true
                apt-get update 2>/dev/null || true
                ${PACKAGE_INSTALL[int]} podman 2>/dev/null || true
            fi
            ;;
        Debian)
            run_package_update
            ${PACKAGE_INSTALL[int]} podman 2>/dev/null || true
            if ! command -v podman >/dev/null 2>&1; then
                # shellcheck disable=SC1091
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
    if [[ -f /usr/local/bin/podman_install_path ]]; then
        local configured_graph_root
        configured_graph_root=$(cat /usr/local/bin/podman_install_path 2>/dev/null || true)
        [[ -n "$configured_graph_root" ]] && graph_root="$configured_graph_root"
    fi
    if [[ "$storage_driver" == "btrfs" ]] && [[ -f /usr/local/bin/podman_mount_point ]]; then
        local _mp
        _mp=$(cat /usr/local/bin/podman_mount_point)
        [[ -n "$_mp" ]] && graph_root="$_mp"
    fi
    mkdir -p "$graph_root" 2>/dev/null || true
    if [[ "$graph_root" != "/var/lib/containers/storage" ]] && command -v semanage >/dev/null 2>&1 && command -v restorecon >/dev/null 2>&1; then
        semanage fcontext -a -e /var/lib/containers "$graph_root" 2>/dev/null || true
        restorecon -R "$graph_root" 2>/dev/null || true
    fi
    # 配置 containers.conf
    cat > /etc/containers/containers.conf <<EOF
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
firewall_driver = "${FIREWALL_BACKEND}"
[engine]
cgroup_manager = "systemd"
events_logger = "journald"
EOF
    # 配置 storage.conf（覆盖写入，确保驱动与路径正确）
    cat > /etc/containers/storage.conf <<EOF
[storage]
driver = "${storage_driver}"
runroot = "/run/containers/storage"
graphroot = "${graph_root}"
[storage.options]
additionalimagestores = []
[storage.options.overlay]
mountopt = "nodev"
EOF
    if [[ "$storage_driver" == "btrfs" ]]; then
        _green "Podman storage configured: driver=btrfs, graphroot=${graph_root}  (disk size limitation ENABLED)"
    else
        _green "Podman storage configured: driver=overlay (standard, no disk size limitation)"
    fi
    # 配置 registries.conf（添加默认搜索路径）
    if [[ ! -f /etc/containers/registries.conf ]]; then
        cat > /etc/containers/registries.conf <<'EOF'
unqualified-search-registries = ["docker.io", "ghcr.io", "quay.io"]
EOF
    fi
    # 确保 policy.json 存在
    if [[ ! -f /etc/containers/policy.json ]]; then
        cat > /etc/containers/policy.json <<'EOF'
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ],
    "transports": {
        "docker-daemon": {
            "": [
                {
                    "type": "insecureAcceptAnything"
                }
            ]
        }
    }
}
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
    if [[ "${FIREWALL_BACKEND:-nftables}" == "nftables" ]]; then
        modprobe nf_tables 2>/dev/null || true
    fi
    update_sysctl "net.ipv4.ip_forward=1"
    update_sysctl "net.bridge.bridge-nf-call-iptables=1"
    update_sysctl "net.bridge.bridge-nf-call-ip6tables=1"
    update_sysctl "kernel.unprivileged_userns_clone=1"
    sysctl --system >/dev/null 2>&1 || true
    _green "Kernel parameters configured"
}
ensure_subid_range() {
    local file="$1"
    local user="$2"
    local start="$3"
    [[ -n "$file" && -n "$user" && -n "$start" ]] || return 0
    touch "$file" 2>/dev/null || return 0
    if ! awk -F: -v wanted_user="$user" '$1 == wanted_user { found=1 } END { exit found ? 0 : 1 }' "$file" 2>/dev/null; then
        echo "${user}:${start}:65536" >> "$file"
    fi
}
configure_rootless_user() {
    local rootless_user="${PODMAN_ROOTLESS_USER:-}" subuid_start="${PODMAN_ROOTLESS_SUBUID_START:-100000}" subgid_start="${PODMAN_ROOTLESS_SUBGID_START:-100000}"
    [[ -n "$rootless_user" ]] || return 0
    if [[ ! "$rootless_user" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]]; then
        _yellow "Invalid PODMAN_ROOTLESS_USER=${rootless_user}, skipping rootless setup"
        return 0
    fi
    if [[ ! "$subuid_start" =~ ^[0-9]+$ || ! "$subgid_start" =~ ^[0-9]+$ ]]; then
        _yellow "Invalid rootless subuid/subgid start, using defaults 100000:100000"
        subuid_start="100000"
        subgid_start="100000"
    fi
    if ! id "$rootless_user" >/dev/null 2>&1; then
        if is_truthy "${PODMAN_ROOTLESS_CREATE_USER:-}"; then
            if command -v useradd >/dev/null 2>&1; then useradd -m "$rootless_user" 2>/dev/null || true; elif command -v adduser >/dev/null 2>&1; then adduser -D "$rootless_user" 2>/dev/null || true; fi
        fi
    fi
    if ! id "$rootless_user" >/dev/null 2>&1; then
        _yellow "Rootless user ${rootless_user} does not exist; set PODMAN_ROOTLESS_CREATE_USER=true or create it manually"
        return 0
    fi
    ensure_subid_range /etc/subuid "$rootless_user" "$subuid_start"
    ensure_subid_range /etc/subgid "$rootless_user" "$subgid_start"
    if command -v loginctl >/dev/null 2>&1; then loginctl enable-linger "$rootless_user" 2>/dev/null || true; fi
    echo "$rootless_user" > /usr/local/bin/podman_rootless_user
    _green "Rootless Podman user configured: ${rootless_user}"
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
    local uplink
    _yellow "Configuring IPv6 kernel parameters..."
    uplink=$(podman_ipv6_uplink_interface 2>/dev/null || true)
    if [[ -z "$uplink" ]]; then
        _yellow "Could not determine the IPv6 uplink; leaving host IPv6 settings unchanged"
        return 1
    fi
    update_sysctl "net.ipv6.conf.all.forwarding=1"
    # Enabling forwarding makes Linux ignore normal router advertisements
    # unless the actual IPv6 uplink opts in explicitly. ndpresponder answers
    # NDP itself, so do not change global proxy_ndp state owned by the host.
    update_sysctl "net.ipv6.conf.${uplink}.accept_ra=2"
    sysctl --system >/dev/null 2>&1 || true
}
# ======== 创建 Podman IPv6 网络 ========
set_ipv6_network_mode() {
    printf '%s\n' "$1" > "$(podman_state_file podman_ipv6_network_mode)"
}

# A host with only one public /128 still has IPv6 connectivity, but it cannot
# safely donate that address to a container.  Keep the bridge private in that
# case and use NAT66 for outbound IPv6 instead of treating the /128 as a
# routable allocation pool.
podman_ipv6_ula_state_matches_network() {
    local recorded_mode="$1" recorded_subnet="$2" network_subnet="$3"
    [[ "$recorded_mode" == "nat" && "$recorded_subnet" == "$network_subnet" ]] || return 1
    normalize_ipv6_internal_subnet "$network_subnet" >/dev/null
}

configure_podman_ipv6_nat66() {
    local subnet="$1" postrouting forward nft_table="oneclickvirt_podman_ipv6"
    normalize_ipv6_internal_subnet "$subnet" >/dev/null || return 1

    # Prefer ip6tables when available so the allowance follows Netavark's
    # usual firewall path.  The nft fallback is for hosts without iptables.
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -C FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || return 1
        ip6tables -C FORWARD -d "$subnet" -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -d "$subnet" -j ACCEPT 2>/dev/null || return 1
        ip6tables -t nat -C POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE 2>/dev/null || \
            ip6tables -t nat -A POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE 2>/dev/null || return 1
        ip6tables -t nat -C POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE 2>/dev/null && \
            ip6tables -C FORWARD -s "$subnet" -j ACCEPT 2>/dev/null && \
            ip6tables -C FORWARD -d "$subnet" -j ACCEPT 2>/dev/null
        return
    fi

    if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
        nft add table ip6 "$nft_table" 2>/dev/null || true
        nft "add chain ip6 ${nft_table} forward { type filter hook forward priority filter; policy accept; }" 2>/dev/null || true
        nft "add chain ip6 ${nft_table} postrouting { type nat hook postrouting priority srcnat; policy accept; }" 2>/dev/null || true
        postrouting=$(nft list chain ip6 "$nft_table" postrouting 2>/dev/null || true)
        forward=$(nft list chain ip6 "$nft_table" forward 2>/dev/null || true)
        if ! grep -Fq "ip6 saddr ${subnet}" <<<"$postrouting" || ! grep -Fq 'masquerade' <<<"$postrouting"; then
            nft add rule ip6 "$nft_table" postrouting ip6 saddr "$subnet" ip6 daddr != "$subnet" masquerade 2>/dev/null || return 1
        fi
        if ! grep -Fq "ip6 saddr ${subnet} accept" <<<"$forward"; then
            nft add rule ip6 "$nft_table" forward ip6 saddr "$subnet" accept 2>/dev/null || return 1
        fi
        if ! grep -Fq "ip6 daddr ${subnet} accept" <<<"$forward"; then
            nft add rule ip6 "$nft_table" forward ip6 daddr "$subnet" accept 2>/dev/null || return 1
        fi
        postrouting=$(nft list chain ip6 "$nft_table" postrouting 2>/dev/null || true)
        forward=$(nft list chain ip6 "$nft_table" forward 2>/dev/null || true)
        grep -Fq "ip6 saddr ${subnet}" <<<"$postrouting" && \
            grep -Fq 'masquerade' <<<"$postrouting" && \
            grep -Fq "ip6 saddr ${subnet} accept" <<<"$forward" && \
            grep -Fq "ip6 daddr ${subnet} accept" <<<"$forward"
        return
    fi
    return 1
}

install_podman_ipv6_nat66_service() {
    local helper=/usr/local/bin/podman-ipv6-nat.sh
    cat > "$helper" <<'EOF'
#!/bin/bash
# OneClickVirt Podman IPv6 NAT66 restore helper.
set -u

state_dir=/usr/local/bin
mode=$(tr -d '[:space:]' <"${state_dir}/podman_ipv6_network_mode" 2>/dev/null || true)
subnet=$(tr -d '[:space:]' <"${state_dir}/podman_ipv6_subnet" 2>/dev/null || true)
[[ "$mode" == nat && -n "$subnet" ]] || exit 0

python3 - "$subnet" <<'PY'
import ipaddress
import sys
try:
    network = ipaddress.IPv6Network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if network.prefixlen == 64 and network.subnet_of(ipaddress.IPv6Network("fc00::/7")) else 1)
PY

if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -s "$subnet" -j ACCEPT || exit 1
    ip6tables -C FORWARD -d "$subnet" -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -d "$subnet" -j ACCEPT || exit 1
    ip6tables -t nat -C POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE 2>/dev/null || \
        ip6tables -t nat -A POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE || exit 1
    exit 0
fi

command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1 || exit 1
nft_table=oneclickvirt_podman_ipv6
nft add table ip6 "$nft_table" 2>/dev/null || true
nft "add chain ip6 ${nft_table} forward { type filter hook forward priority filter; policy accept; }" 2>/dev/null || true
nft "add chain ip6 ${nft_table} postrouting { type nat hook postrouting priority srcnat; policy accept; }" 2>/dev/null || true
postrouting=$(nft list chain ip6 "$nft_table" postrouting 2>/dev/null || true)
forward=$(nft list chain ip6 "$nft_table" forward 2>/dev/null || true)
grep -Fq "ip6 saddr ${subnet}" <<<"$postrouting" || \
    nft add rule ip6 "$nft_table" postrouting ip6 saddr "$subnet" ip6 daddr != "$subnet" masquerade || exit 1
grep -Fq "ip6 saddr ${subnet} accept" <<<"$forward" || \
    nft add rule ip6 "$nft_table" forward ip6 saddr "$subnet" accept || exit 1
grep -Fq "ip6 daddr ${subnet} accept" <<<"$forward" || \
    nft add rule ip6 "$nft_table" forward ip6 daddr "$subnet" accept || exit 1
EOF
    chmod 700 "$helper"

    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/podman-ipv6-nat.service <<'EOF'
[Unit]
Description=Restore OneClickVirt Podman IPv6 NAT66 rules
After=network-online.target podman.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/podman-ipv6-nat.sh

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now podman-ipv6-nat.service 2>/dev/null || \
            _yellow "Could not enable podman-ipv6-nat.service; verify NAT66 after reboot"
        return 0
    fi

    if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        cat > /etc/init.d/podman-ipv6-nat <<'EOF'
#!/sbin/openrc-run
# OneClickVirt Podman IPv6 NAT66 restore service.

description="Restore OneClickVirt Podman IPv6 NAT66 rules"

depend() {
    need net
    after podman
}

start() {
    ebegin "$description"
    /usr/local/bin/podman-ipv6-nat.sh
    eend $?
}
EOF
        chmod 700 /etc/init.d/podman-ipv6-nat
        rc-update add podman-ipv6-nat default 2>/dev/null || true
        rc-service podman-ipv6-nat restart 2>/dev/null || \
            _yellow "Could not start podman-ipv6-nat OpenRC service; verify NAT66 after reboot"
        return 0
    fi

    _yellow "No service manager found; verify Podman IPv6 NAT66 rules after reboot"
}

ipv6_gateway_for_subnet() {
    local subnet="$1"
    local py_bin
    py_bin=$(python_cmd)
    [[ -n "$py_bin" ]] || return 1
    "$py_bin" - "$subnet" <<'PY'
import ipaddress
import sys

network = ipaddress.IPv6Network(sys.argv[1], strict=False)
if network.num_addresses < 2:
    raise SystemExit(1)
print(ipaddress.IPv6Address(int(network.network_address) + 1))
PY
}

normalize_ipv6_internal_subnet() {
    local subnet="$1"
    local py_bin
    py_bin=$(python_cmd)
    [[ -n "$py_bin" ]] || return 1
    "$py_bin" - "$subnet" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.IPv6Network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)
if network.prefixlen != 64 or not network.is_private:
    raise SystemExit(1)
print(network)
PY
}

manual_ipv6_subnet_candidate() {
    local index="$1"
    local py_bin
    py_bin=$(python_cmd)
    [[ -n "$py_bin" ]] || return 1
    "$py_bin" - "$index" <<'PY'
import ipaddress
import sys

index = int(sys.argv[1])
base = ipaddress.IPv6Network("fd42:5339:296f:1d00::/56")
print(ipaddress.IPv6Network((int(base.network_address) + (index << 64), 64)))
PY
}

choose_manual_ipv6_subnet() {
    local candidate index
    for index in $(seq 0 255); do
        candidate=$(manual_ipv6_subnet_candidate "$index" 2>/dev/null || true)
        [[ -n "$candidate" ]] || continue
        if ipv6_subnet_overlaps_host "$candidate" || ipv6_subnet_overlaps_podman_network "$candidate"; then
            continue
        fi
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

ipv6_subnet_overlaps_podman_network() {
    local subnet="$1"
    local py_bin network_id
    py_bin=$(python_cmd)
    [[ -n "$py_bin" ]] || return 1
    {
        while IFS= read -r network_id; do
            [[ -n "$network_id" ]] || continue
            podman network inspect -f '{{range .Subnets}}{{.Subnet}}{{"\n"}}{{end}}' "$network_id" 2>/dev/null || true
        done < <(podman network ls -q 2>/dev/null || true)
    } | "$py_bin" -c '
import ipaddress
import sys

candidate = ipaddress.IPv6Network(sys.argv[1], strict=False)
for raw in sys.stdin:
    try:
        network = ipaddress.ip_network(raw.strip(), strict=False)
    except ValueError:
        continue
    if network.version == 6 and candidate.overlaps(network):
        raise SystemExit(0)
raise SystemExit(1)
' "$subnet"
}

# Netavark exposes user-specified routes through the network inspect JSON. An
# unmanaged IPv6 network needs this explicit route because no_default_route
# deliberately prevents it from installing any automatic default route.
podman_ipv6_network_has_explicit_default_route() {
    local py_bin
    py_bin=$(python_cmd)
    [[ -n "$py_bin" ]] || return 1
    podman network inspect podman-ipv6 2>/dev/null | "$py_bin" -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, OSError):
    raise SystemExit(1)

networks = payload if isinstance(payload, list) else [payload]
for network in networks:
    if not isinstance(network, dict):
        continue
    for route in network.get("routes") or []:
        if isinstance(route, dict) and route.get("destination") == "::/0":
            raise SystemExit(0)
raise SystemExit(1)
'
}

podman_ipv6_network_subnet() {
    local py_bin
    py_bin=$(python_cmd)
    [[ -n "$py_bin" ]] || return 1
    podman network inspect podman-ipv6 2>/dev/null | "$py_bin" -c '
import ipaddress
import json
import sys

try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, OSError):
    raise SystemExit(1)

networks = payload if isinstance(payload, list) else [payload]
for network in networks:
    if not isinstance(network, dict):
        continue
    for subnet in network.get("subnets") or []:
        if not isinstance(subnet, dict):
            continue
        value = subnet.get("subnet")
        try:
            candidate = ipaddress.ip_network(value, strict=False)
        except ValueError:
            continue
        if candidate.version == 6:
            print(candidate)
            raise SystemExit(0)
raise SystemExit(1)
'
}

podman_ipv6_network_has_attached_containers() {
    podman ps -aq --filter 'network=podman-ipv6' 2>/dev/null | grep -q '[^[:space:]]'
}

create_managed_ipv6_network() {
    local prefix="$1"
    local net_err="$2"
    if podman network create \
        --driver bridge \
        --ipv6 \
        --interface-name podman-br1 \
        --subnet 172.21.0.0/16 \
        --gateway 172.21.0.1 \
        --subnet "$prefix" \
        podman-ipv6 2>"$net_err"; then
        _green "podman-ipv6 created (managed dual-stack): IPv4=172.21.0.0/16, IPv6=${prefix}"
        return 0
    fi

    # Older Podman releases may not implement --interface-name.  Do not retry
    # collision failures with the same subnet because that cannot change the result.
    if grep -qiE 'unknown (option|flag).*interface-name|unrecognized option.*interface-name' "$net_err" 2>/dev/null; then
        if podman network create \
            --driver bridge \
            --ipv6 \
            --subnet 172.21.0.0/16 \
            --gateway 172.21.0.1 \
            --subnet "$prefix" \
            podman-ipv6 2>"$net_err"; then
            _green "podman-ipv6 created (managed dual-stack): IPv4=172.21.0.0/16, IPv6=${prefix}"
            return 0
        fi
    fi
    return 1
}

UNMANAGED_IPV6_BRIDGE_CREATED=false
bridge_has_attached_interfaces() {
    local bridge="$1"
    ip -o link show master "$bridge" 2>/dev/null | grep -q .
}

ensure_unmanaged_ipv6_bridge() {
    local prefix="$1"
    local gateway="$2"
    local prefix_len="${prefix#*/}"
    UNMANAGED_IPV6_BRIDGE_CREATED=false

    if ip link show podman-br1 >/dev/null 2>&1; then
        if [[ "$(cat "$(podman_state_file podman_ipv6_bridge_owned)" 2>/dev/null)" != "true" ]]; then
            _yellow "podman-br1 already exists but is not owned by this installer; refusing to modify it"
            return 1
        fi
        if ! ip -d link show podman-br1 2>/dev/null | grep -qw bridge; then
            _yellow "podman-br1 exists but is not a Linux bridge; refusing to modify it"
            return 1
        fi
        # A previous uninstall may have had to leave this installer-owned bridge
        # behind because another runtime still had ports attached. Once the
        # Podman network is gone, reconfiguring it would change that runtime's
        # L2 domain, so require a clean bridge before it can be reused.
        if bridge_has_attached_interfaces podman-br1 && ! podman network exists podman-ipv6 2>/dev/null; then
            _yellow "podman-br1 has attached interfaces but podman-ipv6 no longer exists; refusing to reuse the retained bridge"
            return 1
        fi
    else
        if ! ip link add name podman-br1 type bridge 2>/dev/null; then
            _yellow "Failed to create unmanaged IPv6 bridge podman-br1"
            return 1
        fi
        printf '%s\n' "true" > "$(podman_state_file podman_ipv6_bridge_owned)"
        UNMANAGED_IPV6_BRIDGE_CREATED=true
    fi

    if ! ip link set podman-br1 up 2>/dev/null || \
       ! ip -6 addr replace "${gateway}/${prefix_len}" dev podman-br1 2>/dev/null; then
        _yellow "Failed to configure ${gateway}/${prefix_len} on podman-br1"
        return 1
    fi
    update_sysctl "net.ipv6.conf.podman-br1.forwarding=1"
    update_sysctl "net.ipv6.conf.podman-br1.accept_ra=0"
    update_sysctl "net.ipv6.conf.podman-br1.accept_dad=0"
    printf '%s\n' "$gateway" > "$(podman_state_file podman_ipv6_gateway)"
    return 0
}

install_unmanaged_ipv6_bridge_service() {
    local helper=/usr/local/bin/podman-ipv6-bridge.sh
    cat > "$helper" <<'EOF'
#!/bin/bash
state_dir=/usr/local/bin
bridge=podman-br1

if [[ "$(cat "${state_dir}/podman_ipv6_bridge_owned" 2>/dev/null)" != "true" ]]; then
    exit 0
fi

subnet=$(cat "${state_dir}/podman_ipv6_subnet" 2>/dev/null || true)
gateway=$(cat "${state_dir}/podman_ipv6_gateway" 2>/dev/null || true)
[[ -n "$subnet" && -n "$gateway" ]] || exit 1
prefix_len=${subnet#*/}

if ! ip link show "$bridge" >/dev/null 2>&1; then
    ip link add name "$bridge" type bridge
fi
ip -d link show "$bridge" 2>/dev/null | grep -qw bridge || exit 1
ip link set "$bridge" up
ip -6 addr replace "${gateway}/${prefix_len}" dev "$bridge"
sysctl -w "net.ipv6.conf.${bridge}.forwarding=1" >/dev/null 2>&1 || true
sysctl -w "net.ipv6.conf.${bridge}.accept_ra=0" >/dev/null 2>&1 || true
sysctl -w "net.ipv6.conf.${bridge}.accept_dad=0" >/dev/null 2>&1 || true
EOF
    chmod 700 "$helper"

    if ! command -v systemctl >/dev/null 2>&1; then
        _yellow "Unmanaged IPv6 bridge is not persisted on this non-systemd host; rerun the installer after reboot"
        return 0
    fi

    cat > /etc/systemd/system/podman-ipv6-bridge.service <<'EOF'
[Unit]
Description=OneClickVirt Podman unmanaged IPv6 bridge
After=network-online.target
Wants=network-online.target
Before=podman-restart.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/podman-ipv6-bridge.sh

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now podman-ipv6-bridge.service 2>/dev/null || \
        _yellow "Could not enable podman-ipv6-bridge.service; bridge is active now but verify it after reboot"
}

cleanup_failed_unmanaged_ipv6_bridge() {
    if [[ "$UNMANAGED_IPV6_BRIDGE_CREATED" == "true" ]]; then
        ip link set podman-br1 down 2>/dev/null || true
        ip link delete podman-br1 2>/dev/null || true
        rm -f "$(podman_state_file podman_ipv6_bridge_owned)" "$(podman_state_file podman_ipv6_gateway)"
    fi
}

create_unmanaged_ipv6_network() {
    local prefix="$1"
    local gateway
    local net_err="$2"
    gateway=$(ipv6_gateway_for_subnet "$prefix" 2>/dev/null || true)
    if [[ -z "$gateway" ]]; then
        _yellow "Could not derive an IPv6 bridge gateway from ${prefix}"
        return 1
    fi
    if ! ensure_unmanaged_ipv6_bridge "$prefix" "$gateway"; then
        # ensure_unmanaged_ipv6_bridge can create the bridge before a later
        # address or link operation fails. Do not leave that half-created
        # installer-owned bridge behind when no network was created.
        cleanup_failed_unmanaged_ipv6_bridge
        return 1
    fi
    if ! podman network create \
        --driver bridge \
        --ipv6 \
        --disable-dns \
        --interface-name podman-br1 \
        --opt mode=unmanaged \
        --opt no_default_route=1 \
        --route "::/0,${gateway}" \
        --subnet "$prefix" \
        --gateway "$gateway" \
        podman-ipv6 2>"$net_err"; then
        _yellow "Unmanaged IPv6 network creation failed: $(cat "$net_err" 2>/dev/null)"
        cleanup_failed_unmanaged_ipv6_bridge
        return 1
    fi
    printf '%s\n' "$prefix" > "$(podman_state_file podman_ipv6_subnet)"
    set_ipv6_network_mode unmanaged
    install_unmanaged_ipv6_bridge_service
    _green "podman-ipv6 created (unmanaged IPv6 bridge): IPv6=${prefix}; IPv4 and published ports remain on podman-net"
    _yellow "The unmanaged IPv6 network keeps podman-net as the IPv4 default gateway and adds an explicit IPv6 default route through ${gateway}"
    _yellow "Unmanaged IPv6 is routed directly (no NAT or IPv6 port forwarding); ensure the host firewall permits forwarding for podman-br1"
    return 0
}

# Restore the pre-upgrade unmanaged shape only if adding the explicit route
# failed after an empty installer-owned network was removed. This is a
# rollback path, not a supported steady state: callers still return failure so
# no new container will be advertised as IPv6-ready.
restore_unmanaged_ipv6_network_without_default_route() {
    local prefix="$1"
    local net_err="$2"
    local gateway
    gateway=$(ipv6_gateway_for_subnet "$prefix" 2>/dev/null || true)
    [[ -n "$gateway" ]] || return 1

    if ! ensure_unmanaged_ipv6_bridge "$prefix" "$gateway"; then
        cleanup_failed_unmanaged_ipv6_bridge
        return 1
    fi
    if ! podman network create \
        --driver bridge \
        --ipv6 \
        --disable-dns \
        --interface-name podman-br1 \
        --opt mode=unmanaged \
        --opt no_default_route=1 \
        --subnet "$prefix" \
        --gateway "$gateway" \
        podman-ipv6 2>"$net_err"; then
        cleanup_failed_unmanaged_ipv6_bridge
        return 1
    fi
    printf '%s\n' "$prefix" > "$(podman_state_file podman_ipv6_subnet)"
    set_ipv6_network_mode unmanaged
    install_unmanaged_ipv6_bridge_service
    return 0
}

install_manual_ipv6_attach_helper() {
    local helper=/usr/local/bin/podman-ipv6-attach.sh
    cat > "$helper" <<'EOF'
#!/bin/bash
# Installer-owned routed IPv6 attachment for Podman networks without a public IPAM subnet.
set -u

state_dir=${PODMAN_STATE_DIR:-/usr/local/bin}
runtime=podman
network=podman-ipv6
parent_file="${state_dir}/podman_ipv6_public_prefix"
subnet_file="${state_dir}/podman_ipv6_manual_subnet"
gateway_file="${state_dir}/podman_ipv6_manual_gateway"
bridge_file="${state_dir}/podman_ipv6_manual_bridge"
map_file="${state_dir}/podman_ipv6_allocations"
target_file="${state_dir}/podman_ipv6_targets"
lock_dir="${map_file}.lock"

fail() { printf '%s\n' "$*" >&2; return 1; }
valid_name() { [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; }
read_state() {
    parent=$(tr -d '[:space:]' <"$parent_file" 2>/dev/null || true)
    subnet=$(tr -d '[:space:]' <"$subnet_file" 2>/dev/null || true)
    gateway=$(tr -d '[:space:]' <"$gateway_file" 2>/dev/null || true)
    bridge=$(tr -d '[:space:]' <"$bridge_file" 2>/dev/null || true)
    [[ -n "$parent" && -n "$subnet" && -n "$gateway" && -n "$bridge" ]] || fail "Podman manual IPv6 state is incomplete"
}
valid_ipv6_in_parent() {
    python3 - "$1" "$2" <<'PY'
import ipaddress
import sys
try:
    address = ipaddress.IPv6Address(sys.argv[1])
    parent = ipaddress.IPv6Network(sys.argv[2], strict=False)
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if address in parent and not address.is_unspecified and not address.is_multicast else 1)
PY
}
allocate_address() {
    python3 - "$parent" "$map_file" "$gateway" <<'PY'
import ipaddress
import os
import subprocess
import sys

parent = ipaddress.IPv6Network(sys.argv[1], strict=False)
used = set()
for raw in (sys.argv[2],):
    try:
        with open(raw, encoding="utf-8") as handle:
            for line in handle:
                fields = line.split()
                if len(fields) >= 2:
                    used.add(ipaddress.IPv6Address(fields[1]))
    except OSError:
        pass
try:
    used.add(ipaddress.IPv6Address(sys.argv[3]))
except ValueError:
    pass
try:
    output = os.popen("ip -6 -o addr show 2>/dev/null").read()
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 4:
            try:
                address = ipaddress.IPv6Interface(fields[3]).ip
            except ValueError:
                continue
            if address in parent:
                used.add(address)
except OSError:
    pass
try:
    routes = subprocess.check_output(
        ["ip", "-6", "route", "show", "default"],
        text=True,
        stderr=subprocess.DEVNULL,
    )
except (OSError, subprocess.CalledProcessError):
    routes = ""
for line in routes.splitlines():
    fields = line.split()
    for index, field in enumerate(fields[:-1]):
        if field != "via":
            continue
        try:
            upstream = ipaddress.IPv6Address(fields[index + 1])
        except ValueError:
            continue
        if upstream in parent:
            used.add(upstream)
start = int(parent.network_address) + (0x1000 if parent.prefixlen <= 112 else 1)
limit = min(int(parent.broadcast_address), start + 1_000_000)
for value in range(start, limit + 1):
    candidate = ipaddress.IPv6Address(value)
    if candidate not in used and candidate != parent.network_address:
        print(candidate)
        raise SystemExit(0)
raise SystemExit(1)
PY
}
replace_mapping() {
    local name="$1" address="$2" tmp
    tmp=$(mktemp "${map_file}.tmp.XXXXXX") || return 1
    awk -v name="$name" '$1 != name {print}' "$map_file" 2>/dev/null >"$tmp" || true
    printf '%s %s\n' "$name" "$address" >>"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$map_file" || return 1
    sync_targets
}
sync_targets() {
    local tmp rc
    tmp=$(mktemp "${target_file}.tmp.XXXXXX") || return 1
    awk 'NF >= 2 {print $2 "/128"}' "$map_file" | sort -u >"$tmp"
    chmod 644 "$tmp"
    # ndpresponder consumes this through a file bind mount. Replacing the
    # path would leave the container attached to the old inode, so update the
    # existing file in place after the complete replacement was prepared.
    if cat "$tmp" >"$target_file"; then
        rm -f "$tmp"
        return 0
    else
        rc=$?
        rm -f "$tmp"
        return "$rc"
    fi
}
acquire_lock() {
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        mkdir "$lock_dir" 2>/dev/null && return 0
        sleep 0.1
    done
    printf 'Timed out waiting for the Podman IPv6 allocation lock\n' >&2
    return 1
}
release_lock() {
    rmdir "$lock_dir" 2>/dev/null || true
}
find_container_iface() {
    local name="$1" pid="$2" ula iface
    ula=$($runtime inspect -f '{{range .NetworkSettings.Networks}}{{.GlobalIPv6Address}}{{"\n"}}{{end}}' "$name" 2>/dev/null | awk '/:/{print; exit}' || true)
    if [[ -n "$ula" ]]; then
        iface=$(nsenter -t "$pid" -n ip -o -6 addr show 2>/dev/null | awk -v target="$ula" '$4 ~ ("^" target "/") {print $2; exit}' || true)
        [[ -n "$iface" ]] && { printf '%s\n' "$iface"; return 0; }
    fi
    nsenter -t "$pid" -n ip -o link show 2>/dev/null | awk -F': ' '$2 !~ /^lo(@|:|$)/ {gsub(/@.*/, "", $2); iface=$2} END {if (iface != "") print iface}'
}
attach_one_locked() {
    local name="$1" requested="${2:-}" pid address iface
    pid=$($runtime inspect -f '{{.State.Pid}}' "$name" 2>/dev/null || true)
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    address=$(awk -v name="$name" '$1 == name {print $2; exit}' "$map_file" 2>/dev/null || true)
    if [[ -n "$requested" ]]; then
        valid_ipv6_in_parent "$requested" "$parent" || { printf 'Requested IPv6 is outside the routed parent: %s\n' "$requested" >&2; return 1; }
        address="$requested"
    fi
    [[ -n "$address" ]] || address=$(allocate_address) || return 1
    valid_ipv6_in_parent "$address" "$parent" || return 1
    iface=$(find_container_iface "$name" "$pid")
    [[ -n "$iface" ]] || { printf 'Unable to find the IPv6 network interface for %s\n' "$name" >&2; return 1; }
    nsenter -t "$pid" -n ip link set "$iface" up || return 1
    nsenter -t "$pid" -n ip -6 addr replace "$address/128" dev "$iface" || return 1
    nsenter -t "$pid" -n ip -6 route replace default via "$gateway" dev "$iface" || return 1
    ip -6 route replace "$address/128" dev "$bridge" || return 1
    replace_mapping "$name" "$address" || return 1
    printf '%s\n' "$address"
}
attach_one() {
    local name="$1" requested="${2:-}" rc
    valid_name "$name" || return 1
    read_state || return 1
    [[ -f "$map_file" ]] || : >"$map_file"
    [[ -f "$target_file" ]] || : >"$target_file"
    acquire_lock || return 1
    attach_one_locked "$name" "$requested"
    rc=$?
    release_lock
    return "$rc"
}
prune_stale_mappings_locked() {
    local name address tmp changed=false
    [[ -f "$map_file" ]] || return 0
    tmp=$(mktemp "${map_file}.tmp.XXXXXX") || return 1
    while read -r name address; do
        [[ -n "$name" && -n "$address" ]] || continue
        if valid_name "$name" && valid_ipv6_in_parent "$address" "$parent" && \
           "$runtime" inspect "$name" >/dev/null 2>&1; then
            printf '%s %s\n' "$name" "$address" >>"$tmp"
            continue
        fi
        changed=true
        if valid_ipv6_in_parent "$address" "$parent"; then
            ip -6 route del "${address}/128" dev "$bridge" 2>/dev/null || true
        fi
    done <"$map_file"
    if [[ "$changed" == true ]]; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$map_file" || return 1
        sync_targets
        return $?
    fi
    rm -f "$tmp"
    return 0
}
restore_all() {
    local name address rc=0
    read_state || return 1
    [[ -f "$map_file" ]] || return 0
    [[ -f "$target_file" ]] || : >"$target_file"
    acquire_lock || return 1
    prune_stale_mappings_locked || rc=1
    while read -r name address; do
        [[ -n "$name" && -n "$address" ]] || continue
        [[ "$($runtime inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" == true ]] || continue
        attach_one_locked "$name" "$address" >/dev/null || {
            printf 'Failed to restore IPv6 for %s\n' "$name" >&2
            rc=1
        }
    done <"$map_file"
    release_lock
    return "$rc"
}

watch_all() {
    local interval="${PODMAN_IPV6_WATCH_INTERVAL:-2}"
    [[ "$interval" =~ ^[1-9][0-9]*$ ]] || interval=2
    while :; do
        restore_all || true
        sleep "$interval"
    done
}
remove_one_locked() {
    local name="$1" old_address tmp
    old_address=$(awk -v name="$name" '$1 == name {print $2; exit}' "$map_file" 2>/dev/null || true)
    tmp=$(mktemp "${map_file}.tmp.XXXXXX") || return 1
    awk -v name="$name" '$1 != name {print}' "$map_file" 2>/dev/null >"$tmp" || true
    chmod 600 "$tmp"
    mv -f "$tmp" "$map_file" || return 1
    sync_targets || return 1
    if [[ -n "$old_address" ]]; then
        ip -6 route del "${old_address}/128" dev "$bridge" 2>/dev/null || true
    fi
}
remove_one() {
    local name="$1" rc
    valid_name "$name" || return 1
    read_state || return 1
    [[ -f "$map_file" ]] || : >"$map_file"
    [[ -f "$target_file" ]] || : >"$target_file"
    acquire_lock || return 1
    remove_one_locked "$name"
    rc=$?
    release_lock
    return "$rc"
}

case "${1:-}" in
    --restore-all) restore_all ;;
    --watch) watch_all ;;
    --remove)
        name="${2:-}"
        remove_one "$name"
        ;;
    *)
        [[ -n "${1:-}" ]] || { printf 'usage: %s <container> [IPv6] | --restore-all | --watch | --remove <container>\n' "$0" >&2; exit 2; }
        attach_one "$@"
        ;;
esac
EOF
    chmod 700 "$helper"
    mkdir -p "$PODMAN_STATE_DIR"
    [[ -f "$(podman_state_file podman_ipv6_allocations)" ]] || : > "$(podman_state_file podman_ipv6_allocations)"
    [[ -f "$(podman_state_file podman_ipv6_targets)" ]] || : > "$(podman_state_file podman_ipv6_targets)"
    chmod 600 "$(podman_state_file podman_ipv6_allocations)"
    chmod 644 "$(podman_state_file podman_ipv6_targets)"
}

install_manual_ipv6_restore_service() {
    command -v systemctl >/dev/null 2>&1 || return 0
    cat > /etc/systemd/system/podman-ipv6-attach.service <<'EOF'
[Unit]
Description=Restore OneClickVirt Podman routed IPv6 addresses
After=network-online.target podman-restart.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/podman-ipv6-attach.sh --watch
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now podman-ipv6-attach.service 2>/dev/null || \
        _yellow "Could not start podman-ipv6-attach.service; routed IPv6 must be reattached manually after container restarts"
}

create_manual_ipv6_network() {
    local public_prefix="$1" net_err="$2" manual_subnet gateway bridge
    public_prefix=$(normalize_ipv6_subnet "$public_prefix" 2>/dev/null || true)
    [[ -n "$public_prefix" ]] || return 1
    manual_subnet=$(choose_manual_ipv6_subnet 2>/dev/null || true)
    [[ -n "$manual_subnet" ]] || { _yellow "Could not find a free ULA subnet for the Podman IPv6 bridge"; return 1; }
    gateway=$(ipv6_gateway_for_subnet "$manual_subnet" 2>/dev/null || true)
    [[ -n "$gateway" ]] || return 1
    bridge=podman-br1
    if ! podman network create --driver bridge --ipv6 --disable-dns \
        --interface-name "$bridge" --subnet 172.21.0.0/16 --gateway 172.21.0.1 \
        --subnet "$manual_subnet" --gateway "$gateway" podman-ipv6 2>"$net_err"; then
        if ! grep -qiE 'unknown (option|flag).*interface-name|unrecognized option.*interface-name' "$net_err" || \
           ! podman network create --driver bridge --ipv6 --disable-dns \
             --subnet 172.21.0.0/16 --gateway 172.21.0.1 --subnet "$manual_subnet" \
             --gateway "$gateway" podman-ipv6 2>"$net_err"; then
            _yellow "Manual IPv6 network creation failed: $(cat "$net_err" 2>/dev/null)"
            return 1
        fi
        bridge=$(podman network inspect -f '{{.NetworkInterface}}' podman-ipv6 2>/dev/null || true)
        [[ -n "$bridge" && "$bridge" != '<no value>' ]] || bridge=podman-br1
    fi
    printf '%s\n' "$public_prefix" > "$(podman_state_file podman_ipv6_public_prefix)"
    printf '%s\n' "$manual_subnet" > "$(podman_state_file podman_ipv6_manual_subnet)"
    printf '%s\n' "$gateway" > "$(podman_state_file podman_ipv6_manual_gateway)"
    printf '%s\n' "$bridge" > "$(podman_state_file podman_ipv6_manual_bridge)"
    printf '%s\n' manual > "$(podman_state_file podman_ipv6_network_mode)"
    install_manual_ipv6_attach_helper
    install_manual_ipv6_restore_service
    _green "podman-ipv6 created (manual routed IPv6): internal=${manual_subnet}, public parent=${public_prefix}"
    _yellow "Public IPv6 addresses will be assigned as /128 routes after each container starts"
    return 0
}

# Keep IPv6 usable when the host has connectivity but no public address pool
# that can be delegated to containers.  This is the only safe mode for a lone
# public /128 and remains a fallback when a routed-prefix setup cannot be used.
create_podman_nat66_ipv6_network() {
    local public_parent="$1" net_err="$2" subnet gateway
    subnet=$(choose_manual_ipv6_subnet 2>/dev/null || true)
    [[ -n "$subnet" ]] || {
        _yellow "Could not find a free ULA subnet for the Podman NAT66 bridge"
        return 1
    }
    gateway=$(ipv6_gateway_for_subnet "$subnet" 2>/dev/null || true)
    [[ -n "$gateway" ]] || return 1

    if ! create_managed_ipv6_network "$subnet" "$net_err"; then
        _yellow "Podman ULA NAT66 network creation failed: $(cat "$net_err" 2>/dev/null)"
        return 1
    fi
    if ! configure_podman_ipv6_nat66 "$subnet"; then
        podman network rm podman-ipv6 >/dev/null 2>&1 || true
        _yellow "Podman ULA bridge was created but NAT66 could not be installed"
        return 1
    fi

    printf '%s\n' "$subnet" > "$(podman_state_file podman_ipv6_subnet)"
    printf '%s\n' "$public_parent" > "$(podman_state_file podman_ipv6_public_parent)"
    set_ipv6_network_mode nat
    rm -f \
        "$(podman_state_file podman_ipv6_public_prefix)" \
        "$(podman_state_file podman_ipv6_manual_subnet)" \
        "$(podman_state_file podman_ipv6_manual_gateway)" \
        "$(podman_state_file podman_ipv6_manual_bridge)" \
        "$(podman_state_file podman_ipv6_allocations)" \
        "$(podman_state_file podman_ipv6_targets)" \
        "$(podman_state_file podman_ipv6_uplink)" \
        "$(podman_state_file podman_ipv6_ndp_required)"
    install_podman_ipv6_nat66_service
    _green "podman-ipv6 created (isolated ULA NAT66): IPv6=${subnet}"
    _yellow "The host has no delegable public IPv6 pool; containers retain outbound IPv6 through NAT66 and do not receive public /128 addresses"
    return 0
}

migrate_unmanaged_ipv6_network_default_route() {
    local prefix net_err

    if podman_ipv6_network_has_attached_containers; then
        _yellow "Existing unmanaged podman-ipv6 network lacks an explicit IPv6 default route but has attached containers"
        _yellow "Preserving the network. Stop/remove every container attached to podman-ipv6, then rerun this installer to migrate it safely"
        return 1
    fi
    if [[ "$(cat "$(podman_state_file podman_ipv6_bridge_owned)" 2>/dev/null)" != "true" ]]; then
        _yellow "Existing unmanaged podman-ipv6 network lacks an explicit IPv6 default route and podman-br1 is not marked installer-owned"
        _yellow "Refusing to replace an unowned bridge. Recreate podman-ipv6 manually with --opt no_default_route=1 and --route ::/0,<gateway>"
        return 1
    fi
    if ip link show podman-br1 >/dev/null 2>&1 && bridge_has_attached_interfaces podman-br1; then
        _yellow "podman-br1 has attached interfaces outside podman-ipv6; refusing to reconfigure the existing network"
        return 1
    fi

    prefix=$(podman_ipv6_network_subnet 2>/dev/null || true)
    prefix=$(normalize_ipv6_subnet "$prefix" 2>/dev/null || true)
    if [[ -z "$prefix" ]]; then
        _yellow "Could not read a safe public IPv6 subnet from the existing unmanaged podman-ipv6 network"
        return 1
    fi
    if ipv6_subnet_has_live_address "$prefix"; then
        _yellow "Existing unmanaged podman-ipv6 subnet ${prefix} contains a host IPv6 address; refusing to recreate it"
        return 1
    fi

    net_err=$(mktemp /tmp/podman-net.XXXXXX 2>/dev/null || true)
    [[ -n "$net_err" ]] || net_err="/tmp/podman-net.$$"
    _yellow "Migrating empty unmanaged podman-ipv6 network to add its IPv6 default route..."
    if ! podman network rm podman-ipv6 2>"$net_err"; then
        _yellow "Could not remove the empty unmanaged podman-ipv6 network: $(cat "$net_err" 2>/dev/null)"
        rm -f "$net_err" 2>/dev/null || true
        return 1
    fi
    if create_unmanaged_ipv6_network "$prefix" "$net_err"; then
        rm -f "$net_err" 2>/dev/null || true
        _green "Migrated podman-ipv6 with an explicit IPv6 default route"
        return 0
    fi

    _yellow "Could not add the IPv6 default route: $(cat "$net_err" 2>/dev/null)"
    if restore_unmanaged_ipv6_network_without_default_route "$prefix" "$net_err"; then
        _yellow "Restored the previous unmanaged network without an IPv6 default route; IPv6 remains disabled until migration succeeds"
    else
        _yellow "Could not restore the previous unmanaged network: $(cat "$net_err" 2>/dev/null)"
    fi
    rm -f "$net_err" 2>/dev/null || true
    return 1
}

create_ipv6_network() {
    local ipv6_cidr="$1"
    local prefix net_err managed_error network_subnet recorded_mode recorded_subnet
    local -a prefixes=()
    local manual_attempted=false
    _yellow "Creating Podman IPv6 network (podman-ipv6)..."
    if podman network exists podman-ipv6 2>/dev/null; then
        managed_error=$(podman network inspect -f '{{index .Options "mode"}}' podman-ipv6 2>/dev/null || true)
        network_subnet=$(podman_ipv6_network_subnet 2>/dev/null || true)
        recorded_mode=$(cat "$(podman_state_file podman_ipv6_network_mode)" 2>/dev/null | tr -d '[:space:]' || true)
        recorded_subnet=$(cat "$(podman_state_file podman_ipv6_subnet)" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$recorded_mode" == "nat" ]]; then
            if ! podman_ipv6_ula_state_matches_network "$recorded_mode" "$recorded_subnet" "$network_subnet"; then
                _yellow "Existing podman-ipv6 network is not the installer-managed ULA NAT66 network; preserving its current mode"
                return 1
            fi
            if ! configure_podman_ipv6_nat66 "$network_subnet"; then
                _yellow "Could not restore NAT66 for the existing podman-ipv6 network"
                return 1
            fi
            printf '%s\n' "$ipv6_cidr" > "$(podman_state_file podman_ipv6_public_parent)"
            set_ipv6_network_mode nat
            install_podman_ipv6_nat66_service
            _green "Reusing installer-managed Podman ULA NAT66 network: ${network_subnet}"
        elif [[ "$managed_error" == "manual" ]] || [[ -s "$(podman_state_file podman_ipv6_public_prefix)" && -s "$(podman_state_file podman_ipv6_manual_subnet)" ]]; then
            if [[ ! -x /usr/local/bin/podman-ipv6-attach.sh ]]; then
                install_manual_ipv6_attach_helper
            fi
            install_manual_ipv6_restore_service
            set_ipv6_network_mode manual
        elif [[ "$managed_error" == "unmanaged" ]]; then
            if ! podman_ipv6_network_has_explicit_default_route; then
                if migrate_unmanaged_ipv6_network_default_route; then
                    return 0
                fi
                set_ipv6_network_mode ""
                return 1
            fi
            set_ipv6_network_mode unmanaged
        else
            set_ipv6_network_mode managed
        fi
        _green "podman-ipv6 already exists"
        return 0
    fi

    net_err=$(mktemp /tmp/podman-net.XXXXXX 2>/dev/null || true)
    [[ -n "$net_err" ]] || net_err="/tmp/podman-net.$$"

    if [[ -n "${PODMAN_IPV6_SUBNET:-}" ]]; then
        prefix=$(normalize_ipv6_subnet "$PODMAN_IPV6_SUBNET" 2>/dev/null || true)
        if [[ -z "$prefix" ]]; then
            local supplied_address="${PODMAN_IPV6_SUBNET%/*}" supplied_prefix="${PODMAN_IPV6_SUBNET##*/}"
            if [[ "$PODMAN_IPV6_SUBNET" == */* ]] && [[ "$supplied_prefix" =~ ^[0-9]+$ ]] && \
               (( 10#$supplied_prefix <= 128 )) && is_public_ipv6 "$supplied_address"; then
                _yellow "PODMAN_IPV6_SUBNET=${PODMAN_IPV6_SUBNET} has no delegable public pool; using isolated ULA NAT66"
                if create_podman_nat66_ipv6_network "$PODMAN_IPV6_SUBNET" "$net_err"; then
                    rm -f "$net_err" 2>/dev/null || true
                    return 0
                fi
                rm -f "$net_err" 2>/dev/null || true
                return 1
            fi
            _yellow "PODMAN_IPV6_SUBNET must be a public IPv6 CIDR shorter than /128"
            rm -f "$net_err" 2>/dev/null || true
            return 1
        fi
        if ipv6_subnet_overlaps_host "$prefix"; then
            _yellow "PODMAN_IPV6_SUBNET=${prefix} overlaps a host route; switching to routed manual IPv6 mode"
            if create_manual_ipv6_network "$prefix" "$net_err"; then
                rm -f "$net_err" 2>/dev/null || true
                return 0
            fi
            if create_podman_nat66_ipv6_network "$prefix" "$net_err"; then
                rm -f "$net_err" 2>/dev/null || true
                return 0
            fi
            rm -f "$net_err" 2>/dev/null || true
            return 1
        fi
        prefixes=("$prefix")
    else
        mapfile -t prefixes < <(generate_ipv6_subnet_candidates "$ipv6_cidr" 2>/dev/null || true)
        if [[ ${#prefixes[@]} -eq 0 ]]; then
            _yellow "Cannot safely derive a managed public subnet from ${ipv6_cidr}; trying routed and NAT66 fallback modes"
            if create_manual_ipv6_network "$ipv6_cidr" "$net_err"; then
                rm -f "$net_err" 2>/dev/null || true
                return 0
            fi
            if create_podman_nat66_ipv6_network "$ipv6_cidr" "$net_err"; then
                rm -f "$net_err" 2>/dev/null || true
                return 0
            fi
            rm -f "$net_err" 2>/dev/null || true
            return 1
        fi
    fi

    for prefix in "${prefixes[@]}"; do
        if ipv6_subnet_has_live_address "$prefix"; then
            _yellow "Skipping IPv6 subnet ${prefix}: it contains a live host address"
            continue
        fi
        if ipv6_subnet_overlaps_host "$prefix"; then
            _yellow "IPv6 subnet ${prefix} overlaps a host CIDR; managed Netavark bridge would reject it"
            if [[ "$manual_attempted" == false ]] && create_manual_ipv6_network "$ipv6_cidr" "$net_err"; then
                manual_attempted=true
                rm -f "$net_err" 2>/dev/null || true
                return 0
            fi
            manual_attempted=true
            continue
        fi
        _yellow "Trying managed IPv6 subnet for podman-ipv6: ${prefix}"
        if create_managed_ipv6_network "$prefix" "$net_err"; then
            printf '%s\n' "$prefix" > "$(podman_state_file podman_ipv6_subnet)"
            set_ipv6_network_mode managed
            rm -f "$net_err" 2>/dev/null || true
            return 0
        fi
        managed_error=$(cat "$net_err" 2>/dev/null || true)
        _yellow "Managed IPv6 subnet ${prefix} failed: ${managed_error}"
    done

    # A public subnet that belongs to the host's on-link SLAAC prefix cannot be
    # passed to Netavark, even when the specific host address is unused. Use the
    # manual routed bridge so the runtime only sees an isolated ULA network.
    if [[ "$manual_attempted" == false ]] && create_manual_ipv6_network "$ipv6_cidr" "$net_err"; then
        rm -f "$net_err" 2>/dev/null || true
        return 0
    fi
    if create_podman_nat66_ipv6_network "$ipv6_cidr" "$net_err"; then
        rm -f "$net_err" 2>/dev/null || true
        return 0
    fi

    _yellow "Warning: podman-ipv6 creation failed; independent IPv6 remains disabled"
    printf '%s\n' "" > "$(podman_state_file podman_ipv6_subnet)"
    set_ipv6_network_mode ""
    rm -f "$(podman_state_file podman_ipv6_uplink)" "$(podman_state_file podman_ipv6_ndp_required)"
    rm -f "$net_err" 2>/dev/null || true
    return 1
}
# ======== 启动 NDP Responder ========
podman_api_socket() {
    local candidate
    candidate=$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)
    for candidate in "$candidate" /run/podman/podman.sock /var/run/podman/podman.sock; do
        [[ -n "$candidate" && "$candidate" != "<no value>" ]] || continue
        if [[ -S "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

ndpresponder_image_matches_architecture() {
    local expected="$1"
    local actual="$2"
    case "$expected:$actual" in
        amd64:amd64|amd64:x86_64|arm64:arm64|arm64:aarch64|arm:arm|arm:armv7|arm:armv7l) return 0 ;;
    esac
    return 1
}

ndpresponder_supports_target_file() {
    local image="$1" help_output
    # The published tag can lag the source repository. Probe the actual image
    # before mounting a target file; an older binary must never be put into a
    # restart loop with a flag it does not understand.
    help_output=$(podman run --rm "$image" --help 2>&1 || true)
    grep -Eq -- '(^|[[:space:],])--target-file([[:space:],=]|$)' <<<"$help_output"
}

ndpresponder_image_supports_required_features() {
    if [[ "${NDPRESPONDER_TARGET_FILE_REQUIRED:-false}" != true ]]; then
        return 0
    fi
    if ndpresponder_supports_target_file "$1"; then
        return 0
    fi
    _yellow "Responder image does not support --target-file; a source build is required for manual routed IPv6"
    _yellow "ndpresponder 镜像不支持 --target-file；手动路由 IPv6 需要从源码构建新版程序"
    return 1
}

ndpresponder_existing_container_image() {
    local image
    podman inspect ndpresponder >/dev/null 2>&1 || return 1
    image=$(podman inspect -f '{{.ImageName}}' ndpresponder 2>/dev/null || true)
    if [[ -z "$image" || "$image" == '<no value>' ]]; then
        image=$(podman inspect -f '{{.Image}}' ndpresponder 2>/dev/null || true)
    fi
    [[ -n "$image" && "$image" != '<no value>' ]] || return 1
    printf '%s\n' "$image"
}

quarantine_incompatible_manual_ndpresponder() {
    local existing_image
    [[ "${NDPRESPONDER_TARGET_FILE_REQUIRED:-false}" == true ]] || return 0
    existing_image=$(ndpresponder_existing_container_image 2>/dev/null || true)
    [[ -n "$existing_image" ]] || return 0
    if ndpresponder_supports_target_file "$existing_image"; then
        return 0
    fi

    _yellow "Existing ndpresponder cannot read --target-file; removing it to stop an incompatible restart loop"
    _yellow "现有 ndpresponder 不支持 --target-file，正在移除以停止不兼容的重启循环"
    # Updating the policy before removal handles older containers that were
    # created with --restart always and may otherwise keep consuming CPU while
    # a source-build fallback is unavailable.
    podman update --restart=no ndpresponder >/dev/null 2>&1 || true
    podman rm -f ndpresponder >/dev/null 2>&1 || true
}

resolve_ndpresponder_image() {
    local arch_tag="" registry_image="" image_arch source_image source_url
    NDPRESPONDER_IMAGE=""

    case "$ARCH_TYPE" in
        amd64) arch_tag="x86" ;;
        arm64) arch_tag="aarch64" ;;
        arm)   ;;
        *)
            _yellow "Unsupported responder architecture: ${ARCH_TYPE}"
            return 1
            ;;
    esac

    # Always validate the pulled image before considering it usable. An image
    # with a matching tag can still have been published for the wrong CPU.
    if [[ -n "$arch_tag" ]]; then
        local candidate="spiritlhl/ndpresponder_${arch_tag}"
        _yellow "Pulling ndpresponder image: ${candidate}"
        if podman pull "$candidate" 2>/dev/null; then
            registry_image="$candidate"
        elif podman pull "docker.io/${candidate}" 2>/dev/null; then
            registry_image="docker.io/${candidate}"
        else
            _yellow "Could not pull a responder image for ${ARCH_TYPE}; building a local responder image instead"
        fi

        if [[ -n "$registry_image" ]]; then
            image_arch=$(podman image inspect --format '{{.Architecture}}' "$registry_image" 2>/dev/null || true)
            if ndpresponder_image_matches_architecture "$ARCH_TYPE" "$image_arch" && \
               ndpresponder_image_supports_required_features "$registry_image"; then
                NDPRESPONDER_IMAGE="$registry_image"
                return 0
            fi
            _yellow "Responder image ${registry_image} is ${image_arch:-unknown}, expected ${ARCH_TYPE}; building a local responder image instead"
        fi
    else
        _yellow "No published responder image is configured for ${ARCH_TYPE}; building a local responder image instead"
    fi

    # Podman supports a Git repository as a build context. This fallback keeps
    # ARM hosts usable while a registry tag is absent or incorrectly published.
    # Do not remove the running responder until the fresh local image passes
    # the same architecture check above.
    source_image="localhost/oneclickvirt-ndpresponder:${ARCH_TYPE}"
    source_url="${NDPRESPONDER_SOURCE_URL:-https://github.com/oneclickvirt/ndpresponder.git}"
    _yellow "Building ndpresponder from source: ${source_url}"
    if ! podman build --tag "$source_image" "$source_url"; then
        _yellow "Could not build a responder image from source; preserving any existing responder"
        return 1
    fi
    image_arch=$(podman image inspect --format '{{.Architecture}}' "$source_image" 2>/dev/null || true)
    if ! ndpresponder_image_matches_architecture "$ARCH_TYPE" "$image_arch"; then
        _yellow "Locally built responder image ${source_image} is ${image_arch:-unknown}, expected ${ARCH_TYPE}; preserving any existing responder"
        return 1
    fi
    if ! ndpresponder_image_supports_required_features "$source_image"; then
        _yellow "The source-built responder is missing the required target-file capability; preserving any existing responder"
        _yellow "源码构建的 ndpresponder 缺少所需的 target-file 能力，将保留现有 responder"
        return 1
    fi
    NDPRESPONDER_IMAGE="$source_image"
    return 0
}

start_ndpresponder() {
    _yellow "Starting NDP responder for IPv6..."
    local podman_socket ndp_status ndp_logs ndp_image ndp_target_file network_mode ndp_required uplink
    local -a ndp_args ndp_volume_args
    if ! podman network exists podman-ipv6 2>/dev/null; then
        _yellow "podman-ipv6 network not found, skipping ndpresponder"
        return 1
    fi
    network_mode=""
    ndp_required=""
    if [[ -f "$(podman_state_file podman_ipv6_network_mode)" ]]; then
        network_mode=$(tr -d '[:space:]' <"$(podman_state_file podman_ipv6_network_mode)" 2>/dev/null || true)
    fi
    if [[ -f "$(podman_state_file podman_ipv6_ndp_required)" ]]; then
        ndp_required=$(tr -d '[:space:]' <"$(podman_state_file podman_ipv6_ndp_required)" 2>/dev/null || true)
    fi
    if [[ "$network_mode" == "nat" || "$ndp_required" == "false" ]]; then
        if [[ "$network_mode" != "nat" ]]; then
            _green "Podman routed IPv6 uses a non-Ethernet uplink; NDP responder is not required"
            return 0
        fi
        _green "Podman IPv6 uses ULA NAT66; NDP responder is not required"
        return 0
    fi
    if [[ "$ndp_required" != "true" ]]; then
        _yellow "Podman IPv6 NDP state is incomplete; refusing to guess an IPv4 uplink"
        return 1
    fi
    uplink=""
    if [[ -f "$(podman_state_file podman_ipv6_uplink)" ]]; then
        uplink=$(tr -d '[:space:]' <"$(podman_state_file podman_ipv6_uplink)" 2>/dev/null || true)
    fi
    if [[ -z "$uplink" ]]; then
        _yellow "Podman IPv6 NDP state is missing its IPv6 uplink"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start podman.socket 2>/dev/null || true
    fi
    podman_socket=$(podman_api_socket || true)
    if [[ -z "$podman_socket" ]]; then
        _yellow "Podman API socket not found; ndpresponder cannot track container IPv6 addresses"
        return 1
    fi
    if [[ "$network_mode" == "manual" ]]; then
        NDPRESPONDER_TARGET_FILE_REQUIRED=true
    else
        NDPRESPONDER_TARGET_FILE_REQUIRED=false
    fi
    quarantine_incompatible_manual_ndpresponder
    if ! resolve_ndpresponder_image; then
        return 1
    fi
    ndp_image="$NDPRESPONDER_IMAGE"
    podman rm -f ndpresponder 2>/dev/null || true
    ndp_target_file=""
    if [[ "$network_mode" == "manual" ]]; then
        ndp_target_file=$(podman_state_file podman_ipv6_targets)
        [[ -f "$ndp_target_file" ]] || : > "$ndp_target_file"
        ndp_args=(--target-file /etc/ndpresponder-targets)
        ndp_volume_args=(--volume "${ndp_target_file}:/etc/ndpresponder-targets:ro")
    else
        ndp_args=(-N podman-ipv6)
        ndp_volume_args=()
    fi
    ndp_args=(-i "$uplink" "${ndp_args[@]}")
    if podman run -d \
        --restart on-failure:3 \
        --cpus 0.02 \
        --memory 64m \
        --cap-drop=ALL \
        --cap-add=NET_RAW \
        --cap-add=NET_ADMIN \
        --network host \
        --volume "${podman_socket}:/var/run/docker.sock:ro" \
        "${ndp_volume_args[@]}" \
        -e DOCKER_HOST=unix:///var/run/docker.sock \
        --name ndpresponder \
        "${ndp_image}" \
        "${ndp_args[@]}" 2>/dev/null; then
        # ndpresponder verifies the API socket before serving. Keep observing
        # past that bounded probe so a process that is about to exit is never
        # recorded as a healthy IPv6 responder.
        for _ndp_attempt in 1 2 3 4 5 6; do
            sleep 1
            ndp_status=$(podman inspect -f '{{.State.Status}}' ndpresponder 2>/dev/null || true)
            if [[ "$ndp_status" == "running" ]]; then
                _green "NDP responder started and connected to the Podman API socket"
                return 0
            fi
        done
        ndp_logs=$(podman logs --tail 20 ndpresponder 2>&1 || true)
        _yellow "ndpresponder exited immediately: ${ndp_logs}"
    else
        _yellow "ndpresponder start failed; IPv6 may require manual NDP configuration"
    fi
    # Do not leave a failed responder with an unconditional restart policy.
    # The old container would otherwise spin forever on an unsupported flag.
    podman rm -f ndpresponder 2>/dev/null || true
    return 1
}
# ======== 配置 podman.socket 服务（可选，供 API 使用） ========
systemd_unit_exists() {
    local unit="$1"
    systemctl list-unit-files "$unit" --no-legend 2>/dev/null | awk -v wanted="$unit" '$1 == wanted { found=1 } END { exit found ? 0 : 1 }'
}
setup_podman_socket() {
    command -v systemctl >/dev/null 2>&1 || return 0
    if systemd_unit_exists podman.socket; then
        systemctl enable --now podman.socket 2>/dev/null || true
        _green "podman.socket enabled"
    fi
    if ! systemd_unit_exists podman-restart.service; then
        printf '%s\n' "[Unit]" "Description=OneClickVirt Podman Restart Policy Containers" "Documentation=https://github.com/oneclickvirt/podman" "After=network-online.target" "Wants=network-online.target" "[Service]" "Type=oneshot" "RemainAfterExit=yes" \
            "ExecStart=/bin/sh -c 'for policy in always on-failure; do podman ps -aq --filter restart-policy=\"\$policy\" 2>/dev/null; done | sort -u | while IFS= read -r id; do [ -n \"\$id\" ] && podman start \"\$id\" || true; done'" \
            "ExecStop=/bin/sh -c 'for policy in always on-failure; do podman ps -aq --filter restart-policy=\"\$policy\" 2>/dev/null; done | sort -u | while IFS= read -r id; do [ -n \"\$id\" ] && podman stop \"\$id\" || true; done'" "[Install]" "WantedBy=multi-user.target" > /etc/systemd/system/podman-restart.service
        systemctl daemon-reload 2>/dev/null || true
    fi
    if systemd_unit_exists podman-restart.service; then
        systemctl enable podman-restart.service 2>/dev/null || true
        _green "podman-restart.service enabled (containers with --restart auto-start on boot)"
    fi
}
# ======== DNS 保活服务 ========
setup_dns_check() {
    _yellow "Setting up DNS liveness check service..."
cat > /usr/local/bin/check-dns-podman.sh <<'EOF'
#!/bin/bash
# DNS liveness check for Podman containers
while true; do
    if ! { { command -v nslookup >/dev/null 2>&1 && nslookup github.com >/dev/null 2>&1; } || { command -v getent >/dev/null 2>&1 && getent hosts github.com >/dev/null 2>&1; } || ping -c 1 -W 2 github.com >/dev/null 2>&1; }; then
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
    if [[ "$(cat "$(podman_state_file podman_ipv6_enabled)" 2>/dev/null)" == "true" ]]; then
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
    _blue "  2026.08.26"
    _blue "======================================================"
    echo
    # 重新计算 int（系统类型索引）
    for ((int = 0; int < ${#REGEX[@]}; int++)); do
        if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
            break
        fi
    done
    install_base_deps
    detect_interface
    check_ipv6
    detect_firewall_backend
    # ======== 硬盘限制支持询问 ========
    # 支持以下环境变量实现一键安装（跳过所有交互提示）：
    #   noninteractive=true            使用默认值跳过所有交互提示
    #   NEED_DISK_LIMIT=y/yes/true/1   是否启用 btrfs 容器磁盘大小限制
    #   PODMAN_INSTALL_PATH=<path>     Podman 存储路径（默认 /var/lib/containers/storage）
    #   PODMAN_POOL_SIZE=<整数>        存储池大小，单位 GB（仅 NEED_DISK_LIMIT 启用时有效）
    #   PODMAN_LOOP_FILE=<path>        loop 镜像文件路径（默认 /opt/podman-pool.img）
    # --- 是否启用磁盘大小限制 ---
    if [[ -n "${NEED_DISK_LIMIT:-}" ]]; then
        if is_truthy "${NEED_DISK_LIMIT}"; then
            _need_disk_limit_input="y"
            _yellow "环境变量 NEED_DISK_LIMIT=${NEED_DISK_LIMIT}：启用容器磁盘大小限制"
        else
            _need_disk_limit_input="n"
            _yellow "环境变量 NEED_DISK_LIMIT=${NEED_DISK_LIMIT}：不启用容器磁盘大小限制"
        fi
    elif is_noninteractive; then
        _need_disk_limit_input="n"
        _yellow "noninteractive=true：使用默认标准 Podman 安装，不启用容器磁盘大小限制"
    else
        _green "是否需要支持容器硬盘大小限制的Podman环境？（支持btrfs存储驱动）"
        _green "Do you need Podman with container disk size limitation? (Support btrfs storage driver)"
        _blue "如果选择 'y'，可以为每个容器限制磁盘空间 / If 'y', you can limit the disk space for each container"
        _blue "如果选择 'n'，则为标准Podman安装，无磁盘限制 / If 'n', standard Podman installation without disk limits"
        reading "Do you need container disk size limitation? ([n]/y): " _need_disk_limit_input
    fi
    # --- Podman 存储路径 ---
    if [[ -n "${PODMAN_INSTALL_PATH:-}" ]]; then
        _podman_install_path="${PODMAN_INSTALL_PATH}"
        _yellow "环境变量 PODMAN_INSTALL_PATH：${_podman_install_path}"
    elif is_noninteractive; then
        _podman_install_path="/var/lib/containers/storage"
        _yellow "noninteractive=true：使用默认 Podman 存储路径 ${_podman_install_path}"
    else
        _green "Where do you want to install Podman storage? (Enter to default: /var/lib/containers/storage):"
        reading "Podman存储路径？（回车则默认：/var/lib/containers/storage）：" _podman_install_path
    fi
    if [[ -z "$_podman_install_path" ]]; then
        _podman_install_path="/var/lib/containers/storage"
    fi
    echo "$_podman_install_path" > /usr/local/bin/podman_install_path
    if is_truthy "${_need_disk_limit_input:-}"; then
        echo "true" > /usr/local/bin/podman_need_disk_limit
        # --- 存储池大小 ---
        if [[ -n "${PODMAN_POOL_SIZE:-}" ]] && [[ "${PODMAN_POOL_SIZE}" =~ ^[1-9][0-9]*$ ]]; then
            _podman_pool_size="${PODMAN_POOL_SIZE}"
            _yellow "环境变量 PODMAN_POOL_SIZE：${_podman_pool_size}GB"
        elif is_noninteractive; then
            _podman_pool_size="20"
            _yellow "noninteractive=true：PODMAN_POOL_SIZE 未提供或无效，使用默认 ${_podman_pool_size}GB"
        else
            while true; do
                _green "How large a Podman storage pool is needed? (unit: GB, e.g., enter 20 for 20G):"
                reading "需要多大的Podman存储池？（单位GB，例如输入20表示20G）：" _podman_pool_size
                if [[ "$_podman_pool_size" =~ ^[1-9][0-9]*$ ]]; then
                    break
                else
                    _yellow "Invalid input, please enter a positive integer. / 输入无效，请输入一个正整数。"
                fi
            done
        fi
        # --- loop 文件路径 ---
        if [[ -n "${PODMAN_LOOP_FILE:-}" ]]; then
            _podman_loop_file="${PODMAN_LOOP_FILE}"
            _yellow "环境变量 PODMAN_LOOP_FILE：${_podman_loop_file}"
        elif is_noninteractive; then
            _podman_loop_file="/opt/podman-pool.img"
            _yellow "noninteractive=true：使用默认 Podman loop 文件 ${_podman_loop_file}"
        else
            _green "Where do you want to store the Podman loop file? (Enter to default: /opt/podman-pool.img):"
            reading "Podman循环文件存储位置？（回车则默认：/opt/podman-pool.img）：" _podman_loop_file
        fi
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
        if ! setup_podman_btrfs_loop "$_podman_pool_size" "$_podman_loop_file" "$_podman_install_path"; then
            _red "Podman btrfs loop filesystem setup failed"
            exit 1
        fi
    fi
    install_podman
    configure_podman_storage
    configure_kernel
    configure_rootless_user
    create_podman_network
    setup_podman_socket
    setup_dns_check
    if [[ "$IPV6_ENABLED" == true ]]; then
        if adapt_ipv6 && \
           create_ipv6_network "$IPV6_CIDR" && \
           configure_podman_ipv6_ndp_state && \
           start_ndpresponder; then
            echo "true" > "$(podman_state_file podman_ipv6_enabled)"
        else
            echo "false" > "$(podman_state_file podman_ipv6_enabled)"
        fi
    else
        echo "false" > "$(podman_state_file podman_ipv6_enabled)"
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
