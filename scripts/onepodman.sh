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
export DEBIAN_FRONTEND=noninteractive

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
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _yellow "CDN available, using CDN: $cdn_success_url"
    else
        _yellow "No CDN available, using direct connection"
    fi
}

check_cdn_file

# ======== 检查 Podman ========
if ! command -v podman >/dev/null 2>&1; then
    _red "podman not found. Please run podmaninstall.sh first."
    exit 1
fi

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
download_and_load_image() {
    local system_type="$1"
    local arch="$ARCH_TYPE"
    local tar_filename="spiritlhl_${system_type}_${arch}.tar.gz"
    local canonical_image="spiritlhl/${system_type}:latest"

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
        if podman load -i "/tmp/${tar_filename}"; then
            rm -f "/tmp/${tar_filename}"
            # 确保以 spiritlhl/<os>:latest 标记
            if ! podman image exists "${canonical_image}" 2>/dev/null; then
                # 找到刚加载的镜像并打标签
                local loaded_id
                loaded_id=$(podman images --format "{{.ID}}" | head -1)
                [[ -n "$loaded_id" ]] && podman tag "$loaded_id" "${canonical_image}" 2>/dev/null || true
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

    if [[ "$sys_type" == "alpine" ]]; then
        curl -sL --connect-timeout 10 --max-time 30 \
            "${base_url}/ssh_sh.sh" -o /tmp/ssh_sh.sh 2>/dev/null || true
        if [[ -f /tmp/ssh_sh.sh ]]; then
            podman cp /tmp/ssh_sh.sh "${cname}:/ssh_sh.sh" 2>/dev/null || true
        fi
    else
        curl -sL --connect-timeout 10 --max-time 30 \
            "${base_url}/ssh_bash.sh" -o /tmp/ssh_bash.sh 2>/dev/null || true
        if [[ -f /tmp/ssh_bash.sh ]]; then
            podman cp /tmp/ssh_bash.sh "${cname}:/ssh_bash.sh" 2>/dev/null || true
        fi
    fi
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

    # 磁盘限制选项
    local storage_opts=""
    if [[ "$disk" -gt 0 ]]; then
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
            podman exec "${name}" sh -c "sh /ssh_sh.sh '${passwd}'" 2>/dev/null || true
        else
            _yellow "ssh_sh.sh not found in container, relying on built-in entrypoint"
        fi
        podman exec "${name}" sh -c "echo 'root:${passwd}' | chpasswd" 2>/dev/null || true
    else
        if podman exec "${name}" test -f /ssh_bash.sh 2>/dev/null; then
            podman exec "${name}" bash -c "bash /ssh_bash.sh '${passwd}'" 2>/dev/null || true
        else
            _yellow "ssh_bash.sh not found in container, relying on built-in entrypoint"
        fi
        podman exec "${name}" bash -c "echo 'root:${passwd}' | chpasswd" 2>/dev/null || true
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
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >> "${name}"
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
