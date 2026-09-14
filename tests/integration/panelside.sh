#!/usr/bin/env bash
# The commands the PSM panel's psm-agent runs, without questions, on a server
# that has only PSM: psm core (a core on demand), psm standalone (Snell v4/v5/v6,
# ss-rust), psm traffic (metering and limits), psm node export --format singbox
# and psm version — and PSM's own unattended install. The menus' installs are
# covered by the full suites.

set -uo pipefail
cd /opt/psm || exit 1

pass=0; fail=0; failed=()
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); failed+=("$1"); }
chk() {
    local n="$1"; shift
    if "$@" >/tmp/chk.out 2>&1; then ok "$n"; else bad "$n"; tail -15 /tmp/chk.out | sed 's/^/       /'; fi
}
sec() { echo; echo "=== $1"; }
listening() { local hex; hex=$(printf '%04X' "$1"); awk -v p=":${hex}\$" '$4 == "0A" && toupper($2) ~ p { f = 1 } END { exit !f }' /proc/net/tcp /proc/net/tcp6 2>/dev/null; }
# some bytes to a TCP port (the server may drop the connection: they are counted anyway)
poke() { timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1; head -c 200000 /dev/zero >&3" 2>/dev/null || true; }
export -f listening poke   # the checks run them inside bash -c
musl=0; [[ -f /etc/alpine-release ]] && musl=1

sec "PSM, installed without questions (bootstrap.sh --panel does this)"
chk "PSM_UNATTENDED=1 install.sh returns, no menu" bash -c 'PSM_UNATTENDED=1 PSM_LANG=en timeout 900 bash install.sh </dev/null'
chk "the psm command exists" test -x /usr/local/bin/psm
chk "psm version answers" bash -c 'psm version | grep -Eq "^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9a-f]+|unknown)$"'
chk "psm help lists the new commands" bash -c 'psm help | grep -q "psm standalone" && psm help | grep -q "psm traffic" && psm help | grep -q "psm agent"'

sec "psm core: a core on demand"
chk "no core yet" bash -c 'psm core list --json | jq -e "all(.[]; .installed == false)"'
chk "psm core install sing-box, no questions" bash -c 'timeout 600 psm core install sing-box --json </dev/null | tee /dev/stderr | jq -e ".core == \"sing-box\" and .installed == true and .already == false"'
chk "… sing-box runs" /usr/local/bin/sing-box version
chk "--if-missing leaves it alone" bash -c 'psm core install sing-box --if-missing --json | jq -e ".already == true"'
chk "an unknown core → 2" bash -c 'psm core install v2ray; [[ $? == 2 ]]'
chk "a node on it" bash -c 'psm node add sing-box ss2022 --tag t-ss --port 30001 --json >/dev/null'
chk "psm node export --format singbox" bash -c \
    'psm node export sing-box ss2022 t-ss --server 203.0.113.5 --format singbox | jq -e ".type == \"shadowsocks\" and .server == \"203.0.113.5\" and .server_port == 30001"'
chk "a node sing-box has no outbound for says so (2)" bash -c \
    'psm node add sing-box snell --tag t-sn --port 30002 --set version=5 --json >/dev/null && { psm node export sing-box snell t-sn --server 203.0.113.5 --format singbox; [[ $? == 2 ]]; }'

sec "psm traffic"
chk "set: meter t-ss without a limit" bash -c 'psm traffic set t-ss --limit-bytes 0 --json | jq -e ".tag == \"t-ss\" and .limit_bytes == 0 and .source == \"iptables\""'
poke 30001
chk "list counts its bytes" bash -c 'psm traffic list --json | jq -e ".[] | select(.tag == \"t-ss\") | .used_bytes > 1000"'
chk "the periodic check is installed" bash -c 'systemctl is-active --quiet psm-traffic.timer 2>/dev/null || test -f /etc/cron.d/psm-traffic'
chk "a limit below that, and the check pauses it" bash -c 'psm traffic set t-ss --limit-bytes 1000 --json >/dev/null && bash /opt/psm/manager.sh --traffic-check >/dev/null 2>&1; psm traffic list --json | jq -e ".[] | select(.tag == \"t-ss\") | .paused == true"'
chk "… and it refuses connections" bash -c '! timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/30001"'
chk "reset: counter at 0, running again" bash -c 'psm traffic reset t-ss --json | jq -e ".paused == false and .used_bytes == 0"'
chk "… it takes connections" timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/30001'
chk "a raised limit also lifts a pause" bash -c 'psm traffic set t-ss --limit-bytes 1000 >/dev/null; poke(){ :; }; timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/30001; head -c 200000 /dev/zero >&3" 2>/dev/null; bash /opt/psm/manager.sh --traffic-check >/dev/null 2>&1; psm traffic set t-ss --limit-gb 1 --json | jq -e ".paused == false and .limit_bytes == 1073741824"'
chk "unset: no longer metered" bash -c 'psm traffic unset t-ss --json >/dev/null && ! psm traffic list --json | jq -e ".[] | select(.tag == \"t-ss\")"'
chk "deleting a node drops its metering" bash -c 'psm traffic set t-sn --json >/dev/null && psm node delete sing-box snell t-sn --yes >/dev/null && ! psm traffic list --json | jq -e ".[] | select(.tag == \"t-sn\")"'
chk "an unknown tag → error" bash -c '! psm traffic set nope 2>&1 | grep -q .; psm traffic set nope 2>&1 | grep -q "no node"'
chk "a bad reset day → 2" bash -c 'psm traffic set t-ss --reset-day 40; [[ $? == 2 ]]'

sec "psm standalone: ss-rust"
chk "install ss2022 (aes-256, key generated)" bash -c 'timeout 600 psm standalone install ss2022 --port 30200 --method 2022-blake3-aes-256-gcm --json | tee /dev/stderr | jq -e ".active == true and .port == 30200"'
chk "… listens" listening 30200
chk "… its key is 32 bytes" bash -c '[[ $(psm standalone show ss2022 --json | jq -r .password | base64 -d | wc -c) == 32 ]]'
chk "export uri" bash -c 'psm standalone export ss2022 --server 203.0.113.5 --name hk-ss | grep -Eq "^ss://[A-Za-z0-9_-]+@203\.0\.113\.5:30200#hk-ss$"'
chk "export surge" bash -c 'psm standalone export ss2022 --server 203.0.113.5 --name hk-ss --format surge | grep -q "^hk-ss = ss, 203.0.113.5, 30200, encrypt-method=2022-blake3-aes-256-gcm, password="'
chk "export singbox" bash -c 'psm standalone export ss2022 --server 203.0.113.5 --format singbox | jq -e ".type == \"shadowsocks\" and .server_port == 30200"'
# a real connection: sing-box as the client, through ss-rust, to the internet.
# The config has that one outbound and routes everything to it: without it
# (a failed export) there is no config and no connection — never "direct".
ob=$(psm standalone export ss2022 --server 127.0.0.1 --format singbox 2>/dev/null || true)
jq -n --argjson ob "${ob:-null}" '{log: {level: "error"},
    inbounds: [{type: "mixed", listen: "127.0.0.1", listen_port: 30990}],
    outbounds: [$ob], route: {final: $ob.tag}}' > /tmp/sb-client.json 2>/dev/null || rm -f /tmp/sb-client.json
chk "the client config routes through the ss-rust outbound" bash -c 'jq -e ".outbounds[0].type == \"shadowsocks\" and .route.final == .outbounds[0].tag" /tmp/sb-client.json'
/usr/local/bin/sing-box run -c /tmp/sb-client.json >/tmp/sb-client.log 2>&1 & sbc=$!
sleep 2
chk "a client gets through it (HTTP 204)" bash -c '[[ $(curl -s -o /dev/null -w "%{http_code}" --max-time 20 -x socks5h://127.0.0.1:30990 https://www.gstatic.com/generate_204) == 204 ]]'
chk "metered as ss2022" bash -c 'psm traffic set ss2022 --json >/dev/null && curl -s -o /dev/null --max-time 20 -x socks5h://127.0.0.1:30990 https://www.gstatic.com/generate_204; psm traffic list --json | jq -e ".[] | select(.tag == \"ss2022\") | .used_bytes > 0"'
kill "$sbc" 2>/dev/null
chk "install again on a new port replaces it" bash -c 'psm standalone install ss2022 --port 30201 --json >/dev/null && listening 30201 && ! listening 30200'
chk "a wrong-length key → 2" bash -c 'psm standalone install ss2022 --port 30202 --password "$(openssl rand -base64 8)"; [[ $? == 2 ]]'
chk "a port in use → error" bash -c '! psm standalone install ss2022 --port 30001 2>&1 | tee /dev/stderr | grep -q "in use" && false || true; psm standalone install ss2022 --port 30001 2>&1 | grep -q "in use"'
chk "remove" bash -c 'psm standalone remove ss2022 --yes --json | jq -e ".status == \"removed\"" && ! listening 30201 && ! test -e /usr/local/bin/ss-rust'
chk "… and its metering" bash -c '! psm traffic list --json | jq -e ".[] | select(.tag == \"ss2022\")"'

sec "psm standalone: Snell"
if (( musl )); then
    chk "Snell is refused on musl, with the reason" bash -c 'psm standalone install snell --port 30100 2>&1 | grep -q musl'
else
    for v in 4 5 6; do
        port=$((30100 + v))
        chk "Snell v$v installs" bash -c "timeout 600 psm standalone install snell --port $port --version $v --psk testpsk${v}abcdef --json | tee /dev/stderr | jq -e '.active == true and .port == $port and .version == \"$v\"'"
        chk "… listens on $port" listening "$port"
        chk "… the build is v$v" grep -q "^v$v\." /etc/snell/psm-build
        chk "… Surge line with version=$v" bash -c "psm standalone export snell --server 203.0.113.5 --name hk-snell | grep -qx 'hk-snell = snell, 203.0.113.5, $port, psk=testpsk${v}abcdef, version=$v'"
    done
    chk "the menus' config file is the one written" grep -q '^listen = .*:30106$' /etc/snell/users/snell-main.conf
    chk "no URI for Snell (2)" bash -c 'psm standalone export snell --server 203.0.113.5 --format uri; [[ $? == 2 ]]'
    chk "remove" bash -c 'psm standalone remove snell --yes --json | jq -e ".status == \"removed\"" && ! listening 30106 && ! test -e /usr/local/bin/snell-server'
fi
chk "a bad Snell version → 2" bash -c 'psm standalone install snell --port 30110 --version 3; [[ $? == 2 ]]'

echo
echo "=== RESULT: $pass ok, $fail failed"
(( fail == 0 )) || { printf '  - %s\n' "${failed[@]}"; exit 1; }
