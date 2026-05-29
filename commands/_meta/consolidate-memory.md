---
description: Slash command — consolidate CC auto-memory into role's learnings file
---

You are invoking the memory ↔ learnings consolidation pass for your role.

1. Resolve the active role via `bash "$(wow-locate scripts/whats-my-role.sh)" whats-my-role`.
2. Run `bash "$(wow-locate scripts/consolidate-memory.sh)" <role>`. The script:
   - Walks `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<encoded-project>/memory/` (encoded = `$(git rev-parse --show-toplevel) | sed 's|/|-|g'`).
   - Attributes each entry to a role via 4-path heuristic (frontmatter `metadata.role`, `[role: X]` body marker, exactly-one-role mention, filename prefix).
   - Appends in-scope entries to `implementations/learnings/<role>.md` under a `## From memory consolidation (<date>)` section, with provenance footer.
   - Marks consolidated memory files with `consolidated-into:` in frontmatter (or deletes when `WOW_DROP_CONSOLIDATED_MEMORY=1`).
   - Appends ambiguous entries to `implementations/learnings/.consolidate-needs-triage.md` for human review.
3. Parse the script's stdout summary `{role, path, entries_added, entries_skipped, triage_count}` and emit `learnings-consolidated` (to: `manager-*`) via `mcp__claude-wow__bus_emit` with that payload. Always emit — even on a no-op / triage-only run.
4. If `triage_count > 0`, report to the user that triage entries need attention; otherwise, confirm with the entries_added count.
