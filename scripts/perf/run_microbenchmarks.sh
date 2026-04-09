#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BASELINE_PATH="${ROOT_DIR}/Tests/DockCatTaskAssistantTests/Fixtures/performance-baseline.json"
ENFORCE_FLAG="${1:-}"

if [[ "${ENFORCE_FLAG}" == "--enforce" ]]; then
  export DOCKCAT_PERF_ENFORCE=1
else
  export DOCKCAT_PERF_ENFORCE=0
fi

OUTPUT_FILE="${ROOT_DIR}/.build/performance-regression.log"
mkdir -p "${ROOT_DIR}/.build"

pushd "${ROOT_DIR}" >/dev/null
TEST_OUTPUT="$(swift test --filter PerformanceRegressionTests 2>&1)"
TEST_STATUS=$?
popd >/dev/null

printf '%s\n' "${TEST_OUTPUT}" | tee "${OUTPUT_FILE}"

if [[ ${TEST_STATUS} -ne 0 ]]; then
  exit ${TEST_STATUS}
fi

BENCHMARK_LINES="$(printf '%s\n' "${TEST_OUTPUT}" | grep '^BENCHMARK_RESULT ' || true)"
if [[ -z "${BENCHMARK_LINES}" ]]; then
  echo "No benchmark output detected."
  exit 1
fi

BENCHMARK_LINES_ENV="${BENCHMARK_LINES}" python3 - "${BASELINE_PATH}" <<'PY'
import json
import re
import sys
import os

baseline_path = sys.argv[1]
pattern = re.compile(r"name=(?P<name>\S+) median_ms=(?P<median>\S+) p95_ms=(?P<p95>\S+) iterations=(?P<iterations>\d+)")
benchmark_lines = os.environ.get("BENCHMARK_LINES_ENV", "")

with open(baseline_path, "r", encoding="utf-8") as handle:
    baseline = json.load(handle)

rows = []
for line in benchmark_lines.splitlines():
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
            int(info["iterations"]),
            scenario.get("median_ms"),
            scenario.get("p95_ms"),
        )
    )

if not rows:
    print("Unable to parse benchmark output.", file=sys.stderr)
    sys.exit(1)

print("\nMicrobenchmark summary:")
for name, median, p95, iterations, baseline_median, baseline_p95 in rows:
    print(
        f"  {name}: median={median:.3f}ms p95={p95:.3f}ms iterations={iterations} "
        f"(baseline median={baseline_median:.3f}ms p95={baseline_p95:.3f}ms)"
    )
PY
