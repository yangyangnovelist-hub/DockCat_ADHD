#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="${ROOT_DIR}/artifacts/perf/${STAMP}"
mkdir -p "${OUTPUT_DIR}"

PROFILE_DURATION="${DOCKCAT_PERF_PROFILE_DURATION:-180s}"
TASK_COUNT="${DOCKCAT_PERF_TASK_COUNT:-4000}"
ITERATIONS="${DOCKCAT_PERF_SAVE_ITERATIONS:-240}"
TRACE_PATH="${OUTPUT_DIR}/allocations.trace"

COMMAND="export DOCKCAT_PERF_TASK_COUNT=${TASK_COUNT}; export DOCKCAT_PERF_SAVE_ITERATIONS=${ITERATIONS}; cd \"${ROOT_DIR}\"; swift test --skip-build --filter PerformanceRegressionTests/test_repositorySaveSnapshotBenchmark"

set +e
xcrun xctrace record \
  --template 'Allocations' \
  --output "${TRACE_PATH}" \
  --time-limit "${PROFILE_DURATION}" \
  --launch -- /bin/zsh -lc "${COMMAND}"
TRACE_STATUS=$?
set -e

if [[ ${TRACE_STATUS} -ne 0 && ${TRACE_STATUS} -ne 54 ]]; then
  exit ${TRACE_STATUS}
fi

echo "Allocation profile saved to ${TRACE_PATH}"
echo "Use this trace to inspect heap growth and ARC-heavy temporary objects."
