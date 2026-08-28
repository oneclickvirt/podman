#!/bin/bash
# from
# https://github.com/oneclickvirt/podman
# 2026.08.28
# oneclickvirt-ssh-init-revision: 20260828.2

# 容器内 SSH 初始化脚本（适用于 bash 系统：Debian/Ubuntu/AlmaLinux/RockyLinux/OpenEuler）

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

# ======== 安装必要组件 ========
install_required_modules() {
    local modules=("wget" "curl" "sudo" "openssh-server")
    case $SYSTEM in
        Debian|Ubuntu)
            apt-get update -y 2>/dev/null || true
            for module in "${modules[@]}"; do
                dpkg -l "$module" 2>/dev/null | grep -q "^ii" || apt-get -y install "$module" 2>/dev/null || true
            done
            apt-get -y install cron 2>/dev/null || apt-get -y install cronie 2>/dev/null || true
            ;;
        CentOS|Fedora)
            for module in "${modules[@]}"; do
                command -v "$module" >/dev/null 2>&1 || yum -y install "$module" 2>/dev/null || true
            done
            yum -y install cronie 2>/dev/null || true
            ;;
        *)
            for module in "${modules[@]}"; do
                command -v "$module" >/dev/null 2>&1 || ${PACKAGE_INSTALL[int]} "$module" 2>/dev/null || true
            done
            ;;
    esac
}

# ======== 更新 motd ========
update_motd() {
    grep -qF 'Related repo https://github.com/oneclickvirt/podman' /etc/motd 2>/dev/null || \
        echo 'Related repo https://github.com/oneclickvirt/podman' >> /etc/motd
    grep -qF '--by https://t.me/spiritlhl' /etc/motd 2>/dev/null || \
        echo '--by https://t.me/spiritlhl' >> /etc/motd
}

# ======== 关闭 SELinux / iptables（RHEL 系）========
disable_selinux_iptables() {
    service iptables stop 2>/dev/null || true
    if [ -f /etc/selinux/config ]; then
        sed -i.bak '/^SELINUX=/cSELINUX=disabled' /etc/selinux/config
        setenforce 0 2>/dev/null || true
    fi
}

# ======== 配置 sshd ========
set_sshd_option() {
    local config_file="$1"
    local option="$2"
    local value="$3"
    if grep -qE "^#?${option}[[:space:]]+" "$config_file"; then
        sed -i "s/^#\?${option}.*/${option} ${value}/g" "$config_file"
    else
        echo "${option} ${value}" >> "$config_file"
    fi
}

enable_sshd_dual_stack() {
    local config_file="$1"
    local config_dir="$2"
    local file

    # Explicit IPv4-only listeners silently make a routed public IPv6 unusable.
    # Disable inherited listener/family overrides, then make the primary config
    # bind both address families on the standard SSH port.
    for file in "$config_file" "${config_dir}"*; do
        [ -f "$file" ] || continue
        sed -E -i \
            -e '/^[[:space:]]*#/!s/^[[:space:]]*AddressFamily[[:space:]]+.*/# &/' \
            -e '/^[[:space:]]*#/!s/^[[:space:]]*ListenAddress[[:space:]]+.*/# &/' \
            "$file"
    done
    printf '\nAddressFamily any\n' >> "$config_file"
}

update_sshd_config() {
    local config_file="/etc/ssh/sshd_config"
    local config_dir="/etc/ssh/sshd_config.d/"
    if [ -d "$config_dir" ]; then
        for file in "${config_dir}"*; do
            [ -f "$file" ] || continue
            sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' "$file"
            sed -i 's/PermitRootLogin no/PermitRootLogin yes/g' "$file"
            sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/g' "$file"
        done
    fi
    [ -f "$config_file" ] || return 0
    set_sshd_option "$config_file" "Port" "22"
    set_sshd_option "$config_file" "PermitRootLogin" "yes"
    set_sshd_option "$config_file" "PasswordAuthentication" "yes"
    set_sshd_option "$config_file" "PubkeyAuthentication" "yes"
    set_sshd_option "$config_file" "UsePAM" "yes"
    enable_sshd_dual_stack "$config_file" "$config_dir"
}

# ======== 修复 cloud-init ========
fix_cloud_init() {
    if [ -f /etc/cloud/cloud.cfg ]; then
        sed -E -i 's/ssh_pwauth:[[:space:]]*false/ssh_pwauth:   true/g' /etc/cloud/cloud.cfg
        sed -E -i 's/disable_root:[[:space:]]*true/disable_root: false/g' /etc/cloud/cloud.cfg
        sed -E -i 's/disable_root:[[:space:]]*1/disable_root: 0/g' /etc/cloud/cloud.cfg
    fi
}

# A container image may use "exec sshd -D" as its entrypoint. Restarting that
# service kills PID 1 and therefore stops the whole container. Reloading the
# validated PID 1 process keeps the container and existing SSH sessions alive.
sshd_runs_as_pid1() {
    [ "$(cat /proc/1/comm 2>/dev/null)" = "sshd" ]
}

reload_pid1_sshd() {
    if ! /usr/sbin/sshd -t 2>/dev/null; then
        echo "sshd configuration validation failed; keeping PID 1 unchanged" >&2
        return 1
    fi
    if ! kill -HUP 1 2>/dev/null; then
        echo "failed to reload PID 1 sshd" >&2
        return 1
    fi
}

# ======== 生成并启动 sshd ========
start_sshd() {
    cd /etc/ssh || true
    ssh-keygen -A 2>/dev/null || true
    mkdir -p /var/run/sshd
    if sshd_runs_as_pid1; then
        reload_pid1_sshd
        return $?
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    elif command -v service >/dev/null 2>&1; then
        service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
    else
        /usr/sbin/sshd 2>/dev/null || true
    fi
}

# ======== 设置 cron 保活 sshd ========
setup_cron_sshd() {
    local cron_line="* * * * * pgrep -x sshd>/dev/null||/usr/sbin/sshd"
    (crontab -l 2>/dev/null | grep -v "sshd"; echo "$cron_line") | crontab - 2>/dev/null || true
    if command -v crond >/dev/null 2>&1; then
        crond 2>/dev/null || true
    elif command -v cron >/dev/null 2>&1; then
        cron 2>/dev/null || true
    fi
}

# ======== 主流程 ========
passwd_input="${1:-${ROOT_PASSWORD:-}}"
if [[ -z "$passwd_input" || "$passwd_input" =~ [[:space:]] ]]; then
    echo "Password is required and must not contain whitespace"
    exit 1
fi

install_required_modules
update_motd
disable_selinux_iptables
fix_cloud_init
update_sshd_config

printf "%s\n" "root:${passwd_input}" | chpasswd 2>/dev/null || \
    printf "%s\n" "root:${passwd_input}" | sudo chpasswd 2>/dev/null || true

if ! start_sshd; then
    echo "SSH initialization failed" >&2
    exit 1
fi
setup_cron_sshd

echo "SSH initialization completed"
