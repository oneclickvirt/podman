#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
holder=''
cleanup() {
    if [[ -n "$holder" ]]; then kill -KILL "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
command -v flock >/dev/null
awk '/^acquire_lock\(\)/ {emit=1} /^find_container_iface\(\)/ {exit} emit' \
    "$repo_root/podmaninstall.sh" >"$tmp/functions"
export lock_file="$tmp/allocations.flock"
# A legacy directory survives an unclean reset, but must no longer block.
mkdir "$tmp/allocations.lock"
bash -c 'source "$1"; acquire_lock; touch "$2"; exec sleep 30' _ "$tmp/functions" "$tmp/ready" &
holder=$!
for ((attempt=0; attempt<100; attempt++)); do
    [[ -e "$tmp/ready" ]] && break
    sleep 0.05
done
[[ -e "$tmp/ready" ]]
if flock -n "$lock_file" true; then
    printf 'concurrent process acquired a held allocation lock\n' >&2
    exit 1
fi
kill -KILL "$holder"
wait "$holder" 2>/dev/null || true
holder=''
source "$tmp/functions"
acquire_lock
release_lock
acquire_lock
release_lock
printf 'allocation lock: contention rejected, SIGKILL recovered, legacy directory ignored\n'
