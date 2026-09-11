#!/usr/bin/env bash
# Local/CI quality gate. It is intentionally rootless and offline.

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PSM_ROOT"

section() {
    echo
    echo "== $1 =="
}

collect_shell_files() {
    find . -type f -name '*.sh' -not -path './.git/*' -print0
}

collect_runtime_shell_files() {
    # lang/ files are associative-array data catalogs rather than standalone
    # programs. They are checked through generated wrappers below so ShellCheck
    # sees the MSG declaration and does not misread dotted keys as variables.
    find . -type f -name '*.sh' -not -path './.git/*' -not -path './lang/*' -print0
}

run_syntax() {
    section "bash syntax"
    local count=0 file
    while IFS= read -r -d '' file; do
        bash -n "$file"
        count=$((count + 1))
    done < <(collect_shell_files)
    echo "checked $count shell files"
}

run_shellcheck() {
    section "ShellCheck"
    command -v shellcheck >/dev/null 2>&1 || {
        echo "ShellCheck is required (Ubuntu: apt-get install shellcheck)" >&2
        return 2
    }

    local -a files=()
    while IFS= read -r -d '' file; do files+=("$file"); done < <(collect_runtime_shell_files)
    shellcheck --shell=bash --severity=warning --exclude=SC1090,SC2034 --format=gcc "${files[@]}"

    local tmp_dir lang wrapper catalog catalog_count=0
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN
    for lang in zh en ko ru; do
        wrapper="$tmp_dir/lang-${lang}.sh"
        {
            printf '#!/usr/bin/env bash\n'
            printf 'declare -A MSG=()\n'
            printf 'source %q\n' "$PSM_ROOT/lang/${lang}.sh"
            while IFS= read -r -d '' catalog; do
                printf 'source %q\n' "$catalog"
                catalog_count=$((catalog_count + 1))
            done < <(find "$PSM_ROOT/lang/$lang" -type f -name '*.sh' -print0 | sort -z)
        } > "$wrapper"
        shellcheck --shell=bash --external-sources --severity=warning \
            --exclude=SC1090,SC2034 --format=gcc "$wrapper"
    done
    rm -rf "$tmp_dir"
    trap - RETURN
    echo "checked ${#files[@]} shell files and $catalog_count language catalogs"
}

run_i18n() {
    section "i18n"
    bash scripts/i18n-check.sh
}

run_tests() {
    section "config regression"
    bash tests/run.sh
}

case "${1:-all}" in
    all)
        run_syntax
        run_shellcheck
        run_i18n
        run_tests
        ;;
    syntax)     run_syntax ;;
    shellcheck) run_shellcheck ;;
    i18n)       run_i18n ;;
    test|tests) run_tests ;;
    *)
        echo "usage: $0 [all|syntax|shellcheck|i18n|tests]" >&2
        exit 2
        ;;
esac

echo
echo "CI checks passed"
