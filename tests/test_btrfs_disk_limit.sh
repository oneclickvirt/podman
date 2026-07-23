#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

if grep -Eq -- '--storage-opt[ =]size=' scripts/onepodman.sh; then
    printf '%s\n' 'onepodman.sh must not pass size as a Podman storage option' >&2
    exit 1
fi

_red() { printf '%s\n' "$*" >&2; }
_green() { printf '%s\n' "$*"; }
helper_source=$(mktemp "${TMPDIR:-/tmp}/podman-btrfs-helper.XXXXXX")
rootfs_path=$(mktemp -d "${TMPDIR:-/tmp}/podman-btrfs-test.XXXXXX")
calls=$(mktemp "${TMPDIR:-/tmp}/podman-btrfs-calls.XXXXXX")
podman_calls=$(mktemp "${TMPDIR:-/tmp}/podman-btrfs-podman-calls.XXXXXX")
batch_root=$(mktemp -d "${TMPDIR:-/tmp}/podman-batch-test.XXXXXX")
batch_script_dir="${batch_root}/source"
batch_cache_dir="${batch_root}/cache"
batch_helper=$(mktemp "${TMPDIR:-/tmp}/podman-batch-helper.XXXXXX")
mkdir -p "$batch_script_dir" "$batch_cache_dir"
trap 'rm -f "$calls" "$podman_calls" "$helper_source" "$batch_helper" "${batch_cache_dir}/onepodman.sh"; rmdir "$rootfs_path" "$batch_script_dir" "$batch_cache_dir" "$batch_root" 2>/dev/null || true' EXIT

sed -n '/^apply_btrfs_disk_limit()/,/^# ======== 主逻辑 ========/p' scripts/onepodman.sh | sed '$d' > "$helper_source"
# shellcheck disable=SC1090
source "$helper_source"

podman() {
    case "${1:-}" in
        inspect)
            return 0
            ;;
        mount)
            printf '%s\n' "$rootfs_path"
            ;;
        unmount)
            printf '%s\n' "$*" >> "$podman_calls"
            ;;
        *)
            return 0
            ;;
    esac
}

btrfs() {
    printf '%s\n' "$*" >> "$calls"
    case "${1:-} ${2:-}" in
        'subvolume show'|'quota enable'|'qgroup limit')
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

apply_btrfs_disk_limit ct-test 10
if ! grep -Eq '^qgroup limit 10g ' "$calls"; then
    printf '%s\n' 'btrfs qgroup limit was not called with the requested size' >&2
    exit 1
fi
if ! grep -Eq '^unmount ct-test$' "$podman_calls"; then
    printf '%s\n' 'temporary Podman rootfs mount was not released' >&2
    exit 1
fi

sed -n '/^pre_check()/,/^# ======== 读取日志/p' scripts/create_podman.sh | sed '$d' > "$batch_helper"
# shellcheck disable=SC1090
source "$batch_helper"

printf '%s\n' '#!/bin/bash' 'printf stale' > "${batch_cache_dir}/onepodman.sh"
export ROOTLESS_MODE=true
export SCRIPT_DIR="$batch_script_dir"
export PODMAN_SCRIPT_DIR="$batch_cache_dir"
export PODMAN_SCRIPT_BASE_URL="https://example.invalid/scripts"
export cdn_success_url=""

curl() {
    local output_file=""
    while (( $# > 0 )); do
        case "$1" in
            -o)
                output_file="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    cp "${repo_root}/scripts/onepodman.sh" "$output_file"
}

pre_check
if ! grep -Eq '^apply_btrfs_disk_limit\(\)' "${batch_cache_dir}/onepodman.sh"; then
    printf '%s\n' 'batch pre-check did not refresh the cached onepodman.sh' >&2
    exit 1
fi

bash -n scripts/onepodman.sh scripts/create_podman.sh
printf '%s\n' 'btrfs disk-limit regression checks passed'
