#!/bin/bash
# Full feature run on Alpine 3.22 / OpenRC (inside psm-alp on the VPS).
cd /opt/psm || exit 1
export TERM=dumb
PASS=0; FAIL=0; FAILS=()
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); FAILS+=("$*"); echo "  FAIL $*"; }
sec() { echo; echo "=== $*"; }
chk() { local d="$1"; shift; if "$@" >/tmp/chk.out 2>&1; then ok "$d"; else bad "$d"; tail -4 /tmp/chk.out | sed 's/^/       /'; fi; }
psm() { bash manager.sh "$@"; }
add() {
    local core="$1" proto="$2" tag="$3"; shift 3
    local out; out=$(psm node add "$core" "$proto" --tag "$tag" "$@" --json 2>&1)
    if grep -qE '"status": ?"created"' <<<"$out"; then ok "add $core/$proto $tag"
    else bad "add $core/$proto $tag"; echo "$out" | grep -vE '^\s*$' | tail -4 | sed 's/^/       /'; fi
}
alive() {   # OpenRC service really running (supervised child present)
    chk "$1 running (OpenRC)" bash -c "source lib/common.sh; svc_is_active $1"
}
listening() { local p i; for p in "$@"; do for i in $(seq 1 10); do ss -Hltun "sport = :$p" | grep -q . && break; sleep 0.5; done; ss -Hltun "sport = :$p" | grep -q . && ok "port $p listening" || bad "port $p listening"; done; }

sec "static checks"
f=0; while IFS= read -r x; do bash -n "$x" || f=1; done < <(find . -name '*.sh'); [[ $f == 0 ]] && ok "bash -n all" || bad "bash -n all"
chk "i18n key alignment" bash scripts/i18n-check.sh

sec "install.sh (GNU userland, cronie)"
chk "install.sh" bash -c "printf '1\n0\n0\n0\n0\n' | timeout 900 bash install.sh"
chk "GNU date"   date -d "now +1 month" +%F
chk "ss present" command -v ss
chk "tzdata"     test -e /usr/share/zoneinfo/Asia/Shanghai
chk "init=openrc" bash -c "source lib/common.sh; _uses_openrc"

mkdir -p /etc/psm/certs /etc/nginx/ssl/x.example.com
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj /CN=www.bing.com \
    -keyout /etc/psm/certs/t.key -out /etc/psm/certs/t.crt >/dev/null 2>&1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj /CN=x.example.com \
    -keyout /etc/nginx/ssl/x.example.com/privkey.pem -out /etc/nginx/ssl/x.example.com/fullchain.pem >/dev/null 2>&1
C=(--sni www.bing.com --cert-path /etc/psm/certs/t.crt --key-path /etc/psm/certs/t.key --insecure 1)
RD=(--server-name www.bing.com --dest www.bing.com:443)

sec "Xray on OpenRC"
chk "xray_install" bash -c "source lib/xray/core.sh; xray_install <<< \$'n\n0\n0\n0\n0\n'"
add xray reality   a-rea  --port 21001 "${RD[@]}" --vless-enc x25519
add xray xhttp     a-kcp  --port 21002 --mode mkcp --kcp-seed s --kcp-header srtp
add xray xhttp     a-h2   --port 21003 --domain x.example.com --mode h2
add xray hysteria2 a-hy2  --port 21004 "${C[@]}" --obfs-pass pw12 --obfs-type gecko
alive xray; listening 21001 21002 21003 21004
chk "xray rc_ulimit" bash -c "grep -q 1048576 /proc/\$(pgrep -x xray | head -1)/limits"
chk "xray log file"  test -s /var/log/psm/xray.log

sec "sing-box on OpenRC (musl build)"
chk "sb_install" bash -c "source lib/singbox/core.sh; sb_install <<< \$'1\nn\n0\n0\n'"
chk "sing-box is a static/musl build" bash -c "! grep -q ld-linux-x86-64 /usr/local/bin/sing-box"
add sing-box hysteria2 a-shy  --port 22001 "${C[@]}" --obfs-pass pw12 --obfs-type gecko
add sing-box snell     a-ssn  --port 22002 --version 5
add sing-box vless     a-svl  --port 22003 "${C[@]}" --transport ws
alive sing-box; listening 22001 22002 22003

sec "mihomo on OpenRC"
chk "mh_install" bash -c "source lib/mihomo/core.sh; mh_install <<< \$'n\n0\n0\n0\n'"
add mihomo ss2022 a-mss  --port 23001 --shadow-tls-sni www.microsoft.com
add mihomo vless  a-mvl  --port 23002 "${C[@]}" --vless-enc x25519
add mihomo snell  a-msn  --port 23003 --version 4
alive mihomo; listening 23001 23002 23003
chk "mihomo SAFE_PATHS env file" grep -q /etc/psm/certs /etc/mihomo/psm.env
chk "openrc script loads psm.env" grep -q "/etc/mihomo/psm.env" /etc/init.d/mihomo
svc_ok=$(bash -c "source lib/common.sh; svc_is_active mihomo && echo y"); [[ $svc_ok == y ]] || { cp /etc/mihomo/config.yaml /root/mh-diag.yaml; cp /usr/local/bin/mihomo /root/mh-diag-bin; }

sec "standalone ss-rust / Snell / realm"
chk "ss-rust native install" bash -c "source lib/ssrust.sh; ssrust_install </dev/null"
alive ss-rust
chk "standalone Snell via Docker" bash -c "source lib/snell.sh; snell_install <<<\$'y\n' >/dev/null 2>&1; grep -q jinqians/snell-server /etc/init.d/snell && source lib/common.sh && svc_is_active snell"
chk "realm install" bash -c "source lib/realm.sh; realm_install <<< \$'n\n'; test -x /etc/init.d/realm"

sec "periodic jobs via cronie"
chk "traffic job"  bash -c "source lib/traffic.sh; _trf_install_timer >/dev/null 2>&1; test -f /etc/cron.d/psm-traffic && test -x /etc/local.d/psm-traffic.stop"
chk "cronie running, busybox crond off" bash -c "rc-service cronie status >/dev/null && ! rc-service crond status >/dev/null 2>&1"
chk "ruleset job"  bash -c "source lib/ruleset/apply.sh; rs_timer_enable >/dev/null 2>&1; test -f /etc/cron.d/psm-ruleset-update"
echo '* * * * * root date >> /tmp/cron-fired' > /etc/cron.d/psm-selftest; CRON_AT=$(date +%s)

sec "crash-loop detection"
cat > /etc/init.d/psmflap <<'EOF'
#!/sbin/openrc-run
command="/bin/sh"
command_args="-c 'sleep 1; exit 1'"
pidfile="/run/psmflap.pid"
supervisor="supervise-daemon"
supervise_daemon_args="--respawn-delay 5"
EOF
chmod 755 /etc/init.d/psmflap; rc-service psmflap start >/dev/null 2>&1; sleep 4
chk "crash loop reported inactive" bash -c "source lib/common.sh; ! svc_is_active psmflap"
rc-service psmflap stop >/dev/null 2>&1; rm -f /etc/init.d/psmflap

sec "doctor / test suite"
chk "doctor --json" bash -c "bash manager.sh doctor --json | jq -e '.checks | length > 0'"
bash manager.sh doctor --json 2>/dev/null | jq -r '.checks[] | select(.category=="core") | "       \(.id) \(.status)"'
chk "tests/run.sh" bash tests/run.sh

sec "cron actually fired"
w=$(( 75 - ( $(date +%s) - CRON_AT ) )); (( w > 0 )) && sleep $w
chk "/etc/cron.d job executed" test -s /tmp/cron-fired; rm -f /etc/cron.d/psm-selftest

sec "full uninstall"
chk "uninstall.sh" bash -c "yes y | timeout 600 bash uninstall.sh"
for s in xray sing-box mihomo ss-rust realm snell; do [[ -e /etc/init.d/$s ]] && bad "/etc/init.d/$s left" || ok "/etc/init.d/$s removed"; done
pgrep -x xray >/dev/null || pgrep -x sing-box >/dev/null || pgrep -x mihomo >/dev/null && bad "core process left" || ok "no core processes"
compgen -G '/etc/cron.d/*psm*' >/dev/null && bad "cron drop-ins left" || ok "no PSM cron drop-ins"
[[ -e /opt/psm ]] && bad "/opt/psm left behind" || ok "/opt/psm removed"

echo; echo "=== RESULT: $PASS ok, $FAIL failed"
for f in "${FAILS[@]}"; do echo "  - $f"; done

exit $(( FAIL > 0 ))
