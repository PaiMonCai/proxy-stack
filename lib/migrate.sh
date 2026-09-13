#!/usr/bin/env bash
# migrate.sh — move a PSM server to another host
#
#   psm migrate export [--output FILE] [--encrypt]
#   psm migrate import FILE [--yes] [--force]
#   psm migrate push [USER@]HOST [--port N] [--identity KEY] [--force]
#
# A bundle is a tar.gz: manifest.json (source host, core versions, scheduled
# jobs), SHA256SUMS, config/ (PSM's own state) and files/ (every other path
# PSM owns, mirrored from /). Keys, UUIDs and passwords travel unchanged, so
# clients keep working once they reach the new address.
#
# Import does not replay the old server's service files. It installs the same
# core versions for this system (musl builds on Alpine), puts the files back,
# and redoes what belongs to the host: service definitions for its init
# system, psm-core permissions, firewall ports, Nginx, acme.sh's renewal cron
# and reload hooks, online subscriptions, port-hopping rules, scheduled jobs.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MIG_FORMAT=1
MIG_FAILED=0
MIG_CORES=(xray sing-box mihomo)
# Caches the cores rebuild by themselves (geodata alone is tens of MB), and logs.
MIG_EXCLUDES=('*.db' '*.dat' '*.mmdb' '*.metadb' '*.prev' '*.log')

_mig_usage() { printf '%s\n' "$(t migrate.usage)" >&2; }
_mig_fail()  { MIG_FAILED=$((MIG_FAILED + 1)); }

# Absolute paths carried under files/ (absent ones are skipped). PSM's own
# state goes to config/ instead: PSM may live elsewhere on the new host.
_mig_paths() {
    local f
    printf '%s\n' "$XRAY_CFG_DIR" "$SINGBOX_CFG_DIR" "$MIHOMO_CFG_DIR" \
        /etc/hysteria /etc/ss-rust /etc/snell /etc/realm /etc/psm \
        "$NGINX_SSL_DIR" "$NGINX_STREAM_DIR" /var/www/psm-camouflage "$ACME_HOME"
    # PSM's own Nginx sites; not the distro's files, nor acme.sh's temporary ones
    for f in "$NGINX_HTTP_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        case "${f##*/}" in default.conf|stream.conf|_acme_*) continue ;; esac
        printf '%s\n' "$f"
    done
}

_mig_core_version() {   # xray|sing-box|mihomo → vX.Y.Z; nothing when not installed
    local bin v=""
    case "$1" in
        xray)     bin="$XRAY_BIN" ;;
        sing-box) bin="$SINGBOX_BIN" ;;
        mihomo)   bin="$MIHOMO_BIN" ;;
        *) return 0 ;;
    esac
    [[ -x "$bin" ]] || return 0
    if [[ "$1" == mihomo ]]; then v=$("$bin" -v 2>/dev/null | head -1 || true)
    else v=$("$bin" version 2>/dev/null | head -1 || true); fi
    v=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' <<<"$v" | head -1 || true)
    [[ -n "$v" ]] && printf 'v%s' "$v"
    return 0
}

_mig_node_count() {   # <PSM config dir> → nodes in the three cores' stores
    local f n=0 k
    for f in "$1"/xray/*.json "$1"/singbox/*.json "$1"/mihomo/*.json; do
        [[ -f "$f" ]] || continue
        k=$(jq '[.[]? | objects | select(.tag != null and .port != null)] | length' "$f" 2>/dev/null || true)
        [[ "$k" =~ ^[0-9]+$ ]] && n=$((n + k))
    done
    printf '%s' "$n"
}

_mig_jobs_json() {
    local traffic=false ruleset=false rwd=false hr=false tgbot=false hour=""
    ( source "$LIB_DIR/traffic.sh"; _trf_timer_active ) >/dev/null 2>&1 && traffic=true
    ( source "$LIB_DIR/ruleset/apply.sh"; rs_timer_active ) >/dev/null 2>&1 && ruleset=true
    ( source "$LIB_DIR/xray/reality_watchdog.sh"; _rwd_timer_active ) >/dev/null 2>&1 && rwd=true
    ( source "$LIB_DIR/tgbot/health_report.sh"; _hr_timer_active ) >/dev/null 2>&1 && hr=true
    svc_is_active psm-tgbot >/dev/null 2>&1 && tgbot=true
    [[ -f /etc/cron.d/psm-backup ]] && hour=$(awk '!/^#/ && NF { print $2; exit }' /etc/cron.d/psm-backup)
    jq -nc --argjson t "$traffic" --argjson r "$ruleset" --argjson w "$rwd" --argjson h "$hr" \
        --argjson b "$tgbot" --arg hour "$hour" \
        '{traffic:$t, ruleset:$r, reality_watchdog:$w, health_report:$h, tgbot:$b,
          backup_hour:(if $hour == "" then null else $hour end)}'
}

_mig_manifest() {
    local cores='{}' c v nginx=false
    for c in "${MIG_CORES[@]}"; do
        v=$(_mig_core_version "$c")
        [[ -n "$v" ]] && cores=$(jq -c --arg c "$c" --arg v "$v" '. + {($c): $v}' <<<"$cores")
    done
    if command -v nginx >/dev/null 2>&1 && [[ -d "$NGINX_STREAM_DIR" || -d /var/www/psm-camouflage ]]; then
        nginx=true
    fi
    jq -n --argjson format "$MIG_FORMAT" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg rev "$(git -C "$PSM_ROOT" rev-parse --short HEAD 2>/dev/null || true)" \
        --arg host "$(hostname 2>/dev/null || true)" \
        --arg ip4 "$(get_ipv4 2>/dev/null || true)" \
        --arg os "$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")" \
        --arg init "$(_uses_systemd && echo systemd || echo openrc)" \
        --arg arch "$(uname -m)" --arg cfg "$CFG_DIR" \
        --argjson cores "$cores" --argjson nginx "$nginx" \
        --argjson jobs "$(_mig_jobs_json)" --argjson nodes "$(_mig_node_count "$CFG_DIR")" \
        '{format:$format, created:$created, psm_rev:$rev,
          source:{hostname:$host, ipv4:$ip4, os:$os, init:$init, arch:$arch, cfg_dir:$cfg},
          cores:$cores, nginx:$nginx, jobs:$jobs, nodes:$nodes}'
}

# <work dir> → config/, files/, manifest.json, SHA256SUMS
_mig_collect() {
    local work="$1" p ex=() rel=()
    mkdir -p "$work/config" "$work/files"
    for p in "${MIG_EXCLUDES[@]}"; do ex+=("--exclude=$p"); done
    tar -C "$CFG_DIR" "${ex[@]}" -cf - . | tar -C "$work/config" -xf - || return 1
    while IFS= read -r p; do
        [[ -e "$p" ]] && rel+=("${p#/}")
    done < <(_mig_paths)
    if (( ${#rel[@]} )); then
        tar -C / "${ex[@]}" -cf - "${rel[@]}" | tar -C "$work/files" -xf - || return 1
    fi
    _mig_manifest > "$work/manifest.json" || return 1
    ( cd "$work" && find config files -type f -exec sha256sum {} + ) > "$work/SHA256SUMS" || return 1
}

_mig_passphrase() {   # new|existing → prints the passphrase
    if [[ -n "${PSM_MIGRATE_PASS:-}" ]]; then printf '%s' "$PSM_MIGRATE_PASS"; return 0; fi
    [[ -t 0 ]] || { log_error "$(t migrate.need_pass)"; return 1; }
    local a b=""
    read -rsp "$(t migrate.ask_pass) " a; echo >&2
    if [[ "$1" == new ]]; then
        read -rsp "$(t migrate.ask_pass2) " b; echo >&2
        [[ -n "$a" && "$a" == "$b" ]] || { log_error "$(t migrate.pass_mismatch)"; return 1; }
    fi
    printf '%s' "$a"
}

# <out> <encrypt 0|1> [passphrase]: writes the bundle, 0600
_mig_export_to() {
    local out="$1" encrypt="$2" pass="${3:-}" work nodes
    [[ -d "$CFG_DIR" ]] || { log_error "$(t migrate.nothing)"; return 1; }
    ensure_pkg_deps tar jq openssl >/dev/null 2>&1 || true
    work=$(mktemp -d)
    log_step "$(t migrate.exporting)"
    if ! _mig_collect "$work" \
        || ! ( cd "$work" && tar -czf bundle.tgz manifest.json SHA256SUMS config files ); then
        rm -rf "$work"; log_error "$(t migrate.pack_failed)"; return 1
    fi
    nodes=$(jq -r '.nodes' "$work/manifest.json")
    mkdir -p "$(dirname "$out")"
    if (( encrypt )); then
        PSM_MIGRATE_PASS="$pass" openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
            -pass env:PSM_MIGRATE_PASS -in "$work/bundle.tgz" -out "$out" \
            || { rm -rf "$work"; log_error "$(t migrate.pack_failed)"; return 1; }
    else
        mv "$work/bundle.tgz" "$out" || { rm -rf "$work"; log_error "$(t migrate.pack_failed)"; return 1; }
    fi
    chmod 600 "$out"
    rm -rf "$work"
    log_ok "$(t migrate.exported "$out" "$(du -h "$out" | cut -f1)" "$nodes")"
}

psm_migrate_export() {
    local out="" encrypt=0 pass=""
    while (( $# )); do
        case "$1" in
            --output|-o) [[ -n "${2:-}" ]] || { _mig_usage; return 2; }; out="$2"; shift 2; continue ;;
            --encrypt) encrypt=1 ;;
            *) _mig_usage; return 2 ;;
        esac
        shift
    done
    require_root
    [[ -n "$out" ]] || out="/root/psm-migrate-$(hostname 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).tgz"
    if (( encrypt )); then pass=$(_mig_passphrase new) || return 1; fi
    _mig_export_to "$out" "$encrypt" "$pass" || return 1
    log_warn "$(t migrate.secret_warn)"
    log_info "$(t migrate.next_steps "$out")"
    printf '%s\n' "$out"
}

# <file> <work dir>: decrypt when needed, unpack, check format and checksums
_mig_unpack() {
    local file="$1" dir="$2" src="$1" pass
    if [[ "$(head -c 8 "$file" 2>/dev/null | tr -d '\000')" == "Salted__" ]]; then
        pass=$(_mig_passphrase existing) || return 1
        PSM_MIGRATE_PASS="$pass" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
            -pass env:PSM_MIGRATE_PASS -in "$file" -out "$dir/bundle.tgz" 2>/dev/null \
            || { log_error "$(t migrate.bad_pass)"; return 1; }
        src="$dir/bundle.tgz"
    fi
    if ! tar -xzf "$src" -C "$dir" 2>/dev/null \
        || ! jq -e --argjson f "$MIG_FORMAT" '.format == $f' "$dir/manifest.json" >/dev/null 2>&1; then
        log_error "$(t migrate.bad_bundle "$file")"; return 1
    fi
    rm -f "$dir/bundle.tgz"
    ( cd "$dir" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) || { log_error "$(t migrate.corrupt)"; return 1; }
}

# What install.sh gives a new server: the GNU userland on Alpine, the tools
# PSM needs, its directories and the psm command. push lands on a bare host.
_mig_base() {
    log_step "$(t migrate.base)"
    pkg_update >/dev/null 2>&1 || true
    ensure_alpine_base || true
    ensure_pkg_deps curl wget unzip jq openssl socat qrencode tar || true
    mkdir -p "$CFG_DIR" "$BAK_DIR" "$LOG_DIR" "$NGINX_SSL_DIR" /usr/local/share/xray /var/log/xray
    chmod +x "$PSM_ROOT/manager.sh" 2>/dev/null || true
    ln -sf "$PSM_ROOT/manager.sh" /usr/local/bin/psm
    return 0
}

# The same core versions as the old server, built for this system. A core that
# is already installed is kept (a different version is only reported).
_mig_install_cores() {
    local core tag have
    while IFS=$'\t' read -r core tag; do
        [[ -n "$core" ]] || continue
        have=$(_mig_core_version "$core")
        if [[ -n "$have" ]]; then
            [[ "$have" == "$tag" ]] || log_warn "$(t migrate.keep_core "$core" "$have" "$tag")"
            continue
        fi
        log_step "$(t migrate.install_core "$core" "$tag")"
        if ! ( export PSM_NO_WIZARD=1
               case "$core" in
                   xray)     source "$LIB_DIR/xray/core.sh";    PSM_XRAY_TAG="$tag" xray_install ;;
                   sing-box) source "$LIB_DIR/singbox/core.sh"; PSM_SB_TAG="$tag" sb_install ;;
                   mihomo)   source "$LIB_DIR/mihomo/core.sh";  PSM_MH_TAG="$tag" mh_install ;;
               esac ) </dev/null >&2; then
            log_error "$(t migrate.core_install_failed "$core")"; _mig_fail
        fi
    done < <(jq -r '.cores | to_entries[] | "\(.key)\t\(.value)"' "$1")
    return 0
}

_mig_nginx_install() {
    jq -e '.nginx == true' "$1" >/dev/null 2>&1 || return 0
    log_step "$(t migrate.nginx)"
    ( source "$LIB_DIR/nginx.sh"; nginx_install ) </dev/null >&2 || { log_error "$(t migrate.nginx_bad)"; _mig_fail; }
    return 0
}

_mig_restore() {   # <work dir> <manifest>
    local work="$1" src_cfg s f
    log_step "$(t migrate.restoring)"
    for s in "${MIG_CORES[@]}"; do
        svc_exists "$s" && { svc_stop "$s" >/dev/null 2>&1 || true; }
    done
    mkdir -p "$CFG_DIR"
    cp -a "$work/config/." "$CFG_DIR/"
    cp -a "$work/files/." /
    # PSM in another directory here: its state paths inside the configs follow
    src_cfg=$(jq -r '.source.cfg_dir // empty' "$2")
    if [[ -n "$src_cfg" && "$src_cfg" != "$CFG_DIR" ]]; then
        log_info "$(t migrate.remap "$src_cfg" "$CFG_DIR")"
        while IFS= read -r f; do
            sed -i "s|${src_cfg}|${CFG_DIR}|g" "$f"
        done < <(grep -rlF "$src_cfg" "$CFG_DIR" "$XRAY_CFG_DIR" "$SINGBOX_CFG_DIR" "$MIHOMO_CFG_DIR" \
                     "$NGINX_STREAM_DIR" "$NGINX_HTTP_DIR" 2>/dev/null || true)
    fi
    return 0
}

_mig_nginx_apply() {
    jq -e '.nginx == true' "$1" >/dev/null 2>&1 || return 0
    if nginx -t >/dev/null 2>&1; then
        svc_enable nginx >/dev/null 2>&1 || true
        svc_restart nginx >/dev/null 2>&1 || true
        ( source "$LIB_DIR/system.sh"; firewall_open_port 443 tcp ) >/dev/null 2>&1 || true
    else
        log_error "$(t migrate.nginx_bad)"
        nginx -t 2>&1 | tail -5 >&2 || true
        _mig_fail
    fi
    return 0
}

# acme.sh came with its account and domain configs; its cron entry and the
# reload hooks (systemctl vs rc-service) belong to this host.
_mig_acme() {
    [[ -f "$ACME_HOME/acme.sh" ]] || return 0
    log_step "$(t migrate.acme)"
    ensure_cron >/dev/null 2>&1 || true
    "$ACME_HOME/acme.sh" --install-cronjob --home "$ACME_HOME" >/dev/null 2>&1 || true
    ( source "$LIB_DIR/cert.sh"
      for d in "$NGINX_SSL_DIR"/*/; do
          d=$(basename "$d")
          if [[ -d "$ACME_HOME/$d" || -d "$ACME_HOME/${d}_ecc" ]]; then
              cert_install_domain "$d" >/dev/null 2>&1 || true
          fi
      done ) || true
    return 0
}

_mig_wait_active() { local i; for i in 1 2 3 4 5 6 7 8; do svc_is_active "$1" && return 0; sleep 1; done; return 1; }

# Service definitions for this init system, then each core's own
# config-test-and-restart path (which also applies the psm-core permissions).
_mig_services() {
    local core
    log_step "$(t migrate.services)"
    for core in $(jq -r '.cores | keys[]' "$1"); do
        [[ -n "$(_mig_core_version "$core")" ]] || continue
        if ( case "$core" in
                 xray)
                     source "$LIB_DIR/xray/core.sh"
                     _write_xray_service; svc_daemon_reload; svc_enable xray
                     "$XRAY_BIN" run -test -config "$XRAY_CFG" >/dev/null 2>&1 || xray_rebuild_from_stores
                     xray_test_restart ;;
                 sing-box)
                     source "$LIB_DIR/singbox/core.sh"
                     _sb_write_service; svc_daemon_reload; svc_enable sing-box
                     sb_test_restart ;;
                 mihomo)
                     source "$LIB_DIR/mihomo/core.sh"
                     _mh_write_service; svc_daemon_reload; svc_enable mihomo
                     mh_test_restart ;;
             esac ) </dev/null >&2 && _mig_wait_active "$core"; then
            log_ok "$(t migrate.core_ok "$core")"
        else
            log_error "$(t migrate.core_failed "$core")"; _mig_fail
        fi
    done
    return 0
}

_mig_firewall() {
    log_step "$(t migrate.firewall)"
    ( source "$LIB_DIR/system.sh"
      for f in "$CFG_DIR"/xray/*.json "$CFG_DIR"/singbox/*.json "$CFG_DIR"/mihomo/*.json; do
          [[ -f "$f" ]] || continue
          case "$(basename "$f" .json)" in
              hysteria2|tuic|wireguard) proto=udp ;;
              ss2022|shadowsocks|ss)    proto=both ;;
              *)                        proto=tcp ;;
          esac
          while IFS= read -r port; do
              [[ "$port" =~ ^[0-9]+$ ]] && { firewall_open_port "$port" "$proto" >/dev/null 2>&1 || true; }
          done < <(jq -r '.[]? | objects | select(.tag != null) | .port // empty' "$f" 2>/dev/null || true)
      done ) || true
    return 0
}

# An online subscription keeps its token (the URL clients hold); its files are
# rebuilt so the links carry this server's address when they carried the old IP.
_mig_subscriptions() {
    ( source "$LIB_DIR/subscribe.sh"
      tok=$(_sub_state_get '.token')
      [[ -n "$tok" && "$(_sub_state_get '.expired')" != true ]] || exit 0
      domain=$(_sub_state_get '.domain'); server=$(_sub_state_get '.server')
      old=$(jq -r '.source.ipv4 // empty' "$1"); new=$(get_ipv4 2>/dev/null || true)
      [[ -n "$new" && ( -z "$server" || "$server" == "$old" ) ]] && server="$new"
      _sub_online_write "$tok" "$domain" "$server" \
          && _sub_state_save "$(_sub_state_load | jq --arg s "$server" '.server = $s')" ) >/dev/null 2>&1 || true
    # each account's own subscription (lib/users.sh), same tokens
    if [[ -f "$CFG_DIR/users.json" ]]; then
        ( source "$LIB_DIR/users.sh"; _users_online_refresh ) >/dev/null 2>&1 || true
    fi
    return 0
}

_mig_jobs() {
    local m="$1" hour
    log_step "$(t migrate.jobs)"
    ( source "$LIB_DIR/hop.sh"; psm_hop_sync ) >/dev/null 2>&1 || true
    if jq -e '.jobs.traffic' "$m" >/dev/null 2>&1; then
        ( source "$LIB_DIR/traffic.sh"; _trf_install_timer ) >/dev/null 2>&1 || true
    fi
    if jq -e '.jobs.ruleset' "$m" >/dev/null 2>&1; then
        ( source "$LIB_DIR/ruleset/apply.sh"; rs_timer_enable ) >/dev/null 2>&1 || true
    fi
    if jq -e '.jobs.reality_watchdog' "$m" >/dev/null 2>&1; then
        ( source "$LIB_DIR/xray/reality_watchdog.sh"; _rwd_install_timer ) >/dev/null 2>&1 || true
    fi
    if jq -e '.jobs.health_report' "$m" >/dev/null 2>&1; then
        ( source "$LIB_DIR/tgbot/health_report.sh"; _hr_install_timer ) >/dev/null 2>&1 || true
    fi
    hour=$(jq -r '.jobs.backup_hour // empty' "$m")
    if [[ "$hour" =~ ^[0-9]+$ ]]; then
        ensure_cron >/dev/null 2>&1 || true
        printf '0 %s * * * root %s/manager.sh --backup-full >> %s/backup.log 2>&1\n' \
            "$hour" "$PSM_ROOT" "$LOG_DIR" > /etc/cron.d/psm-backup
    fi
    return 0
}

_mig_notices() {   # <work dir> <manifest>
    local list=() d ip old domains=""
    for d in hysteria ss-rust snell realm; do
        [[ -n "$(ls -A "$1/files/etc/$d" 2>/dev/null)" ]] && list+=("$d")
    done
    (( ${#list[@]} )) && log_warn "$(t migrate.standalone "${list[*]}")"
    jq -e '.jobs.tgbot' "$2" >/dev/null 2>&1 && log_warn "$(t migrate.tgbot)"
    for d in "$NGINX_SSL_DIR"/*/; do
        [[ -d "$d" ]] && domains+="$(basename "$d") "
    done
    ip=$(get_ipv4 2>/dev/null || true); old=$(jq -r '.source.ipv4 // empty' "$2")
    [[ -n "$domains" ]] && log_warn "$(t migrate.dns "${ip:-?}" "$domains")"
    [[ -n "$old" && "$old" != "$ip" ]] && log_warn "$(t migrate.links "${ip:-?}" "$old")"
    return 0
}

psm_migrate_import() {
    local file="" yes=0 force=0
    while (( $# )); do
        case "$1" in
            --yes|-y) yes=1 ;;
            --force) force=1 ;;
            -*) _mig_usage; return 2 ;;
            *) if [[ -z "$file" ]]; then file="$1"; else _mig_usage; return 2; fi ;;
        esac
        shift
    done
    [[ -n "$file" ]] || { _mig_usage; return 2; }
    require_root
    [[ -f "$file" ]] || { log_error "$(t migrate.no_file "$file")"; return 1; }
    ensure_pkg_deps tar jq openssl >/dev/null 2>&1 || true

    local work m
    work=$(mktemp -d); m="$work/manifest.json"
    _mig_unpack "$file" "$work" || { rm -rf "$work"; return 1; }
    log_info "$(t migrate.summary \
        "$(jq -r '"\(.source.hostname) (\(.source.ipv4 // "?"), \(.source.os))"' "$m")" \
        "$(jq -r '.created' "$m")" \
        "$(jq -r '[.cores | to_entries[] | "\(.key) \(.value)"] | join(", ") | if . == "" then "-" else . end' "$m")" \
        "$(jq -r '.nodes' "$m")")"

    local here; here=$(_mig_node_count "$CFG_DIR")
    if (( here > 0 && ! force )); then
        log_error "$(t migrate.has_nodes)"; rm -rf "$work"; return 1
    fi
    if (( ! yes )) && ! ask_yn "$(t migrate.ask_confirm)" N; then
        rm -rf "$work"; return 0
    fi
    (( here > 0 )) && { ( source "$LIB_DIR/backup.sh"; do_quick_backup pre-migrate ) >/dev/null 2>&1 || true; }

    MIG_FAILED=0
    _mig_base
    _mig_install_cores "$m"
    _mig_nginx_install "$m"
    _mig_restore "$work" "$m"
    _mig_nginx_apply "$m"
    _mig_acme
    _mig_services "$m"
    _mig_firewall
    _mig_subscriptions "$m"
    _mig_jobs "$m"
    _mig_notices "$work" "$m"
    rm -rf "$work"

    ( source "$LIB_DIR/doctor.sh"; psm_doctor ) || true
    if (( MIG_FAILED == 0 )); then
        log_ok "$(t migrate.done)"
    else
        log_error "$(t migrate.failed "$MIG_FAILED")"
        return 1
    fi
}

# Export here, copy PSM and the bundle over SSH, import there. The new server
# needs nothing but SSH: bash is installed first when it is missing (Alpine),
# and PSM comes from this server, so both run the same version.
psm_migrate_push() {
    local target="" port=22 ident="" force=""
    while (( $# )); do
        case "$1" in
            --port|-p)     [[ -n "${2:-}" ]] || { _mig_usage; return 2; }; port="$2"; shift 2; continue ;;
            --identity|-i) [[ -n "${2:-}" ]] || { _mig_usage; return 2; }; ident="$2"; shift 2; continue ;;
            --force) force="--force" ;;
            -*) _mig_usage; return 2 ;;
            *) if [[ -z "$target" ]]; then target="$1"; else _mig_usage; return 2; fi ;;
        esac
        shift
    done
    [[ -n "$target" && "$port" =~ ^[0-9]+$ ]] || { _mig_usage; return 2; }
    require_root
    if ! command -v ssh >/dev/null 2>&1; then
        detect_os
        case "$PKG_MGR" in yum) pkg_install openssh-clients ;; *) pkg_install openssh-client ;; esac >/dev/null 2>&1 || true
    fi
    # One connection for every step, so a password is asked once.
    local ssh=(ssh -p "$port" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15
               -o ControlMaster=auto -o "ControlPath=/tmp/psm-mig-%C" -o ControlPersist=120)
    [[ -n "$ident" ]] && ssh+=(-i "$ident")

    local work bundle rc=0
    work=$(mktemp -d); bundle="$work/psm-migrate.tgz"
    _mig_export_to "$bundle" 0 || { rm -rf "$work"; return 1; }

    log_step "$(t migrate.push.prepare "$target")"
    if ! "${ssh[@]}" "$target" 'command -v bash >/dev/null 2>&1 \
            || apk add -q --no-cache bash >/dev/null 2>&1 \
            || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bash; } >/dev/null 2>&1 \
            || yum install -y -q bash >/dev/null 2>&1
        command -v bash >/dev/null 2>&1 && command -v tar >/dev/null 2>&1'; then
        log_error "$(t migrate.push.no_bash "$target")"; rm -rf "$work"; return 1
    fi

    # Streamed over ssh rather than scp: recent scp needs an SFTP server, which
    # a minimal Alpine does not have.
    log_step "$(t migrate.push.copy "$target")"
    if ! tar -C "$PSM_ROOT" --exclude=./config --exclude=./backup --exclude=./logs -czf - . \
            | "${ssh[@]}" "$target" 'umask 077; cat > /root/psm.tgz' \
        || ! "${ssh[@]}" "$target" 'umask 077; cat > /root/psm-migrate.tgz' < "$bundle"; then
        rc=1
    fi

    if (( rc == 0 )); then
        log_step "$(t migrate.push.remote "$target")"
        "${ssh[@]}" "$target" "bash -c '
            set -e
            if [ ! -f /opt/psm/lib/migrate.sh ]; then mkdir -p /opt/psm && tar -xzf /root/psm.tgz -C /opt/psm; fi
            rm -f /root/psm.tgz
            rc=0
            bash /opt/psm/manager.sh migrate import /root/psm-migrate.tgz --yes $force </dev/null || rc=\$?
            rm -f /root/psm-migrate.tgz
            exit \$rc'" || rc=$?
    fi
    "${ssh[@]}" -O exit "$target" >/dev/null 2>&1 || true

    if (( rc == 0 )); then
        rm -rf "$work"
        log_ok "$(t migrate.push.done "$target")"
        return 0
    fi
    local kept; kept="/root/psm-migrate-push-$(date +%Y%m%d-%H%M%S).tgz"
    mv "$bundle" "$kept" 2>/dev/null || kept="$bundle"
    rm -rf "$work"
    log_error "$(t migrate.push.failed "$target" "$kept")"
    return 1
}

migrate_menu_import() {
    local f; ask f "$(t migrate.ask_file)" ""
    [[ -n "$f" ]] || return 0
    psm_migrate_import "$f" || true
}

psm_migrate_cli() {
    local cmd="${1:-}"
    (( $# )) && shift
    case "$cmd" in
        export) psm_migrate_export "$@" ;;
        import) psm_migrate_import "$@" ;;
        push)   psm_migrate_push "$@" ;;
        -h|--help|help) printf '%s\n' "$(t migrate.usage)" ;;
        *) _mig_usage; return 2 ;;
    esac
}
