#!/usr/bin/env bash
# Lint fixture (Story 170): a quoted <pat> with an embedded space (mirrors the
# real github-bridge-subcall-degraded.sh:99). A naive $4 extraction would read
# the count '1' and falsely flag; LAST-field extraction reads the ceiling 30.
# lint-timing-ceilings.sh MUST PASS this line (BLOCKER-2 regression).
wait_for "$f" 'recovered: test/repo' 1 30
