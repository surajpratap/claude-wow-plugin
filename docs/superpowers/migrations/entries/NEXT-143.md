# `<NEXT-from>` → `<NEXT-to>`

<!-- sprint-mode placeholder: <NEXT-from> + <NEXT-to> are substituted by sprint-merge-bump.sh -->

## Modified

- **`plugin/scripts/wow-process/idle-monitor.py`** — the busy-predicate now counts a peer busy when its most-recent `bg-spawn` (across ALL episodes, not just the current stop-episode) is ≤ `BG_BUSY_MAX_AGE_SECONDS` (default 1200s/20min; env-tunable via `WOW_BG_BUSY_MAX_AGE_SECONDS`) old. Replaces Story-098's current-episode-only check, which read idle while a bg run that outlived its spawning episode was still going (`all-idle-nudge` then fired every 60s — recurred ~12× last sprint). Future-ts rows (clock skew, > `SKEW_TOLERANCE_SECONDS` ahead) are ignored. `now` is overridable via `WOW_IDLE_NOW_EPOCH` (deterministic tests). `parse_iso_ts` is now UTC-aware (`fromisoformat`, handles fractional/offset, with the whole-second-`Z` strptime fallback).
- **`plugin/tests/idle-monitor-bg-task-suppress.sh`** — pinned `WOW_IDLE_NOW_EPOCH` near the fixtures' ts so bg-spawn rows count as recent under the time-bound. Two assertions intentionally updated idle→busy (`A-c` resumed-after-bg, `A-e` cross-episode): the time-bound design deliberately keeps a recent bg-spawn busy regardless of later non-stop rows — the activity log can't distinguish "bg finished, peer resumed" from "bg still running, peer woke for an unrelated reason" (the exact bug), so resumption no longer self-clears; the cap provides recovery.

## Added

- **`plugin/tests/idle-monitor-bg-cross-episode.sh`** — regression: a GENUINE cross-episode fixture (intervening `stop` so the bg-spawn sits in a prior closed episode) → busy; a `cap=0` override flips it to idle, proving the verdict comes solely from the time-bound cross-episode bg-spawn (red-green). Plus expired-window→idle (recovery), same-episode→busy, no-bg→idle, and a future-ts skew-guard→idle case.

## Why

Story 098's "busy" exception was episode-scoped; a bg run that outlives its spawning episode (peer wakes for an unrelated reason, works, stops again) read idle. Time-bound only (not a self-clearing "later non-stop row", which would re-introduce the bug): fixes cross-episode + bounds it so a stale/finished bg eventually expires → idle-monitor recovers. The bg-spawn row records `claude_pid`, not the bg child PID (PreToolUse fires pre-spawn), so this is a bounded heuristic; precise per-PID liveness is backlog 181.

## Consumer action

`/reload-plugins` + restart peers per standard upgrade hygiene. No behavior change for consumers beyond fewer spurious idle nudges during long background runs; `WOW_BG_BUSY_MAX_AGE_SECONDS` tunes the window.

## Closes

Backlog item 177 (sprint 2026-05-22-self-correction-2). Incomplete-fix of story 098 / backlog 116. Predecessors: 098 (current-episode bg-spawn busy exception), 058 (activity-log liveness).
