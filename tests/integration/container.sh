#!/usr/bin/env bash
# Runs one integration suite in a disposable container, the same way on a test
# box and in GitHub Actions:
#
#   tests/integration/container.sh debian|ubuntu24|ubuntu22|alpine|rocky9|alma8 full|nginx443|e2e|users|snell
#
# The three supported families: Debian 13 and Ubuntu 24.04 / 22.04 (22.04 for
# jq 1.6 and Nginx 1.18), Alpine 3.22 (OpenRC, musl), and the Red Hat family as
# Rocky Linux 9 and AlmaLinux 8 (dnf, EPEL, jq 1.6; Alma 8 for systemd 239 and
# Nginx 1.14). The systemd ones run systemd as PID 1, so
# both service layers are exercised for real. The containers are privileged:
# the suites install services, firewall rules and (Snell on Alpine) Docker.
# A suite is tests/integration/<suite>-<os>.sh when that exists, else
# <suite>-systemd.sh / <suite>-openrc.sh by init system, else <suite>.sh.
#
# tests/integration/migrate.sh sources this file for it_start / it_copy_tree.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_it_run_systemd() {   # <container name> <image>: boot systemd as PID 1, wait for it
    local state
    docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run --tmpfs /run/lock --name "$1" --hostname "$1" "$2" >/dev/null
    for _ in $(seq 1 30); do
        state=$(docker exec "$1" systemctl is-system-running 2>/dev/null || true)
        [[ "$state" == running || "$state" == degraded ]] && break
        sleep 1
    done
}

it_init() { case "$1" in alpine) echo openrc ;; *) echo systemd ;; esac; }

it_start() {   # it_start <debian|ubuntu24|ubuntu22|alpine|rocky9|alma8> <container name>
    local os="$1" name="$2" image base
    case "$os" in
        debian|ubuntu24|ubuntu22)
            case "$os" in
                debian)   base=debian:13;   image=psm-it-debian13-systemd ;;
                ubuntu24) base=ubuntu:24.04; image=psm-it-ubuntu24-systemd:1 ;;
                ubuntu22) base=ubuntu:22.04; image=psm-it-ubuntu22-systemd:1 ;;
            esac
            if ! docker image inspect "$image" >/dev/null 2>&1; then
                docker build -q -t "$image" - >/dev/null <<EOF
FROM ${base}
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv dbus \
      curl jq unzip openssl ca-certificates iproute2 procps cron git file \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
EOF
            fi
            _it_run_systemd "$name" "$image"
            ;;
        rocky9|alma8)
            case "$os" in rocky9) base=rockylinux:9 ;; alma8) base=almalinux:8 ;; esac
            image="psm-it-${os}-systemd:2"   # bump the tag when the image changes
            if ! docker image inspect "$image" >/dev/null 2>&1; then
                docker build -q -t "$image" - >/dev/null <<EOF
FROM ${base}
RUN dnf -y -q install systemd procps-ng iproute cronie jq unzip openssl tar git file which hostname findutils diffutils \
 && dnf clean all
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
EOF
            fi
            _it_run_systemd "$name" "$image"
            ;;
        alpine)
            docker run -d --init --privileged --name "$name" --hostname "$name" alpine:3.22 sleep infinity >/dev/null
            docker exec "$name" sh -c '
                apk add -q --no-cache bash openrc busybox-openrc >/dev/null \
                && sed -i "s/^#\?rc_sys=.*/rc_sys=\"docker\"/" /etc/rc.conf \
                && printf "auto lo\niface lo inet loopback\n" > /etc/network/interfaces \
                && mkdir -p /run/openrc && touch /run/openrc/softlevel \
                && { openrc default >/dev/null 2>&1 || true; }'
            ;;
        *) echo "unknown os: $os (debian|ubuntu24|ubuntu22|alpine|rocky9|alma8)" >&2; return 2 ;;
    esac
}

it_copy_tree() {   # it_copy_tree <container>: this checkout, without state, into /opt/psm
    tar -C "$root" --exclude=./.git --exclude=./config --exclude=./docs -cf - . \
        | docker exec -i "$1" sh -c 'mkdir -p /opt/psm && tar -xf - -C /opt/psm'
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

set -euo pipefail

os="${1:?usage: $0 debian|ubuntu24|ubuntu22|alpine|rocky9|alma8 SUITE}"
suite="${2:?usage: $0 debian|ubuntu24|ubuntu22|alpine|rocky9|alma8 SUITE}"
script="tests/integration/${suite}-${os}.sh"
[[ -f "$root/$script" ]] || script="tests/integration/${suite}-$(it_init "$os").sh"
[[ -f "$root/$script" ]] || script="tests/integration/${suite}.sh"
[[ -f "$root/$script" ]] || { echo "unknown suite: $suite" >&2; exit 2; }

name="psm-it-${os}-${suite}-$$"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

it_start "$os" "$name"
it_copy_tree "$name"
echo "== $os / $suite ($script)"
docker exec "$name" bash "/opt/psm/$script"
