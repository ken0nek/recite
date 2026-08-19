#!/bin/sh
# Opt-in pty test for the alt-enter binding the README tells you to add.
#
# A keybinding cannot be exercised without a terminal, so binding.exp drives a
# real pty. That makes it timing-sensitive by construction — sends faster than
# fish's reader drop characters — and the default run promises the opposite: that
# a failure means the code is wrong rather than the environment. Hence the gate,
# the same one clipboard.sh sits behind. Binding tests are manual by nature —
# they need a terminal; this makes them available, not mandatory.
#
# No side effects: binding.exp puts a stub recite-clip on PATH inside a mktemp -d
# sandbox, so the real clipboard is never touched.
set -u

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if ! command -v expect > /dev/null 2>&1; then
  echo "skip (expect not installed)"
  exit 0
fi

TERM=dumb expect "$dir/binding.exp"
