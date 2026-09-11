#!/bin/bash
# Standalone Snell on Alpine through Docker (fresh container, no Docker yet).
cd /opt/psm || exit 1
export TERM=dumb
PASS=0; FAIL=0; FAILS=()
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); FAILS+=("$*"); echo "  FAIL $*"; }
sec() { echo; echo "=== $*"; }
chk() { local d="$1"; shift; if "$@" >/tmp/chk.out 2>&1; then ok "$d"; else bad "$d"; tail -6 /tmp/chk.out | sed 's/^/       /'; fi; }
L() { bash -c "source lib/snell.sh; $*"; }
CONF=/etc/snell/users/snell-main.conf
port() { awk -F: '/^listen/ { gsub(/[^0-9]/,"",$NF); print $NF; exit }' $CONF; }
psk()  { sed -n 's/^psk = //p' $CONF; }
up()   { local i; for i in $(seq 1 20); do ss -Hltn "sport = :$(port)" | grep -q . && return 0; sleep 1; done; return 1; }

sec "install.sh"
chk "install.sh" bash -c "printf '1\n0\n0\n0\n0\n' | timeout 900 bash install.sh"
command -v docker >/dev/null && bad "docker preinstalled (test is not fresh)" || ok "no docker before"

sec "snell_install on Alpine (answers Y to installing Docker)"
out=$(L "snell_install" <<<$'y\n' 2>&1); rc=$?
[[ $rc == 0 ]] && ok "snell_install exit 0" || { bad "snell_install exit $rc"; echo "$out" | tail -12 | sed 's/^/       /'; }
grep -q 'jinqians/snell-server' <<<"$out" && ok "explains the Docker route" || bad "no explanation shown"
chk "docker installed and running" bash -c "command -v docker && rc-service docker status"
chk "OpenRC service runs the image" grep -q 'jinqians/snell-server:v5' /etc/init.d/snell
chk "service needs docker (boot order)" grep -q 'need docker' /etc/init.d/snell
chk "port $(port) listening tcp" up
chk "port $(port) listening udp" bash -c "ss -Hlun 'sport = :$(port)' | grep -q ."
chk "svc_is_active snell" bash -c "source lib/common.sh; svc_is_active snell"
chk "container running" bash -c "docker ps --format '{{.Names}}' | grep -qx psm-snell"
grep -q "version = 5" <<<"$out" && ok "Surge line printed (version = 5)" || bad "no Surge line"
chk "image kept PSM's config (same PSK in log)" grep -q "$(psk)" /var/log/psm/snell.log
chk "main-menu status sees Docker mode" bash -c "[[ -f /etc/init.d/snell ]] && grep -q 'jinqians/snell-server' /etc/init.d/snell"

sec "lifecycle"
P0=$(port); K0=$(psk)
chk "restart" bash -c "source lib/common.sh; svc_restart snell"
chk "listening after restart" up
docker kill psm-snell >/dev/null 2>&1; sleep 8
chk "respawned after the container was killed" bash -c "source lib/common.sh; svc_is_active snell && docker ps --format '{{.Names}}' | grep -qx psm-snell"
chk "listening after respawn" up
rc-service docker restart >/dev/null 2>&1; sleep 5
chk "back after docker daemon restart" bash -c "source lib/common.sh; for i in \$(seq 1 20); do svc_is_active snell && docker ps --format '{{.Names}}' | grep -qx psm-snell && exit 0; sleep 1; done; exit 1"
chk "listening after docker restart" up
chk "snell_update (pull + restart)" L "snell_update </dev/null"
[[ $(port) == "$P0" && $(psk) == "$K0" ]] && ok "update kept port and PSK" || bad "update changed port/PSK"
chk "listening after update" up
out=$(L "snell_diagnose" 2>&1); grep -q 'psm-snell' <<<"$out" && ok "diagnose shows the container" || bad "diagnose"
out=$(L "snell_show_config" 2>&1); grep -q "version = 5" <<<"$out" && ok "show_config: version 5" || bad "show_config"

sec "uninstall + reinstall"
chk "snell_uninstall" L "snell_uninstall <<<\$'y\n'"
[[ -e /etc/init.d/snell ]] && bad "init script left" || ok "init script removed"
docker ps -a --format '{{.Names}}' | grep -qx psm-snell && bad "container left" || ok "container removed"
docker image inspect jinqians/snell-server:v5 >/dev/null 2>&1 && bad "image left" || ok "image removed"
[[ -e /etc/snell ]] && bad "/etc/snell left" || ok "/etc/snell removed"
chk "reinstall (Docker already there, no prompt)" L "snell_install </dev/null"
chk "listening after reinstall" up

sec "full uninstall.sh"
chk "uninstall.sh" bash -c "yes y | timeout 600 bash uninstall.sh"
docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx psm-snell && bad "container left by uninstall.sh" || ok "uninstall.sh removed the container"
[[ -e /etc/init.d/snell ]] && bad "init script left by uninstall.sh" || ok "uninstall.sh removed the service"

echo; echo "=== RESULT: $PASS ok, $FAIL failed"
for f in "${FAILS[@]}"; do echo "  - $f"; done

exit $(( FAIL > 0 ))
