# ADR-0001: Split Import Runtime And Task Intake Control Out Of AppModel

## Status
Accepted

## Date
2026-04-07

## Context

### Problem Statement
`AppModel` had grown into a broad coordination object responsible for UI state, task mutations, import parsing, local model runtime preparation, persistence scheduling, and user-preference updates. This made performance work harder because hot paths and slow paths lived in the same type, and intake pressure from bulk imports could still push large task batches into the app without any admission control.

### Constraints
- The app is a local-first macOS SwiftUI application, not a server process.
- The task model and UI contracts must stay compatible with the existing views.
- We need performance controls that work on developer machines and in CI.
- Bulk task imports must remain available, but not at the cost of UI lockups or runaway memory growth.

### Requirements
- Preserve current user-facing behavior for task editing, importing, and local model setup.
- Reduce `AppModel` responsibility count and isolate slower coordination logic.
- Add explicit backpressure at the task-intake entry point.
- Keep persistence and benchmark tooling observable with Instruments and tests.

## Decision

We split two responsibilities out of `AppModel`:

1. `ImportRuntimeCoordinator`
   - Owns import-analysis preference changes, GGUF file selection, local model autodetection, and embedded runtime preparation.
   - Keeps runtime bootstrap and status mutation outside the main application state façade.

2. `TaskIntakeLimiter`
   - Enforces admission control for bulk import parsing and bulk task commit.
   - Rejects new intake when the app is already processing another import, when draft queues are too deep, when import text is too large, when a batch is too large, or when total task count would exceed a safety limit.

We also removed the unused `AppFlowyDocumentBridge` dependency chain, because its only remaining consumer was dead code.

### Architecture Diagram

```text
SwiftUI Views
    |
    v
  AppModel
    |-- TaskUseCases
    |-- ImportUseCases
    |-- SyncUseCases
    |-- SnapshotPersistenceCoordinator
    |-- ImportRuntimeCoordinator
    '-- TaskIntakeLimiter
```

### Key Interfaces
- `ImportRuntimeCoordinator.updateImportAnalysisProvider(_:)`
- `ImportRuntimeCoordinator.prepareEmbeddedImportRuntimeIfNeeded()`
- `TaskIntakeLimiter.beginParse(textLength:draftItemCount:currentTaskCount:)`
- `TaskIntakeLimiter.beginCommit(acceptedItemCount:currentTaskCount:)`
- `SnapshotPersistenceCoordinator.scheduleSave(snapshot:generation:)`

## Alternatives Considered

### Alternative 1: Keep Everything In AppModel
- **Description**: Continue growing `AppModel` and add more helper methods inline.
- **Pros**: Fewer files and fewer wrapper types.
- **Cons**: Keeps hot and cold paths tightly coupled, makes testing harder, and encourages future responsibility creep.
- **Rejection Reason**: This would preserve the current architectural bottleneck instead of reducing it.

### Alternative 2: Move All Intake Control Into ImportUseCases
- **Description**: Put admission control directly inside import use-case methods.
- **Pros**: Intake logic stays near import execution.
- **Cons**: Admission control is app-level policy, not import-domain logic; it would still couple task-capacity policy to parsing behavior.
- **Rejection Reason**: We want intake limits to remain visible and configurable at the app boundary.

## Consequences

### Positive
- `AppModel` now delegates local-model runtime concerns instead of owning them directly.
- Task-intake pressure is explicitly bounded before large imports mutate application state.
- Dead dependency surface is smaller after removing the unused AppFlowy bridge.
- Future profiling work can target smaller coordinators instead of one giant model object.

### Negative
- There are more coordination types to understand.
- Intake limits introduce a new class of user-visible rejection behavior for oversized imports.

### Risks
- Limits may be too conservative for some users.
  - Mitigation: thresholds are centralized in `TaskIntakeLimiter` and can be tuned without redesigning the app.
- More coordinators could lead to state-sync mistakes.
  - Mitigation: all coordinator state mutation still flows through `AppModel` closures on the main actor.

## Performance Implications
- **CPU**: Lower overhead in hot task-edit paths because several full-array rewrites were replaced with in-place mutation.
- **Memory**: Lower transient pressure during edits; intake limits reduce the chance of very large draft or commit spikes.
- **Load Time**: Neutral.
- **Network**: Neutral.

## Migration Plan
- Remove the unused AppFlowy bridge from `Package.swift`.
- Route import runtime operations through `ImportRuntimeCoordinator`.
- Route bulk intake admission through `TaskIntakeLimiter`.
- Keep the existing view API on `AppModel` so UI migration remains incremental.

## Validation Criteria
- `swift test` remains green.
- `./scripts/perf/run_microbenchmarks.sh --enforce` remains green.
- CPU and thread samples continue to show the main hotspot in persistence rather than new lock contention from the added coordinators.
- Bulk imports are rejected gracefully when limits are exceeded, with a visible message in the dashboard.

## Related Decisions
- [Performance playbook](/Users/handsomeboy/software development/DockCatTaskAssistant/docs/performance-playbook.md)
