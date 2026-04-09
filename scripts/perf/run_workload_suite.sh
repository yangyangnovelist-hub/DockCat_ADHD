#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BASELINE_PATH="${ROOT_DIR}/Tests/DockCatTaskAssistantTests/Fixtures/workload-baseline.json"
ENFORCE_FLAG="${1:-}"

if [[ "${ENFORCE_FLAG}" == "--enforce" ]]; then
  export DOCKCAT_PERF_ENFORCE=1
else
  export DOCKCAT_PERF_ENFORCE=0
fi

OUTPUT_FILE="${ROOT_DIR}/.build/workload-regression.log"
mkdir -p "${ROOT_DIR}/.build"

pushd "${ROOT_DIR}" >/dev/null
set +e
TEST_OUTPUT="$(swift test --filter WorkloadPerformanceTests 2>&1)"
TEST_STATUS=$?
set -e
popd >/dev/null

printf '%s\n' "${TEST_OUTPUT}" | tee "${OUTPUT_FILE}"

if [[ ${TEST_STATUS} -ne 0 ]]; then
  exit ${TEST_STATUS}
fi

WORKLOAD_LINES="$(printf '%s\n' "${TEST_OUTPUT}" | grep '^WORKLOAD_RESULT ' || true)"
if [[ -z "${WORKLOAD_LINES}" ]]; then
  echo "No workload output detected."
  exit 1
fi

WORKLOAD_LINES_ENV="${WORKLOAD_LINES}" python3 - "${BASELINE_PATH}" <<'PY'
import json
import os
import re
import sys

baseline_path = sys.argv[1]
pattern = re.compile(
    r"name=(?P<name>\S+) median_ms=(?P<median>\S+) p95_ms=(?P<p95>\S+) "
    r"throughput_per_second=(?P<throughput>\S+) iterations=(?P<iterations>\d+)"
)
workload_lines = os.environ.get("WORKLOAD_LINES_ENV", "")

with open(baseline_path, "r", encoding="utf-8") as handle:
    baseline = json.load(handle)

rows = []
for line in workload_lines.splitlines():
    match = pattern.search(line)
    if not match:
        continue
    info = match.groupdict()
    scenario = baseline["scenarios"].get(info["name"], {})
    rows.append(
        (
            info["name"],
            float(info["median"]),
            float(info["p95"]),
            float(info["throughput"]),
            int(info["iterations"]),
            scenario.get("median_ms"),
            scenario.get("min_throughput_per_second"),
        )
    )

if not rows:
    print("Unable to parse workload output.", file=sys.stderr)
    sys.exit(1)

print("\nWorkload summary:")
for name, median, p95, throughput, iterations, baseline_median, baseline_throughput in rows:
    print(
        f"  {name}: median={median:.3f}ms p95={p95:.3f}ms throughput={throughput:.3f}/s iterations={iterations} "
        f"(baseline median={baseline_median:.3f}ms min throughput={baseline_throughput:.3f}/s)"
    )
PY
