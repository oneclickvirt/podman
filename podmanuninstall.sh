#!/bin/bash
# from
# https://github.com/oneclickvirt/podman
# 2026.03.01
# 完整卸载 Podman 环境及所有容器

_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root"
    exit 1
fi

# 支持环境变量 FORCE_UNINSTALL=true/yes/1/y 跳过确认提示，实现一键卸载
_skip_confirm=false
case "${FORCE_UNINSTALL:-}" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Yy]) _skip_confirm=true ;;
esac

echo ""
echo "======================================================"
_red "  ⚠  警告：即将卸载 Podman 全套环境"
echo "  包含：所有运行中/停止的容器、所有镜像、"
echo "  Podman 网络、辅助服务及状态文件"
echo "  操作不可逆！"
echo "======================================================"
if [[ "$_skip_confirm" == "true" ]]; then
    _yellow "环境变量 FORCE_UNINSTALL 已启用，自动跳过确认，继续卸载..."
else
    read -rp "$(_yellow "确认卸载？输入 yes 继续，其他任意键退出: ")" confirm
    if [[ "$confirm" != "yes" ]]; then
        _green "已取消"
        exit 0
    fi
fi

# ======== 1. 停止并删除所有容器 ========
_blue "[1/7] 停止并删除所有容器..."
if command -v podman >/dev/null 2>&1; then
    containers=$(podman ps -aq 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
        _yellow "  停止所有容器..."
        podman stop $containers 2>/dev/null || true
        _yellow "  删除所有容器..."
        podman rm -f $containers 2>/dev/null || true
    fi
    _green "  容器清理完成"
fi

# ======== 2. 删除所有镜像 ========
_blue "[2/7] 删除所有镜像..."
if command -v podman >/dev/null 2>&1; then
    images=$(podman images -aq 2>/dev/null || true)
    if [[ -n "$images" ]]; then
        podman rmi -f $images 2>/dev/null || true
    fi
    # 清理 volume 和未使用资源
    podman volume prune -f 2>/dev/null || true
    podman system prune -af 2>/dev/null || true
    _green "  镜像清理完成"
fi

# ======== 3. 停止 ndpresponder ========
_blue "[3/7] 停止 ndpresponder..."
if command -v podman >/dev/null 2>&1; then
    podman rm -f ndpresponder 2>/dev/null || true
fi

# ======== 4. 停止 systemd 服务 ========
_blue "[4/7] 停止并禁用辅助服务..."
for svc in check-dns-podman podman-restart podman.socket podman; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop "$svc" 2>/dev/null || true
        _yellow "  已停止 ${svc}"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        systemctl disable "$svc" 2>/dev/null || true
    fi
done
for f in /etc/systemd/system/check-dns-podman.service; do
    [[ -f "$f" ]] && rm -f "$f" && _yellow "  删除 $f"
done
systemctl daemon-reload 2>/dev/null || true

# ======== 5. 删除 Podman 网络 ========
_blue "[5/7] 删除 Podman 网络..."
if command -v podman >/dev/null 2>&1; then
    for net in podman-net podman-ipv6; do
        if podman network exists "$net" 2>/dev/null; then
            podman network rm -f "$net" 2>/dev/null || true
            _yellow "  删除网络: $net"
        fi
    done
fi
# 删除残留网桥
for br in podman-br0 podman-br1; do
    if ip link show "$br" >/dev/null 2>&1; then
        ip link set "$br" down 2>/dev/null || true
        ip link delete "$br" 2>/dev/null || true
        _yellow "  删除网桥: $br"
    fi
done

# ======== 6. 删除状态/辅助文件 ========
_blue "[6/7] 删除辅助状态文件..."
# 清理 btrfs loop（需要在删除状态文件之前读取）
if [[ -f /usr/local/bin/podman_mount_point ]]; then
    _bt_mp=$(cat /usr/local/bin/podman_mount_point 2>/dev/null)
    if [[ -n "$_bt_mp" ]]; then
        umount "$_bt_mp" 2>/dev/null || true
        _yellow "  已卸载 btrfs: $_bt_mp"
    fi
fi
if [[ -f /usr/local/bin/podman_loop_device ]]; then
    _bt_ld=$(cat /usr/local/bin/podman_loop_device 2>/dev/null)
    if [[ -n "$_bt_ld" ]]; then
        losetup -d "$_bt_ld" 2>/dev/null || true
        _yellow "  已分离 loop 设备: $_bt_ld"
    fi
fi
if [[ -f /usr/local/bin/podman_loop_file ]]; then
    _bt_lf=$(cat /usr/local/bin/podman_loop_file 2>/dev/null)
    if [[ -n "$_bt_lf" ]]; then
        rm -f "$_bt_lf" 2>/dev/null
        _yellow "  删除 loop 文件: $_bt_lf"
        sed -i "\|${_bt_lf}|d" /etc/fstab 2>/dev/null || true
    fi
fi
# 删除所有 podman 状态文件
for f in /usr/local/bin/podman_*; do
    [[ -f "$f" ]] && rm -f "$f" && _yellow "  删除 $f"
done
[[ -f /usr/local/bin/check-dns-podman.sh ]] && rm -f /usr/local/bin/check-dns-podman.sh && _yellow "  删除 /usr/local/bin/check-dns-podman.sh"
rm -f /tmp/spiritlhl_*.tar.gz 2>/dev/null || true
rm -f /tmp/ssh_bash.sh /tmp/ssh_sh.sh 2>/dev/null || true

# ======== 7. 清理 sysctl 配置（仅删除本脚本写入的条目） ========
_blue "[7/7] 清理辅助配置..."
# 注意：podman 使用了 /etc/sysctl.conf，不轻易删除整个文件
# 仅提示用户手动检查
_yellow "  提示：sysctl.conf 中的内核参数（ip_forward 等）未被清除，请手动检查 /etc/sysctl.conf"

echo ""
echo "======================================================"
_green "  ✓ Podman 环境已完整卸载！"
echo "======================================================"
echo ""
echo "如需重新安装，执行："
echo "  bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/podman/main/podmaninstall.sh)"
