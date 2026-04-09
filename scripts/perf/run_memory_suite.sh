#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BASELINE_PATH="${ROOT_DIR}/Tests/DockCatTaskAssistantTests/Fixtures/memory-baseline.json"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="${ROOT_DIR}/artifacts/perf/${STAMP}/memory"
RESULTS_TSV="${OUTPUT_DIR}/memory-results.tsv"
SUMMARY_JSON="${OUTPUT_DIR}/summary.json"
SUMMARY_MD="${OUTPUT_DIR}/summary.md"
ENFORCE_FLAG="${1:-}"

mkdir -p "${OUTPUT_DIR}"
mkdir -p "${ROOT_DIR}/.build"

record_result() {
  local name="$1"
  local current_mb="$2"
  local peak_mb="$3"
  local max_rss_mb="$4"
  local notes="$5"
  printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${current_mb}" "${peak_mb}" "${max_rss_mb}" "${notes}" >> "${RESULTS_TSV}"
}

capture_vmmap_values() {
  local pid="$1"
  python3 - "$pid" <<'PY'
import re
import subprocess
import sys

pid = sys.argv[1]
try:
    output = subprocess.check_output(["vmmap", "-summary", pid], text=True, stderr=subprocess.DEVNULL)
except Exception:
    print("NA\tNA")
    raise SystemExit(0)

current = "NA"
peak = "NA"
for line in output.splitlines():
    if line.startswith("Physical footprint:"):
        match = re.search(r"Physical footprint:\s+([0-9.]+)([KMG])", line)
        if match:
            value, unit = match.groups()
            factor = {"K": 1/1024, "M": 1, "G": 1024}[unit]
            current = f"{float(value) * factor:.1f}"
    elif line.startswith("Physical footprint (peak):"):
        match = re.search(r"Physical footprint \(peak\):\s+([0-9.]+)([KMG])", line)
        if match:
            value, unit = match.groups()
            factor = {"K": 1/1024, "M": 1, "G": 1024}[unit]
            peak = f"{float(value) * factor:.1f}"
print(f"{current}\t{peak}")
PY
}

run_idle_app_launch() {
  local executable="${ROOT_DIR}/.build/release/DockCatTaskAssistant"
  if [[ ! -x "${executable}" ]]; then
    (cd "${ROOT_DIR}" && swift build -c release >/dev/null)
  fi

  local log_file="${OUTPUT_DIR}/idle-app.log"
  nohup "${executable}" >"${log_file}" 2>&1 &
  local pid=$!

  sleep 8

  local max_rss_kb=0
  for _ in 1 2 3; do
    if ps -p "${pid}" >/dev/null 2>&1; then
      local rss_kb
      rss_kb="$(ps -o rss= -p "${pid}" | awk '{print $1}')"
      if [[ -n "${rss_kb}" && "${rss_kb}" -gt "${max_rss_kb}" ]]; then
        max_rss_kb="${rss_kb}"
      fi
    fi
    sleep 2
  done

  local vmmap_values current_mb peak_mb
  vmmap_values="$(capture_vmmap_values "${pid}")"
  current_mb="$(printf '%s' "${vmmap_values}" | cut -f1)"
  peak_mb="$(printf '%s' "${vmmap_values}" | cut -f2)"
  local max_rss_mb
  max_rss_mb="$(python3 - <<PY
rss_kb = ${max_rss_kb}
print(f"{rss_kb / 1024:.1f}")
PY
)"

  kill "${pid}" >/dev/null 2>&1 || true
  wait "${pid}" 2>/dev/null || true

  record_result "idle_app_launch" "${current_mb}" "${peak_mb}" "${max_rss_mb}" "release app idle launch"
}

run_workload_process() {
  local name="$1"
  local filter="$2"
  local notes="$3"
  local runner_log="${OUTPUT_DIR}/${name}.log"

  /bin/zsh -lc "cd \"${ROOT_DIR}\"; swift test --filter ${filter}" >"${runner_log}" 2>&1 &
  local runner_pid=$!

  local target_pid=""
  for _ in {1..20}; do
    target_pid="$(pgrep -P "${runner_pid}" xctest | head -n 1 || true)"
    if [[ -z "${target_pid}" ]]; then
      target_pid="$(pgrep -f 'xctest.*DockCatTaskAssistantPackageTests' | head -n 1 || true)"
    fi
    if [[ -n "${target_pid}" ]]; then
      break
    fi
    sleep 1
  done

  if [[ -z "${target_pid}" ]]; then
    wait "${runner_pid}" || true
    record_result "${name}" "NA" "NA" "NA" "${notes}; target pid unavailable"
    return
  fi

  local max_rss_kb=0
  local current_mb="NA"
  local peak_mb="NA"
  local vmmap_captured=0

  while ps -p "${target_pid}" >/dev/null 2>&1; do
    local rss_kb
    rss_kb="$(ps -o rss= -p "${target_pid}" | awk '{print $1}')"
    if [[ -n "${rss_kb}" && "${rss_kb}" -gt "${max_rss_kb}" ]]; then
      max_rss_kb="${rss_kb}"
    fi
    if [[ "${vmmap_captured}" -eq 0 ]]; then
      local vmmap_values
      vmmap_values="$(capture_vmmap_values "${target_pid}")"
      current_mb="$(printf '%s' "${vmmap_values}" | cut -f1)"
      peak_mb="$(printf '%s' "${vmmap_values}" | cut -f2)"
      vmmap_captured=1
    fi
    sleep 1
  done

  wait "${runner_pid}" || true

  local max_rss_mb
  max_rss_mb="$(python3 - <<PY
rss_kb = ${max_rss_kb}
print(f"{rss_kb / 1024:.1f}")
PY
)"
  record_result "${name}" "${current_mb}" "${peak_mb}" "${max_rss_mb}" "${notes}"
}

python_emit_reports() {
  python3 - "${RESULTS_TSV}" "${SUMMARY_JSON}" "${SUMMARY_MD}" "${BASELINE_PATH}" "${ENFORCE_FLAG}" <<'PY'
import json
import sys
from pathlib import Path

results_path = Path(sys.argv[1])
summary_json = Path(sys.argv[2])
summary_md = Path(sys.argv[3])
baseline_path = Path(sys.argv[4])
enforce_flag = sys.argv[5]

rows = []
for line in results_path.read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    name, current_mb, peak_mb, max_rss_mb, notes = line.split("\t", 4)
    rows.append(
        {
            "name": name,
            "physical_footprint_mb": None if current_mb == "NA" else float(current_mb),
            "peak_physical_footprint_mb": None if peak_mb == "NA" else float(peak_mb),
            "max_rss_mb": None if max_rss_mb == "NA" else float(max_rss_mb),
            "notes": notes,
        }
    )

summary_json.write_text(json.dumps({"scenarios": rows}, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

lines = ["# Memory Suite Summary", ""]
for row in rows:
    lines.append(f"- `{row['name']}`: footprint={row['physical_footprint_mb']}MB peak={row['peak_physical_footprint_mb']}MB max_rss={row['max_rss_mb']}MB ({row['notes']})")
summary_md.write_text("\n".join(lines) + "\n", encoding="utf-8")

if enforce_flag != "--enforce":
    raise SystemExit(0)

baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
failures = []
for row in rows:
    expected = baseline["scenarios"].get(row["name"])
    if not expected:
        failures.append(f"Missing memory baseline for {row['name']}")
        continue
    for key, baseline_key in [
        ("physical_footprint_mb", "max_physical_footprint_mb"),
        ("peak_physical_footprint_mb", "max_peak_physical_footprint_mb"),
        ("max_rss_mb", "max_rss_mb"),
    ]:
        actual = row[key]
        limit = expected.get(baseline_key)
        if actual is None or limit is None:
            continue
        if actual > limit:
            failures.append(f"{row['name']} {key} {actual}MB exceeds {limit}MB")

if failures:
    for failure in failures:
        print(failure, file=sys.stderr)
    raise SystemExit(1)
PY
}

: > "${RESULTS_TSV}"
run_idle_app_launch
run_workload_process "workload_snapshot_burst" "WorkloadPerformanceTests/test_debouncedSnapshotBurstWorkload" "xctest snapshot burst"
run_workload_process "workload_cold_restore" "WorkloadPerformanceTests/test_coldRestoreSnapshotWorkload" "xctest cold restore"
python_emit_reports

echo "Memory summary JSON: ${SUMMARY_JSON}"
echo "Memory summary Markdown: ${SUMMARY_MD}"
