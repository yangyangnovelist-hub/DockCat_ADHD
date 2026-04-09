# DockCatTaskAssistant Performance Playbook

## Goals

- Reproduce hot paths with stable synthetic pressure instead of ad hoc clicking.
- Capture CPU, allocation, and thread state evidence that maps back to concrete source files.
- Enforce a microbenchmark baseline in CI so regressions fail fast.

## Important Stack-Specific Notes

- This is a Swift/macOS app, so there is no JVM-style GC to inspect.
- Replace “GC pauses” with `Allocations`, heap growth, ARC churn, and temporary object spikes.
- Replace “Thread Dump” with `sample`, `spindump`, and Instruments’ Swift Concurrency or Time Profiler views.

## What Changed In This Refactor

- Snapshot persistence now goes through a debounced actor queue instead of firing a fresh full save on every mutation.
- Single-task updates in `TaskUseCases` now mutate arrays in place instead of rebuilding the full task array with `.map`.
- Core persistence and mind map sync paths now emit signposts through `PerformanceTrace`, so Instruments can attribute time to named intervals.
- Performance regression tests now exercise:
  - `task_rename_hot_path`
  - `mind_map_sync`
  - `repository_save_snapshot`
  - `repository_cold_restore`
  - persistence correctness round trips and debounce coalescing

## Current Baseline

- `task_rename_hot_path`: median `0.121ms`, p95 `0.198ms`
- `mind_map_sync`: median `44.963ms`, p95 `45.282ms`
- `repository_save_snapshot`: median `10.851ms`, p95 `10.883ms`
- `repository_cold_restore`: median `78.517ms`, p95 `79.147ms`

These numbers were recorded on April 7, 2026 from the local development machine and are stored in [`performance-baseline.json`](/Users/handsomeboy/software development/DockCatTaskAssistant/Tests/DockCatTaskAssistantTests/Fixtures/performance-baseline.json).

## Run Microbenchmarks

```bash
./scripts/perf/run_microbenchmarks.sh
./scripts/perf/run_microbenchmarks.sh --enforce
./scripts/perf/run_correctness_harness.sh
./scripts/perf/run_workload_suite.sh
./scripts/perf/run_workload_suite.sh --enforce
./scripts/perf/run_memory_suite.sh
./scripts/perf/run_memory_suite.sh --enforce
```

- `--enforce` sets `DOCKCAT_PERF_ENFORCE=1` and turns the checked-in baseline into a hard gate.
- The benchmark output is also mirrored into `.build/performance-regression.log`.
- The correctness harness runs repository save/load contract tests plus `SnapshotPersistenceCoordinator` debounce coverage and mirrors output into `.build/persistence-harness.log`.
- The workload harness mirrors output into `.build/workload-regression.log` and checks broad, manual-use baselines intended to catch major regressions rather than CI-grade noise.
- The memory harness writes JSON and Markdown summaries under `artifacts/perf/<timestamp>/memory/`.

## Run Workload Suite

```bash
./scripts/perf/run_workload_suite.sh
./scripts/perf/run_workload_suite.sh --enforce
```

- Current workload scenarios:
  - `rapid_task_edit_burst`
  - `large_import_commit`
  - `debounced_snapshot_burst`
  - `cold_restore_snapshot`
- These scenarios intentionally exercise `AppRepository` and `SnapshotPersistenceCoordinator` instead of stopping at in-memory mutations.
- The checked-in workload thresholds are intentionally broad because workstation contention makes this layer much noisier than the microbench suite.

## Run Memory Suite

```bash
./scripts/perf/run_memory_suite.sh
./scripts/perf/run_memory_suite.sh --enforce
```

- Current memory scenarios:
  - `idle_app_launch`
  - `workload_snapshot_burst`
  - `workload_cold_restore`
- The suite samples:
  - `RSS`
  - `physical footprint`
  - `peak physical footprint`
- Use the JSON output for automation and the Markdown summary for quick review.

## Capture CPU Flame Graphs

```bash
DOCKCAT_PERF_PROFILE_DURATION=180s ./scripts/perf/profile_cpu.sh
```

- This records a Time Profiler trace against the synthetic mind map synchronization benchmark.
- Open the generated `.trace` bundle in Instruments and inspect the widest stacks first.
- Look for repeated JSON serialization, tree rebuilding, regex cleanup, and full-array rewrites.

## Capture Allocation Pressure

```bash
DOCKCAT_PERF_PROFILE_DURATION=180s ./scripts/perf/profile_allocations.sh
```

- This records the repository save benchmark under the `Allocations` template.
- Look for large short-lived `Array`, `Dictionary`, and JSON payload allocations.
- Watch for a sawtooth heap pattern driven by repeated full snapshot writes.
- On some SIP-enabled machines, headless `xctrace` allocation capture can fail to attach to the spawned process. If that happens, run the same scenario from Instruments.app or fall back to Activity Monitor plus the thread samples.

## Capture Thread State

```bash
./scripts/perf/capture_thread_samples.sh
```

- The script launches the save benchmark, finds the `xctest` pid, and captures three `sample` dumps spaced five seconds apart.
- Use the text dumps to spot:
  - lock contention
  - blocking file I/O
  - repeated database writes
  - threads parked in the same wait chain

## CI Gate

- GitHub Actions runs `./scripts/perf/run_correctness_harness.sh` and `./scripts/perf/run_microbenchmarks.sh --enforce` on pull requests and manual dispatches.
- The threshold is currently `5%` over the checked-in median values.
- P95 is still recorded and printed on every run, but it is not a hard gate because shared CI runners introduce too much tail-latency noise.
- Workload and memory suites are intentionally kept out of PR hard gating because they are much more sensitive to host contention.
- If you intentionally improve or rebalance a benchmark, update the code first, rerun the benchmarks locally, then refresh the baseline file in the same PR.

## Recommended Next Targets

- Split `AppModel` into separate coordinators for persistence, import, and dashboard session state.
- Move large mind map JSON operations off the immediate UI mutation path when the user is not actively viewing the mind map.
- Add a queue-depth metric around import and sync operations so future backpressure policies can reject or defer work before UI responsiveness collapses.
