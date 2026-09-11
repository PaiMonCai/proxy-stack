#!/usr/bin/env bash
# Runs one integration suite in a disposable container, the same way on a test
# box and in GitHub Actions:
#
#   tests/integration/container.sh debian|alpine full|nginx443|e2e|snell
#
# Debian 13 runs systemd as PID 1, Alpine 3.22 runs OpenRC (supervise-daemon),
# so both service layers are exercised for real. The containers are privileged:
# the suites install services, firewall rules and (Snell on Alpine) Docker.
# A suite is tests/integration/<suite>-<os>.sh when that exists, else <suite>.sh.

set -euo pipefail

os="${1:?usage: $0 debian|alpine SUITE}"
suite="${2:?usage: $0 debian|alpine SUITE}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="tests/integration/${suite}-${os}.sh"
[[ -f "$root/$script" ]] || script="tests/integration/${suite}.sh"
[[ -f "$root/$script" ]] || { echo "unknown suite: $suite" >&2; exit 2; }

name="psm-it-${os}-${suite}-$$"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

case "$os" in
    debian)
        image=psm-it-debian13-systemd
        if ! docker image inspect "$image" >/dev/null 2>&1; then
            docker build -q -t "$image" - >/dev/null <<'EOF'
FROM debian:13
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv dbus \
      curl jq unzip openssl ca-certificates iproute2 procps cron git file \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
EOF
        fi
        docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
            --tmpfs /run --tmpfs /run/lock --name "$name" --hostname "$name" "$image" >/dev/null
        for _ in $(seq 1 30); do
            state=$(docker exec "$name" systemctl is-system-running 2>/dev/null || true)
            [[ "$state" == running || "$state" == degraded ]] && break
            sleep 1
        done
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
    *) echo "unknown os: $os (debian|alpine)" >&2; exit 2 ;;
esac

tar -C "$root" --exclude=./.git --exclude=./config --exclude=./docs -cf - . \
    | docker exec -i "$name" sh -c 'mkdir -p /opt/psm && tar -xf - -C /opt/psm'
echo "== $os / $suite ($script)"
docker exec "$name" bash "/opt/psm/$script"
