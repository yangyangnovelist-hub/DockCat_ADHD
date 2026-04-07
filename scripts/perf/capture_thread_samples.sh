#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="${ROOT_DIR}/artifacts/perf/${STAMP}/thread-samples"
mkdir -p "${OUTPUT_DIR}"

TASK_COUNT="${DOCKCAT_PERF_TASK_COUNT:-4000}"
ITERATIONS="${DOCKCAT_PERF_SAVE_ITERATIONS:-240}"
COMMAND="export DOCKCAT_PERF_TASK_COUNT=${TASK_COUNT}; export DOCKCAT_PERF_SAVE_ITERATIONS=${ITERATIONS}; cd \"${ROOT_DIR}\"; swift test --skip-build --filter PerformanceRegressionTests/test_repositorySaveSnapshotBenchmark"

/bin/zsh -lc "${COMMAND}" &
RUNNER_PID=$!

cleanup() {
  if ps -p "${RUNNER_PID}" >/dev/null 2>&1; then
    kill "${RUNNER_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

TARGET_PID=""
for _ in {1..12}; do
  TARGET_PID="$(pgrep -P "${RUNNER_PID}" xctest | head -n 1 || true)"
  if [[ -z "${TARGET_PID}" ]]; then
    TARGET_PID="$(pgrep -f 'xctest.*DockCatTaskAssistantPackageTests' | head -n 1 || true)"
  fi
  if [[ -n "${TARGET_PID}" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "${TARGET_PID}" ]]; then
  echo "Unable to find xctest pid for sampling."
  wait "${RUNNER_PID}"
  exit 1
fi

for sample_index in 1 2 3; do
  sample "${TARGET_PID}" 5 1 -file "${OUTPUT_DIR}/sample-${sample_index}.txt" >/dev/null 2>&1 || true
  sleep 5
done

wait "${RUNNER_PID}"
trap - EXIT

echo "Thread samples saved to ${OUTPUT_DIR}"
echo "Search for long-running frames, lock contention, and repeated blocking I/O."
