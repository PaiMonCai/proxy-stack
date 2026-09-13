#!/usr/bin/env bash
# Moves a PSM server between two disposable containers, the way a user would:
#
#   tests/integration/migrate.sh debian alpine push   # psm migrate push over SSH
#   tests/integration/migrate.sh alpine debian file   # export --encrypt, copy, import
#
# migrate-src.sh builds the old server and records what has to survive;
# migrate-dst.sh checks the new one: the same configs and share links,
# re-applied for its own init system, and a client that gets through every
# node on the new host.

set -euo pipefail

src_os="${1:?usage: $0 SRC_OS DST_OS [push|file]}"
dst_os="${2:?usage: $0 SRC_OS DST_OS [push|file]}"
mode="${3:-push}"
source "$(dirname "${BASH_SOURCE[0]}")/container.sh"

src="psm-it-mig-src-$$"
dst="psm-it-mig-dst-$$"
tmp=$(mktemp -d)
cleanup() { docker rm -f "$src" "$dst" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

echo "== migrate $src_os -> $dst_os ($mode)"
it_start "$src_os" "$src"
it_start "$dst_os" "$dst"
it_copy_tree "$src"
docker exec "$src" bash /opt/psm/tests/integration/migrate-src.sh

rc=0
if [[ "$mode" == push ]]; then
    # The new server: nothing but an SSH server that trusts the old one's key.
    docker exec "$dst" sh -c '
        if command -v apk >/dev/null; then apk add -q --no-cache openssh-server >/dev/null
        elif command -v dnf >/dev/null; then dnf -y -q install openssh-server >/dev/null 2>&1
        else apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null 2>&1; fi
        ssh-keygen -A >/dev/null && mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh
        pgrep -x sshd >/dev/null || /usr/sbin/sshd'
    docker exec "$src" sh -c '
        command -v ssh-keygen >/dev/null || { if command -v apk >/dev/null; then apk add -q --no-cache openssh-client >/dev/null
            elif command -v dnf >/dev/null; then dnf -y -q install openssh-clients >/dev/null 2>&1
            else apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-client >/dev/null 2>&1; fi; }
        [ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f /root/.ssh/id_ed25519'
    docker exec "$src" cat /root/.ssh/id_ed25519.pub \
        | docker exec -i "$dst" sh -c 'cat >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$dst")
    echo "== psm migrate push root@$ip"
    docker exec "$src" bash -c "cd /opt/psm && bash manager.sh migrate push root@$ip" || rc=$?
else
    echo "== psm migrate export --encrypt / import"
    docker exec "$src" bash -c 'cd /opt/psm && PSM_MIGRATE_PASS=mig-test-pass bash manager.sh migrate export --encrypt --output /root/psm-bundle.tgz' >/dev/null
    docker cp "$src:/root/psm-bundle.tgz" "$tmp/b.tgz"
    it_copy_tree "$dst"   # PSM itself, as the one-line installer leaves it
    docker cp "$tmp/b.tgz" "$dst:/root/psm-bundle.tgz"
    # a wrong passphrase is refused before anything is touched
    if docker exec "$dst" bash -c 'cd /opt/psm && PSM_MIGRATE_PASS=wrong bash manager.sh migrate import /root/psm-bundle.tgz --yes' >/dev/null 2>&1; then
        echo "  FAIL import accepted a wrong passphrase"; rc=99
    fi
    if (( rc == 0 )); then
        docker exec "$dst" bash -c 'cd /opt/psm && PSM_MIGRATE_PASS=mig-test-pass bash manager.sh migrate import /root/psm-bundle.tgz --yes' || rc=$?
    fi
fi

docker exec "$src" tar -C /root -cf - mig-expect | docker exec -i "$dst" tar -C /root -xf -
docker exec -e MIG_RC="$rc" -e MIG_MODE="$mode" "$dst" bash /opt/psm/tests/integration/migrate-dst.sh
