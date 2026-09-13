#!/usr/bin/env bash
# coreperm.sh — Xray, sing-box and mihomo run as the unprivileged user psm-core
#
# The cores need two capabilities (binding ports below 1024, and SO_MARK for
# the WARP / VPNGate exits), which systemd and OpenRC grant them; everything
# else root used to cover is file access. This keeps it working:
#   - the core's own state (mihomo's home, sing-box's cache.db directory,
#     Xray's log directory) belongs to psm-core;
#   - its config files are readable by the psm-core group;
#   - every certificate / key its config references is readable too, including
#     after acme.sh renews it (renewals rewrite the key as root 0600).
# It runs as root before every core start (systemd ExecStartPre=+, OpenRC
# start_pre) and right after PSM writes a config, so a reboot after a renewal
# or a freshly written config never locks the core out.
#
#   bash lib/coreperm.sh <xray|sing-box|mihomo>

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PSM_CORE_USER="psm-core"

# Directories under which PSM may grant psm-core traversal to reach a
# certificate. A key elsewhere (say, under /root) is reported, not opened up.
_coreperm_cert_roots() {
    printf '%s\n' "$NGINX_SSL_DIR" "$CFG_DIR" /etc/psm "${XRAY_CFG_DIR:-/usr/local/etc/xray}" \
        "${SINGBOX_CFG_DIR:-/etc/sing-box}" "${MIHOMO_CFG_DIR:-/etc/mihomo}" /etc/hysteria
}

# systemd older than 231 (Amazon Linux 2 ships 219) knows neither
# AmbientCapabilities (229) nor ExecStartPre=+ (231): an unprivileged core
# could not bind its port there, so the cores stay root. PSM_SYSTEMD_VERSION
# overrides the detected version (tests).
psm_core_nonroot_supported() {
    _uses_systemd || return 0
    local v="${PSM_SYSTEMD_VERSION:-}"
    [[ -n "$v" ]] || v=$(systemctl --version 2>/dev/null | awk 'NR == 1 {print $2}')
    [[ "$v" =~ ^[0-9]+$ ]] || return 0
    (( v >= 231 ))
}

# The [Service] lines that decide who the core runs as.
psm_core_unit_lines() {   # <xray|sing-box|mihomo>
    if psm_core_nonroot_supported; then
        cat <<EOF
User=${PSM_CORE_USER}
Group=${PSM_CORE_USER}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
# '+' runs this as root: it keeps what psm-core must read readable (lib/coreperm.sh)
ExecStartPre=+/bin/bash ${LIB_DIR}/coreperm.sh $1
EOF
    else
        cat <<EOF
# systemd older than 231: too old to start the core unprivileged (lib/coreperm.sh).
# Root keeps all its capabilities: files a newer PSM gave to psm-core stay readable.
User=root
NoNewPrivileges=true
EOF
    fi
}

psm_core_user_ensure() {
    id -u "$PSM_CORE_USER" &>/dev/null && return 0
    if command -v useradd &>/dev/null; then
        useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin \
            --user-group "$PSM_CORE_USER" 2>/dev/null
    else   # busybox (Alpine)
        addgroup -S "$PSM_CORE_USER" 2>/dev/null
        adduser -S -D -H -h /nonexistent -s /sbin/nologin -G "$PSM_CORE_USER" "$PSM_CORE_USER" 2>/dev/null
    fi
    id -u "$PSM_CORE_USER" &>/dev/null
}

# Make <file> readable by psm-core: its group, and every parent directory it
# cannot already traverse, provided that directory is under a cert root.
_coreperm_grant_file() {
    local f="$1" d root ok
    [[ -e "$f" ]] || return 0
    chgrp "$PSM_CORE_USER" "$f" 2>/dev/null && chmod g+r "$f" 2>/dev/null
    d=$(dirname "$f")
    while [[ "$d" != "/" && -n "$d" ]]; do
        if [[ "$(stat -c '%A' "$d" 2>/dev/null)" != *x ]]; then   # others cannot traverse
            ok=0
            while IFS= read -r root; do
                [[ -n "$root" && ( "$d" == "$root" || "$d" == "$root"/* ) ]] && { ok=1; break; }
            done < <(_coreperm_cert_roots)
            if (( ok )); then
                chgrp "$PSM_CORE_USER" "$d" 2>/dev/null || true; chmod g+x "$d" 2>/dev/null || true
            else
                log_warn "$(t common.coreperm.cannot_reach "$f" "$d")"
                return 0
            fi
        fi
        d=$(dirname "$d")
    done
}

# Every certificate / key path a core config references (all three formats).
_coreperm_cert_paths() {
    jq -r '[.. | objects | to_entries[]
             | select(.key | test("^(certificateFile|keyFile|certificate_path|key_path|certificate|private-key)$"))
             | .value | strings | select(startswith("/"))] | unique[]' "$1" 2>/dev/null
}

psm_core_perms() {
    local core="$1" cfg_dir cfg state_dirs=() d
    psm_core_user_ensure || { log_warn "$(t common.coreperm.no_user)"; return 1; }
    case "$core" in
        xray)
            cfg_dir="${XRAY_CFG_DIR:-/usr/local/etc/xray}"; cfg="$cfg_dir/config.json"
            state_dirs=(/var/log/xray) ;;
        sing-box)
            cfg_dir="${SINGBOX_CFG_DIR:-/etc/sing-box}"; cfg="$cfg_dir/config.json"
            state_dirs=("$cfg_dir") ;;      # cache.db lives next to config.json
        mihomo)
            cfg_dir="${MIHOMO_CFG_DIR:-/etc/mihomo}"; cfg="$cfg_dir/config.yaml"
            state_dirs=("$cfg_dir") ;;      # home: cache.db, geodata, rule providers
        *) return 1 ;;
    esac
    [[ -d "$cfg_dir" ]] || return 0
    # Best effort throughout (`|| true`): callers run under errexit, and a file
    # PSM cannot fix is for the core to report, not a reason to abort a change.
    mkdir -p "${state_dirs[@]}" 2>/dev/null || true
    # Config tree: group psm-core, readable; directories traversable.
    chgrp -R "$PSM_CORE_USER" "$cfg_dir" 2>/dev/null || true
    find "$cfg_dir" -type d -exec chmod g+rx {} + 2>/dev/null || true
    find "$cfg_dir" -type f -exec chmod g+r {} + 2>/dev/null || true
    # State the core writes itself.
    for d in "${state_dirs[@]}"; do
        chown "$PSM_CORE_USER:$PSM_CORE_USER" "$d" 2>/dev/null || true; chmod 750 "$d" 2>/dev/null || true
        find "$d" -maxdepth 1 -type f \( -name '*.db' -o -name '*.log' -o -name '*.dat' -o -name '*.mmdb' \) \
            -exec chown "$PSM_CORE_USER:$PSM_CORE_USER" {} + 2>/dev/null || true
        # mihomo downloads rule / proxy providers into subdirectories of its home
        find "$d" -mindepth 1 -maxdepth 1 -type d -exec chown -R "$PSM_CORE_USER:$PSM_CORE_USER" {} + 2>/dev/null || true
    done
    # Read by the init system as root only.
    [[ -f "$cfg_dir/psm.env" ]] && { chown root:root "$cfg_dir/psm.env"; chmod 600 "$cfg_dir/psm.env"; } || true
    # Certificates and keys the config points at.
    local f
    [[ -f "$cfg" ]] && while IFS= read -r f; do _coreperm_grant_file "$f"; done < <(_coreperm_cert_paths "$cfg")
    return 0
}

# Does this systemd unit / OpenRC script run the core as psm-core? (A plain
# grep would also match the comment PSM puts in the unit.)
_coreperm_unit_nonroot() {
    grep -qE "^(User=|command_user=\"?)${PSM_CORE_USER}" "$1" 2>/dev/null
}

# Called before every restart PSM does: fix permissions for what was just
# written, and move a unit that still runs the core as root to psm-core once.
psm_core_nonroot_ensure() {
    local core="$1" def
    # too old a systemd: the core stays root, and its files stay root's too
    psm_core_nonroot_supported || return 0
    psm_core_perms "$core" || return 0
    if _uses_systemd; then def="/etc/systemd/system/${core}.service"; else def="/etc/init.d/${core}"; fi
    [[ -f "$def" ]] || return 0
    _coreperm_unit_nonroot "$def" && return 0
    case "$core" in
        xray)     declare -F _write_xray_service >/dev/null && _write_xray_service ;;
        sing-box) declare -F _sb_write_service  >/dev/null && _sb_write_service ;;
        mihomo)   declare -F _mh_write_service  >/dev/null && _mh_write_service ;;
    esac
    svc_daemon_reload 2>/dev/null || true
    log_info "$(t common.coreperm.migrated "$core")"
}

# Entry point for ExecStartPre / start_pre: bash lib/coreperm.sh <core>
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    psm_core_perms "${1:-}"
    exit 0   # never block a start: the core reports what it cannot read
fi
