#!/usr/bin/env bash
# relay_cli.sh — psm relay: the realm relay rules, without questions (the PSM
# panel's 中转).
#
# A relay listens on this server and forwards to another host: the entry
# machine takes the client's connection and hands it to the landing machine,
# whose node configuration does not change. realm does this at L4 and neither
# parses nor decrypts what passes through.
#
# The hop itself can be encrypted (--tls): realm wraps the forwarded stream in
# TLS, so what travels between the two machines no longer looks like the node's
# own protocol. The landing side terminates it, the entry side dials it.
# Without --tls the hop is a plain TCP/UDP forward, as before.
#
# The rule store (config/realm/rules.json) stays the source of truth; realm's
# config.toml is generated from it, exactly as the menu does.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_RELAY_CLI_VERSION=1

_relay_err() { printf 'psm relay: %s\n' "$*" >&2; }

_relay_usage() {
    cat <<'EOF'
Usage:
  psm relay list [--json]
  psm relay show TAG [--json]
  psm relay add --tag TAG --listen-port PORT --remote-host HOST --remote-port PORT
                [--udp] [--tls] [--tls-sni NAME] [--tls-cert FILE] [--tls-key FILE]
                [--tls-insecure] [--no-firewall] [--json]
  psm relay update TAG [--listen-port PORT] [--remote-host HOST] [--remote-port PORT]
                [--udp true|false] [--tls true|false] [--tls-sni NAME]
                [--tls-cert FILE] [--tls-key FILE] [--tls-insecure true|false] [--json]
  psm relay delete TAG --yes [--if-exists] [--json]
  psm relay probe [TAG] [--samples N] [--json]
  psm relay install [--json]

Only the entry machine needs a rule; the landing machine's nodes stay as they
are. Encryption of the hop is optional and off by default:

  landing   psm relay add --tag out --listen-port 8443 \
                --remote-host 127.0.0.1 --remote-port 443 --tls
  entry     psm relay add --tag in --listen-port 443 \
                --remote-host LANDING_IP --remote-port 8443 \
                --tls --tls-sni relay.example.com --tls-insecure

A rule that forwards to this machine (127.0.0.1, or any of its own addresses)
terminates TLS — the landing side, which holds the certificate; one that
forwards to another host dials it — the entry side. The terminating side uses
--tls-cert/--tls-key when given, else a self-signed pair made for --tls-sni.
--tls-insecure lets the dialling side accept a self-signed certificate.

--tls covers the TCP hop only. With --udp the UDP half keeps going as plain
UDP, since realm wraps TCP streams: a protocol that matters over UDP
(Hysteria2, TUIC, WireGuard) is not hidden by it.
EOF
}

_relay_load_realm() {
    # shellcheck source=/dev/null
    source "$LIB_DIR/realm.sh"
}

_relay_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
_relay_valid_tag()  { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }

_relay_bool() {
    case "${1,,}" in
        true|1|yes|on)  printf 'true' ;;
        false|0|no|off) printf 'false' ;;
        *) return 1 ;;
    esac
}

# A self-signed pair for the terminating side, when none was given. The
# dialling side accepts it with --tls-insecure; a real certificate is better
# when the relay has a name of its own.
_relay_self_signed() {   # <sni> → "<cert>\t<key>"
    local sni="$1" dir crt key
    dir="$CFG_DIR/realm/certs"
    crt="$dir/${sni}.crt"; key="$dir/${sni}.key"
    if [[ -s "$crt" && -s "$key" ]]; then
        printf '%s\t%s' "$crt" "$key"; return 0
    fi
    mkdir -p "$dir" || return 1
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -days 3650 -subj "/CN=${sni}" -addext "subjectAltName=DNS:${sni}" \
        -keyout "$key" -out "$crt" >/dev/null 2>&1 || {
        _relay_err "could not make a self-signed certificate for $sni"; return 1; }
    chmod 600 "$key" 2>/dev/null || true
    printf '%s\t%s' "$crt" "$key"
}

_relay_result() {   # <status> <rule json> <as_json>
    local status="$1" rule="$2" as_json="$3"
    if [[ "$as_json" == "1" ]]; then
        printf '%s' "$rule" | jq -c --arg s "$status" --argjson v "$_RELAY_CLI_VERSION" \
            '{status:$s, api_version:$v, item:.}'
    else
        printf '%s: %s\n' "$status" "$(printf '%s' "$rule" | jq -r '.tag')"
    fi
}

# Write the rule, apply it, and put the store back if realm refuses it.
_relay_apply_rule() {   # <rule json> <as_json> <status> <open_firewall>
    local rule="$1" as_json="$2" status="$3" open_fw="$4"
    local tag prev port proto udp
    tag=$(printf '%s' "$rule" | jq -r '.tag')
    prev=$(_realm_load)
    port=$(printf '%s' "$rule" | jq -r '.listen_port')
    udp=$(printf '%s' "$rule" | jq -r '.udp')
    [[ "$udp" == "true" ]] && proto=both || proto=tcp

    # Something else already holding the port is the common way for a rule to
    # be dead on arrival, and realm will not say so loudly enough (see below).
    # A rule that already listens there is realm's own: on a change that keeps
    # the port, realm is the listener, so only a port no rule used counts.
    if ! printf '%s' "$prev" | jq -e --argjson p "$port" 'any(.[]; .listen_port == $p)' >/dev/null 2>&1 \
       && _relay_port_bound "$port" tcp; then
        _relay_err "port $port is already in use on this machine; nothing changed"
        return 1
    fi

    _realm_upsert "$rule"
    if ! _realm_apply >&2; then
        _realm_save "$prev"
        _realm_apply >/dev/null 2>&1 || true
        _relay_err "realm did not accept the rule for $tag; nothing changed"
        return 1
    fi
    # The service being active is not enough (see _relay_port_bound): the port
    # has to be listening, or this rule is dead while everything reports well.
    local try
    for try in 1 2 3; do
        _relay_port_bound "$port" "$proto" && break
        [[ "$try" == 3 ]] || sleep 1
    done
    if ! _relay_port_bound "$port" "$proto"; then
        _realm_save "$prev"
        _realm_apply >/dev/null 2>&1 || true
        _relay_err "realm is running but is not listening on $port (is the port already in use?); nothing changed"
        return 1
    fi

    if [[ "$open_fw" == "1" ]]; then
        _relay_fw_open "$port" "$proto"
    fi
    # metering, so the panel can show what the hop carries
    _relay_meter_ensure "$tag" "$port"
    _relay_result "$status" "$rule" "$as_json"
}

# ── did the rule really take? ────────────────────────────────────────────────
# realm keeps running when a single endpoint cannot bind: it logs
# "[tcp]failed to bind 0.0.0.0:PORT: Address in use (os error 98)" and goes on
# serving the others. So a restart that leaves the service active is no proof
# that this rule took, and a relay that can never accept a connection would be
# reported as applied. The listening sockets are read straight from /proc, so
# this needs neither ss nor netstat and behaves the same on Debian, Alpine and
# Red Hat.
#
# It answers "is anything listening there", not "is realm listening there": the
# process squatting the port would otherwise make the check pass. That is why
# the port is also checked for a squatter before the rule is applied.
_relay_port_bound() {   # <port> <tcp|udp|both>
    local port="$1" want="$2" hex p ok=1
    hex=$(printf '%04X' "$port")
    for p in tcp udp; do
        [[ "$want" == both || "$want" == "$p" ]] || continue
        if [[ "$p" == tcp ]]; then
            # 0A is TCP_LISTEN; a connected socket on the same port is not a listener
            awk -v p=":${hex}\$" '$4 == "0A" && toupper($2) ~ p { f = 1 } END { exit !f }' \
                /proc/net/tcp /proc/net/tcp6 2>/dev/null || ok=0
        else
            awk -v p=":${hex}\$" 'toupper($2) ~ p { f = 1 } END { exit !f }' \
                /proc/net/udp /proc/net/udp6 2>/dev/null || ok=0
        fi
    done
    [[ "$ok" == 1 ]]
}

# ── the firewall, the way nodes do it ────────────────────────────────────────
# A port this opened is written down in $CFG_DIR/firewall-ports, and only a
# port written down there is ever closed again: a port the user opened for
# something else of their own must survive a relay being deleted.
_RELAY_FW_LEDGER="$CFG_DIR/firewall-ports"

_relay_fw_open() {   # <port> <tcp|udp|both>
    local port="$1" want="$2" p
    declare -f firewall_backend &>/dev/null || source "$LIB_DIR/system.sh"
    [[ -n "$(firewall_backend)" ]] || return 0   # nothing enforces: nothing to open
    for p in tcp udp; do
        [[ "$want" == both || "$want" == "$p" ]] || continue
        grep -qx "$port/$p" "$_RELAY_FW_LEDGER" 2>/dev/null && continue
        firewall_port_allowed "$port" "$p" && continue
        if firewall_open_port "$port" "$p" >&2; then
            mkdir -p "$CFG_DIR" && printf '%s/%s\n' "$port" "$p" >> "$_RELAY_FW_LEDGER"
        else
            _relay_err "warning: could not open $p/$port in the firewall; the relay is not reachable until it is open"
        fi
    done
    return 0
}

_relay_fw_close() {   # <port>: only what this opened, and only if no rule still uses it
    local port="$1" p others
    [[ -s "$_RELAY_FW_LEDGER" ]] || return 0
    grep -q "^$port/" "$_RELAY_FW_LEDGER" || return 0
    others=$(_realm_load | jq --argjson p "$port" '[.[] | select(.listen_port == $p)] | length' 2>/dev/null)
    [[ "$others" == 0 ]] || return 0
    declare -f firewall_close_port &>/dev/null || source "$LIB_DIR/system.sh"
    for p in tcp udp; do
        grep -qx "$port/$p" "$_RELAY_FW_LEDGER" || continue
        firewall_close_port "$port" "$p" >/dev/null 2>&1 || true
        sed -i "\|^$port/$p\$|d" "$_RELAY_FW_LEDGER"
    done
    return 0
}

# ── how the hop is doing ─────────────────────────────────────────────────────
# Round trip, jitter and loss are measured with plain TCP connects to the
# landing side, not with ping: ICMP is filtered often enough on these networks
# that ping would report loss that is not there, and a relay carries TCP
# anyway, so a connect is what the traffic actually experiences.
#
# Jitter here is the mean absolute difference between consecutive round trips
# over the burst — the same quantity RFC 3550 keeps a running estimate of.
_RELAY_PROBE_SAMPLES=5
_RELAY_PROBE_TIMEOUT=3

# One TCP connect, in milliseconds; nothing at all when it did not connect.
# curl measures the connect itself (and honours a connect timeout), so it is
# used when it speaks telnet://; bash's own /dev/tcp is the fallback, wrapped
# in `timeout` because a filtered port would otherwise hang for minutes.
_relay_connect_ms() {   # <host> <port>
    local host="$1" port="$2" t s e
    local LC_ALL=C
    if [[ "${_RELAY_CURL_TELNET:-}" == "" ]]; then
        curl --version 2>/dev/null | grep -qw telnet && _RELAY_CURL_TELNET=1 || _RELAY_CURL_TELNET=0
    fi
    if [[ "$_RELAY_CURL_TELNET" == 1 ]]; then
        t=$(curl -sS -o /dev/null --connect-timeout "$_RELAY_PROBE_TIMEOUT" \
                 --max-time "$_RELAY_PROBE_TIMEOUT" -w '%{time_connect}' \
                 "telnet://${host}:${port}" </dev/null 2>/dev/null)
        case "$t" in ''|0|0.000000) return 1 ;; esac
        awk -v t="$t" 'BEGIN { printf "%.2f\n", t * 1000 }'
        return 0
    fi
    s="$EPOCHREALTIME"
    timeout "$_RELAY_PROBE_TIMEOUT" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null || return 1
    e="$EPOCHREALTIME"
    awk -v s="$s" -v e="$e" 'BEGIN { printf "%.2f\n", (e - s) * 1000 }'
}

# ── metering, on the same chain the nodes use ────────────────────────────────
# A relay is metered by its listening port through PSM_TRF, exactly as a
# standalone node is. The tag is prefixed so it can never collide with a node's
# own tag in that chain.
_relay_meter_tag() { printf 'relay-%s' "$1"; }

_relay_meter_load() {
    declare -f _trf_ipt_ensure_rules &>/dev/null && return 0
    source "$LIB_DIR/traffic.sh" 2>/dev/null || return 1
}

_relay_meter_ensure() {   # <tag> <listen port>
    _relay_meter_load || return 0
    _trf_ipt_ensure_rules "$(_relay_meter_tag "$1")" "$2" >/dev/null 2>&1 || true
}

_relay_meter_remove() {   # <tag> <listen port>
    _relay_meter_load || return 0
    _trf_ipt_remove_rules "$(_relay_meter_tag "$1")" "$2" >/dev/null 2>&1 || true
}

# Bytes counted for this relay since the rules were put in place (cumulative:
# the panel turns consecutive readings into the traffic of an interval).
_relay_meter_bytes() {   # <tag>
    _relay_meter_load || { echo 0; return 0; }
    _trf_ipt_query_bytes "$(_relay_meter_tag "$1")" 2>/dev/null || echo 0
}

# One rule's measurement, as a JSON object.
_relay_probe_one() {   # <rule json> <samples>
    local rule="$1" n="$2" tag host port i ms
    tag=$(printf '%s' "$rule" | jq -r '.tag')
    host=$(printf '%s' "$rule" | jq -r '.remote_host')
    port=$(printf '%s' "$rule" | jq -r '.remote_port')

    local -a rtts=()
    local sent=0 lost=0
    for ((i = 0; i < n; i++)); do
        sent=$((sent + 1))
        if ms=$(_relay_connect_ms "$host" "$port"); then
            rtts+=("$ms")
        else
            lost=$((lost + 1))
        fi
    done

    local rtt_avg=null rtt_min=null rtt_max=null jitter=null
    if (( ${#rtts[@]} > 0 )); then
        rtt_avg=$(printf '%s\n' "${rtts[@]}" | awk '{ s += $1 } END { printf "%.2f", s / NR }')
        rtt_min=$(printf '%s\n' "${rtts[@]}" | awk 'NR == 1 || $1 < m { m = $1 } END { printf "%.2f", m }')
        rtt_max=$(printf '%s\n' "${rtts[@]}" | awk '$1 > m { m = $1 } END { printf "%.2f", m }')
        if (( ${#rtts[@]} > 1 )); then
            jitter=$(printf '%s\n' "${rtts[@]}" | awk '
                NR > 1 { d = $1 - p; if (d < 0) d = -d; s += d; c++ }
                { p = $1 }
                END { printf "%.2f", (c ? s / c : 0) }')
        else
            jitter=0
        fi
    fi
    local loss; loss=$(awk -v l="$lost" -v s="$sent" 'BEGIN { printf "%.1f", s ? l * 100 / s : 0 }')

    jq -nc --arg tag "$tag" --arg host "$host" --argjson port "$port" \
        --argjson rtt "$rtt_avg" --argjson min "$rtt_min" --argjson max "$rtt_max" \
        --argjson jitter "$jitter" --argjson loss "$loss" \
        --argjson sent "$sent" --argjson bytes "$(_relay_meter_bytes "$tag")" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        { tag: $tag, remote_host: $host, remote_port: $port,
          rtt_ms: $rtt, rtt_min_ms: $min, rtt_max_ms: $max, jitter_ms: $jitter,
          loss_pct: $loss, samples: $sent, bytes: $bytes, at: $at }'
}

_relay_cmd_probe() {
    local as_json=0 one="" n="$_RELAY_PROBE_SAMPLES"
    while (( $# )); do
        case "$1" in
            --json) as_json=1; shift ;;
            --samples)
                [[ $# -ge 2 ]] || { _relay_err '--samples requires a number'; return 2; }
                n="$2"
                [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 20 )) || { _relay_err '--samples must be 1-20'; return 2; }
                shift 2 ;;
            -*) _relay_err "unknown option: $1"; return 2 ;;
            *) one="$1"; shift ;;
        esac
    done
    _relay_load_realm
    local rules; rules=$(_realm_load)
    [[ -n "$one" ]] && rules=$(printf '%s' "$rules" | jq -c --arg t "$one" '[.[] | select(.tag == $t)]')
    if [[ -n "$one" ]] && [[ "$(printf '%s' "$rules" | jq 'length')" == 0 ]]; then
        _relay_err "no such relay: $one"; return 1
    fi

    local items="[]" rule item
    while IFS= read -r rule; do
        [[ -n "$rule" ]] || continue
        item=$(_relay_probe_one "$rule" "$n") || continue
        items=$(jq -c --argjson i "$item" '. + [$i]' <<<"$items")
    done < <(printf '%s' "$rules" | jq -c '.[]')

    if (( as_json )); then
        jq -nc --argjson v "$_RELAY_CLI_VERSION" --argjson items "$items" \
            '{api_version: $v, count: ($items | length), items: $items}'
    else
        printf '%s' "$items" | jq -r '.[] |
            "\(.tag)\t\(.remote_host):\(.remote_port)\t\(if .rtt_ms == null then "unreachable" else "\(.rtt_ms) ms" end)\tjitter \(.jitter_ms // 0) ms\tloss \(.loss_pct)%\t\(.bytes) bytes"'
    fi
}

# ── list / show ──────────────────────────────────────────────────────────────
_relay_cmd_list() {
    local as_json=0
    while (( $# )); do
        case "$1" in
            --json) as_json=1; shift ;;
            *) _relay_err "unknown option: $1"; return 2 ;;
        esac
    done
    _relay_load_realm
    local rules; rules=$(_realm_load)
    if (( as_json )); then
        printf '%s' "$rules" | jq -c --argjson v "$_RELAY_CLI_VERSION" \
            '{api_version:$v, count:length, items:.}'
        return 0
    fi
    printf '%-20s %-8s %-28s %-8s %s\n' TAG LISTEN REMOTE PROTO TLS
    printf '%s' "$rules" | jq -r '.[] |
        [.tag, (.listen_port|tostring), (.remote_host + ":" + (.remote_port|tostring)),
         (if .udp then "tcp+udp" else "tcp" end),
         (if (.tls // false) then (if (.tls_cert // "") != "" then "terminate" else "dial" end) else "-" end)]
        | @tsv' 2>/dev/null | while IFS=$'\t' read -r t l r p s; do
        printf '%-20s %-8s %-28s %-8s %s\n' "$t" "$l" "$r" "$p" "$s"
    done
}

_relay_cmd_show() {
    local tag="${1:-}"; shift || true
    local as_json=0
    while (( $# )); do
        case "$1" in
            --json) as_json=1; shift ;;
            *) _relay_err "unknown option: $1"; return 2 ;;
        esac
    done
    [[ -n "$tag" && "$tag" != --* ]] || { _relay_err 'show requires TAG'; return 2; }
    _relay_load_realm
    local rule; rule=$(_realm_get_by_tag "$tag")
    [[ -n "$rule" && "$rule" != "null" ]] || { _relay_err "no such relay: $tag"; return 1; }
    if (( as_json )); then
        printf '%s' "$rule" | jq -c --argjson v "$_RELAY_CLI_VERSION" '{api_version:$v, item:.}'
    else
        printf '%s' "$rule" | jq -r 'to_entries[] | "\(.key): \(.value)"'
    fi
}

# ── the TLS half of a rule ───────────────────────────────────────────────────
# Which side this rule is depends on where it forwards: to this machine
# (127.0.0.1 / ::1 / localhost) it terminates TLS, anywhere else it dials.
_relay_is_local_addr() {   # <host>: an address of this machine (so the hop ends here)
    local h="$1"
    case "$h" in 127.0.0.1|::1|localhost) return 0 ;; esac
    # A landing rule often names the machine's own public address rather than
    # the loopback; treating that as the dialling side would ask for an SNI and
    # write the wrong half of the pair.
    ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$h"
}

# realm's transport options are one `;`-separated string, and an option it
# cannot parse makes it panic rather than refuse the config (measured on 2.9.4:
# "tls;nosuchopt=1" panics in kaminari's opt.rs). So nothing with `;` or `=` may
# reach it from a name or a path.
_relay_tls_safe() {   # <what> <value>
    local what="$1" v="$2"
    case "$v" in
        *[';=']*) _relay_err "$what may not contain ';' or '=': $v"; return 1 ;;
    esac
}

_relay_tls_fields() {   # <remote_host> <sni> <cert> <key> <insecure> → json
    local rh="$1" sni="$2" cert="$3" key="$4" insecure="$5" pair
    local terminates=0
    _relay_tls_safe '--tls-sni' "$sni" || return 1
    _relay_tls_safe '--tls-cert' "$cert" || return 1
    _relay_tls_safe '--tls-key' "$key" || return 1
    _relay_is_local_addr "$rh" && terminates=1
    if (( terminates )); then
        [[ -n "$sni" ]] || sni=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo relay.local)
        if [[ -z "$cert" || -z "$key" ]]; then
            pair=$(_relay_self_signed "$sni") || return 1
            cert=${pair%%$'\t'*}; key=${pair#*$'\t'}
        fi
        [[ -s "$cert" && -s "$key" ]] || { _relay_err "certificate files not found: $cert $key"; return 1; }
        jq -nc --arg s "$sni" --arg c "$cert" --arg k "$key" \
            '{tls:true, tls_sni:$s, tls_cert:$c, tls_key:$k, tls_insecure:false}'
    else
        [[ -n "$sni" ]] || { _relay_err '--tls-sni is required when the hop dials TLS'; return 1; }
        jq -nc --arg s "$sni" --argjson i "$insecure" \
            '{tls:true, tls_sni:$s, tls_cert:"", tls_key:"", tls_insecure:$i}'
    fi
}

# ── add ──────────────────────────────────────────────────────────────────────
# A whole rule as JSON, the way `psm node add --input -` takes a node: the
# panel's agent hands one over on stdin rather than building a command line.
_relay_load_input() {   # <FILE|-|@FILE|JSON>
    local spec="$1" content
    case "$spec" in
        -) content=$(command cat) ;;
        @*) content=$(command cat "${spec#@}") || return 1 ;;
        *) if [[ -f "$spec" ]]; then content=$(command cat "$spec") || return 1; else content="$spec"; fi ;;
    esac
    printf '%s' "$content" | jq -e 'type == "object"' >/dev/null 2>&1 || {
        _relay_err 'input must be a JSON object'; return 1; }
    printf '%s' "$content" | jq -c '.'
}

_relay_cmd_add() {
    local tag="" lp="" rh="" rp="" udp="" tls="" sni="" cert="" key="" insecure=""
    local as_json=0 open_fw=1 input=""
    while (( $# )); do
        case "$1" in
            --input) [[ $# -ge 2 ]] || { _relay_err '--input requires FILE or -'; return 2; }; input="$2"; shift 2 ;;
            --data)  [[ $# -ge 2 ]] || { _relay_err '--data requires JSON or @FILE'; return 2; }; input="$2"; shift 2 ;;
            --tag) tag="${2:-}"; shift 2 ;;
            --listen-port) lp="${2:-}"; shift 2 ;;
            --remote-host) rh="${2:-}"; shift 2 ;;
            --remote-port) rp="${2:-}"; shift 2 ;;
            --udp) udp=true; shift ;;
            --tls) tls=true; shift ;;
            --tls-sni) sni="${2:-}"; shift 2 ;;
            --tls-cert) cert="${2:-}"; shift 2 ;;
            --tls-key) key="${2:-}"; shift 2 ;;
            --tls-insecure) insecure=true; shift ;;
            --no-firewall) open_fw=0; shift ;;
            --json) as_json=1; shift ;;
            *) _relay_err "unknown option: $1"; return 2 ;;
        esac
    done
    # the JSON first, then the options on top of it, as psm node add does
    local from='{}'
    [[ -n "$input" ]] && { from=$(_relay_load_input "$input") || return 2; }
    exec </dev/null
    local v
    v=$(printf '%s' "$from" | jq -r '.tag // ""');          [[ -n "$tag" ]] || tag="$v"
    v=$(printf '%s' "$from" | jq -r '.listen_port // ""');  [[ -n "$lp" ]] || lp="$v"
    v=$(printf '%s' "$from" | jq -r '.remote_host // ""');  [[ -n "$rh" ]] || rh="$v"
    v=$(printf '%s' "$from" | jq -r '.remote_port // ""');  [[ -n "$rp" ]] || rp="$v"
    v=$(printf '%s' "$from" | jq -r '.udp // ""');          [[ -n "$udp" ]] || udp="$v"
    v=$(printf '%s' "$from" | jq -r '.tls // ""');          [[ -n "$tls" ]] || tls="$v"
    v=$(printf '%s' "$from" | jq -r '.tls_sni // ""');      [[ -n "$sni" ]] || sni="$v"
    v=$(printf '%s' "$from" | jq -r '.tls_cert // ""');     [[ -n "$cert" ]] || cert="$v"
    v=$(printf '%s' "$from" | jq -r '.tls_key // ""');      [[ -n "$key" ]] || key="$v"
    v=$(printf '%s' "$from" | jq -r '.tls_insecure // ""'); [[ -n "$insecure" ]] || insecure="$v"
    udp=$(_relay_bool "${udp:-false}") || { _relay_err 'udp must be true or false'; return 2; }
    tls=$(_relay_bool "${tls:-false}") || { _relay_err 'tls must be true or false'; return 2; }
    insecure=$(_relay_bool "${insecure:-false}") || { _relay_err 'tls_insecure must be true or false'; return 2; }
    _relay_valid_tag "$tag" || { _relay_err 'a tag is required: letters, digits, . _ - (max 64)'; return 2; }
    _relay_valid_port "$lp" || { _relay_err '--listen-port must be 1-65535'; return 2; }
    _relay_valid_port "$rp" || { _relay_err '--remote-port must be 1-65535'; return 2; }
    [[ -n "$rh" ]] || { _relay_err '--remote-host is required'; return 2; }
    [[ $EUID -eq 0 ]] || { _relay_err 'must run as root'; return 1; }

    _relay_load_realm
    if _realm_load | jq -e --arg t "$tag" 'any(.[]; .tag == $t)' >/dev/null 2>&1; then
        _relay_err "a relay called $tag exists already; use update"; return 1
    fi
    if _realm_load | jq -e --argjson p "$lp" 'any(.[]; .listen_port == $p)' >/dev/null 2>&1; then
        _relay_err "another relay already listens on port $lp"; return 1
    fi
    _relay_ensure_realm || return 1

    local rule
    rule=$(jq -nc --arg tag "$tag" --argjson lp "$lp" --arg rh "$rh" --argjson rp "$rp" \
        --argjson udp "$udp" \
        '{tag:$tag, listen_port:$lp, remote_host:$rh, remote_port:$rp, udp:$udp,
          tls:false, tls_sni:"", tls_cert:"", tls_key:"", tls_insecure:false}') || return 1
    if [[ "$tls" == "true" ]]; then
        local tlsj; tlsj=$(_relay_tls_fields "$rh" "$sni" "$cert" "$key" "$insecure") || return 1
        rule=$(jq -nc --argjson r "$rule" --argjson t "$tlsj" '$r * $t') || return 1
    fi
    _relay_apply_rule "$rule" "$as_json" created "$open_fw"
}

# ── delete ───────────────────────────────────────────────────────────────────
_relay_cmd_delete() {
    local tag="${1:-}"; shift || true
    local yes=0 if_exists=0 as_json=0
    while (( $# )); do
        case "$1" in
            --yes|-y) yes=1; shift ;;
            --if-exists) if_exists=1; shift ;;
            --json) as_json=1; shift ;;
            *) _relay_err "unknown option: $1"; return 2 ;;
        esac
    done
    [[ -n "$tag" && "$tag" != --* ]] || { _relay_err 'delete requires TAG'; return 2; }
    (( yes )) || { _relay_err 'delete needs --yes'; return 2; }
    [[ $EUID -eq 0 ]] || { _relay_err 'must run as root'; return 1; }
    exec </dev/null

    _relay_load_realm
    local rule; rule=$(_realm_get_by_tag "$tag")
    if [[ -z "$rule" || "$rule" == "null" ]]; then
        (( if_exists )) && { _relay_result absent "$(jq -nc --arg t "$tag" '{tag:$t}')" "$as_json"; return 0; }
        _relay_err "no such relay: $tag"; return 1
    fi
    local port udp proto
    port=$(printf '%s' "$rule" | jq -r '.listen_port')
    udp=$(printf '%s' "$rule" | jq -r '.udp')
    [[ "$udp" == "true" ]] && proto=both || proto=tcp

    _realm_delete "$tag"
    _realm_apply >&2 || { _relay_err "realm did not reload after removing $tag"; return 1; }
    # after the rule has left the store, so _relay_fw_close sees the port free
    _relay_fw_close "$port"
    _relay_meter_remove "$tag" "$port"
    _relay_result deleted "$rule" "$as_json"
}

# ── update ───────────────────────────────────────────────────────────────────
_relay_cmd_update() {
    local tag="${1:-}"; shift || true
    local lp="" rh="" rp="" udp="" tls="" sni="" cert="" key="" insecure=""
    local as_json=0 seen=0 input=""
    while (( $# )); do
        case "$1" in
            --input) [[ $# -ge 2 ]] || { _relay_err '--input requires FILE or -'; return 2; }; input="$2"; shift 2 ;;
            --data)  [[ $# -ge 2 ]] || { _relay_err '--data requires JSON or @FILE'; return 2; }; input="$2"; shift 2 ;;
            --listen-port) lp="${2:-}"; seen=1; shift 2 ;;
            --remote-host) rh="${2:-}"; seen=1; shift 2 ;;
            --remote-port) rp="${2:-}"; seen=1; shift 2 ;;
            --udp) udp=$(_relay_bool "${2:-}") || { _relay_err '--udp must be true or false'; return 2; }; seen=1; shift 2 ;;
            --tls) tls=$(_relay_bool "${2:-}") || { _relay_err '--tls must be true or false'; return 2; }; seen=1; shift 2 ;;
            --tls-sni) sni="${2:-}"; seen=1; shift 2 ;;
            --tls-cert) cert="${2:-}"; seen=1; shift 2 ;;
            --tls-key) key="${2:-}"; seen=1; shift 2 ;;
            --tls-insecure) insecure=$(_relay_bool "${2:-}") || { _relay_err '--tls-insecure must be true or false'; return 2; }; seen=1; shift 2 ;;
            --json) as_json=1; shift ;;
            *) _relay_err "unknown option: $1"; return 2 ;;
        esac
    done

    # A JSON body (how the agent sends a change) fills in whatever no flag set.
    # Unlike add, an empty string here means "leave this field alone", so a
    # boolean is normalised only when it was actually given.
    local from='{}' v
    if [[ -n "$input" ]]; then
        from=$(_relay_load_input "$input") || return 2
        v=$(printf '%s' "$from" | jq -r '.tag // ""')
        if [[ -n "$v" && -n "$tag" && "$v" != "$tag" ]]; then
            _relay_err "input renames $tag to $v; a relay cannot be renamed, delete and add instead"
            return 2
        fi
        [[ -n "$tag" || "$tag" == --* ]] || tag="$v"
        v=$(printf '%s' "$from" | jq -r '.listen_port // ""');  [[ -n "$lp" ]] || lp="$v"
        v=$(printf '%s' "$from" | jq -r '.remote_host // ""');  [[ -n "$rh" ]] || rh="$v"
        v=$(printf '%s' "$from" | jq -r '.remote_port // ""');  [[ -n "$rp" ]] || rp="$v"
        # jq's "//" stands in for false as well as for null, so a boolean has to
        # be read by asking whether its key is there at all: without this a
        # {"udp": false} could never turn UDP off again, only on.
        v=$(printf '%s' "$from" | jq -r 'if has("udp") then (.udp|tostring) else "" end');  [[ -n "$udp" ]] || udp="$v"
        v=$(printf '%s' "$from" | jq -r 'if has("tls") then (.tls|tostring) else "" end');  [[ -n "$tls" ]] || tls="$v"
        v=$(printf '%s' "$from" | jq -r '.tls_sni // ""');      [[ -n "$sni" ]] || sni="$v"
        v=$(printf '%s' "$from" | jq -r '.tls_cert // ""');     [[ -n "$cert" ]] || cert="$v"
        v=$(printf '%s' "$from" | jq -r '.tls_key // ""');      [[ -n "$key" ]] || key="$v"
        v=$(printf '%s' "$from" | jq -r 'if has("tls_insecure") then (.tls_insecure|tostring) else "" end'); [[ -n "$insecure" ]] || insecure="$v"
        [[ -n "$udp" ]]      && { udp=$(_relay_bool "$udp")           || { _relay_err 'udp must be true or false'; return 2; }; }
        [[ -n "$tls" ]]      && { tls=$(_relay_bool "$tls")           || { _relay_err 'tls must be true or false'; return 2; }; }
        [[ -n "$insecure" ]] && { insecure=$(_relay_bool "$insecure") || { _relay_err 'tls_insecure must be true or false'; return 2; }; }
        for v in "$lp" "$rh" "$rp" "$udp" "$tls" "$sni" "$cert" "$key" "$insecure"; do
            [[ -n "$v" ]] && { seen=1; break; }
        done
    fi

    [[ -n "$tag" && "$tag" != --* ]] || { _relay_err 'update requires TAG'; return 2; }
    (( seen )) || { _relay_err 'update needs at least one field to change'; return 2; }
    [[ $EUID -eq 0 ]] || { _relay_err 'must run as root'; return 1; }
    exec </dev/null

    _relay_load_realm
    local old; old=$(_realm_get_by_tag "$tag")
    [[ -n "$old" && "$old" != "null" ]] || { _relay_err "no such relay: $tag"; return 1; }

    [[ -n "$lp" ]] && { _relay_valid_port "$lp" || { _relay_err '--listen-port must be 1-65535'; return 2; }; }
    [[ -n "$rp" ]] && { _relay_valid_port "$rp" || { _relay_err '--remote-port must be 1-65535'; return 2; }; }
    if [[ -n "$lp" ]] && _realm_load | jq -e --arg t "$tag" --argjson p "$lp" \
        'any(.[]; .tag != $t and .listen_port == $p)' >/dev/null 2>&1; then
        _relay_err "another relay already listens on port $lp"; return 1
    fi

    local new="$old" patch
    patch=$(jq -nc --arg lp "$lp" --arg rh "$rh" --arg rp "$rp" --arg udp "$udp" \
        --arg tls "$tls" --arg sni "$sni" --arg cert "$cert" --arg key "$key" --arg ins "$insecure" '
        {} | (if $lp  != "" then .listen_port  = ($lp|tonumber) else . end)
           | (if $rh  != "" then .remote_host  = $rh            else . end)
           | (if $rp  != "" then .remote_port  = ($rp|tonumber) else . end)
           | (if $udp != "" then .udp          = ($udp == "true") else . end)
           | (if $sni != "" then .tls_sni      = $sni           else . end)
           | (if $cert != "" then .tls_cert    = $cert          else . end)
           | (if $key != "" then .tls_key      = $key           else . end)
           | (if $ins != "" then .tls_insecure = ($ins == "true") else . end)') || return 1
    new=$(jq -nc --argjson o "$old" --argjson p "$patch" '$o * $p') || return 1

    # Turning TLS on (or moving the hop to another host) recomputes which side
    # this rule is: a certificate belongs to the side that terminates.
    if [[ "$tls" == "false" ]]; then
        new=$(printf '%s' "$new" | jq -c '.tls=false | .tls_sni="" | .tls_cert="" | .tls_key="" | .tls_insecure=false') || return 1
    elif [[ "$tls" == "true" || ( -n "$rh" && "$(printf '%s' "$new" | jq -r '.tls // false')" == "true" ) ]]; then
        local host s c k i tlsj
        host=$(printf '%s' "$new" | jq -r '.remote_host')
        s=$(printf '%s' "$new" | jq -r '.tls_sni // ""')
        c=$(printf '%s' "$new" | jq -r '.tls_cert // ""')
        k=$(printf '%s' "$new" | jq -r '.tls_key // ""')
        i=$(printf '%s' "$new" | jq -r '.tls_insecure // false')
        tlsj=$(_relay_tls_fields "$host" "$s" "$c" "$k" "$i") || return 1
        new=$(jq -nc --argjson r "$new" --argjson t "$tlsj" '$r * $t') || return 1
    fi

    if jq -e --argjson a "$old" --argjson b "$new" -n '$a == $b' >/dev/null; then
        _relay_result unchanged "$old" "$as_json"; return 0
    fi

    # only the port is needed: _relay_fw_close closes whichever of tcp/udp this
    # relay had actually written into the ledger, and leaves the rest alone
    local old_port
    old_port=$(printf '%s' "$old" | jq -r '.listen_port')

    _relay_apply_rule "$new" "$as_json" updated 1 || return 1
    # the old port closes only once the new rule is live, and only if this
    # opened it and no other rule still listens there
    if [[ -n "$lp" && "$lp" != "$old_port" ]]; then
        _relay_fw_close "$old_port"
        # the old port's accounting rules would otherwise keep counting for a
        # port this relay no longer listens on
        _relay_meter_remove "$tag" "$old_port"
    fi
}

# ── install ──────────────────────────────────────────────────────────────────
# realm itself, without questions: the panel's agent calls this before its
# first rule, the way it installs a core before the first node.
_relay_ensure_realm() {
    _relay_load_realm
    [[ -x "$REALM_BIN" ]] && return 0
    realm_install_unattended >&2 || { _relay_err 'could not install realm'; return 1; }
    [[ -x "$REALM_BIN" ]] || { _relay_err "realm is still missing: $REALM_BIN"; return 1; }
}

_relay_cmd_install() {
    local as_json=0
    while (( $# )); do
        case "$1" in
            --json) as_json=1; shift ;;
            *) _relay_err "unknown option: $1"; return 2 ;;
        esac
    done
    [[ $EUID -eq 0 ]] || { _relay_err 'must run as root'; return 1; }
    exec </dev/null
    _relay_ensure_realm || return 1
    local ver; ver=$("$REALM_BIN" --version 2>/dev/null | head -1)
    if (( as_json )); then
        jq -nc --arg v "$ver" --arg b "$REALM_BIN" --argjson ver "$_RELAY_CLI_VERSION" \
            '{status:"installed", api_version:$ver, item:{binary:$b, version:$v}}'
    else
        printf 'installed: %s\n' "$ver"
    fi
}

# ── psm relay ────────────────────────────────────────────────────────────────
psm_relay_cli() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        list)    _relay_cmd_list "$@" ;;
        show)    _relay_cmd_show "$@" ;;
        add)     _relay_cmd_add "$@" ;;
        update)  _relay_cmd_update "$@" ;;
        delete)  _relay_cmd_delete "$@" ;;
        probe)   _relay_cmd_probe "$@" ;;
        install) _relay_cmd_install "$@" ;;
        help|--help|-h|"") _relay_usage ;;
        *) _relay_err "unknown command: $cmd"; _relay_usage >&2; return 2 ;;
    esac
}
