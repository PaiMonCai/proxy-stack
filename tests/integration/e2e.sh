#!/bin/bash
# Real client traffic through every protocol, using the exact share links PSM
# exports (the base64 URI subscription users import) with mihomo as the client.
# A node counts only when a client that imported its link reaches the internet
# through it. Certificates come from a throwaway CA that the client trusts, so
# TLS is verified for real rather than skipped.
# Run via tests/integration/container.sh debian|alpine e2e.
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
    if jq -e '.status == "created"' <<<"$(echo "$out" | sed -n '/^{/,$p')" >/dev/null 2>&1; then
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
CA=/root/e2e-ca
mkdir -p "$CA" /etc/psm/certs /etc/nginx/ssl/x.example.com
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 7 \
    -subj "/CN=PSM E2E CA" -keyout "$CA/ca.key" -out "$CA/ca.crt" >/dev/null 2>&1
issue() {   # issue <dns-name> <key-out> <cert-out>
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=$1" \
        -keyout "$2" -out "$CA/$1.csr" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\n' "$1" > "$CA/$1.ext"
    openssl x509 -req -in "$CA/$1.csr" -CA "$CA/ca.crt" -CAkey "$CA/ca.key" -CAcreateserial \
        -days 7 -extfile "$CA/$1.ext" -out "$3" >/dev/null 2>&1
}
issue x.example.com /etc/nginx/ssl/x.example.com/privkey.pem /etc/nginx/ssl/x.example.com/fullchain.pem
issue t.example.com /etc/psm/certs/t.key /etc/psm/certs/t.crt
chk "certificates signed by the test CA" bash -c "openssl verify -CAfile $CA/ca.crt /etc/psm/certs/t.crt /etc/nginx/ssl/x.example.com/fullchain.pem"
C=(--sni t.example.com --cert-path /etc/psm/certs/t.crt --key-path /etc/psm/certs/t.key --insecure 0)
# learn.microsoft.com: the one target that passed with all three cores in every run
# (www.bing.com intermittently failed a REALITY handshake from one core or another)
RD=(--server-name learn.microsoft.com --dest learn.microsoft.com:443)
AUTH=(--listen-addr 0.0.0.0 --username e2e --password e2e-pass-1)

sec "nodes"
add xray reality     e-xr   --port 31001 "${RD[@]}"
add xray vision      e-xv   --port 31002 --domain x.example.com
add xray xhttp       e-xh   --port 31003 --domain x.example.com --mode xhttp
add xray xhttp       e-xws  --port 31004 --domain x.example.com --mode ws
add xray xhttp       e-xg   --port 31005 --domain x.example.com --mode grpc
add xray xhttp       e-xhu  --port 31006 --domain x.example.com --mode httpupgrade
add xray trojan      e-xt   --port 31007 --domain x.example.com
add xray vmess       e-xvm  --port 31008 --domain x.example.com
add xray ss2022      e-xss  --port 31009
add xray socks       e-xs5  --port 31010 "${AUTH[@]}"
add xray hysteria2   e-xhy  --port 31011 "${C[@]}" --obfs-pass e2e-obfs
add sing-box reality   e-sr   --port 32001 "${RD[@]}"
add sing-box ss2022    e-sss  --port 32002
add sing-box hysteria2 e-shy  --port 32003 "${C[@]}" --obfs-pass e2e-obfs
add sing-box anytls    e-sat  --port 32004 "${C[@]}"
add sing-box trojan    e-st   --port 32005 "${C[@]}"
add sing-box vmess     e-svm  --port 32006 "${C[@]}"
add sing-box vless     e-svt  --port 32007 "${C[@]}" --transport tcp
add sing-box vless     e-svw  --port 32008 "${C[@]}" --transport ws
add sing-box vless     e-svg  --port 32009 "${C[@]}" --transport grpc
add sing-box socks     e-ss5  --port 32010 "${AUTH[@]}"
add sing-box tuic      e-stu  --port 32011 "${C[@]}"
add mihomo reality     e-mr   --port 33001 "${RD[@]}"
add mihomo ss2022      e-mss  --port 33002
add mihomo hysteria2   e-mhy  --port 33003 "${C[@]}" --obfs-pass e2e-obfs
add mihomo anytls      e-mat  --port 33004 "${C[@]}"
add mihomo trojan      e-mt   --port 33005 "${C[@]}"
add mihomo vmess       e-mvm  --port 33006 "${C[@]}"
add mihomo vless       e-mvt  --port 33007 "${C[@]}" --transport tcp
add mihomo vless       e-mvw  --port 33008 "${C[@]}" --transport ws
add mihomo vless       e-mvg  --port 33009 "${C[@]}" --transport grpc
add mihomo socks       e-ms5  --port 33010 "${AUTH[@]}"
add mihomo tuic        e-mtu  --port 33011 "${C[@]}" --congestion-control cubic

sec "share links -> mihomo client -> internet"
M=/root/e2e-client; rm -rf "$M"; mkdir -p "$M"
# The subscription users import, with the server address pointed at this box.
bash -c 'source lib/common.sh; source lib/subscribe.sh; _sub_build_uri_sub 127.0.0.1' > "$M/sub.txt" 2>/dev/null
n=$(openssl base64 -d -A < "$M/sub.txt" 2>/dev/null | grep -c '://')
(( n >= ${#ADDED[@]} )) && ok "subscription holds $n links" || bad "subscription holds $n links for ${#ADDED[@]} nodes"
cat /etc/ssl/certs/ca-certificates.crt "$CA/ca.crt" > "$M/ca-bundle.pem"
# The client config is PSM's own mihomo export, as users import it. Only two
# test-only changes: the provider reads the subscription from a local file (its
# URL would serve exactly that), and the GEOIP rule goes (it needs a database
# download); ports move off 7890 and the controller API is switched on.
bash -c 'source lib/common.sh; source lib/subscribe.sh; _sub_build_mihomo_client 127.0.0.1' > "$M/export.yaml" 2>/dev/null
chk "PSM's mihomo client export" grep -q 'proxy-providers:' "$M/export.yaml"
{
    printf 'external-controller: 127.0.0.1:19090\nbind-address: 127.0.0.1\n'
    sed -e 's|^mixed-port: .*|mixed-port: 17890|' -e 's|^    type: http$|    type: file|' \
        -e '/^    url: "__SUB_URL__"$/d' -e '/^    interval: 3600$/d' -e '/GEOIP,PRIVATE/d' "$M/export.yaml"
} > "$M/config.yaml"
cp "$M/sub.txt" "$M/psm-provider.yaml"
SSL_CERT_FILE="$M/ca-bundle.pem" /usr/local/bin/mihomo -d "$M" -f "$M/config.yaml" > "$M/client.log" 2>&1 &
CPID=$!
trap 'kill $CPID 2>/dev/null' EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null 127.0.0.1:19090/version && break; sleep 0.5; done
# The provider loads after the API is up: wait until the group is populated.
for _ in $(seq 1 60); do
    names=$(curl -s 127.0.0.1:19090/proxies/PSM | jq -r '.all[]' 2>/dev/null)
    (( $(grep -c . <<<"$names") >= ${#ADDED[@]} )) && break
    sleep 0.5
done
[[ -n "$names" ]] && ok "mihomo loaded $(wc -l <<<"$names") nodes from the export" || { bad "mihomo loaded nothing"; tail -5 "$M/client.log" | sed 's/^/       /'; }
for tag in "${ADDED[@]}"; do
    name="PSM-$tag"
    if ! grep -qxF "$name" <<<"$names"; then bad "$tag: the client could not import its share link"; continue; fi
    curl -s -o /dev/null -X PUT 127.0.0.1:19090/proxies/PSM -d "{\"name\":\"$name\"}"
    for _ in 1 2; do   # one retry: a single slow request must not fail a node
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x socks5h://127.0.0.1:17890 https://www.gstatic.com/generate_204)
        [[ "$code" == 204 ]] && break
    done
    [[ "$code" == 204 ]] && ok "$tag: link -> server -> internet (HTTP 204)" || bad "$tag: HTTP $code through its link"
done
kill $CPID 2>/dev/null

sec "ECH: PSM's sing-box client export and mihomo ech-opts"
add sing-box vless e-sve --port 32040 "${C[@]}" --transport tcp --ech true
ech=$(psm node export sing-box vless e-sve --format ech 2>/dev/null)
[[ -n "$ech" ]] && ok "export --format ech gives the ECH config" || bad "no ECH config exported"
chk "live sing-box inbound has tls.ech" bash -c "jq -e '.inbounds[] | select(.tag == \"e-sve\") | .tls.ech.enabled' /etc/sing-box/config.json"
E=/root/ech-sb; mkdir -p $E
bash -c 'source lib/common.sh; source lib/subscribe.sh; _sub_build_singbox_client 127.0.0.1' > $E/export.json 2>/dev/null
jq '.inbounds[0].listen_port = 17896 | (.outbounds[] | select(.type == "selector")).default = "PSM-e-sve"' $E/export.json > $E/client.json
chk "the sing-box client export carries tls.ech for e-sve" jq -e '.outbounds[] | select(.tag == "PSM-e-sve") | .tls.ech.config | length > 0' $E/client.json
SSL_CERT_FILE="$M/ca-bundle.pem" /usr/local/bin/sing-box run -c $E/client.json > $E/log 2>&1 & EP=$!; sleep 3
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x socks5h://127.0.0.1:17896 https://www.gstatic.com/generate_204); kill $EP 2>/dev/null
[[ "$code" == 204 ]] && ok "PSM's sing-box client export over ECH: HTTP 204" || { bad "sing-box client export over ECH: HTTP $code"; tail -3 $E/log | sed 's/^/       /'; }
uuid=$(jq -r '.[] | select(.tag == "e-sve") | .uuid' /opt/psm/config/singbox/vless.json)
mh_ech() {   # mh_ech <dir> <port> <config>: mihomo client with ech-opts
    mkdir -p "$1"
    printf 'mixed-port: %s\nbind-address: 127.0.0.1\nlog-level: warning\nproxies:\n  - {name: P, type: vless, server: 127.0.0.1, port: 32040, uuid: %s, tls: true, servername: t.example.com, network: tcp, flow: xtls-rprx-vision, ech-opts: {enable: true, config: "%s"}}\nrules:\n  - MATCH,P\n' "$2" "$uuid" "$3" > "$1/config.yaml"
    SSL_CERT_FILE="$M/ca-bundle.pem" /usr/local/bin/mihomo -d "$1" -f "$1/config.yaml" > "$1/log" 2>&1 & MP=$!; sleep 3
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -x "socks5h://127.0.0.1:$2" https://www.gstatic.com/generate_204); kill $MP 2>/dev/null
}
mh_ech /root/ech-m1 17897 "$ech"
[[ "$code" == 204 ]] && ok "mihomo with the exported ECH config: HTTP 204" || bad "mihomo with ECH: HTTP $code"
other=$(bash -c 'source lib/common.sh; psm_ech_keypair t.example.com && printf %s "$ECH_CONFIG_B64"')
mh_ech /root/ech-m2 17898 "$other"
[[ "$code" != 204 ]] && ok "another server's ECH config is rejected (HTTP $code)" || bad "a foreign ECH config was accepted"
chk "update --ech false" psm node update sing-box vless e-sve --ech false
chk "ECH keys removed from the node" bash -c "! jq -e '.[] | select(.tag == \"e-sve\") | .ech_key' /opt/psm/config/singbox/vless.json"

sec "WireGuard (sing-box endpoint) <- mihomo WireGuard clients built from PSM's wg-quick files"
add sing-box wireguard e-swg --port 32030 --peer-count 2
wg=$(psm node export sing-box wireguard e-swg 2>/dev/null)
[[ $(grep -c '^\[Interface\]' <<<"$wg") == 2 ]] && ok "export: one wg-quick file per client (2)" || bad "export did not give 2 wg-quick files"
wgpub=$(awk -F' = ' '/^PublicKey/ {print $2; exit}' <<<"$wg")
i=0
while IFS=$'\t' read -r wpriv waddr; do
    i=$((i + 1)); d=/root/wg$i; mkdir -p $d
    printf 'mixed-port: %s\nbind-address: 127.0.0.1\nlog-level: warning\nproxies:\n  - {name: P, type: wireguard, server: 127.0.0.1, port: 32030, ip: %s, private-key: "%s", public-key: "%s", allowed-ips: ["0.0.0.0/0"], udp: true}\nrules:\n  - MATCH,P\n' \
        $((17880 + i)) "${waddr%/*}" "$wpriv" "$wgpub" > $d/config.yaml
    /usr/local/bin/mihomo -d $d -f $d/config.yaml > $d/log 2>&1 & WPID=$!; sleep 3
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x socks5h://127.0.0.1:$((17880 + i)) https://www.gstatic.com/generate_204)
    kill $WPID 2>/dev/null
    [[ "$code" == 204 ]] && ok "WireGuard client $i (${waddr%/*}): HTTP 204" || bad "WireGuard client $i: HTTP $code"
done < <(awk -F' = ' '/^PrivateKey/ {k=$2} /^Address/ {print k "\t" $2}' <<<"$wg")

sec "Hysteria2 port hopping (client in its own network namespace)"
add sing-box hysteria2 e-shop --port 32020 "${C[@]}" --hop-ports 42000-42100
chk "REDIRECT 42000-42100 -> 32020 (psm-hop:e-shop)" bash -c "iptables -t nat -S PREROUTING | grep 'psm-hop:e-shop' | grep -q 'to-ports 32020'"
chk "boot hook installed" bash -c "test -f /etc/systemd/system/psm-hop.service || test -x /etc/local.d/psm-hop.start"
hl=$(bash -c 'source lib/common.sh; source lib/subscribe.sh; _sub_collect_uris 10.99.0.1' 2>/dev/null | grep -m1 'PSM-e-shop')
[[ "$hl" == *":32020,42000-42100?"* ]] && ok "share link carries the hop range" || bad "share link without the hop range: $hl"
ip netns add cns; ip link add vh type veth peer name vc; ip link set vc netns cns
ip addr add 10.99.0.1/24 dev vh; ip link set vh up
ip netns exec cns ip addr add 10.99.0.2/24 dev vc; ip netns exec cns ip link set vc up; ip netns exec cns ip link set lo up
ip netns exec cns ip route add default via 10.99.0.1
hop_client() {   # hop_client <dir> <port> <link>: mihomo in the namespace, fed one link
    mkdir -p "$1"; printf '%s\n' "$3" | openssl base64 -A > "$1/sub.txt"
    printf 'mixed-port: %s\nbind-address: 127.0.0.1\nlog-level: warning\nproxy-providers:\n  p: {type: file, path: ./sub.txt}\nproxy-groups:\n  - {name: P, type: select, use: [p]}\nrules:\n  - MATCH,P\n' "$2" > "$1/config.yaml"
    SSL_CERT_FILE="$M/ca-bundle.pem" ip netns exec cns /usr/local/bin/mihomo -d "$1" -f "$1/config.yaml" > "$1/log" 2>&1 &
    HPID=$!; sleep 3
    code=$(ip netns exec cns curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x "socks5h://127.0.0.1:$2" https://www.gstatic.com/generate_204)
    kill $HPID 2>/dev/null
}
hop_client /root/hop1 17891 "$hl"
[[ "$code" == 204 ]] && ok "PSM's hop link from another host: HTTP 204" || bad "hop link: HTTP $code"
hop_client /root/hop2 17892 "${hl/:32020,42000-42100?/:42000-42100?}"
[[ "$code" == 204 ]] && ok "hop ports only (never the node port): HTTP 204, the redirect carries it" || bad "hop ports only: HTTP $code"
chk "delete e-shop" bash manager.sh node delete sing-box hysteria2 e-shop --yes
chk "its REDIRECT rule is gone" bash -c "! iptables -t nat -S PREROUTING | grep -q 'psm-hop:e-shop'"
chk "boot hook removed with the last hop node" bash -c "! test -f /etc/systemd/system/psm-hop.service && ! test -f /etc/local.d/psm-hop.start"

echo; echo "=== RESULT: $PASS ok, $FAIL failed"
for f in "${FAILS[@]}"; do echo "  - $f"; done
exit $(( FAIL > 0 ))
