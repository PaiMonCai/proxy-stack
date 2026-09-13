#!/bin/bash
# Source side of tests/integration/migrate.sh: a PSM server worth moving (three
# cores, TLS / REALITY / QUIC nodes, a node behind Nginx on the shared 443, a
# certificate from a test CA, port hopping, scheduled jobs). Leaves what the
# destination must reproduce in /root/mig-expect.
cd /opt/psm || exit 1
export TERM=dumb
PASS=0; FAIL=0; FAILS=(); ADDED=()
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); FAILS+=("$*"); echo "  FAIL $*"; }
sec() { echo; echo "=== $*"; }
chk() { local d="$1"; shift; if "$@" >/tmp/chk.out 2>&1; then ok "$d"; else bad "$d"; tail -5 /tmp/chk.out | sed 's/^/       /'; fi; }
psm() { bash manager.sh "$@"; }
add() {
    local core="$1" proto="$2" tag="$3"; shift 3
    local out; out=$(psm node add "$core" "$proto" --tag "$tag" "$@" --json 2>&1)
    if grep -qE '"status": ?"created"' <<<"$out"; then
        ok "add $core/$proto $tag"; ADDED+=("$tag")
    else
        bad "add $core/$proto $tag"; echo "$out" | grep -vE '^\s*$' | tail -4 | sed 's/^/       /'
    fi
}

sec "install + cores"
chk "install.sh"   bash -c "printf '1\n0\n0\n0\n0\n' | timeout 900 bash install.sh"
chk "xray_install" bash -c "source lib/xray/core.sh; xray_install <<< \$'n\n0\n0\n0\n0\n'"
chk "sb_install"   bash -c "source lib/singbox/core.sh; sb_install <<< \$'1\nn\n0\n0\n'"
chk "mh_install"   bash -c "source lib/mihomo/core.sh; mh_install <<< \$'n\n0\n0\n0\n'"

sec "test CA and certificates"
CA=/root/mig-ca
mkdir -p "$CA" /etc/psm/certs /etc/nginx/ssl/x.example.com
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 7 \
    -subj "/CN=PSM migrate CA" -keyout "$CA/ca.key" -out "$CA/ca.crt" >/dev/null 2>&1
issue() {   # issue <dns-name> <key-out> <cert-out>
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=$1" \
        -keyout "$2" -out "$CA/$1.csr" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\n' "$1" > "$CA/$1.ext"
    openssl x509 -req -in "$CA/$1.csr" -CA "$CA/ca.crt" -CAkey "$CA/ca.key" -CAcreateserial \
        -days 7 -extfile "$CA/$1.ext" -out "$3" >/dev/null 2>&1
}
issue x.example.com /etc/nginx/ssl/x.example.com/privkey.pem /etc/nginx/ssl/x.example.com/fullchain.pem
issue t.example.com /etc/psm/certs/t.key /etc/psm/certs/t.crt
C=(--sni t.example.com --cert-path /etc/psm/certs/t.crt --key-path /etc/psm/certs/t.key --insecure 0)
RD=(--server-name learn.microsoft.com --dest learn.microsoft.com:443)

sec "nodes"
add xray reality       m-xr   --port 31001 "${RD[@]}"
add xray vision        m-xv   --port 31002 --domain x.example.com
add sing-box reality   m-sr   --port 32001 "${RD[@]}"
add sing-box hysteria2 m-shy  --port 32003 "${C[@]}" --obfs-pass mig-obfs --hop-ports 42000-42100
add sing-box tuic      m-stu  --port 32011 "${C[@]}"
add sing-box vless     m-s443 --port 32050 "${C[@]}" --transport tcp --mount-443
add mihomo reality     m-mr   --port 33001 "${RD[@]}"
add mihomo trojan      m-mt   --port 33005 "${C[@]}"
add mihomo vless       m-mvw  --port 33008 "${C[@]}" --transport ws

sec "online subscription (camouflage site on the shared 443)"
chk "sub_online_enable" bash -c "source lib/common.sh; source lib/subscribe.sh; printf 'x.example.com\n30\n127.0.0.1\n' | sub_online_enable"
TOK=$(jq -r '.token // empty' /opt/psm/config/subscribe/state.json 2>/dev/null)
chk "served through Nginx on 443" bash -c "curl -sk --resolve x.example.com:443:127.0.0.1 https://x.example.com/psm-sub/$TOK/sub.txt | openssl base64 -d -A | grep -q '://'"

sec "scheduled jobs"
chk "traffic job"  bash -c "source lib/traffic.sh; _trf_install_timer >/dev/null 2>&1; _trf_timer_active"
chk "rule-set job" bash -c "source lib/ruleset/apply.sh; rs_timer_enable >/dev/null 2>&1; rs_timer_active"

sec "expectations for the destination"
E=/root/mig-expect; rm -rf "$E"; mkdir -p "$E"
cp "$CA/ca.crt" "$E/ca.crt"
printf '%s\n' "$TOK" > "$E/sub_token"
printf '%s\n' "${ADDED[@]}" > "$E/tags.txt"
( cd / && sha256sum usr/local/etc/xray/config.json etc/sing-box/config.json etc/mihomo/config.yaml ) > "$E/cfg.sha"
bash -c 'source lib/common.sh; source lib/subscribe.sh; _sub_collect_uris 10.9.9.9' > "$E/uris.txt" 2>/dev/null
chk "expectations written" bash -c "test -s $E/cfg.sha && test \$(grep -c . $E/uris.txt) -ge ${#ADDED[@]}"

echo; echo "=== RESULT: $PASS ok, $FAIL failed"
for f in "${FAILS[@]}"; do echo "  - $f"; done
exit $(( FAIL > 0 ))
