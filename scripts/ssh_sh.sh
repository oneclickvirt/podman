#!/bin/sh
# from
# https://github.com/oneclickvirt/podman
# 2026.03.01

# 容器内 SSH 初始化脚本（仅适用于 Alpine Linux）

if [ "$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2)" != "alpine" ]; then
    echo "This script only supports Alpine Linux."
    exit 1
fi

passwd_input="${1:-123456}"

# 处理 sshd_config.d/ 中的覆盖配置
config_dir="/etc/ssh/sshd_config.d/"
if [ -d "$config_dir" ]; then
    for file in "${config_dir}"*; do
        [ -f "$file" ] || continue
        sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' "$file"
        sed -i 's/PermitRootLogin no/PermitRootLogin yes/g' "$file"
        sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/g' "$file"
    done
fi

# 安装 SSH 及相关工具
apk update 2>/dev/null || true
apk add --no-cache openssh-server openssh openssh-keygen bash curl wget cronie 2>/dev/null || true

# 生成主机密钥
mkdir -p /etc/ssh
ssh-keygen -A 2>/dev/null || true

# 配置 sshd
set_sshd_option() {
    config_file="$1"
    option="$2"
    value="$3"
    if grep -qE "^#?${option}[[:space:]]+" "$config_file"; then
        sed -i "s/^#\?${option}.*/${option} ${value}/" "$config_file"
    else
        echo "${option} ${value}" >> "$config_file"
    fi
}

config_file="/etc/ssh/sshd_config"
if [ -f "$config_file" ]; then
    set_sshd_option "$config_file" "PermitRootLogin" "yes"
    set_sshd_option "$config_file" "PasswordAuthentication" "yes"
    set_sshd_option "$config_file" "PubkeyAuthentication" "yes"
    set_sshd_option "$config_file" "Port" "22"
    if grep -qE '^#?ListenAddress[[:space:]]+0\.0\.0\.0' "$config_file"; then
        sed -i 's/^#\?ListenAddress[[:space:]]\+0\.0\.0\.0/ListenAddress 0.0.0.0/' "$config_file"
    else
        echo "ListenAddress 0.0.0.0" >> "$config_file"
    fi
fi

# 修复 cloud-init
if [ -f /etc/cloud/cloud.cfg ]; then
    sed -i 's/preserve_hostname:[[:space:]]*false/preserve_hostname: true/g' /etc/cloud/cloud.cfg
    sed -i 's/disable_root:[[:space:]]*true/disable_root: false/g' /etc/cloud/cloud.cfg
    sed -i 's/ssh_pwauth:[[:space:]]*false/ssh_pwauth:   true/g' /etc/cloud/cloud.cfg
fi

mkdir -p /var/run/sshd

# 设置 root 密码
echo "root:${passwd_input}" | chpasswd 2>/dev/null || true

# 启动 sshd
rc-update add sshd default 2>/dev/null || true
/usr/sbin/sshd 2>/dev/null || true

# 设置 cron 保活
cron_line="* * * * * pgrep -x sshd>/dev/null||/usr/sbin/sshd"
(crontab -l 2>/dev/null | grep -v "sshd"; echo "$cron_line") | crontab - 2>/dev/null || true
crond 2>/dev/null || true

# 更新 motd
grep -qF 'Related repo https://github.com/oneclickvirt/podman' /etc/motd 2>/dev/null || \
    echo 'Related repo https://github.com/oneclickvirt/podman' >> /etc/motd
grep -qF '--by https://t.me/spiritlhl' /etc/motd 2>/dev/null || \
    echo '--by https://t.me/spiritlhl' >> /etc/motd

echo "SSH initialization completed (Alpine)"
