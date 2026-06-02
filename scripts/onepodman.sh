#!/bin/bash
# from
# https://github.com/oneclickvirt/podman
# 2026.03.01

# Usage:
# ./onepodman.sh <name> <cpu> <memory_mb> <password> <sshport> <startport> <endport> [independent_ipv6:y/n] [system] [disk_gb]

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
export DEBIAN_FRONTEND=noninteractive

WITHOUT_CDN=false
if is_truthy "${WITHOUTCDN:-}"; then
    WITHOUT_CDN=true
fi

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi

# ======== 参数 ========
name="${1:-test}"
cpu="${2:-1}"
memory="${3:-512}"
passwd="${4:-123456}"
sshport="${5:-25000}"
startport="${6:-34975}"
endport="${7:-35000}"
independent_ipv6="${8:-N}"
system="${9:-debian}"
disk="${10:-0}"

declare -A used_host_ports=()

validate_port() {
    local value="${1:-}"
    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 ))
}

mark_used_port_range() {
    local start="$1"
    local end="$2"
    local p
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || return 0
    (( start >= 1 && end <= 65535 && start <= end )) || return 0
    for ((p = start; p <= end; p++)); do
        used_host_ports["$p"]=1
    done
}

mark_port_token() {
    local token="${1:-}"
    if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        mark_used_port_range "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
        mark_used_port_range "$token" "$token"
    fi
}

collect_used_host_ports() {
    local listen_port port_line mapping
    used_host_ports=()
    if command -v ss >/dev/null 2>&1; then
        while IFS= read -r listen_port; do
            mark_port_token "$listen_port"
        done < <(ss -H -tuln 2>/dev/null | awk '{n=split($5,a,":"); p=a[n]; gsub(/[^0-9]/,"",p); if(p!="") print p}' || true)
    fi
    if command -v podman >/dev/null 2>&1; then
        while IFS= read -r port_line; do
            while IFS= read -r mapping; do
                [[ -n "$mapping" ]] && mark_port_token "${mapping%->}"
            done < <(printf '%s\n' "$port_line" | grep -oE '([0-9]{1,5})(-[0-9]{1,5})?->' || true)
        done < <(podman ps -a --format '{{.Ports}}' 2>/dev/null || true)
    fi
}

validate_inputs() {
    system=$(echo "$system" | tr '[:upper:]' '[:lower:]')
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        _red "Invalid container name: ${name}"
        exit 1
    fi
    if [[ ! "$cpu" =~ ^[0-9]+([.][0-9]+)?$ || "$cpu" == "0" || "$cpu" == "0.0" ]]; then
        _red "Invalid CPU value: ${cpu}"
        exit 1
    fi
    if [[ ! "$memory" =~ ^[1-9][0-9]*$ ]]; then
        _red "Invalid memory value: ${memory}"
        exit 1
    fi
    if [[ -z "$passwd" || "$passwd" =~ [[:space:]] ]]; then
        _red "Invalid password: password must be non-empty and must not contain whitespace"
        exit 1
    fi
    if ! validate_port "$sshport" || ! validate_port "$startport" || ! validate_port "$endport"; then
        _red "Invalid port value: ssh=${sshport}, range=${startport}-${endport}"
        exit 1
    fi
    if (( startport > endport )); then
        _red "Invalid port range: startport must be <= endport"
        exit 1
    fi
    if [[ ! "$disk" =~ ^[0-9]+$ ]]; then
        _red "Invalid disk value: ${disk}"
        exit 1
    fi
    if [[ ! "$system" =~ ^(ubuntu|debian|alpine|almalinux|rockylinux|openeuler)$ ]]; then
        _red "Unsupported system: ${system}"
        exit 1
    fi
    if is_truthy "$independent_ipv6"; then
        independent_ipv6="y"
    else
        independent_ipv6="n"
    fi
}

validate_inputs

# ======== 系统检测 ========
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch" "Alpine")
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

# ======== 架构 ========
ARCH_UNAME=$(uname -m)
case "$ARCH_UNAME" in
    x86_64)  ARCH_TYPE="amd64" ;;
    aarch64) ARCH_TYPE="arm64" ;;
    *)       ARCH_TYPE="amd64" ;;
esac
if [[ -f /usr/local/bin/podman_arch ]]; then
    ARCH_TYPE=$(cat /usr/local/bin/podman_arch)
fi

# ======== 存储驱动检测 ========
check_storage_driver() {
    podman_storage_driver="overlay"
    if [[ -f /usr/local/bin/podman_storage_driver ]]; then
        podman_storage_driver=$(cat /usr/local/bin/podman_storage_driver)
    fi
    if [[ "$podman_storage_driver" == "btrfs" ]]; then
        btrfs_support="Y"
        _green "Detected btrfs storage driver, disk size limitation is supported"
        _green "检测到btrfs存储驱动，支持硬盘大小限制"
    else
        btrfs_support="N"
        if [[ "$disk" != "0" ]]; then
            _yellow "Current storage driver ($podman_storage_driver) does not support disk size limitation, ignoring disk parameter"
            _yellow "当前存储驱动($podman_storage_driver)不支持硬盘大小限制，忽略硬盘参数"
            disk="0"
        fi
    fi
}

check_storage_driver

# ======== 检查 Podman 与资源冲突 ========
if ! command -v podman >/dev/null 2>&1; then
    _red "podman not found. Please run podmaninstall.sh first."
    exit 1
fi

if ! is_truthy "${PODMAN_SKIP_RESOURCE_CHECK:-}"; then
    if podman container exists "$name" 2>/dev/null; then
        _red "Container ${name} already exists"
        exit 1
    fi

    collect_used_host_ports
    if [[ -n "${used_host_ports[$sshport]:-}" ]]; then
        _red "SSH host port ${sshport} is already in use"
        exit 1
    fi
    for ((port = startport; port <= endport; port++)); do
        if [[ -n "${used_host_ports[$port]:-}" ]]; then
            _red "Public host port ${port} is already in use"
            exit 1
        fi
    done
fi

# ======== CDN ========
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

# ======== IPv6 条件检测（三重：网络存在 + ndpresponder 运行 + 地址文件有值）========
IPV6_ENABLED=false
ipv6_address=""
ipv6_address_without_last_segment=""
if [[ -f /usr/local/bin/podman_ipv6_enabled ]] && \
   [[ "$(cat /usr/local/bin/podman_ipv6_enabled)" == "true" ]]; then
    # 条件1：podman-ipv6 网络存在
    if podman network exists podman-ipv6 2>/dev/null; then
        # 条件2：ndpresponder 容器正在运行
        ndp_status=$(podman inspect -f '{{.State.Status}}' ndpresponder 2>/dev/null || echo "")
        if [[ "$ndp_status" == "running" ]]; then
            # 条件3：IPv6 地址文件有值
            if [[ -f /usr/local/bin/podman_check_ipv6 ]] && \
               [[ -s /usr/local/bin/podman_check_ipv6 ]]; then
                ipv6_address=$(cat /usr/local/bin/podman_check_ipv6)
                ipv6_address_without_last_segment="${ipv6_address%:*}:"
                IPV6_ENABLED=true
            fi
        fi
    fi
fi
# 读取公网 IPv4（用于 SSH 连接信息显示）
host_ipv4=""
if [[ -f /usr/local/bin/podman_main_ipv4 ]]; then
    host_ipv4=$(cat /usr/local/bin/podman_main_ipv4)
fi
[[ -z "$host_ipv4" ]] && host_ipv4=$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)

# ======== lxcfs 检测 ========
lxcfs_volumes=""
for dir in /var/lib/lxcfs/proc /var/lib/lxcfs; do
    if [[ -d "${dir}/proc" ]]; then
        lxcfs_volumes="-v ${dir}/proc/cpuinfo:/proc/cpuinfo:rw \
            -v ${dir}/proc/diskstats:/proc/diskstats:rw \
            -v ${dir}/proc/meminfo:/proc/meminfo:rw \
            -v ${dir}/proc/stat:/proc/stat:rw \
            -v ${dir}/proc/uptime:/proc/uptime:rw"
        break
    fi
done

# ======== 下载并加载镜像 ========
tag_loaded_image() {
    local system_type="$1"
    local canonical_image="$2"
    local load_output="$3"
    local ref
    local candidates=(
        "localhost/spiritlhl/${system_type}:latest"
        "spiritlhl/${system_type}:latest"
        "docker.io/spiritlhl/${system_type}:latest"
    )

    for ref in "${candidates[@]}"; do
        if podman image exists "$ref" 2>/dev/null; then
            podman tag "$ref" "$canonical_image" 2>/dev/null || true
            return 0
        fi
    done

    ref=$(printf '%s\n' "$load_output" | awk -F': ' '/Loaded image/ {print $NF; exit}')
    if [[ -n "$ref" ]] && podman image exists "$ref" 2>/dev/null; then
        podman tag "$ref" "$canonical_image" 2>/dev/null || true
        return 0
    fi
    return 1
}

download_and_load_image() {
    local system_type="$1"
    local arch="$ARCH_TYPE"
    local tar_filename="spiritlhl_${system_type}_${arch}.tar.gz"
    # Podman 加载本地 tar 后镜像统一存储在 localhost/ 命名空间下
    local canonical_image="localhost/spiritlhl/${system_type}:latest"

    # 检查本地是否已有镜像
    if podman image exists "${canonical_image}" 2>/dev/null; then
        _green "Image ${canonical_image} already exists, skipping download"
        export image_name="${canonical_image}"
        return 0
    fi

    # 优先从 GitHub Releases 下载（支持 CDN 加速）
    local github_url="https://github.com/oneclickvirt/podman/releases/download/${system_type}/${tar_filename}"
    local download_url="${cdn_success_url}${github_url}"
    _yellow "Downloading image: $download_url"

    if curl -L --connect-timeout 15 --max-time 600 -o "/tmp/${tar_filename}" "$download_url" && \
       [[ -f "/tmp/${tar_filename}" ]] && [[ -s "/tmp/${tar_filename}" ]]; then
        _yellow "Loading image from tar..."
        local load_output
        if load_output=$(podman load -i "/tmp/${tar_filename}" 2>&1); then
            printf '%s\n' "$load_output"
            rm -f "/tmp/${tar_filename}"
            # 确保以 localhost/spiritlhl/<os>:latest 标记；只使用加载结果或已知候选 tag。
            if ! podman image exists "${canonical_image}" 2>/dev/null; then
                tag_loaded_image "$system_type" "$canonical_image" "$load_output" || true
            fi
            if ! podman image exists "${canonical_image}" 2>/dev/null; then
                _red "Loaded image could not be resolved for ${system_type}"
                exit 1
            fi
            export image_name="${canonical_image}"
            _green "Image loaded: ${image_name}"
            return 0
        else
            _yellow "Failed to load tar, removing..."
            rm -f "/tmp/${tar_filename}"
        fi
    else
        _yellow "CDN/direct download failed for ${download_url}"
        rm -f "/tmp/${tar_filename}" 2>/dev/null
    fi

    # 回退：从 ghcr.io 拉取
    local ghcr_image="ghcr.io/oneclickvirt/podman:${system_type}-${arch}"
    _yellow "Trying to pull from ghcr.io: $ghcr_image"
    if podman pull "$ghcr_image"; then
        podman tag "$ghcr_image" "${canonical_image}" 2>/dev/null || true
        export image_name="${canonical_image}"
        _green "Image pulled from ghcr.io: ${ghcr_image}"
        return 0
    fi

    _red "Failed to obtain image for ${system_type}"
    exit 1
}

# ======== 下载 SSH 初始化脚本 ========
download_and_copy_ssh_scripts() {
    local cname="$1"
    local sys_type="$2"
    local base_url="${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/podman/main/scripts"
    local tmp_file

    if [[ "$sys_type" == "alpine" ]]; then
        tmp_file="/tmp/podman_${cname}_ssh_sh.sh"
        rm -f "$tmp_file" 2>/dev/null || true
        curl -sL --connect-timeout 10 --max-time 30 \
            "${base_url}/ssh_sh.sh" -o "$tmp_file" 2>/dev/null || true
        if [[ -s "$tmp_file" ]]; then
            podman cp "$tmp_file" "${cname}:/ssh_sh.sh" 2>/dev/null || true
        fi
    else
        tmp_file="/tmp/podman_${cname}_ssh_bash.sh"
        rm -f "$tmp_file" 2>/dev/null || true
        curl -sL --connect-timeout 10 --max-time 30 \
            "${base_url}/ssh_bash.sh" -o "$tmp_file" 2>/dev/null || true
        if [[ -s "$tmp_file" ]]; then
            podman cp "$tmp_file" "${cname}:/ssh_bash.sh" 2>/dev/null || true
        fi
    fi
    rm -f "$tmp_file" 2>/dev/null || true
}

# ======== 主逻辑 ========
main() {
    _blue "Creating container: name=${name} cpu=${cpu} memory=${memory}MB system=${system}"
    _blue "SSH port: ${sshport}  port range: ${startport}-${endport}  IPv6: ${independent_ipv6}"

    download_and_load_image "$system"

    # 网络选项
    local net_opts=""
    local ipv6_env=""
    if [[ "${independent_ipv6,,}" == "y" ]] && [[ "$IPV6_ENABLED" == "true" ]]; then
        net_opts="--network podman-ipv6"
        ipv6_env="-e IPV6_ENABLED=true"
    else
        if podman network exists podman-net 2>/dev/null; then
            net_opts="--network podman-net"
        else
            net_opts="--network bridge"
        fi
    fi

    # 磁盘限制选项（仅 btrfs 驱动支持）
    local storage_opts=""
    if [[ "$btrfs_support" == "Y" ]] && [[ "$disk" -gt 0 ]]; then
        storage_opts="--storage-opt size=${disk}g"
    fi

    # CPU 限制（podman 使用 --cpus 与 docker 相同）
    # 内存限制
    # 运行容器
    # shellcheck disable=SC2086
    podman run -d \
        --pull=never \
        --cpus="${cpu}" \
        --memory="${memory}m" \
        --memory-swap="${memory}m" \
        --name "${name}" \
        ${net_opts} \
        -p "${sshport}:22" \
        -p "${startport}-${endport}:${startport}-${endport}" \
        --cap-add=MKNOD \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --restart always \
        ${storage_opts} \
        ${lxcfs_volumes} \
        ${ipv6_env} \
        -e ROOT_PASSWORD="${passwd}" \
        "${image_name}"

    if [[ $? -ne 0 ]]; then
        _red "Failed to create container ${name}"
        exit 1
    fi

    _green "Container ${name} created successfully"
    sleep 3

    # 复制并执行 SSH 初始化脚本
    download_and_copy_ssh_scripts "$name" "$system"

    if [[ "$system" == "alpine" ]]; then
        if podman exec "${name}" test -f /ssh_sh.sh 2>/dev/null; then
            podman exec -e ROOT_PASSWORD="${passwd}" "${name}" sh -c 'sh /ssh_sh.sh "$ROOT_PASSWORD"' 2>/dev/null || true
        else
            _yellow "ssh_sh.sh not found in container, relying on built-in entrypoint"
        fi
        podman exec -e ROOT_PASSWORD="${passwd}" "${name}" sh -c 'printf "%s\n" "root:${ROOT_PASSWORD}" | chpasswd' 2>/dev/null || true
    else
        if podman exec "${name}" test -f /ssh_bash.sh 2>/dev/null; then
            podman exec -e ROOT_PASSWORD="${passwd}" "${name}" bash -c 'bash /ssh_bash.sh "$ROOT_PASSWORD"' 2>/dev/null || true
        else
            _yellow "ssh_bash.sh not found in container, relying on built-in entrypoint"
        fi
        podman exec -e ROOT_PASSWORD="${passwd}" "${name}" bash -c 'printf "%s\n" "root:${ROOT_PASSWORD}" | chpasswd' 2>/dev/null || true
    fi

    # 尝试启动 sshd（若 entrypoint 未自动启动）
    if [[ "$system" == "alpine" ]]; then
        podman exec "${name}" sh -c "pgrep -x sshd || /usr/sbin/sshd" 2>/dev/null || true
    else
        podman exec "${name}" bash -c \
            "pgrep -x sshd >/dev/null || (service ssh start 2>/dev/null || service sshd start 2>/dev/null || /usr/sbin/sshd 2>/dev/null)" 2>/dev/null || true
    fi

    sleep 2

    # 记录容器信息
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" > "${name}"
    cat "${name}"

    # 查询容器实际获得的 IPv6 地址（仅 IPv6 模式）
    local container_ipv6=""
    if [[ "${independent_ipv6,,}" == "y" ]] && [[ "$IPV6_ENABLED" == "true" ]]; then
        container_ipv6=$(podman inspect -f \
            '{{range .NetworkSettings.Networks}}{{.GlobalIPv6Address}}{{end}}' \
            "${name}" 2>/dev/null || true)
        [[ -z "$container_ipv6" ]] && container_ipv6=$(podman inspect -f \
            '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
            "${name}" 2>/dev/null | grep -E '^[0-9a-f:]+:[0-9a-f:]+$' | head -1 || true)
    fi

    echo ""
    _green "======================================================"
    _green "  Container: ${name}"
    _green "  System:    ${system}"
    _green "  SSH:       ${host_ipv4}:${sshport}"
    _green "  Password:  ${passwd}"
    _green "  Ports:     ${startport}-${endport}"
    if [[ -n "$container_ipv6" ]]; then
        _green "  IPv6:      ${container_ipv6}"
    fi
    _green "======================================================"
}

main "$@"
