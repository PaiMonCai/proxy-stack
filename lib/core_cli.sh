#!/usr/bin/env bash
# core_cli.sh — psm core: the three cores, without questions
#
#   psm core list [--json]
#   psm core install xray|sing-box|mihomo [--if-missing] [--json]
#
# install is the unattended install `psm migrate` uses (PSM_NO_WIZARD, no
# stdin): the latest stable release and its service, no wizard. The PSM panel's
# psm-agent runs it before the first node of a core, so a server that has only
# PSM (or not even that: bootstrap.sh --panel installs PSM) gets the core it
# needs. The menus' installs are unchanged.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_core_err() { printf 'psm core: %s\n' "$*" >&2; }

_core_usage() {
    cat <<'EOF'
Usage:
  psm core list [--json]
  psm core install xray|sing-box|mihomo [--if-missing] [--json]
EOF
}

_core_norm() {
    case "${1:-}" in
        xray) echo xray ;;
        sing-box|singbox) echo sing-box ;;
        mihomo) echo mihomo ;;
        *) return 1 ;;
    esac
}

_core_bin() {
    case "$1" in
        xray) printf '%s' "$XRAY_BIN" ;;
        sing-box) printf '%s' "$SINGBOX_BIN" ;;
        mihomo) printf '%s' "$MIHOMO_BIN" ;;
    esac
}

# The core's own version line, empty when it is not installed.
_core_version() {
    local bin out
    bin=$(_core_bin "$1")
    [[ -x "$bin" ]] || return 0
    case "$1" in
        mihomo) out=$("$bin" -v 2>/dev/null || true) ;;
        *)      out=$("$bin" version 2>/dev/null || true) ;;
    esac
    printf '%s' "${out%%$'\n'*}"
}

_core_entry() {   # <core> → one JSON object
    local ver active=false
    ver=$(_core_version "$1")
    svc_is_active "$1" 2>/dev/null && active=true
    jq -nc --arg c "$1" --arg v "$ver" --argjson a "$active" \
        '{core: $c, installed: ($v != ""), version: $v, active: $a}'
}

_core_list() {
    local json=0 c out="[]"
    [[ "${1:-}" == --json ]] && json=1
    for c in xray sing-box mihomo; do
        out=$(jq -c --argjson e "$(_core_entry "$c")" '. + [$e]' <<<"$out")
    done
    if (( json )); then
        printf '%s\n' "$out"
    else
        jq -r '.[] | "\(.core)\t\(if .installed then .version else "not installed" end)\t\(if .active then "running" else "stopped" end)"' <<<"$out"
    fi
}

_core_install() {
    local core="" if_missing=0 json=0 already=false
    while (( $# )); do
        case "$1" in
            --if-missing) if_missing=1; shift ;;
            --json) json=1; shift ;;
            -*) _core_err "unknown option: $1"; return 2 ;;
            *) core=$(_core_norm "$1") || { _core_err "unknown core: $1 (xray, sing-box or mihomo)"; return 2; }; shift ;;
        esac
    done
    [[ -n "$core" ]] || { _core_usage >&2; return 2; }
    [[ $EUID -eq 0 ]] || { _core_err 'run as root'; return 1; }

    if (( if_missing )) && [[ -x "$(_core_bin "$core")" ]]; then
        already=true
    else
        # An installed core asks before reinstalling: say yes. A fresh one asks nothing.
        local answer=""
        [[ -x "$(_core_bin "$core")" ]] && answer=$'y\n'
        if ! ( export PSM_NO_WIZARD=1
               case "$core" in
                   xray)     source "$LIB_DIR/xray/core.sh";    xray_install ;;
                   sing-box) source "$LIB_DIR/singbox/core.sh"; sb_install ;;
                   mihomo)   source "$LIB_DIR/mihomo/core.sh";  mh_install ;;
               esac ) <<<"$answer" >&2; then
            _core_err "installing $core failed"
            return 1
        fi
        [[ -x "$(_core_bin "$core")" ]] || { _core_err "$core was not installed"; return 1; }
    fi
    if (( json )); then
        jq -c --argjson a "$already" '. + {already: $a}' <<<"$(_core_entry "$core")"
    else
        printf '%s %s\n' "$core" "$(_core_version "$core")"
    fi
}

psm_core_cli() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        list|ls) _core_list "$@" ;;
        install) _core_install "$@" ;;
        help|--help|-h) _core_usage ;;
        *) _core_usage >&2; return 2 ;;
    esac
}
