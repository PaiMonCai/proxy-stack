#!/usr/bin/env bash
# ech.sh — turn ECH on or off for an existing sing-box / mihomo TLS node
#
# ECH is a toggle on existing nodes rather than another question in every add
# flow: it goes through `psm node update … --ech true|false`, so key generation,
# validation, apply and rollback are the same code path as the CLI. See
# lib/common.sh (psm_ech_keypair, _sb_ech_merge/_mh_ech_merge) for how the keys
# reach the cores and why enabling ECH never breaks existing share links.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$LIB_DIR/node_cli.sh"

ECH_PROTOCOLS="vless trojan anytls hysteria2 tuic"

# ech_menu <sing-box|mihomo>
ech_menu() {
    local core="$1" all rows=() i=0 row proto tag state sel
    all=$(_node_cli_collect "$core" "") || return 1
    echo -e "\n${BOLD}$(t common.ech.title) — ${core}${NC}"
    while IFS=$'\t' read -r proto tag state; do
        [[ " $ECH_PROTOCOLS " == *" $proto "* ]] || continue
        i=$((i + 1)); rows+=("$proto"$'\t'"$tag"$'\t'"$state")
        printf "  ${CYAN}%2d.${NC} %-10s %-24s ECH: %s\n" "$i" "$proto" "$tag" \
            "$([[ "$state" == on ]] && t common.ech.state_on || t common.ech.state_off)"
    done < <(printf '%s' "$all" | jq -r '.[] | "\(.protocol)\t\(.tag)\t\(if (.node.ech_key // "") != "" then "on" else "off" end)"')
    (( i == 0 )) && { log_warn "$(t common.ech.none)"; return 0; }
    read -rp "$(echo -e "${CYAN}$(t common.ech.ask_select)${NC}")" sel
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )) || return 0
    IFS=$'\t' read -r proto tag state <<<"${rows[$((sel - 1))]}"
    if [[ "$state" == on ]]; then
        psm_node_cli update "$core" "$proto" "$tag" --ech false >/dev/null && log_ok "$(t common.ech.disabled "$tag")"
    else
        psm_node_cli update "$core" "$proto" "$tag" --ech true >/dev/null || return 1
        log_ok "$(t common.ech.enabled "$tag")"
        echo -e "  $(t common.ech.config_hint)"
        psm_node_cli export "$core" "$proto" "$tag" --format ech
    fi
}
