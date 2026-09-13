#!/usr/bin/env bash
# Install and update keep the READMEs, screenshots, CI files and tests off the
# server: bootstrap.sh clones sparse and partial, and the three update paths
# (re-running bootstrap, the menu's auto-update, update.sh) slim an existing
# full clone before they pull. The checks go further than "not in /opt/psm":
# those files' contents must never have been downloaded.
#
# A local bare repository stands in for GitHub. Its install.sh is a stub; the
# full suites cover the real installer.

set -uo pipefail

src=/src
if [[ "$(cd "$(dirname "$0")" && pwd)" != "$src/tests/integration" ]]; then
    rm -rf "$src" && cp -a /opt/psm "$src" && exec bash "$src/tests/integration/slim.sh"
fi
rm -rf /opt/psm

pass=0; fail=0; failed=()
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); failed+=("$1"); }
chk() {
    local n="$1"; shift
    if "$@" >/tmp/chk.out 2>&1; then ok "$n"; else bad "$n"; tail -15 /tmp/chk.out | sed 's/^/       /'; fi
}
sec() { echo; echo "=== $1"; }

command -v git >/dev/null 2>&1 || apk add -q --no-cache git curl >/dev/null
echo "git $(git --version | awk '{print $3}')"

# Every path the servers must not get. The same list, word for word, in both copies.
slim_line() { grep -F "want=\$(printf '%s\n'" "$1" | sed 's/^ *//'; }
sec "one exclusion list"
chk "bootstrap.sh and lib/common.sh exclude the same paths" \
    bash -c "[[ -n \"\$(grep -F \"want=\" $src/bootstrap.sh)\" && \"$(slim_line "$src/bootstrap.sh")\" == \"$(slim_line "$src/lib/common.sh")\" ]]"

# ── the stand-in for GitHub ──────────────────────────────────────────────────
sec "stand-in repository"
work=/srv/work; bare=/srv/psm.git
rm -rf /srv && mkdir -p "$work"
git config --global user.name psm-test
git config --global user.email test@example.com
cp -a "$src/." "$work/"
# The copied tree keeps the host checkout's owner; git 2.35.2+ refuses to work
# in a repository root does not own ("dubious ownership").
chown -R 0:0 "$work"
printf '#!/usr/bin/env bash\necho PSM-STUB-INSTALL\n' > "$work/install.sh"
git -C "$work" init -q && git -C "$work" checkout -q -b main   # no `init -b` before git 2.28
git -C "$work" add -A && git -C "$work" commit -qm v1
git clone -q --bare "$work" "$bare"
git -C "$bare" config uploadpack.allowFilter true
git -C "$bare" config uploadpack.allowAnySHA1InWant true
export PSM_REPO="file://$bare"
chk "the stand-in carries READMEs, screenshots and tests" \
    bash -c "git -C $bare ls-tree -r --name-only main | grep -qx README.md \
          && git -C $bare ls-tree -r --name-only main | grep -q '^.github/assets/.*png$' \
          && git -C $bare ls-tree -r --name-only main | grep -q '^tests/'"

bump() {   # <tag>: a README change, a new screenshot and a script change, published
    echo "$1" >> "$work/README.md"
    head -c 300000 /dev/urandom > "$work/.github/assets/$1.png"
    echo "# $1 marker" >> "$work/lib/common.sh"
    git -C "$work" add -A && git -C "$work" commit -qm "$1" && git -C "$work" push -q "$bare" main
}

# /opt/psm has the scripts, none of the rest, and nothing shows as modified.
slim_ok() {
    local p
    for p in manager.sh install.sh lib/common.sh LICENSE; do
        [[ -f "/opt/psm/$p" ]] || { echo "missing: $p"; return 1; }
    done
    for p in README.md README_EN.md README_KO.md README_RU.md .github tests; do
        [[ ! -e "/opt/psm/$p" ]] || { echo "present: $p"; return 1; }
    done
    local st; st=$(git -C /opt/psm status --porcelain)
    [[ -z "$st" ]] || { echo "$st"; return 1; }
}

# That file's content is not in the object store (listed without fetching it).
not_downloaded() {   # <path in the repository>
    local b list
    b=$(git -C /opt/psm ls-tree HEAD -- "$1" | awk '{print $3}')
    [[ -n "$b" ]] || { echo "not in HEAD: $1"; return 1; }
    # Listed first, then searched: `rev-list | grep -q` would fail under
    # pipefail whenever grep stops reading early and rev-list gets SIGPIPE.
    list=$(git -C /opt/psm rev-list --objects --missing=print HEAD) || return 1
    grep -qx "?$b" <<<"$list" || { echo "downloaded: $1"; return 1; }
}

# ── fresh install ────────────────────────────────────────────────────────────
sec "fresh install (bootstrap.sh)"
chk "bootstrap clones and hands over to install.sh" \
    bash -c "bash $src/bootstrap.sh </dev/null | grep -q PSM-STUB-INSTALL"
chk "only the scripts are checked out" slim_ok
chk "README content not downloaded"     not_downloaded README.md
chk "screenshot content not downloaded" not_downloaded .github/assets/banner.png
chk "test content not downloaded"       not_downloaded tests/integration/slim.sh

# ── update: bootstrap again ──────────────────────────────────────────────────
sec "update by re-running bootstrap.sh"
bump v2
chk "bootstrap updates"                  bash "$src/bootstrap.sh" </dev/null
chk "the script change arrived"          grep -q 'v2 marker' /opt/psm/lib/common.sh
chk "still only the scripts"             slim_ok
chk "new README not downloaded"          not_downloaded README.md
chk "new screenshot not downloaded"      not_downloaded .github/assets/v2.png
chk "bootstrap again, nothing new"       bash "$src/bootstrap.sh" </dev/null
chk "still only the scripts"             slim_ok

# ── update: an install from before, through the menu ─────────────────────────
sec "an existing full clone, updated by the menu"
rm -rf /opt/psm && git clone -q --depth=1 "$PSM_REPO" /opt/psm   # how bootstrap used to clone
chk "the old clone has the READMEs"      test -f /opt/psm/README.md
bump v3
printf '0\n' | timeout 120 bash /opt/psm/manager.sh >/tmp/menu.out 2>&1 || true
chk "the menu's auto-update pulled"      grep -q 'v3 marker' /opt/psm/lib/common.sh
chk "only the scripts are left"          slim_ok
chk "new README not downloaded"          not_downloaded README.md
chk "new screenshot not downloaded"      not_downloaded .github/assets/v3.png

# ── update: an install from before, through update.sh ────────────────────────
sec "an existing full clone, updated by update.sh"
rm -rf /opt/psm && git clone -q --depth=1 "$PSM_REPO" /opt/psm
bump v4
bash -c 'source /opt/psm/update.sh && psm_update_scripts' >/tmp/update.out 2>&1 || true
chk "update.sh pulled"                   grep -q 'v4 marker' /opt/psm/lib/common.sh
chk "only the scripts are left"          slim_ok
chk "new README not downloaded"          not_downloaded README.md
chk "new screenshot not downloaded"      not_downloaded .github/assets/v4.png

echo
echo "=== RESULT: $pass ok, $fail failed"
for f in "${failed[@]}"; do echo "  - $f"; done
(( fail == 0 ))
