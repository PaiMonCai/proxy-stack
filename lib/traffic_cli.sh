#!/usr/bin/env bash
# traffic_cli.sh — psm traffic: per-node metering and limits, without
# questions (for scripts and the PSM panel)
#
#   psm traffic list [--json]
#   psm traffic set TAG [--limit-bytes N | --limit-gb N] [--reset-day 1-28] [--json]
#   psm traffic reset TAG [--json]
#   psm traffic unset TAG [--json]
#
# TAG is a node's tag, or snell / ss2022 for the standalone servers, as in the
# traffic menu (which keeps working on the same state). A limit of 0 meters a
# node without limiting it. The periodic check, installed with the first
# `set`, pauses a node that goes over its limit until the monthly reset (on
# the reset day) or `psm traffic reset`.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
PSM_ROOT="${PSM_ROOT:-$(cd "$LIB_DIR/.." && pwd)}"
# shellcheck source=/dev/null
source "$LIB_DIR/traffic.sh"

_trf_cli_err() { printf 'psm traffic: %s\n' "$*" >&2; }

_trf_cli_usage() {
    cat <<'EOF'
Usage:
  psm traffic list [--json]
  psm traffic set TAG [--limit-bytes N | --limit-gb N] [--reset-day 1-28] [--json]
  psm traffic reset TAG [--json]
  psm traffic unset TAG [--json]
EOF
}

# One state entry as the CLI prints it.
_TRF_CLI_ENTRY='{tag: $t, port: (.port // null), source: (.source // "xray"),
  limit_bytes: ((.limit_bytes // 0) | floor), used_bytes: ((.accumulated_bytes // 0) | floor),
  paused: (.paused // false), reset_day: (.reset_day // 0), last_reset: (.last_reset // ""),
  last_check: (.last_check // "")}'

_trf_cli_entry() { jq -c --arg t "$1" ".[\$t] | $_TRF_CLI_ENTRY" "$TRAFFIC_STATE"; }

# Port, counting method, counting port and interface of a node, worked out as
# the traffic menu does: Xray nodes through its stats API, the rest through
# iptables counters on their port (the 127.0.0.1 backend of a 443-shared node).
_trf_cli_locate() {
    local tag="$1" item core n port cport laddr
    case "$tag" in
        snell)
            if [[ -f /etc/snell/users/snell-main.conf ]]; then
                port=$(awk -F: '/^listen/ { gsub(/[^0-9]/, "", $NF); print $NF; exit }' /etc/snell/users/snell-main.conf || true)
                if [[ -n "$port" ]]; then printf '%s\tiptables\t%s\t\n' "$port" "$port"; return 0; fi
            fi ;;
        ss2022)
            if [[ -f /etc/ss-rust/config.json ]]; then
                port=$(jq -r '.server_port // empty' /etc/ss-rust/config.json 2>/dev/null || true)
                if [[ -n "$port" ]]; then printf '%s\tiptables\t%s\t\n' "$port" "$port"; return 0; fi
            fi ;;
    esac
    # shellcheck source=/dev/null
    source "$LIB_DIR/node_cli.sh"
    item=$(_node_cli_find "$tag" "" "" 2>/dev/null) || return 1
    core=$(jq -r '.core' <<<"$item"); n=$(jq -c '.node' <<<"$item")
    port=$(jq -r '.public_port // .port' <<<"$n")
    cport=$(jq -r '.port' <<<"$n")
    laddr=$(jq -r '.listen_addr // ""' <<<"$n")
    if [[ "$core" == xray ]]; then
        printf '%s\txray\t%s\t\n' "$port" "$port"
    elif [[ "$laddr" == 127.0.0.1 ]]; then
        printf '%s\tiptables\t%s\tlo\n' "$port" "$cport"
    else
        printf '%s\tiptables\t%s\t\n' "$port" "$cport"
    fi
}

_trf_cli_list() {
    local json=0 out
    [[ "${1:-}" == --json ]] && json=1
    _trf_init
    if [[ $EUID -eq 0 ]]; then   # bring the counters up to date first
        _trf_ipt_restore_all >/dev/null 2>&1 || true
        _trf_checkpoint_all >/dev/null 2>&1 || true
    fi
    out=$(jq -c "[to_entries[] | .key as \$t | .value | $_TRF_CLI_ENTRY]" "$TRAFFIC_STATE")
    if (( json )); then
        printf '%s\n' "$out"
    else
        jq -r '.[] | "\(.tag)\tport \(.port)\tused \(.used_bytes)\tlimit \(if .limit_bytes > 0 then .limit_bytes else "none" end)\t\(if .paused then "paused" else "running" end)"' <<<"$out"
    fi
}

_trf_cli_set() {
    local tag="${1:-}" limit="" gb="" day="" json=0
    [[ -n "$tag" && "$tag" != -* ]] || { _trf_cli_err 'set needs TAG'; return 2; }
    shift
    while (( $# )); do
        case "$1" in
            --limit-bytes) limit="${2:-}"; shift 2 ;;
            --limit-gb) gb="${2:-}"; shift 2 ;;
            --reset-day) day="${2:-}"; shift 2 ;;
            --json) json=1; shift ;;
            *) _trf_cli_err "unknown option: $1"; return 2 ;;
        esac
    done
    if [[ -n "$gb" ]]; then
        [[ "$gb" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { _trf_cli_err '--limit-gb: a number'; return 2; }
        limit=$(awk -v g="$gb" 'BEGIN { printf "%.0f", g * 1073741824 }')
    fi
    limit="${limit:-0}"
    [[ "$limit" =~ ^[0-9]+$ ]] || { _trf_cli_err '--limit-bytes: a whole number'; return 2; }
    [[ $EUID -eq 0 ]] || { _trf_cli_err 'run as root'; return 1; }

    local loc port source cport iface
    loc=$(_trf_cli_locate "$tag") || { _trf_cli_err "no node or standalone server named $tag"; return 1; }
    IFS=$'\t' read -r port source cport iface <<<"$loc"
    _trf_init
    [[ -n "$day" ]] || day=$(_trf_get "$tag" reset_day)
    day="${day:-1}"
    if ! [[ "$day" =~ ^[0-9]+$ ]] || (( day < 1 || day > 28 )); then
        _trf_cli_err '--reset-day: 1-28'; return 2
    fi

    _trf_init_tag "$tag" "$port"
    _trf_set_field "$tag" limit_bytes "$limit"
    _trf_set_field "$tag" reset_day "$day"
    _trf_set_str   "$tag" source "$source"
    _trf_set_field "$tag" count_port "$cport"
    _trf_set_str   "$tag" count_iface "$iface"
    _trf_set_field "$tag" meter true
    # this month counts from now: no immediate "monthly" reset of a fresh entry
    [[ -n "$(_trf_get "$tag" last_reset)" ]] || _trf_set_str "$tag" last_reset "$(date +%Y-%m)"

    if [[ "$source" == xray ]]; then
        if ! _trf_stats_enabled; then
            # shellcheck source=/dev/null
            source "$LIB_DIR/xray/core.sh"
            _trf_enable_stats >&2
        fi
    else
        _trf_ipt_ensure_rules "$tag" "$cport" "$iface" >&2
    fi
    _trf_timer_active || _trf_install_timer >&2

    # a raised limit (or none) lifts a pause
    if [[ "$(_trf_get "$tag" paused)" == true ]]; then
        local used; used=$(_trf_to_int "$(_trf_get "$tag" accumulated_bytes)")
        if (( limit == 0 || used < limit )); then _trf_resume_tag "$tag" >&2; fi
    fi
    if (( json )); then _trf_cli_entry "$tag"; else _trf_cli_entry "$tag" | jq -r 'to_entries[] | "\(.key): \(.value)"'; fi
}

# Starts the count from zero again (and lifts a pause).
_trf_cli_reset() {
    local tag="${1:-}" json=0 source cur=0 tmp
    [[ "${2:-}" == --json ]] && json=1
    [[ $EUID -eq 0 ]] || { _trf_cli_err 'run as root'; return 1; }
    _trf_init
    jq -e --arg t "$tag" '.[$t] != null' "$TRAFFIC_STATE" >/dev/null 2>&1 \
        || { _trf_cli_err "$tag is not metered"; return 1; }
    [[ "$(_trf_get "$tag" paused)" == true ]] && _trf_resume_tag "$tag" >&2
    source=$(_trf_get "$tag" source)
    case "${source:-xray}" in
        xray)     cur=$(_trf_query_bytes "$tag" 2>/dev/null || echo 0) ;;
        iptables) cur=$(_trf_ipt_query_bytes "$tag" 2>/dev/null || echo 0) ;;
    esac
    cur=$(_trf_to_int "$cur")
    tmp=$(mktemp)
    jq --arg t "$tag" --argjson cb "$cur" \
        '.[$t].accumulated_bytes = 0 | .[$t].checkpoint_bytes = $cb | .[$t].warned90 = false
         | .[$t].paused = false | .[$t].paused_at = null' "$TRAFFIC_STATE" > "$tmp" && mv "$tmp" "$TRAFFIC_STATE"
    echo "$(TZ="Asia/Hong_Kong" date '+%Y-%m-%d %H:%M:%S') RESET tag=${tag} (psm traffic reset)" >> "$TRAFFIC_LOG"
    if (( json )); then _trf_cli_entry "$tag"; else echo "$tag: counter reset"; fi
}

_trf_cli_unset() {
    local tag="${1:-}" json=0
    [[ "${2:-}" == --json ]] && json=1
    [[ $EUID -eq 0 ]] || { _trf_cli_err 'run as root'; return 1; }
    _trf_init
    if jq -e --arg t "$tag" '.[$t] != null' "$TRAFFIC_STATE" >/dev/null 2>&1; then
        _trf_cleanup_node "$tag" >&2
    fi
    if (( json )); then jq -nc --arg t "$tag" '{tag: $t, status: "removed"}'; else echo "$tag: no longer metered"; fi
}

psm_traffic_cli() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        list|ls) _trf_cli_list "$@" ;;
        set) _trf_cli_set "$@" ;;
        reset) _trf_cli_reset "$@" ;;
        unset|remove) _trf_cli_unset "$@" ;;
        help|--help|-h) _trf_cli_usage ;;
        *) _trf_cli_usage >&2; return 2 ;;
    esac
}
