#!/bin/bash
# from
# https://github.com/oneclickvirt/podman
# 2026.03.01

# 批量开设 Podman 容器脚本
# 交互式创建多个 Linux 容器，记录到 ctlog 日志文件

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
is_noninteractive() {
    is_truthy "${noninteractive:-${NONINTERACTIVE:-}}"
}
reading() {
    is_noninteractive && return 1
    read -rp "$(_green "$1")" "$2"
}
get_env_first() {
    local name
    for name in "$@"; do
        if [[ -n "${!name:-}" ]]; then
            printf '%s' "${!name}"
            return 0
        fi
    done
    return 1
}
positive_int_or_default() {
    local value="${1:-}"
    local default_value="$2"
    if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$default_value"
    fi
}
nonnegative_int_or_default() {
    local value="${1:-}"
    local default_value="$2"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$default_value"
    fi
}
cpu_or_default() {
    local value="${1:-}"
    local default_value="$2"
    if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && [[ "$value" != "0" ]] && [[ "$value" != "0.0" ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$default_value"
    fi
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

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
cd /root || exit 1

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

# ======== 检查依赖 ========
pre_check() {
    if ! command -v podman >/dev/null 2>&1; then
        _yellow "podman not found, running podmaninstall.sh..."
        if [[ -f /root/podmaninstall.sh ]]; then
            bash /root/podmaninstall.sh
        else
            bash <(curl -sL "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/podman/main/podmaninstall.sh")
        fi
    fi

    local local_onepodman
    local_onepodman="${SCRIPT_DIR}/onepodman.sh"
    if [[ ! -f /root/scripts/onepodman.sh ]]; then
        mkdir -p /root/scripts
        if [[ -f "$local_onepodman" ]]; then
            cp "$local_onepodman" /root/scripts/onepodman.sh
        else
            curl -sL --connect-timeout 10 --max-time 60 \
                "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/podman/main/scripts/onepodman.sh" \
                -o /root/scripts/onepodman.sh
        fi
        chmod +x /root/scripts/onepodman.sh
    fi
}

# ======== 读取日志，恢复编号状态 ========
log_file="ctlog"
container_prefix="ct"
container_num=0
ssh_port=25000
public_port_end=34975
declare -A existing_container_names=()
declare -A used_host_ports=()

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
    local start end
    if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        start="${BASH_REMATCH[1]}"
        end="${BASH_REMATCH[2]}"
        mark_used_port_range "$start" "$end"
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
        mark_used_port_range "$token" "$token"
    fi
}

collect_existing_state() {
    local name sshp _pw _cpu _mem sp ep _dk port_line mapping listen_port
    existing_container_names=()
    used_host_ports=()

    if command -v podman >/dev/null 2>&1; then
        while IFS= read -r name; do
            [[ -n "$name" ]] && existing_container_names["$name"]=1
        done < <(podman ps -a --format '{{.Names}}' 2>/dev/null || true)

        while IFS= read -r port_line; do
            while IFS= read -r mapping; do
                [[ -n "$mapping" ]] && mark_port_token "${mapping%->}"
            done < <(printf '%s\n' "$port_line" | grep -oE '([0-9]{1,5})(-[0-9]{1,5})?->' || true)
        done < <(podman ps -a --format '{{.Ports}}' 2>/dev/null || true)
    fi

    if [[ -f "$log_file" ]]; then
        while read -r name sshp _pw _cpu _mem sp ep _dk _rest || [[ -n "$name" ]]; do
            [[ -n "$name" ]] && existing_container_names["$name"]=1
            mark_port_token "$sshp"
            mark_used_port_range "$sp" "$ep"
        done < "$log_file"
    fi

    if command -v ss >/dev/null 2>&1; then
        while IFS= read -r listen_port; do
            mark_port_token "$listen_port"
        done < <(ss -H -tuln 2>/dev/null | awk '{n=split($5,a,":"); p=a[n]; gsub(/[^0-9]/,"",p); if(p!="") print p}' || true)
    fi
}

next_container_name() {
    local candidate
    while true; do
        container_num=$((container_num + 1))
        candidate="${container_prefix}${container_num}"
        if [[ -z "${existing_container_names[$candidate]:-}" ]]; then
            container_name="$candidate"
            existing_container_names["$container_name"]=1
            return 0
        fi
        _yellow "Container name ${candidate} already exists, skipping"
    done
}

next_ssh_port() {
    local candidate
    while true; do
        candidate=$((ssh_port + 1))
        if (( candidate > 65535 )); then
            _red "No available SSH host port left"
            exit 1
        fi
        ssh_port="$candidate"
        if [[ -z "${used_host_ports[$ssh_port]:-}" ]]; then
            mark_used_port_range "$ssh_port" "$ssh_port"
            return 0
        fi
        _yellow "SSH port ${ssh_port} already in use, skipping"
    done
}

next_public_port_range() {
    local start end conflict_port p
    start=$((public_port_end + 1))
    while true; do
        end=$((start + 24))
        if (( end > 65535 )); then
            _red "No available public port range left"
            exit 1
        fi
        conflict_port=""
        for ((p = start; p <= end; p++)); do
            if [[ -n "${used_host_ports[$p]:-}" ]]; then
                conflict_port="$p"
                break
            fi
        done
        if [[ -z "$conflict_port" ]]; then
            public_port_start="$start"
            public_port_end="$end"
            mark_used_port_range "$public_port_start" "$public_port_end"
            return 0
        fi
        _yellow "Public port ${conflict_port} already in use, searching next range"
        start=$((conflict_port + 1))
    done
}

check_log() {
    if [[ -f "$log_file" ]]; then
        local last_line
        last_line=$(tail -n 1 "$log_file" 2>/dev/null || true)
        if [[ -n "$last_line" ]]; then
            local last_name last_ssh last_endport
            read -r last_name last_ssh _ _ _ _ last_endport _ <<< "$last_line"

            if [[ "$last_name" =~ ^([a-zA-Z]+)([0-9]+)$ ]]; then
                container_prefix="${BASH_REMATCH[1]}"
                container_num="${BASH_REMATCH[2]}"
            fi
            [[ "$last_ssh" =~ ^[0-9]+$ && "$last_ssh" -gt 0 ]] && ssh_port="$last_ssh"
            [[ "$last_endport" =~ ^[0-9]+$ && "$last_endport" -gt 0 ]] && public_port_end="$last_endport"

            _blue "Resuming from: prefix=${container_prefix}, num=${container_num}, last_ssh=${ssh_port}, last_endport=${public_port_end}"
        fi
    fi
}

apply_resume_overrides() {
    local value
    value=$(get_env_first PODMAN_CONTAINER_PREFIX CONTAINER_PREFIX 2>/dev/null || true)
    if [[ -n "$value" && "$value" =~ ^[a-zA-Z][a-zA-Z0-9_.-]*$ ]]; then
        container_prefix="$value"
        _yellow "Using container prefix from environment: ${container_prefix}"
    fi

    value=$(get_env_first PODMAN_CONTAINER_START_NUM CONTAINER_START_NUM 2>/dev/null || true)
    if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        container_num=$((value - 1))
        _yellow "Using first container number from environment: ${value}"
    fi

    value=$(get_env_first PODMAN_START_SSH_PORT START_SSH_PORT SSH_PORT 2>/dev/null || true)
    if [[ "$value" =~ ^[1-9][0-9]*$ ]] && (( value <= 65535 )); then
        ssh_port=$((value - 1))
        _yellow "Using first SSH port from environment: ${value}"
    fi

    value=$(get_env_first PODMAN_PUBLIC_PORT_START PUBLIC_PORT_START 2>/dev/null || true)
    if [[ "$value" =~ ^[1-9][0-9]*$ ]] && (( value <= 65535 )); then
        public_port_end=$((value - 1))
        _yellow "Using first public port from environment: ${value}"
    fi
}

# ======== 交互式创建 ========
build_new_containers() {
    local env_value
    env_value=$(get_env_first PODMAN_CREATE_NUMS PODMAN_CREATE_COUNT CREATE_NUMS CREATE_COUNT 2>/dev/null || true)
    if [[ -n "$env_value" ]]; then
        new_nums="$env_value"
        _yellow "Using container count from environment: ${new_nums}"
    elif is_noninteractive; then
        new_nums=1
        _yellow "noninteractive=true: using default container count ${new_nums}"
    else
        reading "需要新增几个容器？(How many containers to create?) [default: 1]: " new_nums
    fi
    new_nums=$(positive_int_or_default "$new_nums" 1)

    env_value=$(get_env_first PODMAN_MEMORY_MB MEMORY_MB 2>/dev/null || true)
    if [[ -n "$env_value" ]]; then
        memory_nums="$env_value"
        _yellow "Using memory from environment: ${memory_nums}MB"
    elif is_noninteractive; then
        memory_nums=512
        _yellow "noninteractive=true: using default memory ${memory_nums}MB"
    else
        reading "每个容器内存大小(MB) (Memory per container in MB) [default: 512]: " memory_nums
    fi
    memory_nums=$(positive_int_or_default "$memory_nums" 512)

    env_value=$(get_env_first PODMAN_CPU CPU 2>/dev/null || true)
    if [[ -n "$env_value" ]]; then
        cpu_nums="$env_value"
        _yellow "Using CPU from environment: ${cpu_nums}"
    elif is_noninteractive; then
        cpu_nums=1
        _yellow "noninteractive=true: using default CPU ${cpu_nums}"
    else
        reading "每个容器 CPU 核数 (CPU cores per container, e.g. 1 or 0.5) [default: 1]: " cpu_nums
    fi
    cpu_nums=$(cpu_or_default "$cpu_nums" 1)

    # 询问磁盘限制（仅 btrfs 驱动支持）
    disk_size=0
    storage_driver="overlay"
    if [[ -f /usr/local/bin/podman_storage_driver ]]; then
        storage_driver=$(cat /usr/local/bin/podman_storage_driver)
    fi
    if [[ "$storage_driver" == "btrfs" ]]; then
        env_value=$(get_env_first PODMAN_DISK_GB DISK_GB 2>/dev/null || true)
        if [[ -n "$env_value" ]]; then
            disk_size="$env_value"
            _yellow "Using disk limit from environment: ${disk_size}GB"
        elif is_noninteractive; then
            disk_size=0
            _yellow "noninteractive=true: using default disk limit ${disk_size}GB"
        else
            reading "磁盘限制(GB) (Disk limit in GB, 0=unlimited) [default: 0]: " disk_size
        fi
        disk_size=$(nonnegative_int_or_default "$disk_size" 0)
    else
        _yellow "当前存储驱动($storage_driver)不支持硬盘大小限制，磁盘参数设为0"
        _yellow "Current storage driver ($storage_driver) does not support disk size limitation, disk set to 0"
        disk_size=0
    fi

    env_value=$(get_env_first PODMAN_SYSTEM SYSTEM_TYPE 2>/dev/null || true)
    if [[ -n "$env_value" ]]; then
        system_type="$env_value"
        _yellow "Using system from environment: ${system_type}"
    elif is_noninteractive; then
        system_type="debian"
        _yellow "noninteractive=true: using default system ${system_type}"
    else
        _blue "可选系统: ubuntu / debian / alpine / almalinux / rockylinux / openeuler"
        reading "选择系统 (Choose system) [default: debian]: " system_type
        [[ -z "$system_type" ]] && system_type="debian"
    fi
    system_type=$(echo "$system_type" | tr '[:upper:]' '[:lower:]')
    if [[ ! "$system_type" =~ ^(ubuntu|debian|alpine|almalinux|rockylinux|openeuler)$ ]]; then
        _yellow "Unknown system '${system_type}', using debian"
        system_type="debian"
    fi

    IPV6_AVAILABLE=false
    if [[ -f /usr/local/bin/podman_ipv6_enabled ]]; then
        if [[ "$(cat /usr/local/bin/podman_ipv6_enabled)" == "true" ]]; then
            IPV6_AVAILABLE=true
        fi
    fi
    independent_ipv6="n"
    if [[ "$IPV6_AVAILABLE" == "true" ]]; then
        env_value=$(get_env_first PODMAN_IPV6 INDEPENDENT_IPV6 IPV6 2>/dev/null || true)
        if [[ -n "$env_value" ]]; then
            ipv6_choice="$env_value"
            _yellow "Using IPv6 choice from environment: ${ipv6_choice}"
        elif is_noninteractive; then
            ipv6_choice="n"
            _yellow "noninteractive=true: using default IPv6 choice ${ipv6_choice}"
        else
            reading "是否为每个容器分配独立 IPv6？(Assign independent IPv6 to each container?) [y/N]: " ipv6_choice
        fi
        is_truthy "${ipv6_choice:-}" && independent_ipv6="y"
    fi

    _blue "======================================================"
    _blue "  即将创建 $new_nums 个容器"
    _blue "  系统: $system_type  内存: ${memory_nums}MB  CPU: ${cpu_nums}  磁盘: ${disk_size}GB"
    _blue "  IPv6: $independent_ipv6"
    _blue "======================================================"

    local scripts_dir
    if [[ -f "${SCRIPT_DIR}/onepodman.sh" ]]; then
        scripts_dir="$SCRIPT_DIR"
    elif [[ -f /root/scripts/onepodman.sh ]]; then
        scripts_dir="/root/scripts"
    else
        scripts_dir="/root"
    fi

    collect_existing_state

    for ((i = 1; i <= new_nums; i++)); do
        next_container_name
        next_ssh_port
        next_public_port_range

        ori=$(date +%s%N | md5sum 2>/dev/null || date | md5sum)
        passwd="${ori:2:9}"

        _yellow "[${i}/${new_nums}] Creating container: ${container_name}  ssh:${ssh_port}  ports:${public_port_start}-${public_port_end}"

        if ! PODMAN_SKIP_RESOURCE_CHECK=true bash "${scripts_dir}/onepodman.sh" \
            "$container_name" \
            "$cpu_nums" \
            "$memory_nums" \
            "$passwd" \
            "$ssh_port" \
            "$public_port_start" \
            "$public_port_end" \
            "$independent_ipv6" \
            "$system_type" \
            "$disk_size"; then
            _red "Failed to create container ${container_name}, stop batch creation"
            exit 1
        fi

        # 将 onepodman.sh 写出的同名文件内容追加到 ctlog
        if [[ -f "/root/${container_name}" ]]; then
            cat "/root/${container_name}" >> "$log_file"
            rm -f "/root/${container_name}"
        elif [[ -f "${container_name}" ]]; then
            cat "${container_name}" >> "$log_file"
            rm -f "${container_name}"
        else
            # 兜底：手动写入
            echo "${container_name} ${ssh_port} ${passwd} ${cpu_nums} ${memory_nums} ${public_port_start} ${public_port_end} ${disk_size}" >> "$log_file"
        fi
        _green "Container ${container_name} logged"
    done

    _green "======================================================"
    _green "  批量创建完成！所有容器信息已保存到: ${log_file}"
    _green "======================================================"
    _blue "查看所有容器: podman ps -a"
    _blue "查看日志文件: cat ${log_file}"
}

# ======== 显示已有日志 ========
show_log() {
    if [[ -f "$log_file" ]]; then
        _blue "======================================================"
        _blue "  已有容器记录 / Existing container log:"
        _blue "======================================================"
        local n sshp pw cp mem sp ep dk
        while read -r n sshp pw cp mem sp ep dk _rest || [[ -n "$n" ]]; do
            [[ -z "$n" ]] && continue
            _blue "  名称:${n}  SSH端口:${sshp}  密码:${pw}  CPU:${cp}  内存:${mem}MB  端口:${sp}-${ep}  磁盘:${dk}GB"
        done < "$log_file"
        echo
    fi
}

# ======== 主流程 ========
main() {
    pre_check
    check_log
    apply_resume_overrides
    show_log
    build_new_containers
    check_log
}

main "$@"
