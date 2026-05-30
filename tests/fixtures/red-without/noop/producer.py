#!/usr/bin/env python3
# A fixture producer whose noop.patch changes only a COMMENT (behavior-neutral).
# The fixture-test below stays GREEN under that revert -> the lint MUST detect
# the annotation as a no-op (hollow). This is the core anti-hollow assertion.
import sys

# MARKER-COMMENT-A: noop.patch flips this comment text only (no behavior change).


def emit() -> None:
    sys.stdout.write('bus_emit stable-token\n')


if __name__ == '__main__':
    emit()
