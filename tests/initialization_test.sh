#!/usr/bin/env bash
# Fault injection only: selected functions run against mock commands.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/podmaninstall.sh"
load_function() {
    source <(awk -v name="$1" '$0 == name "() {" { printing=1 } printing { print } printing && /^}$/ { exit }' "$installer")
}
_green() { :; }
_yellow() { :; }
_red() { :; }
_blue() { :; }
_info() { :; }
_warn() { :; }
_step() { :; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

load_function create_podman_network
podman_network_binary_available() { return 1; }
mock_exists=false mock_create_count=0 mock_fail_all=true
mock_network_json='[{"driver":"bridge","subnets":[{"subnet":"172.20.0.0/16"}]}]'
podman() {
    case "$*" in
        'network exists podman-net') $mock_exists ;;
        'network inspect podman-net') printf '%s\n' "$mock_network_json" ;;
        'network create '*)
            [[ "$*" == *--disable-dns* ]] || fail 'missing aardvark needs DNS-disabled new network'
            mock_create_count=$((mock_create_count + 1))
            $mock_fail_all && return 1
            [[ "$*" == *--interface-name* ]] && return 1
            mock_exists=true ;;
        *) fail "Unexpected podman command: $*" ;;
    esac
}
if create_podman_network; then fail 'both creation attempts failing must propagate'; fi
[[ "$mock_create_count" == 2 ]] || fail 'must retain compatibility fallback'
mock_fail_all=false
create_podman_network || fail 'second creation method should succeed'
mock_create_count=0
create_podman_network || fail 'existing network should succeed'
[[ "$mock_create_count" == 0 ]] || fail 'existing network must not be recreated'
mock_network_json='[{"driver":"bridge","subnets":[{"subnet":"10.0.0.0/24"}]}]'
if create_podman_network; then fail 'incompatible existing network must fail closed'; fi
podman_source=$(<"$installer")
grep -Fq 'No working nftables or iptables backend is available' <<<"$podman_source" ||
    fail 'Podman must reject a missing firewall fallback'
grep -Fq 'if ! fallocate -l "${pool_size_gb}G" "$loop_file"' <<<"$podman_source" ||
    fail 'Podman btrfs setup must propagate loop-file allocation failures'
grep -Fq 'if ! loop_device=$(losetup --find --show "$loop_file")' <<<"$podman_source" ||
    fail 'Podman btrfs setup must propagate loop attachment failures'
grep -Fq 'if ! mkfs.btrfs -f "$loop_device"' <<<"$podman_source" ||
    fail 'Podman btrfs setup must propagate filesystem formatting failures'
grep -Fq 'if ! mount "$loop_device" "$mount_point"' <<<"$podman_source" ||
    fail 'Podman btrfs setup must propagate mount failures'
grep -Fq 'update_sysctl "net.ipv6.conf.all.forwarding=1" || return 1' <<<"$podman_source" ||
    fail 'Podman IPv6 forwarding failure must disable optional IPv6 cleanly'
printf 'Podman installation fault-injection tests passed (4 scenarios)\n'
