#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/podmaninstall.sh"

extract_function() {
    local name="$1"
    awk -v name="$name" '
        $0 == name "() {" { printing = 1 }
        printing {
            print
            if ($0 == "}") {
                exit
            }
        }
    ' "$installer"
}

python_cmd() {
    command -v python3
}

PODMAN_STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/podman-ipv6-state.XXXXXX")
trap 'rm -rf -- "$PODMAN_STATE_DIR"' EXIT

# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
source <(extract_function podman_state_file)

# shellcheck disable=SC1090 # The test intentionally loads one installer function.
source <(extract_function generate_ipv6_subnet_candidates)
# shellcheck disable=SC1090 # The test intentionally loads one installer function.
source <(extract_function is_public_ipv6)
# shellcheck disable=SC1090 # The test intentionally loads the CIDR selector.
source <(extract_function select_public_ipv6_cidr)
# shellcheck disable=SC1090 # The test intentionally loads one installer function.
source <(extract_function normalize_ipv6_subnet)
# shellcheck disable=SC1090 # The test intentionally loads the ULA NAT66 validator.
source <(extract_function normalize_ipv6_internal_subnet)
# shellcheck disable=SC1090 # The test intentionally loads the ULA NAT66 state guard.
source <(extract_function podman_ipv6_ula_state_matches_network)
# shellcheck disable=SC1090 # The test intentionally loads the host-route guard.
source <(extract_function ipv6_subnet_overlaps_host)
# shellcheck disable=SC1090 # The test intentionally loads one installer function.
source <(extract_function create_ipv6_network)
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
source <(extract_function ndpresponder_image_matches_architecture)
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
source <(extract_function ndpresponder_supports_target_file)
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
source <(extract_function ndpresponder_image_supports_required_features)
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
source <(extract_function ndpresponder_existing_container_image)
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
source <(extract_function quarantine_incompatible_manual_ndpresponder)
# shellcheck disable=SC1090 # The test intentionally loads the route-health helper.
source <(extract_function podman_ipv6_network_has_explicit_default_route)

host_cidr="2a14:6781:000a:0000:0009:0000:0000:0000/64"

# shellcheck disable=SC2329 # Invoked by the dynamically sourced IPv6 helper.
ip() {
    if [[ "$1" == "-6" && "$2" == "-o" && "$3" == "addr" ]]; then
        case "${IPV6_TEST_SCENARIO:-default}" in
            delegated)
                printf '%s\n' '2: vmbr0 inet6 2a14:7c0:1002:10f8::1/128 scope global'
                printf '%s\n' '4: vmbr2 inet6 2a14:7c0:1002:10f8::1/38 scope global'
                ;;
            tunnel)
                printf '%s\n' '5: he-ipv6 inet6 2001:470:1f14:9::2/64 scope global'
                ;;
            hostonly)
                printf '%s\n' '2: eth0 inet6 2a14:6781:000a:0000::9/128 scope global'
                ;;
            *)
                printf '%s\n' '2: eth0 inet6 2605:52c0:2:14b:be24:11ff:fe6e:d967/64 scope global'
                ;;
        esac
    elif [[ "$1" == "-6" && "$2" == "route" ]]; then
        printf '%s\n' '2605:52c0:2:14b::/64 dev eth0 proto kernel'
    fi
}
selected=$(select_public_ipv6_cidr)
if [[ "$selected" != '2605:52c0:2:14b:be24:11ff:fe6e:d967/64' ]]; then
    printf 'normal /64 selection returned %q\n' "$selected" >&2
    exit 1
fi
IPV6_TEST_SCENARIO=delegated
selected=$(select_public_ipv6_cidr)
if [[ "$selected" != '2a14:7c0:1002:10f8::1/38' ]]; then
    printf 'delegated /38 was hidden by an uplink /128: %q\n' "$selected" >&2
    exit 1
fi
IPV6_TEST_SCENARIO=tunnel
selected=$(select_public_ipv6_cidr)
if [[ "$selected" != '2001:470:1f14:9::2/64' ]]; then
    printf 'tunnel /64 selection returned %q\n' "$selected" >&2
    exit 1
fi
IPV6_TEST_SCENARIO=hostonly
selected=$(select_public_ipv6_cidr)
if [[ "$selected" != '2a14:6781:000a:0000::9/128' ]]; then
    printf 'host-only /128 selection returned %q\n' "$selected" >&2
    exit 1
fi
unset IPV6_TEST_SCENARIO
if ! ipv6_subnet_overlaps_host "2605:52c0:2:14b:1::/112"; then
    printf 'host connected IPv6 route was not detected as an overlap\n' >&2
    exit 1
fi
if ipv6_subnet_overlaps_host "2a14:6781:a::/112"; then
    printf 'unrelated IPv6 route was reported as an overlap\n' >&2
    exit 1
fi
unset -f ip

managed_ula='fd42:5339:296f:1d00::/64'
if ! podman_ipv6_ula_state_matches_network nat "$managed_ula" "$managed_ula"; then
    printf 'installer-managed Podman ULA was not accepted for NAT66 reuse\n' >&2
    exit 1
fi
if podman_ipv6_ula_state_matches_network manual "$managed_ula" "$managed_ula" || \
   podman_ipv6_ula_state_matches_network nat 'fd42:5339:296f:1d01::/64' "$managed_ula" || \
   podman_ipv6_ula_state_matches_network nat '2a14:6781:a::/64' '2a14:6781:a::/64'; then
    printf 'unmanaged or mismatched Podman ULA was accepted for NAT66 reuse\n' >&2
    exit 1
fi

# The migration test exercises the decision path only; network mutation is
# stubbed so it remains safe for an unprivileged macOS/Linux test runner.
# shellcheck disable=SC2329 # Invoked by the dynamically sourced network creator.
create_manual_ipv6_network() { return 1; }

# A single routed /128 has usable host IPv6 but no address pool. The network
# creator must retain outbound IPv6 by choosing its private NAT66 mode.
nat66_parent=''
# shellcheck disable=SC2329 # Invoked by the dynamically sourced network creator.
create_podman_nat66_ipv6_network() {
    nat66_parent="$1"
    return 0
}
# shellcheck disable=SC2329 # Invoked by the dynamically sourced network creator.
_yellow() { :; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced network creator.
podman() {
    [[ "$*" == 'network exists podman-ipv6' ]] && return 1
    return 1
}
# shellcheck disable=SC2034 # Read by the dynamically sourced IPv6 network creator.
PODMAN_IPV6_SUBNET=''
if ! create_ipv6_network '2a14:6781:000a:0000::9/128'; then
    printf 'host-only /128 did not fall back to Podman ULA NAT66\n' >&2
    exit 1
fi
if [[ "$nat66_parent" != '2a14:6781:000a:0000::9/128' ]]; then
    printf 'Podman NAT66 fallback used unexpected parent %q\n' "$nat66_parent" >&2
    exit 1
fi

candidates=()
while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && candidates+=("$candidate")
done < <(generate_ipv6_subnet_candidates "$host_cidr")

[[ ${#candidates[@]} -gt 0 ]] || {
    printf 'expected at least one IPv6 sibling candidate\n' >&2
    exit 1
}

python3 - "$host_cidr" "${candidates[@]}" <<'PY'
import ipaddress
import sys

host = ipaddress.IPv6Interface(sys.argv[1])
parent = host.network
for raw in sys.argv[2:]:
    child = ipaddress.IPv6Network(raw)
    if child.network_address not in parent or child.broadcast_address not in parent:
        raise SystemExit(f"candidate outside host prefix: {child}")
    if host.ip in child:
        raise SystemExit(f"candidate contains host address: {child}")
PY

if ! is_public_ipv6 "2a14:6781:a::9"; then
    printf 'expected a global unicast IPv6 to be accepted\n' >&2
    exit 1
fi
for non_public in "fec0::1" "ff02::1" "64:ff9b::1" "2001:0000::1" "2001:0002::1" "2001:0010::1" "2001:0020::1" "2001:0db8::1" "2002::1" "3fff:000f::1"; do
    if is_public_ipv6 "$non_public"; then
        printf 'non-public IPv6 was accepted as an allocation source: %s\n' "$non_public" >&2
        exit 1
    fi
done
if normalize_ipv6_subnet "ff02::/64" >/dev/null; then
    printf 'multicast IPv6 subnet was accepted for Podman\n' >&2
    exit 1
fi

if extract_function check_ipv6 | grep -Eq 'API_NET|curl[[:space:]]'; then
    printf 'check_ipv6 must not use an external address as a subnet source\n' >&2
    exit 1
fi
if ! extract_function adapt_ipv6 | grep -Fq "net.ipv6.conf.\${interface}.accept_ra=2"; then
    printf 'Podman IPv6 forwarding must preserve router advertisements on the uplink\n' >&2
    exit 1
fi
if ! ndpresponder_image_matches_architecture arm64 arm64 ||
   ! ndpresponder_image_matches_architecture arm armv7l ||
   ndpresponder_image_matches_architecture arm64 amd64; then
    printf 'Podman responder image architecture validation is incorrect\n' >&2
    exit 1
fi

if ! extract_function start_ndpresponder | grep -Fq -- '--restart on-failure:3'; then
    printf 'ndpresponder must use a bounded failure restart policy\n' >&2
    exit 1
fi
if extract_function start_ndpresponder | grep -Fq -- '--restart always'; then
    printf 'ndpresponder must not use an unconditional restart policy\n' >&2
    exit 1
fi

# A stale image must be rejected when manual routed mode needs the hot-reloaded
# target file. The probe is deliberately isolated from the later Podman mocks.
if ! (
    # shellcheck disable=SC2329 # Invoked by the dynamically sourced capability probe.
    podman() {
        [[ "${1:-}" == run ]] || return 1
        printf '%s\n' '      --target-file value  reloadable static targets'
    }
    ndpresponder_supports_target_file stale-image
); then
    printf 'target-file capability probe rejected a compatible image\n' >&2
    exit 1
fi
if (
    # shellcheck disable=SC2329 # Invoked by the dynamically sourced capability probe.
    podman() {
        [[ "${1:-}" == run ]] || return 1
        printf '%s\n' '      -n value  static targets'
    }
    ndpresponder_supports_target_file stale-image
); then
    printf 'target-file capability probe accepted a stale image\n' >&2
    exit 1
fi

# Manual routed IPv6 relies on the hot-reloaded target file. A stale responder
# launched with --restart always must be removed before a failed source build
# can leave it consuming CPU in a restart loop.
# shellcheck disable=SC2329 # Invoked by the dynamically sourced quarantine helper.
_yellow() { :; }
NDPRESPONDER_TARGET_FILE_REQUIRED=true
manual_quarantine_updated=false
manual_quarantine_removed=false
# shellcheck disable=SC2329 # Invoked by the dynamically sourced quarantine helper.
podman() {
    case "$1:$2" in
        inspect:ndpresponder)
            return 0
            ;;
        inspect:-f)
            printf '%s\n' stale-responder-image
            return 0
            ;;
        run:--rm)
            printf '%s\n' '      -n value  static targets'
            return 0
            ;;
        update:--restart=no)
            manual_quarantine_updated=true
            return 0
            ;;
        rm:-f)
            manual_quarantine_removed=true
            return 0
            ;;
        *)
            printf 'unexpected podman invocation during manual responder quarantine: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
quarantine_incompatible_manual_ndpresponder
[[ "$manual_quarantine_updated" == true && "$manual_quarantine_removed" == true ]] || {
    printf 'incompatible manual responder was not quarantined before a restart loop could continue\n' >&2
    exit 1
}
# shellcheck disable=SC2034 # Read by the dynamically sourced responder starter.
NDPRESPONDER_TARGET_FILE_REQUIRED=false

if ! grep -Fq 'arm64) arch_tag="aarch64"' "$installer"; then
    printf 'Podman must select the published aarch64 responder tag on ARM64\n' >&2
    exit 1
fi

# Netavark reports an explicit route in network inspect JSON. An unmanaged
# network with no_default_route must not be treated as ready without ::/0.
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
podman() {
    if [[ "$*" == 'network inspect podman-ipv6' ]]; then
        printf '%s\n' '[{"routes":[{"destination":"::/0","gateway":"2a14:6781:a:0:2::1"}]}]'
        return 0
    fi
    printf 'unexpected podman invocation while checking IPv6 default route: %s\n' "$*" >&2
    return 1
}
if ! podman_ipv6_network_has_explicit_default_route; then
    printf 'explicit IPv6 default route was not recognized\n' >&2
    exit 1
fi
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
podman() {
    if [[ "$*" == 'network inspect podman-ipv6' ]]; then
        printf '%s\n' '[{"routes":[]}]'
        return 0
    fi
    printf 'unexpected podman invocation while checking missing IPv6 default route: %s\n' "$*" >&2
    return 1
}
if podman_ipv6_network_has_explicit_default_route; then
    printf 'missing IPv6 default route was accepted\n' >&2
    exit 1
fi

# An old empty unmanaged network can be replaced safely, but the migration
# must not remove a network that still has any attached container.
# shellcheck disable=SC1090 # The test intentionally loads the migration helper.
source <(extract_function migrate_unmanaged_ipv6_network_default_route)
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
_yellow() { :; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
_green() { :; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
podman_ipv6_network_has_attached_containers() { return 1; }
podman_ipv6_network_subnet() { printf '%s\n' '2a14:6781:a:0:2::/96'; }
normalize_ipv6_subnet() { printf '%s\n' "$1"; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
ipv6_subnet_has_live_address() { return 1; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
ip() { return 1; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
cat() {
    if [[ "$1" == '/usr/local/bin/podman_ipv6_bridge_owned' ]]; then
        printf '%s\n' true
        return 0
    fi
    command cat "$@"
}
printf '%s\n' true >"$(podman_state_file podman_ipv6_bridge_owned)"
migrated_prefix=""
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
podman() {
    if [[ "$*" == 'network rm podman-ipv6' ]]; then
        return 0
    fi
    printf 'unexpected podman invocation during empty unmanaged migration: %s\n' "$*" >&2
    return 1
}
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
create_unmanaged_ipv6_network() {
    migrated_prefix="$1"
    return 0
}
if ! migrate_unmanaged_ipv6_network_default_route; then
    printf 'empty unmanaged IPv6 network was not migrated\n' >&2
    exit 1
fi
[[ "$migrated_prefix" == '2a14:6781:a:0:2::/96' ]] || {
    printf 'migration used unexpected IPv6 subnet: %q\n' "$migrated_prefix" >&2
    exit 1
}

removed_attached_network=false
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
podman_ipv6_network_has_attached_containers() { return 0; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
podman() {
    if [[ "$*" == 'network rm podman-ipv6' ]]; then
        removed_attached_network=true
    fi
    return 0
}
if migrate_unmanaged_ipv6_network_default_route; then
    printf 'migration accepted a network with attached containers\n' >&2
    exit 1
fi
[[ "$removed_attached_network" == false ]] || {
    printf 'migration removed a network with attached containers\n' >&2
    exit 1
}

# The installer must surface an old route-less unmanaged network as not ready,
# rather than letting onepodman attach new containers to it.
network_migration_called=false
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
podman() {
    case "$1:$2" in
        network:exists) return 0 ;;
        network:inspect) printf '%s\n' unmanaged; return 0 ;;
    esac
    printf 'unexpected podman invocation while checking old unmanaged network: %s\n' "$*" >&2
    return 1
}
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
podman_ipv6_network_has_explicit_default_route() { return 1; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
migrate_unmanaged_ipv6_network_default_route() {
    network_migration_called=true
    return 1
}
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer helper.
set_ipv6_network_mode() { :; }
if create_ipv6_network "$host_cidr"; then
    printf 'installer accepted an unmanaged network without an IPv6 default route\n' >&2
    exit 1
fi
[[ "$network_migration_called" == true ]] || {
    printf 'installer did not inspect/migrate the old unmanaged network\n' >&2
    exit 1
}

# A broken remote ARM tag must not tear down a known-good responder before the
# fallback source image has passed architecture validation.
# shellcheck disable=SC1090 # The test intentionally loads the installer function.
source <(extract_function resolve_ndpresponder_image)
# shellcheck disable=SC1090 # The test intentionally loads the installer function.
source <(extract_function start_ndpresponder)
# NAT66 has no public container addresses to proxy. It must be considered
# healthy without opening a Podman API socket or starting a responder process.
printf '%s\n' nat >"$(podman_state_file podman_ipv6_network_mode)"
nat66_socket_called=false
# shellcheck disable=SC2329 # Invoked by the dynamically sourced responder starter.
podman_api_socket() {
    nat66_socket_called=true
    return 1
}
# shellcheck disable=SC2329 # Invoked by the dynamically sourced responder starter.
_green() { :; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced responder starter.
podman() {
    [[ "$*" == 'network exists podman-ipv6' ]] && return 0
    printf 'unexpected Podman invocation during NAT66 responder bypass: %s\n' "$*" >&2
    return 1
}
if ! start_ndpresponder; then
    printf 'Podman NAT66 unnecessarily required ndpresponder\n' >&2
    exit 1
fi
[[ "$nat66_socket_called" == false ]] || {
    printf 'Podman NAT66 attempted to open the API socket\n' >&2
    exit 1
}
printf '%s\n' '' >"$(podman_state_file podman_ipv6_network_mode)"
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer function.
_yellow() { :; }
# shellcheck disable=SC2034 # Read by the dynamically sourced installer function.
ARCH_TYPE=arm64
# shellcheck disable=SC2034 # Read by the dynamically sourced installer function.
interface=""
podman_rm_called=false
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer function.
podman_api_socket() { printf '%s\n' /tmp/podman-api.sock; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer function.
systemctl() { :; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer function.
podman() {
    case "$1:$2" in
        network:exists|pull:*)
            return 0
            ;;
        image:inspect)
            printf '%s\n' amd64
            return 0
            ;;
        build:*)
            return 1
            ;;
        rm:*)
            podman_rm_called=true
            return 0
            ;;
        *)
            printf 'unexpected podman invocation during architecture guard: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
if start_ndpresponder; then
    printf 'Podman replaced a responder after both the remote and source images failed validation\n' >&2
    exit 1
fi
[[ "$podman_rm_called" == false ]] || {
    printf 'Podman removed the existing responder before a verified replacement existed\n' >&2
    exit 1
}

# A wrong registry architecture should fall back to a native source build.
# The existing responder is replaced only after inspecting that local image.
podman_rm_called=false
source_build_called=false
NDPRESPONDER_SOURCE_URL='https://example.test/ndpresponder.git'
sleep() { :; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer function.
_green() { :; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer function.
podman() {
    case "$1:$2" in
        network:exists|pull:*)
            return 0
            ;;
        image:inspect)
            if [[ "$*" == *'localhost/oneclickvirt-ndpresponder:arm64'* ]]; then
                printf '%s\n' arm64
            else
                printf '%s\n' amd64
            fi
            return 0
            ;;
        build:*)
            source_build_called=true
            [[ "$*" == *"$NDPRESPONDER_SOURCE_URL"* ]]
            return
            ;;
        rm:*)
            podman_rm_called=true
            return 0
            ;;
        run:*)
            return 0
            ;;
        inspect:-f)
            printf '%s\n' running
            return 0
            ;;
        *)
            printf 'unexpected podman invocation during source fallback: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
if ! start_ndpresponder; then
    printf 'Podman did not start a verified source-built responder after rejecting the wrong registry architecture\n' >&2
    exit 1
fi
[[ "$source_build_called" == true ]] || {
    printf 'Podman did not attempt the responder source-build fallback\n' >&2
    exit 1
}
[[ "$podman_rm_called" == true ]] || {
    printf 'Podman did not replace the responder after the source image was verified\n' >&2
    exit 1
}
unset NDPRESPONDER_SOURCE_URL

# A sibling of a host-assigned prefix overlaps the host route, which Netavark
# rejects in managed mode. The installer must choose its owned unmanaged
# bridge fallback instead of retrying the unsafe host-containing subnet. If
# the first sibling is already used by another Podman network, it must keep
# trying later siblings.
_yellow() { :; }
captured_manual_parent=""
manual_fallback_called=false
managed_attempted=false
# shellcheck disable=SC2329 # Invoked by the dynamically loaded installer function.
podman() {
    [[ "${1:-}" == network && "${2:-}" == exists ]] && return 1
    printf 'unexpected podman invocation: %s\n' "$*" >&2
    return 1
}
generate_ipv6_subnet_candidates() {
    printf '%s\n' '2a14:6781:a:0:1::/96'
    printf '%s\n' '2a14:6781:a:0:2::/96'
}
ipv6_subnet_has_live_address() { return 1; }
ipv6_subnet_overlaps_host() { return 0; }
ipv6_subnet_overlaps_podman_network() {
    [[ "$1" == '2a14:6781:a:0:1::/96' ]]
}
create_managed_ipv6_network() {
    managed_attempted=true
    return 1
}
create_manual_ipv6_network() {
    captured_manual_parent="$1"
    manual_fallback_called=true
    return 0
}
set_ipv6_network_mode() { :; }
unset PODMAN_IPV6_SUBNET
create_ipv6_network "$host_cidr"
[[ "$captured_manual_parent" == "$host_cidr" ]] || {
    printf 'expected manual fallback to retain the public parent, got %q\n' "$captured_manual_parent" >&2
    exit 1
}
[[ "$managed_attempted" == false ]] || {
    printf 'managed network creation was attempted despite host-route overlap\n' >&2
    exit 1
}
[[ "$manual_fallback_called" == true ]] || {
    printf 'manual routed fallback was not attempted\n' >&2
    exit 1
}
if ! grep -Fq 'net_opts="--network podman-net --network podman-ipv6"' "$repo_root/scripts/onepodman.sh"; then
    printf 'unmanaged IPv6 containers must attach podman-net before podman-ipv6\n' >&2
    exit 1
fi

# A bridge creation that fails after adding a new bridge must run the same
# ownership-aware cleanup used for a failed Podman network creation.
# shellcheck disable=SC1090 # The test intentionally loads one installer function.
source <(extract_function create_unmanaged_ipv6_network)
cleanup_called=false
ipv6_gateway_for_subnet() { printf '%s\n' '2a14:6781:a:0:2::1'; }
ensure_unmanaged_ipv6_bridge() {
    # shellcheck disable=SC2034 # Read by the dynamically loaded cleanup helper.
    UNMANAGED_IPV6_BRIDGE_CREATED=true
    return 1
}
cleanup_failed_unmanaged_ipv6_bridge() { cleanup_called=true; }
if create_unmanaged_ipv6_network '2a14:6781:a:0:2::/96' /tmp/unused-netavark-error; then
    printf 'expected unmanaged setup failure\n' >&2
    exit 1
fi
[[ "$cleanup_called" == true ]] || {
    printf 'expected cleanup after unmanaged bridge setup failure\n' >&2
    exit 1
}

# An installer-owned bridge can survive an uninstall only when other runtime
# ports are still attached. It must not be repurposed when the old
# podman-ipv6 network is already gone.
# shellcheck disable=SC1090 # The test intentionally loads one installer function.
source <(extract_function bridge_has_attached_interfaces)
# shellcheck disable=SC1090 # The test intentionally loads one installer function.
source <(extract_function ensure_unmanaged_ipv6_bridge)
ip() {
    case "$*" in
        'link show podman-br1') return 0 ;;
        '-d link show podman-br1') printf '%s\n' '7: podman-br1: <BROADCAST> mtu 1500 bridge'; return 0 ;;
        '-o link show master podman-br1') printf '%s\n' '8: veth-retained@if7: <BROADCAST> master podman-br1'; return 0 ;;
        '-6 addr replace '*)
            printf 'retained bridge was reconfigured: %s\n' "$*" >&2
            return 1
            ;;
        *)
            printf 'unexpected ip invocation: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
cat() {
    [[ "$1" == '/usr/local/bin/podman_ipv6_bridge_owned' ]] && {
        printf '%s\n' true
        return 0
    }
    command cat "$@"
}
podman() {
    [[ "$*" == 'network exists podman-ipv6' ]] && return 1
    printf 'unexpected podman invocation while checking retained bridge: %s\n' "$*" >&2
    return 1
}
update_sysctl() {
    printf 'retained bridge sysctl changed: %s\n' "$*" >&2
    return 1
}
if ensure_unmanaged_ipv6_bridge '2a14:6781:a:0:2::/96' '2a14:6781:a:0:2::1'; then
    printf 'expected retained bridge reuse to be rejected\n' >&2
    exit 1
fi

printf 'podman IPv6 network candidate tests passed\n'
