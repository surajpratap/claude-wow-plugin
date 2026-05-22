# `<NEXT-from>` → `<NEXT-to>`

<!-- sprint-mode placeholder: <NEXT-from> + <NEXT-to> are substituted by sprint-merge-bump.sh -->

## Root-cause (so the misdiagnosis does not recur)

The cross-sprint verification flakes were **resource/OOM contention from concurrent `run-all`** (many python bridge subprocesses + startup-timing-sensitive suites racing under load). They were NOT:

- **a port-47823 collision** — the 6 hardcoded-`47823` bridge tests are POLLING mode, and `run.py` binds an HTTP listener ONLY in webhook mode, so 47823 is never bound (no collision; an instrumented 3×-concurrent reproduction produced zero connection-refused); and
- **NOT a `github-bridge-cursor.sh` test bug** — instrumented 0/15 nonzero under heavy concurrent load, with a deterministic `$FAIL`-only exit. An earlier "1/12 nonzero" was a harness/resource artifact.

The fix is to **serialize** concurrent `run-all` so they don't contend — which is exactly why the team's manual run-all-slot practice worked.

## Added

- **`plugin/scripts/run-all-lock.py`** — python lock wrapper: acquires an exclusive `fcntl.flock` on a repo-keyed lockfile (canonical-absolute `git-common-dir`, hashed, under `$TMPDIR`) and runs the suite pass as its child while holding. The lock fd is NON-inheritable (PEP 446), so suite subprocesses never co-hold it → the lock lifetime is bound to the wrapper and releases the instant it dies (normal exit OR signal) — no held-slot-deadlock. Env-overridable acquire timeout (`WOW_RUNALL_LOCK_TIMEOUT`, default 1800s) so a live hung holder can't block forever. `flock(1)` is absent on stock macOS; `fcntl.flock` is portable.
- **`plugin/scripts/run-all-lock.sh`** — sourceable re-exec guard: re-execs `run-all.sh` under the python wrapper (preserving original args), then in the locked pass applies test-only regression hooks.
- **`plugin/tests/run-all-lock.sh`** — regression that drives the REAL `run-all.sh` path (a proxy would hide an inert/subprocess integration): proves a 2nd concurrent run-all BLOCKS until the 1st releases, auto-releases when the holder is killed, and the acquire-timeout fires with a diagnostic.
- **`plugin/tests/lib/bridge-port.sh`** — `wait_for_bridge` (poll for OUR bridge's `armed` readiness on stdout, not a forgeable port probe).

## Modified

- **`plugin/tests/run-all.sh`** + **root `tests/run-all.sh`** — **OPT-IN** serialization (default OFF): source the lock only when `WOW_RUNALL_SERIALIZE=1`. Normal `run-all` is completely unchanged (no re-exec, no lock); peers/CI opt in for serialization when running concurrently. (Per the human's call — the lock is a tool, not forced on every run-all.)
- **`plugin/tests/github-bridge-webhook-mode.sh`** — replaced the fixed startup `sleep 3` with `wait_for_bridge` (the genuine startup-race robustness win).

## Consumer action

`/reload-plugins` + restart peers per standard upgrade hygiene. `run-all` is unchanged by default. To serialize concurrent runs (avoid resource/OOM contention when multiple agents run the suite at once), set `WOW_RUNALL_SERIALIZE=1` — `run-all` then re-execs under the lifetime-bound lock; `WOW_RUNALL_LOCK_TIMEOUT` tunes the max wait.

## Closes

Backlog 178 (sprint 2026-05-22-self-correction-2); subsumes backlog 158. The original port/cursor premise was a verified misdiagnosis (re-framed by M after SD's instrumentation).
