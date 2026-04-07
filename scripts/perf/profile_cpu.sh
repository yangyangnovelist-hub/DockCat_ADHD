#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="${ROOT_DIR}/artifacts/perf/${STAMP}"
mkdir -p "${OUTPUT_DIR}"

PROFILE_DURATION="${DOCKCAT_PERF_PROFILE_DURATION:-180s}"
TASK_COUNT="${DOCKCAT_PERF_TASK_COUNT:-4000}"
ITERATIONS="${DOCKCAT_PERF_MINDMAP_ITERATIONS:-3600}"
TRACE_PATH="${OUTPUT_DIR}/cpu-profile.trace"

COMMAND="export DOCKCAT_PERF_TASK_COUNT=${TASK_COUNT}; export DOCKCAT_PERF_MINDMAP_ITERATIONS=${ITERATIONS}; cd \"${ROOT_DIR}\"; swift test --skip-build --filter PerformanceRegressionTests/test_mindMapSynchronizationBenchmark"

set +e
xcrun xctrace record \
  --template 'Time Profiler' \
  --output "${TRACE_PATH}" \
  --time-limit "${PROFILE_DURATION}" \
  --launch -- /bin/zsh -lc "${COMMAND}"
TRACE_STATUS=$?
set -e

if [[ ${TRACE_STATUS} -ne 0 && ${TRACE_STATUS} -ne 54 ]]; then
  exit ${TRACE_STATUS}
fi

echo "CPU profile saved to ${TRACE_PATH}"
echo "Open the trace in Instruments and inspect the widest stacks first."
