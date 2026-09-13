#!/usr/bin/env bash
# hop.sh — Hysteria2 port hopping (server side)
#
# Hysteria2 clients can hop between the ports of a range; the server listens on
# one port only. A node with hop_ports "A-B" gets a nat PREROUTING rule that
# redirects UDP A..B to its real port, for IPv4 and IPv6. The firewall only
# needs the real port: the redirect happens before the INPUT filter.
#
# The rules are derived state: psm_hop_sync rebuilds all of them from the
# Hysteria2 node stores (sing-box, mihomo, Xray), after every apply and at boot
# (iptables rules are not restored by themselves on Debian). Every rule carries
# the comment psm-hop:<tag>, which is how sync finds its own rules again.
#
#   bash lib/hop.sh sync     rebuild the rules (what the boot hook runs)

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

HOP_MAX_SPAN=20000
HOP_SYSTEMD_UNIT="/etc/systemd/system/psm-hop.service"
HOP_LOCAL_D="/etc/local.d/psm-hop.start"

# Every Hysteria2 node that asks for hopping, as "tag<TAB>port<TAB>A-B" lines.
_hop_wanted() {
    local f
    for f in "$CFG_DIR/singbox/hysteria2.json" "$CFG_DIR/mihomo/hysteria2.json" "$CFG_DIR/xray/hysteria2.json"; do
        [[ -f "$f" ]] || continue
        jq -r '.[]? | select((.hop_ports // "") != "") | "\(.tag)\t\(.port)\t\(.hop_ports)"' "$f" 2>/dev/null
    done
}

# hop_range_valid <A-B> <node-port> <tag>: sane, not too wide, and not
# swallowing another node's port or another process's UDP listener (a
# redirect would silently steal that traffic).
hop_range_valid() {
    local range="$1" port="$2" tag="${3:-}" a b p
    [[ "$range" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || { HOP_ERR="format"; return 1; }
    a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
    (( a >= 1024 && b <= 65535 && a < b )) || { HOP_ERR="bounds"; return 1; }
    (( b - a + 1 <= HOP_MAX_SPAN )) || { HOP_ERR="too_wide"; return 1; }
    # other PSM nodes (any protocol, any core) inside the range
    local f
    for f in "$CFG_DIR"/xray/*.json "$CFG_DIR"/singbox/*.json "$CFG_DIR"/mihomo/*.json; do
        [[ -f "$f" ]] || continue
        while IFS=$'\t' read -r t p; do
            [[ "$t" == "$tag" ]] && continue
            [[ "$p" =~ ^[0-9]+$ ]] && (( p >= a && p <= b )) && { HOP_ERR="node:$t:$p"; return 1; }
        done < <(jq -r '.[]? | select(.port != null) | "\(.tag)\t\(.port)"' "$f" 2>/dev/null)
    done
    # anything else already listening on UDP inside the range
    if command -v ss &>/dev/null; then
        while read -r p; do
            [[ "$p" =~ ^[0-9]+$ && "$p" != "$port" ]] && (( p >= a && p <= b )) && { HOP_ERR="listener:$p"; return 1; }
        done < <(ss -Hlun 2>/dev/null | awk '{print $4}' | sed 's/.*://')
    fi
    return 0
}

# ask_hy2_hop_ports <var> <node-port> <tag>: optional port-hopping range for a
# Hysteria2 node ("" = off). Suggests a random 1000-port window and asks again
# until the range passes hop_range_valid.
ask_hy2_hop_ports() {
    local _hop_var="$1" _hop_port="$2" _hop_tag="$3" _hop_r="" _hop_a
    if ask_yn "$(t common.hop.ask)" N; then
        _hop_a=$(( 20000 + RANDOM % 40000 )); (( _hop_a + 999 > 65535 )) && _hop_a=50000
        while :; do
            ask _hop_r "$(t common.hop.ask_range)" "${_hop_a}-$((_hop_a + 999))"
            hop_range_valid "$_hop_r" "$_hop_port" "$_hop_tag" && break
            log_warn "$(t common.hop.invalid "$_hop_r" "$HOP_ERR")"
        done
        log_info "$(t common.hop.cloud_note "$_hop_r")"
    fi
    printf -v "$_hop_var" '%s' "$_hop_r"
}

_hop_ipt() {   # _hop_ipt <iptables|ip6tables> args...
    command -v "$1" &>/dev/null || return 1
    "$@" 2>/dev/null
}

# Remove every psm-hop rule from both families.
_hop_flush() {
    local t rule
    for t in iptables ip6tables; do
        command -v "$t" &>/dev/null || continue
        while IFS= read -r rule; do
            [[ -n "$rule" ]] || continue
            eval "$t -t nat ${rule/-A PREROUTING/-D PREROUTING}" 2>/dev/null || true
        done < <("$t" -t nat -S PREROUTING 2>/dev/null | grep -- '--comment "\?psm-hop:')
    done
}

# Rebuild the rules from the node stores; install or drop the boot hook.
psm_hop_sync() {
    local wanted; wanted=$(_hop_wanted)
    # Minimal Debian 13 has no iptables (nftables only): without this, hopping
    # would look configured and silently do nothing.
    if [[ -n "$wanted" ]] && ! command -v iptables &>/dev/null; then
        ensure_pkg_deps iptables >/dev/null 2>&1 || true
        command -v iptables &>/dev/null || log_warn "$(t common.hop.no_iptables)"
    fi
    _hop_flush
    local tag port range n=0 fam
    while IFS=$'\t' read -r tag port range; do
        [[ -n "$tag" && "$port" =~ ^[0-9]+$ && "$range" =~ ^[0-9]+-[0-9]+$ ]] || continue
        for fam in iptables ip6tables; do
            _hop_ipt "$fam" -t nat -A PREROUTING -p udp --dport "${range/-/:}" \
                -m comment --comment "psm-hop:${tag}" -j REDIRECT --to-ports "$port" || true
        done
        n=$((n + 1))
    done <<< "$wanted"
    if (( n > 0 )); then _hop_boot_hook_install; else _hop_boot_hook_remove; fi
    return 0
}

# The boot hook re-runs sync, so hopping survives a reboot without depending
# on iptables-persistent / the distro's rule restore.
_hop_boot_hook_install() {
    local script; script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hop.sh"
    if _uses_systemd; then
        [[ -f "$HOP_SYSTEMD_UNIT" ]] && grep -qF "$script" "$HOP_SYSTEMD_UNIT" && return 0
        cat > "$HOP_SYSTEMD_UNIT" <<EOF
[Unit]
Description=PSM Hysteria2 port hopping rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${script} sync
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable psm-hop.service >/dev/null 2>&1 || true
    elif _uses_openrc; then
        mkdir -p /etc/local.d
        printf '#!/bin/sh\n# PSM: Hysteria2 port hopping rules\n/bin/bash %s sync\n' "$script" > "$HOP_LOCAL_D"
        chmod 755 "$HOP_LOCAL_D"
        rc-update add local default >/dev/null 2>&1 || true
    fi
}

_hop_boot_hook_remove() {
    if [[ -f "$HOP_SYSTEMD_UNIT" ]]; then
        systemctl disable psm-hop.service >/dev/null 2>&1 || true
        rm -f "$HOP_SYSTEMD_UNIT"
        systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f "$HOP_LOCAL_D"
}

# Entry point for the boot hook: bash lib/hop.sh sync
if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == "sync" ]]; then
    psm_hop_sync
fi
