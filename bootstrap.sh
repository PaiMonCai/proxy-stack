#!/usr/bin/env bash
# bootstrap.sh — JQ's PSM one-liner installer / updater
#
# First install:
#   bash <(curl -fsSL https://psm.jinqians.com)
#
# Re-run to update:
#   same command — detects existing install and does git pull only
#
# Alpine (no bash out of the box):
#   wget -qO- https://psm.jinqians.com | sh

# ── POSIX shim: get onto bash first ───────────────────────────────────────────
# Everything below this block is bash. This block alone is plain POSIX sh, so
# `… | sh` works on a bare Alpine: it installs bash through apk and re-runs this
# installer under bash. When piped, stdin is the script itself, so the re-run
# takes the keyboard from /dev/tty (the installer asks questions).
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash curl || exit 1
        else
            echo "bash is required: install bash, then re-run this command." >&2
            exit 1
        fi
    fi
    case "$0" in
        *bootstrap.sh) exec bash "$0" "$@" ;;   # run from a file: no download needed
    esac
    PSM_BOOTSTRAP_TMP="$(mktemp)" || exit 1
    export PSM_BOOTSTRAP_TMP
    curl -fsSL "${PSM_BOOTSTRAP_URL:-https://psm.jinqians.com}" -o "$PSM_BOOTSTRAP_TMP" \
        || { rm -f "$PSM_BOOTSTRAP_TMP"; exit 1; }
    if (: </dev/tty) 2>/dev/null; then
        exec bash "$PSM_BOOTSTRAP_TMP" "$@" </dev/tty
    fi
    exec bash "$PSM_BOOTSTRAP_TMP" "$@"
fi
# bash already holds the file open, so the shim's temp copy can go right away.
[[ -n "${PSM_BOOTSTRAP_TMP:-}" ]] && rm -f "$PSM_BOOTSTRAP_TMP"

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PSM_REPO="${PSM_REPO:-https://github.com/jinqians/proxy-stack.git}"
PSM_BRANCH="${PSM_BRANCH:-main}"
PSM_DIR="/opt/psm"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_step() { echo -e "${CYAN}[STEP]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()      { log_error "$*"; exit 1; }

# ── Language ──────────────────────────────────────────────────────────────────
# bootstrap runs via `curl | bash` before the repo (and lib/i18n.sh) exists, so it
# carries its own tiny zh/en map. PSM_LANG overrides; otherwise infer from the
# system locale, falling back to English (installer reach / unknown locale).
_bt_lang="${PSM_LANG:-}"
if [[ -z "$_bt_lang" ]]; then
    case "${LC_ALL:-}${LC_MESSAGES:-}${LANG:-}" in *[Zz][Hh]*) _bt_lang=zh ;; *) _bt_lang=en ;; esac
fi
bt() { [[ "$_bt_lang" == zh ]] && printf '%s' "$1" || printf '%s' "$2"; }

banner() {
    local BC='\033[96m' BB='\033[94m' WH='\033[97m' DM='\033[2m'
    local L1='     _    ___          ____    ____    __  __ '
    local L2='    | |  / _ \        |  _ \  / ___| |  \/  |'
    local L3=" _  | | | | | |       | |_) | \___ \ | |\/| |"
    local L4='| |_| | | |_| |       |  __/   ___) | | |  | |'
    local L5=' \___/   \__\_|       |_|     |____/ |_|  |_|'
    echo ""
    printf "  ${BOLD}${BC}%s${NC}\n"  "$L1"
    printf "  ${BOLD}${BC}%s${NC}\n"  "$L2"
    printf "  ${BOLD}${BB}%s${NC}\n"  "$L3"
    printf "  ${BOLD}${BB}%s${NC}\n"  "$L4"
    printf "  ${BOLD}${BC}%s${NC}\n"  "$L5"
    printf "\n"
    printf "  ${BOLD}${WH}Proxy Stack Manager${NC}  ${DM}·····${NC}  ${YELLOW}◆ jinqians.com${NC}\n"
    echo ""
}

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "$(bt "请以 root 身份运行：  sudo bash <(curl -fsSL <url>)" "Please run as root:  sudo bash <(curl -fsSL <url>)")"

banner

# ── Helper: install packages via available package manager ────────────────────
_pkg_install() {
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y "$@"
    elif command -v dnf &>/dev/null; then
        dnf install -y "$@"
    elif command -v yum &>/dev/null; then
        yum install -y "$@"
    elif command -v apk &>/dev/null; then
        # --no-cache refreshes the index for this transaction and removes it
        # afterwards, which is the usual Alpine server convention.
        apk add --no-cache "$@"
    else
        die "$(bt "无法自动安装软件包，请手动安装： $*" "Cannot install packages automatically. Please install manually: $*")"
    fi
}

# ── Ensure curl is available (may already be installed) ───────────────────────
if ! command -v curl &>/dev/null; then
    log_step "$(bt "正在安装 curl..." "Installing curl...")"
    _pkg_install curl
    log_ok "$(bt "curl 已安装。" "curl installed.")"
fi

# ── Install git if missing ────────────────────────────────────────────────────
if ! command -v git &>/dev/null; then
    log_step "$(bt "正在安装 git..." "Installing git...")"
    _pkg_install git
    log_ok "$(bt "git 已安装。" "git installed.")"
fi

# ── Slim checkout ─────────────────────────────────────────────────────────────
# 服务器只需要脚本：README、截图、CI 配置和测试不放进 $PSM_DIR（sparse checkout），
# 之后 pull 也不下载它们的内容（partial clone 过滤）。老的完整克隆在这里就地转换。
# 与 lib/common.sh 的 psm_repo_slim 相同（菜单自动更新和 update.sh 用那份），两处同步修改。
_psm_slim() {   # <repo dir>
    local d="$1" want
    want=$(printf '%s\n' '/*' '!/README*.md' '!/.github/' '!/tests/')
    if [[ "$(git -C "$d" config --get core.sparseCheckout || true)" != true \
          || "$(cat "$d/.git/info/sparse-checkout" 2>/dev/null)" != "$want" ]]; then
        mkdir -p "$d/.git/info"
        printf '%s\n' "$want" > "$d/.git/info/sparse-checkout"
        git -C "$d" config core.sparseCheckout true
        git -C "$d" read-tree -mu HEAD
    fi
    if [[ -z "$(git -C "$d" config --get remote.origin.promisor || true)" ]]; then
        git -C "$d" config remote.origin.promisor true
        git -C "$d" config remote.origin.partialclonefilter blob:none
        # git 2.24 之前只认这个扩展项，之后的 fetch 过滤条件也只读 core.partialCloneFilter
        git -C "$d" config core.repositoryformatversion 1
        git -C "$d" config extensions.partialClone origin
        git -C "$d" config core.partialCloneFilter blob:none
    fi
}

# ── Clone or update ───────────────────────────────────────────────────────────
if [[ -d "$PSM_DIR/.git" ]]; then
    log_step "$(bt "正在更新已安装的 PSM（$PSM_DIR）..." "Updating existing PSM installation at $PSM_DIR ...")"
    # 仓库里只有脚本，用户数据在 /etc/psm。手动改过的脚本会让 git pull 拒绝合并、
    # 整次更新直接中止 —— 先把改动存成补丁（不丢），再还原到 HEAD。未跟踪文件不动。
    # 安装/更新都会 chmod +x 脚本，仓库里记为 100644 的文件因此显示为"已修改"，
    # 上游一改到它们 pull 就失败。权限不算本地修改：关掉 core.fileMode。
    git -C "$PSM_DIR" config core.fileMode false
    if ! git -C "$PSM_DIR" diff --quiet HEAD -- 2>/dev/null; then
        psm_patch="${HOME:-/root}/psm-local-changes-$(date +%Y%m%d%H%M%S).patch"
        git -C "$PSM_DIR" diff HEAD > "$psm_patch"
        git -C "$PSM_DIR" reset -q --hard HEAD
        log_warn "$(bt "$PSM_DIR 中有本地修改，已保存到 $psm_patch 并还原，以便更新。" "Local changes in $PSM_DIR were saved to $psm_patch and reverted so the update can proceed.")"
    fi
    _psm_slim "$PSM_DIR" || log_warn "$(bt "精简检出失败，按完整检出继续更新。" "Could not slim the checkout; updating the full checkout instead.")"
    # --no-stat: the diffstat after a fast-forward reads every changed file,
    # which would download the READMEs and screenshots the slim checkout skips.
    if ! git -C "$PSM_DIR" pull --ff-only --no-stat; then
        # 历史分叉（本地提交、被改写的浅克隆等）：以远端为准，本地提交仍可从 git reflog 找回
        log_warn "$(bt "无法快进更新，正在重置到远端 $PSM_BRANCH（本地提交可用 git reflog 找回）..." "Cannot fast-forward; resetting to remote $PSM_BRANCH (local commits stay in git reflog)...")"
        git -C "$PSM_DIR" fetch origin "$PSM_BRANCH"
        git -C "$PSM_DIR" reset -q --hard FETCH_HEAD
    fi
    chmod +x "$PSM_DIR"/*.sh "$PSM_DIR/lib"/*.sh 2>/dev/null || true
    log_ok "$(bt "PSM 已更新。" "PSM updated.")"

    psm_cmd_target="$(readlink -f /usr/local/bin/psm 2>/dev/null || true)"
    if [[ ! -x /usr/local/bin/psm || "$psm_cmd_target" != "$PSM_DIR/manager.sh" || ! -d "$PSM_DIR/config" ]]; then
        log_warn "$(bt "现有安装不完整，正在运行安装程序修复..." "Existing checkout is incomplete; running installer to repair it...")"
        exec bash "$PSM_DIR/install.sh"
    fi

    echo ""
    echo -e "  $(bt "运行 ${BOLD}psm${NC} 打开菜单。" "Run ${BOLD}psm${NC} to open the menu.")"
    echo ""
    exit 0
fi

log_step "$(bt "正在克隆 PSM 到 $PSM_DIR ..." "Cloning PSM to $PSM_DIR ...")"
git clone --depth=1 --filter=blob:none --no-checkout -b "$PSM_BRANCH" "$PSM_REPO" "$PSM_DIR"
_psm_slim "$PSM_DIR"
[[ -f "$PSM_DIR/install.sh" ]] || die "$(bt "检出失败：$PSM_DIR 中没有 install.sh。" "Checkout failed: no install.sh in $PSM_DIR.")"
log_ok "$(bt "仓库已下载。" "Repository downloaded.")"

# ── Hand off to the real installer ───────────────────────────────────────────
exec bash "$PSM_DIR/install.sh"
