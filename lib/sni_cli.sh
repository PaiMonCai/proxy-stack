#!/usr/bin/env bash
# sni_cli.sh — psm sni find: REALITY camouflage targets near this server,
# without questions (the PSM panel's "自动选择伪装目标").
#
# The same search as the REALITY menu (lib/xray/sni_finder.sh): a
# cyberspace-mapping engine (Netlas, Quake, ZoomEye or FOFA) lists hosts in
# this server's ASN with their certificate names, and each candidate is
# checked with one TLS handshake (TLS 1.3, X25519, h2). The engine's API key
# comes on stdin (--key-stdin), so it never shows in a process list, and is
# used for this search only; without it, the key saved by the menu is used.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_sni_cli_err() { printf 'psm sni: %s\n' "$*" >&2; }

_sni_cli_usage() {
    cat <<'EOF'
Usage:
  psm sni find [--engine netlas|quake|zoomeye|fofa] [--key-stdin] [--max N] [--json]

Finds REALITY camouflage targets (SNI and dest) in this server's own network:
hosts in the same ASN, from a cyberspace-mapping engine, each checked with a
TLS handshake. --key-stdin reads the engine's API key from the first line of
stdin and uses it for this search only; without it the engine and key saved
by the REALITY menu are used. --max bounds the hosts asked for (default 40).
EOF
}

psm_sni_cli() {
    local cmd="${1:-}"
    case "$cmd" in
        find) shift ;;
        help|--help|-h|"") _sni_cli_usage; return 0 ;;
        *) _sni_cli_err "unknown command: $cmd"; _sni_cli_usage >&2; return 2 ;;
    esac
    local engine="" max=40 as_json=0 key_stdin=0 key=""
    while (( $# )); do
        case "$1" in
            --engine) engine="${2:-}"; shift 2 ;;
            --max) max="${2:-}"; shift 2 ;;
            --key-stdin) key_stdin=1; shift ;;
            --json) as_json=1; shift ;;
            *) _sni_cli_err "unknown option: $1"; return 2 ;;
        esac
    done
    [[ "$max" =~ ^[0-9]+$ ]] && (( max >= 1 && max <= 200 )) || { _sni_cli_err "--max must be 1-200"; return 2; }
    if (( key_stdin )); then
        IFS= read -r key || true
        key=$(printf '%s' "$key" | tr -d '\r\n')
        [[ -n "$key" ]] || { _sni_cli_err "--key-stdin: no key on stdin"; return 2; }
    fi
    exec </dev/null   # nothing below may wait for an answer
    [[ -n "$engine" ]] || engine=$(state_get sni_engine)
    [[ -n "$engine" ]] || engine=netlas
    case "$engine" in netlas|quake|zoomeye|fofa) ;; *) _sni_cli_err "unknown engine: $engine (netlas, quake, zoomeye, fofa)"; return 2 ;; esac
    export PSM_SNI_ENGINE="$engine"
    [[ -n "$key" ]] && export PSM_SNI_KEY="$key"

    # shellcheck source=/dev/null
    source "$LIB_DIR/xray/sni_finder.sh"
    _sni_have_engine || { _sni_cli_err "no API key for $engine: pass one with --key-stdin, or save it in the REALITY menu"; return 1; }
    _sni_check_deps
    _sni_self_asn_country || { _sni_cli_err "could not tell this server's ASN (ip-api.com, ipinfo.io and bgpview.io did not answer)"; return 1; }
    local pairs healthy
    pairs=$(_sni_discover_pairs "$max") || true
    [[ -n "$pairs" ]] || { _sni_cli_err "$engine found no hosts with a certificate in AS$SNI_SELF_ASN (or its quota is used up)"; return 1; }
    healthy=$(_sni_validate_pairs "$pairs") || true
    healthy=$(printf '%s\n' "$healthy" | sed '/^$/d' | sort -t"$(printf '\t')" -k3,3n) || true

    local out
    out=$(printf '%s\n' "$healthy" | jq -R -s -c --arg asn "$SNI_SELF_ASN" --arg cc "$SNI_SELF_COUNTRY" --arg engine "$engine" '
        { asn: ($asn | tonumber? // $asn), country: $cc, engine: $engine,
          candidates: [ split("\n")[] | select(length > 0) | split("\t")
                        | { sni: .[0], dest: .[1], rtt_ms: ((.[2] // "0") | tonumber? // 0), warn: (.[3] // "") } ] }')
    if (( as_json )); then
        printf '%s\n' "$out"
    else
        printf 'AS%s %s (%s)\n' "$SNI_SELF_ASN" "$SNI_SELF_COUNTRY" "$engine"
        printf '%s' "$out" | jq -r '.candidates[] | "  \(.sni)  \(.dest)  \(.rtt_ms)ms  \(.warn)"'
    fi
    if [[ "$(printf '%s' "$out" | jq '.candidates | length')" == 0 ]]; then
        _sni_cli_err "none of the hosts $engine found passed the TLS check"
        return 1
    fi
}
