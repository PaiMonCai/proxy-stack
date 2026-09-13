#!/usr/bin/env bash
# singbox/wireguard.sh — WireGuard server via a sing-box endpoint
#
# A node is one WireGuard server (its own /24 inside 10.66.0.0/16) with one or
# more client peers. sing-box runs it as an `endpoints` entry: traffic from the
# peers goes through sing-box routing like any inbound (route.final = direct).
# Clients use a standard wg-quick configuration (official WireGuard apps,
# mihomo, sing-box), exported per peer with a QR code. mihomo has no WireGuard
# listener, so this protocol is sing-box only. Terminal output: t sb.wg.*.

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

SB_WG_CFG="$SB_STORE_DIR/wireguard.json"
SB_WG_DEFAULT_PORT=51820
SB_WG_MTU=1408

# ── State helpers ─────────────────────────────────────────────────────────────
_sb_wg_load() { [[ -f "$SB_WG_CFG" ]] && jq '.' "$SB_WG_CFG" 2>/dev/null || echo '[]'; }
_sb_wg_save() { mkdir -p "$(dirname "$SB_WG_CFG")"; printf '%s' "$1" | jq '.' > "$SB_WG_CFG"; chmod 600 "$SB_WG_CFG" 2>/dev/null || true; }
_sb_wg_count()      { _sb_wg_load | jq 'length' 2>/dev/null; }
_sb_wg_get_by_tag() { _sb_wg_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }
_sb_wg_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    _sb_wg_save "$(_sb_wg_load | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')"
}
_sb_wg_delete() { _sb_wg_save "$(_sb_wg_load | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"; }

# "private<TAB>public" from `sing-box generate wg-keypair`
sb_wg_keypair() {
    local out priv pub bin="${SB_BIN:-/usr/local/bin/sing-box}"
    out=$("$bin" generate wg-keypair 2>/dev/null) || return 1
    priv=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$out")
    pub=$(awk -F': *' 'tolower($1) ~ /public/ {print $2; exit}' <<<"$out")
    [[ -n "$priv" && -n "$pub" ]] || return 1
    printf '%s\t%s\n' "$priv" "$pub"
}

# First free /24 in 10.66.0.0/16 across all WireGuard nodes, as "10.66.N"
_sb_wg_free_net() {
    local used n
    used=" $(_sb_wg_load | jq -r '.[].subnet' 2>/dev/null | tr '\n' ' ') "
    for (( n = 1; n < 255; n++ )); do
        [[ "$used" == *" 10.66.$n "* ]] || { printf '10.66.%s' "$n"; return 0; }
    done
    return 1
}

# sb_wg_new_peer <node-json> <name> → node with one more peer (next free .N)
sb_wg_new_peer() {
    local n="$1" name="$2" kp priv pub
    kp=$(sb_wg_keypair) || return 1
    priv=${kp%%$'\t'*}; pub=${kp#*$'\t'}
    printf '%s' "$n" | jq -c --arg name "$name" --arg priv "$priv" --arg pub "$pub" '
      ([.peers[]?.host] + [1]) as $used
      | (first(range(2; 255) | select(. as $h | $used | index($h) | not))) as $h
      | .peers += [{name: $name, host: $h, private_key: $priv, public_key: $pub}]'
}

# ── Build the sing-box endpoint ───────────────────────────────────────────────
_sb_wg_build_endpoint() {
    local n="$1"
    jq -n --argjson n "$n" '{
        type: "wireguard",
        tag: $n.tag,
        mtu: ($n.mtu // 1408),
        address: [ ($n.subnet + ".1/24") ],
        private_key: $n.private_key,
        listen_port: $n.port,
        peers: [ $n.peers[] | { public_key: .public_key,
                                allowed_ips: [ ($n.subnet + "." + (.host | tostring) + "/32") ] } ]
    }'
}

# ── Apply: rebuild every WireGuard endpoint from the store ────────────────────
_sb_wg_apply() {
    _sb_cfg_backup
    local eps tmp
    eps=$(_sb_wg_load | jq -c '[.[]]') || return 1
    local built="[]" i count; count=$(jq 'length' <<<"$eps")
    for (( i = 0; i < count; i++ )); do
        built=$(jq -c --argjson e "$(_sb_wg_build_endpoint "$(jq -c ".[$i]" <<<"$eps")")" '. + [$e]' <<<"$built")
    done
    tmp=$(mktemp)
    jq --argjson new "$built" '
        .endpoints = ([ (.endpoints // [])[] | select(.type != "wireguard") ] + $new)
        | if (.endpoints | length) == 0 then del(.endpoints) else . end' "$SB_CFG" > "$tmp" \
        && mv "$tmp" "$SB_CFG"
    sb_test_restart
}

_sb_wg_apply_or_revert() {
    _sb_wg_apply && return 0
    _sb_wg_save "$1"
    log_error "$(t sb.change_reverted)"
    return 1
}

# ── Client configuration (wg-quick) ───────────────────────────────────────────
# sb_wg_client_conf <node-json> <peer-host> <server>
sb_wg_client_conf() {
    local n="$1" host="$2" server="$3"
    printf '%s' "$n" | jq -r --argjson h "$host" --arg s "$server" '
      . as $n | ($n.peers[] | select(.host == $h)) as $p
      | "[Interface]",
        "# PSM-\($n.tag) / \($p.name)",
        "PrivateKey = \($p.private_key)",
        "Address = \($n.subnet).\($p.host)/32",
        "DNS = 1.1.1.1, 8.8.8.8",
        "MTU = \($n.mtu // 1408)",
        "",
        "[Peer]",
        "PublicKey = \($n.public_key)",
        "AllowedIPs = 0.0.0.0/0",
        "Endpoint = \($s):\($n.port)",
        "PersistentKeepalive = 25"'
}

sb_wg_show_peer() {   # sb_wg_show_peer <tag> <peer-host>
    local n; n=$(_sb_wg_get_by_tag "$1")
    [[ -n "$n" ]] || { log_error "$(t sb.wg.not_found "$1")"; return 1; }
    local conf; conf=$(sb_wg_client_conf "$n" "$2" "$(get_ipv4)") || return 1
    echo -e "\n${BOLD}${GREEN}── WireGuard: $1 / $(jq -r --argjson h "$2" '.peers[] | select(.host == $h) | .name' <<<"$n") ──${NC}"
    echo "$conf"
    echo ""
    command -v qrencode &>/dev/null || ensure_pkg_deps qrencode 2>/dev/null || true
    echo "$conf" | qrencode -t ANSIUTF8 2>/dev/null || true
    echo -e "  ${YELLOW}$(t sb.wg.ipv4_only)${NC}"
}

_sb_wg_select() {   # sets SB_WG_SEL_TAG
    SB_WG_SEL_TAG=""
    local count; count=$(_sb_wg_count)
    (( count == 0 )) && { log_warn "$(t sb.wg.none)"; return 1; }
    local tags=() i=0 tag port peers
    while IFS=$'\t' read -r tag port peers; do
        i=$((i+1)); tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s UDP %-6s %s %s\n" "$i" "$tag" "$port" "$peers" "$(t sb.wg.peers_label)"
    done < <(_sb_wg_load | jq -r '.[] | "\(.tag)\t\(.port)\t\(.peers | length)"')
    local sel; read -rp "$(echo -e "${CYAN}$(t sb.wg.ask_select)${NC}")" sel
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )) || return 1
    SB_WG_SEL_TAG="${tags[$((sel-1))]}"
}

_sb_wg_select_peer() {   # <node-json> → sets SB_WG_SEL_HOST
    SB_WG_SEL_HOST=""
    local hosts=() i=0 host name
    while IFS=$'\t' read -r host name; do
        i=$((i+1)); hosts+=("$host")
        printf "  ${CYAN}%2d.${NC} %-16s %s\n" "$i" "$name" "$(jq -r '.subnet' <<<"$1").$host"
    done < <(jq -r '.peers[] | "\(.host)\t\(.name)"' <<<"$1")
    local sel; read -rp "$(echo -e "${CYAN}$(t sb.wg.ask_select_peer)${NC}")" sel
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )) || return 1
    SB_WG_SEL_HOST="${hosts[$((sel-1))]}"
}

# ── Add / peers / delete ──────────────────────────────────────────────────────
sb_wg_add_node() {
    _sb_require_installed || return
    echo -e "\n${BOLD}$(t sb.wg.add_title)${NC}"
    local tag port npeers net kp node i
    ask tag  "$(t sb.wg.ask_tag)"  "sb-wg-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4)"
    [[ "$tag" =~ ^sb-wg- ]] || tag="sb-wg-${tag}"
    ask port "$(t sb.wg.ask_port)" "$SB_WG_DEFAULT_PORT"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { log_error "$(t sb.wg.invalid_port)"; return 1; }
    _sb_check_port_conflict "$port" || { log_info "$(t sb.wg.cancelled)"; return 1; }
    ask npeers "$(t sb.wg.ask_peers)" "1"
    [[ "$npeers" =~ ^[0-9]+$ ]] && (( npeers >= 1 && npeers <= 50 )) || npeers=1
    net=$(_sb_wg_free_net) || { log_error "$(t sb.wg.no_subnet)"; return 1; }
    kp=$(sb_wg_keypair) || { log_error "$(t sb.wg.keygen_fail)"; return 1; }
    node=$(jq -n --arg tag "$tag" --argjson port "$port" --arg net "$net" \
        --arg priv "${kp%%$'\t'*}" --arg pub "${kp#*$'\t'}" --argjson mtu "$SB_WG_MTU" \
        '{tag:$tag, port:$port, subnet:$net, mtu:$mtu, private_key:$priv, public_key:$pub, peers:[]}')
    for (( i = 1; i <= npeers; i++ )); do
        node=$(sb_wg_new_peer "$node" "peer$i") || { log_error "$(t sb.wg.keygen_fail)"; return 1; }
    done
    local prev; prev=$(_sb_wg_load)
    _sb_wg_upsert "$node"
    _sb_wg_apply_or_revert "$prev" || return 1
    log_ok "$(t sb.wg.added "$tag" "$port")"
    ask_yn "$(t sb.wg.ask_firewall "$port")" Y && { source "$LIB_DIR/system.sh"; firewall_open_port "$port" "udp"; }
    for (( i = 2; i < npeers + 2; i++ )); do sb_wg_show_peer "$tag" "$i"; done
}

sb_wg_add_peer() {
    _sb_wg_select || return
    local tag="$SB_WG_SEL_TAG" node name prev host
    node=$(_sb_wg_get_by_tag "$tag")
    ask name "$(t sb.wg.ask_peer_name)" "peer$(( $(jq '.peers | length' <<<"$node") + 1 ))"
    node=$(sb_wg_new_peer "$node" "$name") || { log_error "$(t sb.wg.keygen_fail)"; return 1; }
    prev=$(_sb_wg_load); _sb_wg_upsert "$node"
    _sb_wg_apply_or_revert "$prev" || return 1
    host=$(jq -r '.peers[-1].host' <<<"$node")
    sb_wg_show_peer "$tag" "$host"
}

sb_wg_remove_peer() {
    _sb_wg_select || return
    local tag="$SB_WG_SEL_TAG" node prev
    node=$(_sb_wg_get_by_tag "$tag")
    (( $(jq '.peers | length' <<<"$node") > 1 )) || { log_warn "$(t sb.wg.last_peer)"; return 1; }
    _sb_wg_select_peer "$node" || return
    node=$(jq -c --argjson h "$SB_WG_SEL_HOST" 'del(.peers[] | select(.host == $h))' <<<"$node")
    prev=$(_sb_wg_load); _sb_wg_upsert "$node"
    _sb_wg_apply_or_revert "$prev" || return 1
    log_ok "$(t sb.wg.peer_removed)"
}

sb_wg_view() {
    _sb_wg_select || return
    local node; node=$(_sb_wg_get_by_tag "$SB_WG_SEL_TAG")
    _sb_wg_select_peer "$node" || return
    sb_wg_show_peer "$SB_WG_SEL_TAG" "$SB_WG_SEL_HOST"
}

sb_wg_delete_node() {
    _sb_wg_select || return
    local tag="$SB_WG_SEL_TAG" prev
    ask_yn "$(t sb.wg.ask_confirm_del "$tag")" N || return
    prev=$(_sb_wg_load); _sb_wg_delete "$tag"
    _sb_wg_apply_or_revert "$prev" || return 1
    source "$LIB_DIR/traffic.sh" 2>/dev/null && _trf_cleanup_node "$tag" 2>/dev/null || true
    log_ok "$(t sb.wg.deleted "$tag")"
}

_sb_wg_show_node_list() {
    local count; count=$(_sb_wg_count)
    echo -e "\n${BOLD}sing-box WireGuard:${NC}"
    if (( count == 0 )); then echo "  $(t sb.wg.none)"; return; fi
    _sb_wg_load | jq -r '.[] | "  UDP \(.port) | \(.subnet).0/24 | \(.peers | length) peers | tag: \(.tag)"'
}

# ── Menu ──────────────────────────────────────────────────────────────────────
sb_wg_menu() {
    _sb_require_installed || return
    while true; do
        show_menu "$(t sb.wg.menu_title)" \
            "$(t sb.wg.menu.add)" \
            "$(t sb.wg.menu.view)" \
            "$(t sb.wg.menu.add_peer)" \
            "$(t sb.wg.menu.remove_peer)" \
            "$(t sb.wg.menu.del)" \
            "$(t sb.wg.menu.restart)"
        case "$MENU_CHOICE" in
            1) sb_wg_add_node;    press_enter ;;
            2) sb_wg_view;        press_enter ;;
            3) sb_wg_add_peer;    press_enter ;;
            4) sb_wg_remove_peer; press_enter ;;
            5) sb_wg_delete_node; press_enter ;;
            6) sb_test_restart;   press_enter ;;
            0) return ;;
        esac
    done
}
