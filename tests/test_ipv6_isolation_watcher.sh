#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/podman-ipv6-watcher.XXXXXX")
watch_pid=''
cleanup() {
    touch "$tmp/stop-events"
    if [[ -n "$watch_pid" ]]; then
        wait "$watch_pid" 2>/dev/null || kill "$watch_pid" 2>/dev/null || true
    fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/bin"
awk '
    /^install_podman_ipv6_isolation_watcher\(\)/ { in_function = 1 }
    in_function && index($0, "cat >") && index($0, "<<") && index($0, "EOF") { in_body = 1; next }
    in_body && $0 == "EOF" { exit }
    in_body { print }
' "$repo_root/podmaninstall.sh" >"$tmp/watcher.sh"
[[ -s "$tmp/watcher.sh" ]] || {
    printf 'failed to extract the installed IPv6 isolation watcher\n' >&2
    exit 1
}
chmod +x "$tmp/watcher.sh"
grep -Fq -- "--format '{{.ID}}'" "$tmp/watcher.sh" || {
    printf 'watcher does not read the container ID field exposed by Podman events\n' >&2
    exit 1
}

cat >"$tmp/bin/podman" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
    ps)
        [[ -s "$CONTAINERS_FILE" ]] && cat "$CONTAINERS_FILE"
        ;;
    inspect)
        case "$*" in
            *'.IPAddress'*) printf '%s\n' '10.89.0.8/24' ;;
            *'.State.Pid'*) printf '%s\n' '4321' ;;
            *'.Gateway'*) printf '%s\n' '10.89.0.1' ;;
            *'.Config.Labels'*) printf '%s\n' 'true' ;;
            *) exit 2 ;;
        esac
        ;;
    events)
        touch "$EVENT_READY_FILE"
        tail -n 0 -f "$EVENTS_FILE" &
        tail_pid=$!
        while [[ ! -e "$STOP_EVENTS_FILE" ]]; do sleep 0.05; done
        kill "$tail_pid" 2>/dev/null || true
        wait "$tail_pid" 2>/dev/null || true
        ;;
    stop)
        printf '%s\n' "$2" >>"$STOP_FILE"
        ;;
    *)
        printf 'unexpected fake Podman call: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF
cat >"$tmp/bin/nsenter" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$*" in
    *'ip -o -4 addr show'*)
        [[ -e "$IPV4_FILE" ]] && printf '%s\n' '2: eth1 inet 10.89.0.8/24 scope global' || true
        ;;
    *'ip -4 route show default'*)
        [[ -e "$ROUTE_FILE" ]] && printf '%s\n' 'default via 10.89.0.1 dev eth1' || true
        ;;
    *'ip -4 route del default dev eth1'*)
        if [[ -e "$FAIL_ROUTE_FILE" ]]; then exit 1; fi
        rm -f "$ROUTE_FILE"
        ;;
    *'ip -4 addr del 10.89.0.8/24 dev eth1'*)
        rm -f "$IPV4_FILE"
        ;;
    *)
        printf 'unexpected fake nsenter call: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$tmp/bin/podman" "$tmp/bin/nsenter"

export CONTAINERS_FILE="$tmp/containers"
export EVENTS_FILE="$tmp/events"
export EVENT_READY_FILE="$tmp/events-ready"
export STOP_EVENTS_FILE="$tmp/stop-events"
export STOP_FILE="$tmp/stopped"
export FAIL_ROUTE_FILE="$tmp/fail-route-delete"
export IPV4_FILE="$tmp/ipv4-present"
export ROUTE_FILE="$tmp/route-present"
export PATH="$tmp/bin:$PATH"
printf '%s\n' 'watcher-test-container' >"$CONTAINERS_FILE"
: >"$EVENTS_FILE"
touch "$IPV4_FILE" "$ROUTE_FILE"
bash "$tmp/watcher.sh" --watch >"$tmp/watcher.log" 2>&1 &
watch_pid=$!

wait_isolated() {
    local attempt
    for attempt in {1..100}; do
        [[ ! -e "$IPV4_FILE" && ! -e "$ROUTE_FILE" ]] && return 0
        sleep 0.1
    done
    return 1
}
wait_isolated || {
    printf 'watcher startup did not remove the secondary IPv4 address and route\n' >&2
    cat "$tmp/watcher.log" >&2
    exit 1
}
for attempt in {1..100}; do
    [[ -e "$EVENT_READY_FILE" ]] && break
    sleep 0.1
done
[[ -e "$EVENT_READY_FILE" ]] || {
    printf 'watcher did not open the Podman event stream\n' >&2
    exit 1
}

touch "$IPV4_FILE" "$ROUTE_FILE"
printf '%s\n' 'watcher-test-container' >>"$EVENTS_FILE"
wait_isolated || {
    printf 'watcher did not restore isolation after the container start event\n' >&2
    cat "$tmp/watcher.log" >&2
    exit 1
}

touch "$IPV4_FILE" "$ROUTE_FILE"
touch "$FAIL_ROUTE_FILE"
printf '%s\n' 'watcher-test-container' >>"$EVENTS_FILE"
attempt=0
while [[ ! -s "$STOP_FILE" ]] && ((attempt < 100)); do
    attempt=$((attempt + 1))
    sleep 0.1
done
if [[ ! -s "$STOP_FILE" ]] || ! grep -Fxq 'watcher-test-container' "$STOP_FILE"; then
    printf 'watcher left the container running after IPv4 isolation failed\n' >&2
    cat "$tmp/watcher.log" >&2
    exit 1
fi

printf 'Podman IPv6 isolation watcher tests passed\n'
