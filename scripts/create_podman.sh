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
reading() { read -rp "$(_green "$1")" "$2"; }
export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi

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

    if [[ ! -f /root/scripts/onepodman.sh ]]; then
        mkdir -p /root/scripts
        curl -sL --connect-timeout 10 --max-time 60 \
            "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/podman/main/scripts/onepodman.sh" \
            -o /root/scripts/onepodman.sh
        chmod +x /root/scripts/onepodman.sh
    fi
}

# ======== 读取日志，恢复编号状态 ========
log_file="ctlog"
container_prefix="ct"
container_num=0
ssh_port=25000
public_port_end=34975

check_log() {
    if [[ -f "$log_file" ]]; then
        local last_line
        last_line=$(tail -n 1 "$log_file" 2>/dev/null || true)
        if [[ -n "$last_line" ]]; then
            local last_name last_ssh last_endport
            last_name=$(echo "$last_line"    | awk '{print $1}')
            last_ssh=$(echo "$last_line"     | awk '{print $2}')
            last_endport=$(echo "$last_line" | awk '{print $7}')

            if [[ "$last_name" =~ ^([a-zA-Z]+)([0-9]+)$ ]]; then
                container_prefix="${BASH_REMATCH[1]}"
                container_num="${BASH_REMATCH[2]}"
            fi
            [[ -n "$last_ssh"     && "$last_ssh"     -gt 0 ]] && ssh_port="$last_ssh"
            [[ -n "$last_endport" && "$last_endport" -gt 0 ]] && public_port_end="$last_endport"

            _blue "Resuming from: prefix=${container_prefix}, num=${container_num}, last_ssh=${ssh_port}, last_endport=${public_port_end}"
        fi
    fi
}

# ======== 交互式创建 ========
build_new_containers() {
    reading "需要新增几个容器？(How many containers to create?) [default: 1]: " new_nums
    [[ -z "$new_nums" || ! "$new_nums" =~ ^[0-9]+$ ]] && new_nums=1

    reading "每个容器内存大小(MB) (Memory per container in MB) [default: 512]: " memory_nums
    [[ -z "$memory_nums" || ! "$memory_nums" =~ ^[0-9]+$ ]] && memory_nums=512

    reading "每个容器 CPU 核数 (CPU cores per container, e.g. 1 or 0.5) [default: 1]: " cpu_nums
    [[ -z "$cpu_nums" ]] && cpu_nums=1

    # 询问磁盘限制（仅 btrfs 驱动支持）
    disk_size=0
    storage_driver="overlay"
    if [[ -f /usr/local/bin/podman_storage_driver ]]; then
        storage_driver=$(cat /usr/local/bin/podman_storage_driver)
    fi
    if [[ "$storage_driver" == "btrfs" ]]; then
        reading "磁盘限制(GB) (Disk limit in GB, 0=unlimited) [default: 0]: " disk_size
        [[ -z "$disk_size" || ! "$disk_size" =~ ^[0-9]+$ ]] && disk_size=0
    else
        _yellow "当前存储驱动($storage_driver)不支持硬盘大小限制，磁盘参数设为0"
        _yellow "Current storage driver ($storage_driver) does not support disk size limitation, disk set to 0"
        disk_size=0
    fi

    _blue "可选系统: ubuntu / debian / alpine / almalinux / rockylinux / openeuler"
    reading "选择系统 (Choose system) [default: debian]: " system_type
    [[ -z "$system_type" ]] && system_type="debian"
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
        reading "是否为每个容器分配独立 IPv6？(Assign independent IPv6 to each container?) [y/N]: " ipv6_choice
        [[ "${ipv6_choice,,}" == "y" ]] && independent_ipv6="y"
    fi

    _blue "======================================================"
    _blue "  即将创建 $new_nums 个容器"
    _blue "  系统: $system_type  内存: ${memory_nums}MB  CPU: ${cpu_nums}  磁盘: ${disk_size}GB"
    _blue "  IPv6: $independent_ipv6"
    _blue "======================================================"

    local scripts_dir
    if [[ -f /root/scripts/onepodman.sh ]]; then
        scripts_dir="/root/scripts"
    elif [[ -f "$(dirname "$0")/onepodman.sh" ]]; then
        scripts_dir="$(dirname "$0")"
    else
        scripts_dir="/root"
    fi

    for ((i = 1; i <= new_nums; i++)); do
        container_num=$((container_num + 1))
        container_name="${container_prefix}${container_num}"
        ssh_port=$((ssh_port + 1))
        public_port_start=$((public_port_end + 1))
        public_port_end=$((public_port_start + 24))

        ori=$(date +%s%N | md5sum 2>/dev/null || date | md5sum)
        passwd="${ori:2:9}"

        _yellow "[${i}/${new_nums}] Creating container: ${container_name}  ssh:${ssh_port}  ports:${public_port_start}-${public_port_end}"

        bash "${scripts_dir}/onepodman.sh" \
            "$container_name" \
            "$cpu_nums" \
            "$memory_nums" \
            "$passwd" \
            "$ssh_port" \
            "$public_port_start" \
            "$public_port_end" \
            "$independent_ipv6" \
            "$system_type" \
            "$disk_size"

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
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            local n sshp pw cp mem sp ep dk
            n=$(echo "$line"   | awk '{print $1}')
            sshp=$(echo "$line" | awk '{print $2}')
            pw=$(echo "$line"   | awk '{print $3}')
            cp=$(echo "$line"   | awk '{print $4}')
            mem=$(echo "$line"  | awk '{print $5}')
            sp=$(echo "$line"   | awk '{print $6}')
            ep=$(echo "$line"   | awk '{print $7}')
            dk=$(echo "$line"   | awk '{print $8}')
            _blue "  名称:${n}  SSH端口:${sshp}  密码:${pw}  CPU:${cp}  内存:${mem}MB  端口:${sp}-${ep}  磁盘:${dk}GB"
        done < "$log_file"
        echo
    fi
}

# ======== 主流程 ========
main() {
    pre_check
    check_log
    show_log
    build_new_containers
    check_log
}

main "$@"
