#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUTPUT_FILE="${ROOT_DIR}/.build/persistence-harness.log"

mkdir -p "${ROOT_DIR}/.build"

pushd "${ROOT_DIR}" >/dev/null
TEST_OUTPUT="$(swift test --filter 'AppRepositoryTests|PersistenceHarnessTests' 2>&1)"
TEST_STATUS=$?
popd >/dev/null

printf '%s\n' "${TEST_OUTPUT}" | tee "${OUTPUT_FILE}"

if [[ ${TEST_STATUS} -ne 0 ]]; then
  exit ${TEST_STATUS}
fi

SUMMARY_LINE="$(printf '%s\n' "${TEST_OUTPUT}" | grep -E "Executed [0-9]+ tests?, with 0 failures" | tail -n 1 || true)"
if [[ -n "${SUMMARY_LINE}" ]]; then
  echo
  echo "Correctness harness summary:"
  echo "  ${SUMMARY_LINE}"
else
  echo
  echo "Correctness harness passed."
fi
