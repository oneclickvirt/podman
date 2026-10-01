#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/podman-uninstall-package.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT

function_source=$(awk '
    $0 == "remove_podman_package() {" { printing = 1 }
    printing { print }
    printing && $0 == "}" { exit }
' "$repo_root/podmanuninstall.sh")
[[ -n "$function_source" ]] || {
    printf '%s\n' 'Could not extract remove_podman_package' >&2
    exit 1
}
eval "$function_source"
_red() { :; }
_green() { :; }
_yellow() { :; }

write_mock() {
    local name="$1"
    cat >"$test_bin/$name" <<'EOF'
#!/bin/sh
name=${0##*/}
case "$name" in
    dpkg-query)
        [ "$PKG_TEST_BACKEND" = dpkg ] || exit 1
        [ "$1" = -W ] && [ "$2" = '-f=${db:Status-Abbrev}' ] && [ "$3" = podman ] || exit 2
        printf '%s\n' 'ii '
        ;;
    rpm)
        if [ "$1" = -q ]; then
            case "$PKG_TEST_BACKEND" in rpm-*) exit 0 ;; *) exit 1 ;; esac
        fi
        [ "$PKG_TEST_BACKEND" = rpm-fallback ] && [ "$1" = -e ] && [ "$2" = podman ] || exit 2
        actual="$name $*"
        [ "$actual" = "$PKG_TEST_EXPECTED" ] || exit 90
        printf '%s\n' "$actual" >>"$PKG_TEST_LOG"
        /bin/rm -f "$PKG_TEST_BIN/podman"
        ;;
    apk)
        if [ "$1" = info ]; then
            [ "$PKG_TEST_BACKEND" = apk ] && [ "$2" = -e ] && [ "$3" = podman ] || exit 1
        else
            actual="$name $*"
            [ "$actual" = "$PKG_TEST_EXPECTED" ] || exit 90
            printf '%s\n' "$actual" >>"$PKG_TEST_LOG"
            /bin/rm -f "$PKG_TEST_BIN/podman"
        fi
        ;;
    pacman)
        if [ "$1" = -Qq ]; then
            [ "$PKG_TEST_BACKEND" = pacman ] && [ "$2" = podman ] || exit 1
        else
            actual="$name $*"
            [ "$actual" = "$PKG_TEST_EXPECTED" ] || exit 90
            printf '%s\n' "$actual" >>"$PKG_TEST_LOG"
            /bin/rm -f "$PKG_TEST_BIN/podman"
        fi
        ;;
    apt-get|dnf|yum|zypper|apk|pacman)
        actual="$name $*"
        [ "$actual" = "$PKG_TEST_EXPECTED" ] || {
            printf 'Unexpected package removal invocation: %s\n' "$actual" >&2
            exit 90
        }
        printf '%s\n' "$actual" >>"$PKG_TEST_LOG"
        /bin/rm -f "$PKG_TEST_BIN/podman"
        ;;
    *) exit 2 ;;
esac
EOF
    chmod 700 "$test_bin/$name"
}

run_package_case() {
    local backend="$1" expected="$2" manager="$3"
    test_bin="$test_root/$backend-$manager"
    mkdir -p "$test_bin"
    export PKG_TEST_BACKEND="$backend" PKG_TEST_EXPECTED="$expected"
    export PKG_TEST_BIN="$test_bin" PKG_TEST_LOG="$test_root/$backend-$manager.log"
    : >"$PKG_TEST_LOG"
    : >"$test_bin/podman"
    chmod 700 "$test_bin/podman"
    write_mock "$manager"
    case "$backend" in
        dpkg) write_mock dpkg-query ;;
        rpm-*)
            write_mock rpm
            if [[ "$manager" != rpm ]]; then
                case "$manager" in dnf|yum|zypper) write_mock "$manager" ;; esac
            fi
            ;;
        apk) ;;
        pacman) ;;
    esac
    PATH="$test_bin:$PATH" remove_podman_package
    [[ ! -e "$test_bin/podman" ]] || {
        printf 'Podman executable remained in %s case\n' "$backend-$manager" >&2
        exit 1
    }
    [[ "$(<"$PKG_TEST_LOG")" == "$expected" ]] || {
        printf 'Wrong package command recorded for %s: %s\n' "$backend-$manager" "$(<"$PKG_TEST_LOG")" >&2
        exit 1
    }
}

run_package_case dpkg 'apt-get -y purge podman' apt-get
run_package_case rpm-dnf 'dnf -y remove --noautoremove podman' dnf
run_package_case rpm-yum 'yum -y remove podman' yum
run_package_case rpm-zypper 'zypper --non-interactive remove --no-clean-deps podman' zypper
run_package_case rpm-fallback 'rpm -e podman' rpm
run_package_case apk 'apk del podman' apk
run_package_case pacman 'pacman -R --noconfirm podman' pacman

# An unmanaged executable must make uninstall fail instead of claiming success.
test_bin="$test_root/unmanaged"
mkdir -p "$test_bin"
: >"$test_bin/podman"
chmod 700 "$test_bin/podman"
PKG_TEST_BACKEND=none PATH="$test_bin" remove_podman_package && {
    printf '%s\n' 'Unmanaged podman executable was incorrectly accepted as uninstalled' >&2
    exit 1
}

printf '%s\n' 'Podman uninstall package tests passed'
