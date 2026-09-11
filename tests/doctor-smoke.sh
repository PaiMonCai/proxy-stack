#!/usr/bin/env bash

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

set +e
report="$(bash "$PSM_ROOT/manager.sh" doctor --json)"
rc=$?
set -e

# A diagnostic result may legitimately be unhealthy on a CI runner, but usage
# errors and command failures are never acceptable.
if [[ "$rc" -ne 0 && "$rc" -ne 1 ]]; then
    echo "doctor returned unexpected exit code: $rc" >&2
    exit 1
fi

printf '%s' "$report" | jq -e '
    .schema_version == "1" and
    .tool == "psm-doctor" and
    (.generated_at | type == "string") and
    (.status == "healthy" or .status == "warning" or .status == "critical") and
    (.summary.total == (.checks | length)) and
    ([.checks[].status] | all(. == "ok" or . == "warning" or . == "critical" or . == "skipped"))
' >/dev/null

echo "ok: doctor JSON contract (exit $rc)"
