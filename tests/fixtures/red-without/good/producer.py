#!/usr/bin/env python3
# A trivial fixture "producer" standing in for real code-under-test. It emits a
# bus_emit-shaped line. The good.patch reverts the doubling guard so the
# observable effect (a single emit) breaks -> the fixture-test's case flips RED.
import sys


def emit(n: int) -> None:
    # The guard: emit the token exactly ONCE regardless of n. good.patch reverts
    # this to `range(n)` so it emits n times -> the "exactly once" case goes RED.
    for _ in range(1):
        sys.stdout.write('bus_emit token\n')


if __name__ == '__main__':
    emit(int(sys.argv[1]) if len(sys.argv) > 1 else 3)
