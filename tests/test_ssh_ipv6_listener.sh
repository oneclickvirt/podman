#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

files=(
    "$repo_root/scripts/ssh_bash.sh"
    "$repo_root/scripts/ssh_sh.sh"
    "$repo_root/dockerfiles/entrypoint.sh"
    "$repo_root/dockerfiles/entrypoint_alpine.sh"
)

for file in "${files[@]}"; do
    if ! grep -Fq 'AddressFamily any' "$file"; then
        printf 'missing dual-stack SSH address family setting: %s\n' "$file" >&2
        exit 1
    fi
    if ! grep -Fq 'ListenAddress[[:space:]]+' "$file"; then
        printf 'missing explicit listener override cleanup: %s\n' "$file" >&2
        exit 1
    fi
    if grep -Eq '^[[:space:]]*(echo|printf).*ListenAddress[[:space:]]+0\\.0\\.0\\.0' "$file"; then
        printf 'IPv4-only SSH listener remained: %s\n' "$file" >&2
        exit 1
    fi
done

for file in "$repo_root/scripts/ssh_bash.sh" "$repo_root/scripts/ssh_sh.sh"; do
    if ! grep -Fq 'oneclickvirt-ssh-init-revision:' "$file"; then
        printf 'missing SSH script revision marker: %s\n' "$file" >&2
        exit 1
    fi
    if ! grep -Fq '/proc/1/comm' "$file" || ! grep -Fq 'kill -HUP 1' "$file"; then
        printf 'PID 1 sshd reload guard is missing: %s\n' "$file" >&2
        exit 1
    fi
done

printf '%s\n' 'SSH dual-stack listener regression checks passed'
