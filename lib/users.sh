#!/usr/bin/env bash
# users.sh — accounts on top of PSM's nodes (psm user …)
#
#   psm user add NAME [--nodes all|TAG,TAG] [--days N | --expires YYYY-MM-DD] [--quota SIZE] [--json]
#   psm user list [--json]
#   psm user show NAME [--json] [--show-secrets]
#   psm user update NAME [--nodes …] [--days N | --expires DATE | --no-expiry]
#                        [--quota SIZE | --no-quota] [--reset-usage] [--enable | --disable] [--json]
#   psm user delete NAME [--json]
#   psm user links NAME [--server ADDR]
#   psm user token NAME [--json]          new subscription URL; the old one stops working
#
# A user has one UUID and one password, used on every node assigned to them:
# VLESS / VMess / TUIC take the UUID; Trojan / Hysteria2 / AnyTLS / TUIC /
# SOCKS the password (SOCKS login psmu-NAME). The node's own credential stays
# as it is, so existing links keep working. Shadowsocks 2022, Snell and
# WireGuard stay single-key: users on an SS2022 server would change its
# owner's link.
#
# Accounts are merged into a core's config on every restart PSM does
# (xray_test_restart / sb_test_restart / mh_test_restart), after the node
# builders wrote their owner-only inbounds. Entries PSM added before carry the
# name psmu-NAME (Xray: email psmu-NAME@psm) and are replaced each time;
# mihomo's TUIC users are a {uuid: password} map, where everything after the
# owner's first entry is PSM's. Disabled, expired and over-quota users are
# left out.
#
# Xray counts traffic per user, so a quota counts a user's traffic through
# Xray nodes, per calendar month; reaching it pauses the account everywhere.
# sing-box and mihomo keep node-level quotas (psm traffic): neither exposes
# per-user counters.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

USERS_FILE="$CFG_DIR/users.json"
USERS_PREFIX="psmu-"

_users_err()  { printf 'psm user: %s\n' "$*" >&2; }
_users_usage() {
    cat <<'EOF'
Usage:
  psm user add NAME [--nodes all|TAG,TAG] [--days N | --expires YYYY-MM-DD] [--quota SIZE] [--json]
  psm user list [--json]
  psm user show NAME [--json] [--show-secrets]
  psm user update NAME [--nodes all|TAG,TAG] [--days N | --expires YYYY-MM-DD | --no-expiry]
                       [--quota SIZE | --no-quota] [--reset-usage] [--enable | --disable] [--json]
  psm user delete NAME [--json]
  psm user links NAME [--server ADDR]
  psm user token NAME [--json]

SIZE is bytes or a number with K, M, G or T (1G = 1024^3). A quota counts
the user's traffic through Xray nodes per calendar month.
EOF
}

# ── Store ─────────────────────────────────────────────────────────────────────
_users_load() { [[ -f "$USERS_FILE" ]] && jq -c '.' "$USERS_FILE" 2>/dev/null || echo '{"users":[]}'; }
_users_save() {
    mkdir -p "$(dirname "$USERS_FILE")"
    local tmp; tmp=$(mktemp)
    printf '%s' "$1" | jq '.' > "$tmp" && [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"; mv -f "$tmp" "$USERS_FILE"
}
_users_get() { _users_load | jq -c --arg n "$1" '.users[]? | select(.name == $n)'; }

_users_valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; }

_users_size() {   # 50G / 500M / 1T / bytes → bytes
    local v="${1^^}" n u
    [[ "$v" =~ ^([0-9]+)([KMGT]?)B?$ ]] || return 1
    n=${BASH_REMATCH[1]}; u=${BASH_REMATCH[2]}
    case "$u" in K) n=$((n * 1024)) ;; M) n=$((n * 1024 ** 2)) ;; G) n=$((n * 1024 ** 3)) ;; T) n=$((n * 1024 ** 4)) ;; esac
    printf '%s' "$n"
}

_users_date() {   # YYYY-MM-DD → end of that day, epoch
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    date -d "$1 23:59:59" +%s 2>/dev/null
}

_users_nodes_arg() {   # all | TAG,TAG → JSON array
    if [[ "$1" == all || "$1" == "*" ]]; then echo '["*"]'; return 0; fi
    jq -cn --arg s "$1" '$s | split(",") | map(gsub("^ +| +$"; "")) | map(select(length > 0))'
}

# Users that go into the cores right now.
_users_active_json() {
    [[ -f "$USERS_FILE" ]] || { echo '[]'; return 0; }
    jq -c --argjson now "$(date +%s)" '[.users[]?
        | select(.enabled != false)
        | select(.expires_at == null or .expires_at > $now)
        | select(.quota_bytes == null or (.used_bytes // 0) < .quota_bytes)
        | {name, uuid, password, nodes: (.nodes // ["*"])}]' "$USERS_FILE"
}

_users_state() {   # user JSON → active / disabled / expired / over_quota
    jq -r --argjson now "$(date +%s)" '
        if .enabled == false then "disabled"
        elif (.expires_at != null and .expires_at <= $now) then "expired"
        elif (.quota_bytes != null and (.used_bytes // 0) >= .quota_bytes) then "over_quota"
        else "active" end' <<<"$1"
}

# ── Merge into the cores' configs ─────────────────────────────────────────────
# Owner credentials → node tag, so an inbound shared by several nodes (Xray
# REALITY on one port) still gets the users of each of them.
_users_owner_map() {
    source "$LIB_DIR/node_cli.sh"
    _node_cli_collect "" "" 2>/dev/null | jq -c '[.[] | .node as $n
        | (($n.uuid // empty), ($n.password // empty)) | select(type == "string" and . != "")
        | {key: ., value: $n.tag}] | from_entries' 2>/dev/null || echo '{}'
}

_USERS_JQ_DEFS='
def mark: "'"$USERS_PREFIX"'" + .name;
def assigned($tags): . as $u
    | (($u.nodes | index("*")) != null) or any($tags[]; . as $t | ($u.nodes | index($t)) != null);
def psm_added: (. // "") | tostring | startswith("'"$USERS_PREFIX"'");
'

_USERS_JQ_XRAY='
.inbounds |= map(
  if ((.protocol // "") | IN("vless", "vmess", "trojan", "hysteria"))
     or (.protocol == "socks" and ([(.settings.accounts // [])[] | select(.user | psm_added | not)] | length) > 0) then
    . as $in
    | ([.tag] + ([((.settings.clients // [])[] | (.id // .password // .auth // empty)),
                  ((.settings.accounts // [])[] | (.pass // empty))] | map($owners[.] // empty))) as $tags
    | [$users[] | select(assigned($tags))] as $mine
    | if .protocol == "socks" then
        .settings.accounts = ([.settings.accounts[] | select(.user | psm_added | not)]
                              + [$mine[] | {user: mark, pass: .password}])
      else
        .settings.clients = [(.settings.clients // [])[] | select(.email | psm_added | not)]
        | if .protocol == "vless" then
            .settings.clients += [$mine[] | {id: .uuid, flow: ($in.settings.clients[0].flow // ""), email: (mark + "@psm")}]
          elif .protocol == "vmess" then .settings.clients += [$mine[] | {id: .uuid, email: (mark + "@psm")}]
          elif .protocol == "trojan" then .settings.clients += [$mine[] | {password: .password, email: (mark + "@psm")}]
          else .settings.clients += [$mine[] | {auth: .password, email: (mark + "@psm")}] end
      end
  else . end)
| if ($users | length) > 0 then
    .policy.levels."0" = ((.policy.levels."0" // {}) + {statsUserUplink: true, statsUserDownlink: true})
  else . end'

_USERS_JQ_SB='
.inbounds |= map(
  if ((.type // "") | IN("vless", "vmess", "trojan", "hysteria2", "anytls", "tuic"))
     or (.type == "socks" and ([(.users // [])[] | select(.username | psm_added | not)] | length) > 0) then
    . as $in
    | ([.tag] + ([(.users // [])[] | (.uuid // .password // empty)] | map($owners[.] // empty))) as $tags
    | [$users[] | select(assigned($tags))] as $mine
    | .users = [(.users // [])[] | select((.name // .username) | psm_added | not)]
    | if .type == "vless" then
        .users += [$mine[] | ({name: mark, uuid: .uuid}
                              + (if ($in.users[0].flow // "") != "" then {flow: $in.users[0].flow} else {} end))]
      elif .type == "vmess" then .users += [$mine[] | {name: mark, uuid: .uuid, alterId: 0}]
      elif .type == "tuic"  then .users += [$mine[] | {name: mark, uuid: .uuid, password: .password}]
      elif .type == "socks" then .users += [$mine[] | {username: mark, password: .password}]
      else .users += [$mine[] | {name: mark, password: .password}] end
  else . end)'

_USERS_JQ_MH='
.listeners |= map(
  if ((.type // "") | IN("vless", "vmess", "trojan", "hysteria2", "anytls", "tuic"))
     or (.type == "socks" and ([(.users // [])[] | select(.username | psm_added | not)] | length) > 0) then
    . as $in
    | ((if (.users | type) == "object" then [.users | to_entries[] | .key, .value]
        else [(.users // [])[] | (.uuid // .password // empty)] end) | map($owners[.] // empty)) as $o
    | ([.name] + $o) as $tags
    | [$users[] | select(assigned($tags))] as $mine
    | if (.users | type) == "object" then
        if .type == "tuic" then
          .users = ((.users | to_entries | .[0:1] | from_entries) + ([$mine[] | {key: .uuid, value: .password}] | from_entries))
        else
          .users = ((.users | with_entries(select(.key | psm_added | not))) + ([$mine[] | {key: mark, value: .password}] | from_entries))
        end
      else
        .users = [(.users // [])[] | select(.username | psm_added | not)]
        | if .type == "vless" then
            .users += [$mine[] | ({username: mark, uuid: .uuid}
                                  + (if ($in.users[0].flow // "") != "" then {flow: $in.users[0].flow} else {} end))]
          elif .type == "vmess" then .users += [$mine[] | {username: mark, uuid: .uuid, alterId: 0}]
          else .users += [$mine[] | {username: mark, password: .password}] end
      end
  else . end)'

# psm_users_inject <xray|sing-box|mihomo>: puts the current accounts into that
# core's config, in place. Called by the core's restart path before its check.
psm_users_inject() {
    local core="$1" cfg filter
    case "$core" in
        xray)     cfg="$XRAY_CFG_DIR/config.json";    filter="$_USERS_JQ_XRAY" ;;
        sing-box) cfg="$SINGBOX_CFG_DIR/config.json"; filter="$_USERS_JQ_SB" ;;
        mihomo)   cfg="$MIHOMO_CFG_DIR/config.yaml";  filter="$_USERS_JQ_MH" ;;
        *) return 0 ;;
    esac
    [[ -f "$cfg" ]] || return 0
    # nothing to add and nothing of ours to remove
    [[ -f "$USERS_FILE" ]] || grep -q "$USERS_PREFIX" "$cfg" 2>/dev/null || return 0
    local users owners tmp
    users=$(_users_active_json) || users='[]'
    owners=$(_users_owner_map)
    tmp=$(mktemp)
    if jq --argjson users "$users" --argjson owners "$owners" "$_USERS_JQ_DEFS $filter" "$cfg" > "$tmp" 2>/dev/null \
        && [[ -s "$tmp" ]]; then
        # unchanged: leave it; changed: cat keeps the file's owner and mode
        [[ "$(cksum < "$tmp")" == "$(cksum < "$cfg")" ]] || cat "$tmp" > "$cfg"
    fi
    rm -f "$tmp"
    return 0
}

_users_core_installed() {
    case "$1" in
        xray)     [[ -x "$XRAY_BIN" && -f "$XRAY_CFG_DIR/config.json" ]] ;;
        sing-box) [[ -x "$SINGBOX_BIN" && -f "$SINGBOX_CFG_DIR/config.json" ]] ;;
        mihomo)   [[ -x "$MIHOMO_BIN" && -f "$MIHOMO_CFG_DIR/config.yaml" ]] ;;
    esac
}

# Restart every installed core through its own path (which merges the users),
# then bring the per-user subscriptions up to date.
users_apply() {
    local core rc=0 u
    u=$(_users_load)
    # Xray counts each account from the start (a quota set later must see the
    # traffic before it); expiry and quotas need the periodic check
    if jq -e '(.users // []) | length > 0' <<<"$u" >/dev/null 2>&1 && _users_core_installed xray; then
        ( source "$LIB_DIR/traffic.sh"; _trf_stats_enabled || _trf_enable_stats ) >/dev/null 2>&1 || true
    fi
    if jq -e '[.users[]? | (.quota_bytes != null or .expires_at != null)] | any' <<<"$u" >/dev/null 2>&1; then
        ( source "$LIB_DIR/traffic.sh"; _trf_timer_active || _trf_install_timer ) >/dev/null 2>&1 || true
    fi
    for core in xray sing-box mihomo; do
        _users_core_installed "$core" || continue
        if ! ( case "$core" in
                   xray)     source "$LIB_DIR/xray/core.sh";    xray_test_restart ;;
                   sing-box) source "$LIB_DIR/singbox/core.sh"; sb_test_restart ;;
                   mihomo)   source "$LIB_DIR/mihomo/core.sh";  mh_test_restart ;;
               esac ) >&2; then
            _users_err "$core did not accept the accounts; its previous config was restored"; rc=1
        fi
    done
    _users_save "$(_users_load | jq --argjson a "$(_users_active_json | jq -c '[.[].name]')" '.applied = $a')" || true
    _users_online_refresh
    return "$rc"
}

# ── Per-user links and subscriptions ──────────────────────────────────────────
# Prints the share links of one user (their credentials, their nodes).
_users_links() {   # <user JSON> <server>
    local user="$1" server="$2"
    source "$LIB_DIR/subscribe.sh"
    _SUB_USER="$user" _sub_collect_uris "$server"
}

_users_online_domain() { ( source "$LIB_DIR/subscribe.sh"; _sub_state_get '.domain' ) 2>/dev/null; }

_users_online_url() {   # <user JSON> → URL, or nothing when online subscriptions are off
    local d; d=$(_users_online_domain)
    [[ -n "$d" ]] || return 0
    printf 'https://%s/psm-sub/%s/sub.txt' "$d" "$(jq -r '.token' <<<"$1")"
}

# Rewrites the subscription of every active user; removes those of the others.
_users_online_refresh() {
    local domain server u tok
    domain=$(_users_online_domain)
    [[ -n "$domain" ]] || return 0
    ( source "$LIB_DIR/subscribe.sh"
      server=$(_sub_state_get '.server'); [[ -n "$server" ]] || server=$(get_ipv4 2>/dev/null || echo "$domain")
      active=$(_users_active_json | jq -r '.[].name')
      while IFS= read -r u; do
          [[ -n "$u" ]] || continue
          tok=$(jq -r '.token' <<<"$u")
          if grep -qxF "$(jq -r '.name' <<<"$u")" <<<"$active"; then
              _SUB_USER="$u" _sub_online_write "$tok" "$domain" "$server" || true
          else
              rm -rf "$(_sub_token_dir "$tok")"
          fi
      done < <(_users_load | jq -c '.users[]?') ) >/dev/null 2>&1 || true
    return 0
}

# ── Periodic check (traffic_check, every minute) ──────────────────────────────
# Adds this month's Xray traffic to each user, then re-applies when the set of
# active users differs from the one last applied (expiry, quota, month rollover).
users_check() {
    [[ -f "$USERS_FILE" ]] || return 0
    local month st
    month=$(date +%Y-%m)
    st=$(_users_load | jq -c --arg m "$month" '.users |= map(
        if (.used_month // "") != $m then .used_bytes = 0 | .used_month = $m else . end)')
    if _users_core_installed xray; then
        local q
        q=$( source "$LIB_DIR/traffic.sh" 2>/dev/null
             "$XRAY_BIN" api statsquery -s "$XRAY_API_ADDR" -pattern "user>>>${USERS_PREFIX}" -reset 2>/dev/null ) || q=""
        if [[ -n "$q" ]]; then
            st=$(jq -c --argjson q "$(jq -c '[.stat[]? | {n: (.name | split(">>>")[1] | sub("@psm$"; "")), v: ((.value // 0) | tonumber)}]' <<<"$q" 2>/dev/null || echo '[]')" \
                --arg p "$USERS_PREFIX" '
                .users |= map(. as $u
                    | .used_bytes = ((.used_bytes // 0) + ([$q[] | select(.n == ($p + $u.name)) | .v] | add // 0)))' <<<"$st")
        fi
    fi
    _users_save "$st" || return 0
    local now_active applied
    now_active=$(_users_active_json | jq -c '[.[].name]')
    applied=$(_users_load | jq -c '.applied // []')
    [[ "$now_active" == "$applied" ]] || users_apply >/dev/null 2>&1 || true
    return 0
}

# ── CLI ───────────────────────────────────────────────────────────────────────
_users_redact() { if [[ "$1" == 1 ]]; then cat; else jq -c '.uuid = "***" | .password = "***" | .token = "***"'; fi; }

_users_view() {   # <user JSON> <show secrets 0|1> → JSON with state and URL
    local u="$1"
    jq -c --arg s "$(_users_state "$u")" --arg url "$(_users_online_url "$u")" \
        '. + {state: $s, subscription: (if $url == "" then null else $url end)}' <<<"$u" | _users_redact "$2"
}

_users_print() {   # <view JSON>: one user, for people
    jq -r '
        def gib: if . == null then "-" else ((. / 1073741824 * 100 | round) / 100 | tostring) + " GiB" end;
        "  name          \(.name)",
        "  state         \(.state)",
        "  nodes         \(.nodes | join(","))",
        "  expires       \(if .expires_at == null then "never" else (.expires_at | strftime("%Y-%m-%d %H:%M UTC")) end)",
        "  quota         \(.quota_bytes | gib)   used this month: \(.used_bytes // 0 | gib)",
        "  uuid          \(.uuid)",
        "  password      \(.password)",
        "  subscription  \(.subscription // "online subscriptions are off (psm user links NAME prints the links)")"' <<<"$1"
}

_users_cmd_add() {
    local name="${1:-}" nodes='["*"]' exp="null" quota="null" json=0 v
    [[ -n "$name" && "$name" != -* ]] || { _users_usage >&2; return 2; }
    shift
    _users_valid_name "$name" || { _users_err "NAME: lowercase letters, digits, - and _ (up to 32)"; return 2; }
    while (( $# )); do
        case "$1" in
            --nodes)   [[ -n "${2:-}" ]] || { _users_usage >&2; return 2; }; nodes=$(_users_nodes_arg "$2"); shift 2; continue ;;
            --days)    [[ "${2:-}" =~ ^[0-9]+$ && "$2" -gt 0 ]] || { _users_err "--days needs a positive number"; return 2; }
                       exp=$(( $(date +%s) + $2 * 86400 )); shift 2; continue ;;
            --expires) v=$(_users_date "${2:-}") || { _users_err "--expires needs YYYY-MM-DD"; return 2; }; exp="$v"; shift 2; continue ;;
            --quota)   v=$(_users_size "${2:-}") || { _users_err "--quota needs a size such as 50G"; return 2; }; quota="$v"; shift 2; continue ;;
            --json) json=1 ;;
            *) _users_err "unknown option: $1"; return 2 ;;
        esac
        shift
    done
    [[ -z "$(_users_get "$name")" ]] || { _users_err "user $name already exists"; return 1; }
    local uuid pass tok user
    uuid=$(uuid_gen) && pass=$(rand_str 24) && tok=$(rand_str 48) || { _users_err "cannot generate credentials"; return 1; }
    user=$(jq -cn --arg n "$name" --arg u "$uuid" --arg p "$pass" --arg t "$tok" --argjson nodes "$nodes" \
        --argjson exp "$exp" --argjson q "$quota" --argjson now "$(date +%s)" --arg m "$(date +%Y-%m)" \
        '{name: $n, uuid: $u, password: $p, token: $t, nodes: $nodes, created_at: $now,
          expires_at: $exp, quota_bytes: $q, used_bytes: 0, used_month: $m, enabled: true}')
    _users_save "$(_users_load | jq -c --argjson u "$user" '.users += [$u]')" || { _users_err "cannot write $USERS_FILE"; return 1; }
    users_apply >/dev/null || true
    if (( json )); then jq -c '{status: "created", user: .}' <<<"$(_users_view "$user" 1)"
    else _users_print "$(_users_view "$user" 1)"; fi
}

_users_cmd_update() {
    local name="${1:-}" json=0 v
    [[ -n "$name" && "$name" != -* ]] || { _users_usage >&2; return 2; }
    shift
    local user; user=$(_users_get "$name")
    [[ -n "$user" ]] || { _users_err "no user $name"; return 1; }
    local f=''   # jq assignments collected from the options
    while (( $# )); do
        case "$1" in
            --nodes)       [[ -n "${2:-}" ]] || { _users_usage >&2; return 2; }; f+=" | .nodes = $(_users_nodes_arg "$2")"; shift 2; continue ;;
            --days)        [[ "${2:-}" =~ ^[0-9]+$ && "$2" -gt 0 ]] || { _users_err "--days needs a positive number"; return 2; }
                           f+=" | .expires_at = $(( $(date +%s) + $2 * 86400 ))"; shift 2; continue ;;
            --expires)     v=$(_users_date "${2:-}") || { _users_err "--expires needs YYYY-MM-DD"; return 2; }; f+=" | .expires_at = $v"; shift 2; continue ;;
            --no-expiry)   f+=' | .expires_at = null' ;;
            --quota)       v=$(_users_size "${2:-}") || { _users_err "--quota needs a size such as 50G"; return 2; }; f+=" | .quota_bytes = $v"; shift 2; continue ;;
            --no-quota)    f+=' | .quota_bytes = null' ;;
            --reset-usage) f+=' | .used_bytes = 0' ;;
            --enable)      f+=' | .enabled = true' ;;
            --disable)     f+=' | .enabled = false' ;;
            --json) json=1 ;;
            *) _users_err "unknown option: $1"; return 2 ;;
        esac
        shift
    done
    [[ -n "$f" ]] || { _users_err "nothing to change"; return 2; }
    user=$(jq -c ". ${f}" <<<"$user") || { _users_err "invalid change"; return 2; }
    _users_save "$(_users_load | jq -c --argjson u "$user" '.users |= map(if .name == $u.name then $u else . end)')" \
        || { _users_err "cannot write $USERS_FILE"; return 1; }
    users_apply >/dev/null || true
    if (( json )); then jq -c '{status: "updated", user: .}' <<<"$(_users_view "$user" 1)"
    else _users_print "$(_users_view "$user" 1)"; fi
}

_users_cmd_delete() {
    local name="${1:-}" json=0 user
    [[ -n "$name" && "$name" != -* ]] || { _users_usage >&2; return 2; }
    [[ "${2:-}" == --json ]] && json=1
    user=$(_users_get "$name")
    [[ -n "$user" ]] || { _users_err "no user $name"; return 1; }
    # the subscription goes first, so the link is dead even if a core restart fails
    ( source "$LIB_DIR/subscribe.sh"; rm -rf "$(_sub_token_dir "$(jq -r '.token' <<<"$user")")" ) 2>/dev/null || true
    _users_save "$(_users_load | jq -c --arg n "$name" '.users |= map(select(.name != $n))')" \
        || { _users_err "cannot write $USERS_FILE"; return 1; }
    users_apply >/dev/null || true
    if (( json )); then jq -cn --arg n "$name" '{status: "deleted", name: $n}'; else echo "deleted $name"; fi
}

_users_cmd_token() {
    local name="${1:-}" json=0 user old tok
    [[ -n "$name" && "$name" != -* ]] || { _users_usage >&2; return 2; }
    [[ "${2:-}" == --json ]] && json=1
    user=$(_users_get "$name")
    [[ -n "$user" ]] || { _users_err "no user $name"; return 1; }
    old=$(jq -r '.token' <<<"$user"); tok=$(rand_str 48) || return 1
    ( source "$LIB_DIR/subscribe.sh"; rm -rf "$(_sub_token_dir "$old")" ) 2>/dev/null || true
    user=$(jq -c --arg t "$tok" '.token = $t' <<<"$user")
    _users_save "$(_users_load | jq -c --argjson u "$user" '.users |= map(if .name == $u.name then $u else . end)')" || return 1
    _users_online_refresh
    local url; url=$(_users_online_url "$user")
    if (( json )); then jq -cn --arg n "$name" --arg u "$url" '{status: "rotated", name: $n, subscription: (if $u == "" then null else $u end)}'
    else echo "${url:-new token saved; online subscriptions are off}"; fi
}

_users_cmd_list() {
    local json=0; [[ "${1:-}" == --json ]] && json=1
    local all='[]' u
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        all=$(jq -c --argjson v "$(_users_view "$u" 0)" '. + [$v]' <<<"$all")
    done < <(_users_load | jq -c '.users[]?')
    if (( json )); then jq -c '{users: .}' <<<"$all"; return 0; fi
    [[ "$all" != '[]' ]] || { echo "no users"; return 0; }
    jq -r '
        def gib: if . == null then "-" else ((. / 1073741824 * 10 | round) / 10 | tostring) + "G" end;
        ["NAME", "STATE", "EXPIRES", "USED/QUOTA", "NODES"],
        (.[] | [.name, .state,
                (if .expires_at == null then "never" else (.expires_at | strftime("%Y-%m-%d")) end),
                ((.used_bytes // 0 | gib) + "/" + (.quota_bytes | gib)),
                (.nodes | join(","))])
        | @tsv' <<<"$all" | psm_table
}

_users_cmd_show() {
    local name="${1:-}" json=0 secrets=0 user
    [[ -n "$name" && "$name" != -* ]] || { _users_usage >&2; return 2; }
    shift
    while (( $# )); do
        case "$1" in --json) json=1 ;; --show-secrets) secrets=1 ;; *) _users_err "unknown option: $1"; return 2 ;; esac
        shift
    done
    user=$(_users_get "$name")
    [[ -n "$user" ]] || { _users_err "no user $name"; return 1; }
    if (( json )); then _users_view "$user" "$secrets"; else _users_print "$(_users_view "$user" 1)"; fi
}

_users_cmd_links() {
    local name="${1:-}" server="" user
    [[ -n "$name" && "$name" != -* ]] || { _users_usage >&2; return 2; }
    shift
    [[ "${1:-}" == --server ]] && server="${2:-}"
    user=$(_users_get "$name")
    [[ -n "$user" ]] || { _users_err "no user $name"; return 1; }
    [[ -n "$server" ]] || server=$(get_ipv4 2>/dev/null || true)
    [[ -n "$server" ]] || { _users_err "cannot detect this server's address; pass --server"; return 1; }
    _users_links "$user" "$server"
}

psm_users_cli() {
    command -v jq >/dev/null 2>&1 || { _users_err 'jq is required'; return 127; }
    local cmd="${1:-}"
    (( $# )) && shift
    case "$cmd" in
        add)    require_root; _users_cmd_add "$@" ;;
        update) require_root; _users_cmd_update "$@" ;;
        delete|remove|rm) require_root; _users_cmd_delete "$@" ;;
        token)  require_root; _users_cmd_token "$@" ;;
        list)   _users_cmd_list "$@" ;;
        show)   _users_cmd_show "$@" ;;
        links)  _users_cmd_links "$@" ;;
        help|--help|-h) _users_usage ;;
        *) _users_usage >&2; return 2 ;;
    esac
}
