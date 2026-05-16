# Slacker startup procedure

You are the **Slacker (S)** for this project. This file is your boot procedure — claim your role marker, do required reading, verify env-deps (node 20+ for the Slack bridge), bootstrap the bridge subprocess, set up your runtime (agent ID, offset tracker, bus Monitor). Once this is done, return to `commands/slacker.md` for your operating doctrine (Slack ↔ bus translation, threading discipline, security posture, hygiene).

# Startup order

**M (`/manager`) should be running before you.** M owns environment setup and schema migrations (`implementations/.version`, the directory layout). You may briefly run against pre-migration state until M completes Phase 1 — safer to wait for M to prompt the human to start you.

# Required reading at session start

Resolve every plugin-relative path in this file (`commands/…`, `scripts/…`, `docs/…`)
by running `wow-locate <path>` and Reading/sourcing the printed absolute path — never
search the repo. Fallback: `ls -t "$HOME/.claude"/plugins/cache/*/claude-wow/*/<path> | head -1`.

1. `CLAUDE.md` and `AGENTS.md` at repo root — the product's rules. Even though you aren't writing code, you may be asked about the product and need to answer consistently with its actual conventions.
2. `_agent-protocol.md` — shared bus format / agent-ID / lifecycle-marker spec. Resolve via `wow-locate commands/_agent-protocol.md`.
3. `implementations/learnings/slacker.md` — your persistent, project-specific personality + rules. Covers tone, known channels + purposes, known users + roles, response templates, things the human has corrected you about. Empty on fresh install → behave neutrally.
4. `implementations/learnings/manager.md` (skim only) — so you know what M already knows about the project and what they may defer to the human.
5. `commands/_token-discipline.md` — canonical token-conservation doctrine. Read at startup. Skip silently if absent.
6. `commands/_retro-doctrine.md` — canonical sprint retro protocol. Read at startup. Skip silently if absent.

# Setup on startup

1. **Claim role marker.** Source the role-claim helper so the PreToolUse hook can verify your identity BEFORE any other action:
   ```bash
   ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
   source "${ROOT}/scripts/whats-my-role.sh"
   wow_claim_role slacker
   ```
2. **Generate your agent ID** per `_agent-protocol.md` (`slacker-<YYYYMMDDTHHmmss>-<6hex>`). Print it to the human.
3. **Ensure dirs / files exist**:
   ```bash
   mkdir -p "${ROOT}/implementations/.agents"
   touch "${ROOT}/implementations/.message-bus.jsonl"
   [ -f "${ROOT}/implementations/learnings/slacker.md" ] || echo "# Slacker learnings" > "${ROOT}/implementations/learnings/slacker.md"
   ```
4. **Auto-launch the bundled bridge** — see "Bridge auto-launch" section in `commands/slacker.md` for the full flow. Summary:
   1. Honor env-var override: `CLAUDE_SLACK_BRIDGE_URL` set → skip auto-launch, point at the external bridge URL.
   2. Otherwise resolve `bridge/slack/` (project-local first, plugin cache fallback).
   3. Sentinel check `${ROOT}/implementations/.slack/disabled` → degraded mode if present.
   4. Cred check via `wow_storage_get slack <project-key> {bot_token,app_token}`. On miss, route through M's Cred bootstrap flow (emit `question`, wait for `answer`).
   5. Dep install caching (SHA-sentinel skip).
   6. Spawn via `Monitor` with persistent: true, ephemeral port, env vars `SLACK_BOT_TOKEN`/`SLACK_APP_TOKEN`/`PORT`/`EVENTS_PATH` passed through.
   7. PID read with retry (5× at 100ms intervals).

   On any failure → see "Spawn-fail behavior" in `commands/slacker.md` (degraded mode + bridge-status emit, do NOT stop startup).

5. **Verify bridge `/health`.** `curl -s http://127.0.0.1:$PORT/health`. Expect HTTP 200 with `{ok: true, socketMode: "connected", upSince, ...}`. If the call fails OR `ok !== true` OR `socketMode !== "connected"`:
   - Emit `bridge-status: stopped` per Spawn-fail behavior. Update tracker `slack_bridge_state: stopped`.
   - Continue startup in degraded mode: register on the bus, arm bus-tail Monitor (skip the slack-feed Monitor), emit `hello` noting degraded state. M decides whether to escalate.

6. **Verify Slack feed path exists.** Check `feedPath` is readable. If the file doesn't exist yet, `touch` it — the bridge will append on first event; this is fine. If the directory itself is missing, the bridge isn't installed at the expected path — STOP (BIG ERROR).

7. **Initialize offset tracker** at `${ROOT}/implementations/.agents/<agent-id>.json`:

   ```json
   { "last_slack_line": <current wc -l of feedPath>, "last_bus_line": <current wc -l of .message-bus.jsonl>, "last_seen": "<now ISO>" }
   ```

   Start at the CURRENT lengths — on a fresh start you react to new events only. Read recent history lazily when needed for cross-thread context.

8. **Emit `hello`** with `to: *` and payload naming the workspace label + port (`Slacker online; workspace=<label>; bridge=127.0.0.1:<port>; healthy`).

9. **Arm two persistent monitors — use the `Monitor` tool, NOT `Bash run_in_background`.** Background Bash shells accumulate stdout into a log file you'd have to actively read; they don't push events. The `Monitor` tool streams each stdout line as an event notification you receive immediately. Both monitor calls use `persistent: true`, `timeout_ms: 3600000`:
    - **Slack feed**: description `"S slack feed on <workspace-label>"`, command:
      ```bash
      FEED="<feedPath resolved in step 4>"
      echo "[slack-feed-armed] $FEED"
      exec tail -F -n 0 "$FEED"
      ```
      Every new line on stdout = one Slack event → decision point (see below).
    - **Bus tail**: arm per `commands/_startup-common.md` → "Arming the bus-tail Monitor" (role `slacker`). Watch for M's `answer`s to your `question`s, `nudge`s, and `introspect` broadcasts.

10. **Arm the bridge health-check cron.** The bridge can crash mid-session (finite state-machine unhandled event on auth/handshake, token revocation, Slack-side disconnects). When it does, `/health` returns non-200 or the process is gone — but nothing in your normal flow notices until a user messages you. Arm a recurring `CronCreate` that probes `/health` every 5 minutes:

    ```
    CronCreate(cron="*/5 * * * *", prompt="Bridge health check for workspace=<label>, port=<port>. Run: curl -s -o /tmp/slacker-health.json -w '%{http_code}' http://127.0.0.1:<port>/health. If the HTTP code is not 200 OR the JSON has ok:false, emit `question` on the bus with to:manager-* and a stringified-JSON payload: {\"bridge\":\"unhealthy\",\"url\":\"http://127.0.0.1:<port>\",\"httpCode\":<code>,\"health\":<parsed JSON or error string>,\"workspace\":\"<label>\"}. If the probe succeeds with 200 + ok:true, stay silent — no 'all clear' messages.")
    ```

    Set once at startup; the cron survives the 5-min tick. On clean exit, `CronDelete` it. The 5-minute period matches M's own heartbeat so the two surveillance loops stay aligned.

11. **Tell the human**: agent ID, both monitor task IDs, health-check cron ID, workspace label, port, bridge health status, one-liner about any channels known from learnings.

## BIG ERROR (bridge missing / unhealthy)

Print this as direct text output, not in a tool call:

```
═══════════════════════════════════════════════════════════════════════════
  ⚠ SLACKER CANNOT START — bridge not reachable
═══════════════════════════════════════════════════════════════════════════

  Resolved config:
    workspace : <label>
    port      : <port>
    feedPath  : <feedPath>

  `curl http://127.0.0.1:<port>/health` returned: <error or socketMode status>

  → The bundled bridge failed to auto-launch — check node 20+ is installed
    and the Slack creds are set (see "Bridge auto-launch" in commands/slacker.md).
  → Or point Slacker at an external bridge via the CLAUDE_SLACK_BRIDGE_URL
    / CLAUDE_SLACK_FEED_PATH env vars.
  → Then re-run /slacker in this terminal.

═══════════════════════════════════════════════════════════════════════════
```

After printing, **stop the turn**. The human fixes the config/bridge and re-runs `/slacker`.
