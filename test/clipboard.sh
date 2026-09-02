#!/bin/sh
# Integration test for recite-clip. Real clipboard, no mocks.
#
# This CLOBBERS the clipboard. Text is saved and restored; non-text contents (an
# image, a file promise) cannot be, and are lost. Kept out of run.sh for that
# reason — the golden suite stays pure.
set -u

# The subject here is the REAL round-trip through the default chain, and both of
# these would silently redirect it. The README tells a remote user to export
# RECITE_BACKEND=osc52; with that set in the tester's own rc, this suite writes
# an escape sequence at their terminal and then reports FAIL because pbpaste
# does not hold the payload — a failure of the environment wearing the name of
# a failure of the code.
unset RECITE_BACKEND RECITE_TTY

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
clip=${RECITE_CLIP:-"$dir/../functions/recite-clip"}

if [ ! -x "$clip" ]; then
  printf 'recite-clip not executable at %s\n' "$clip" >&2
  exit 2
fi

saved=$(pbpaste 2>/dev/null) || saved=
payload='recite-clip round-trip 12345'

# recite-clip reports its backend on stdout now. This suite's subject is the real
# round-trip, not the report — clip-tests.sh pins the line's shape.
printf '%s' "$payload" | "$clip" > /dev/null
rc=$?

got=$(pbpaste 2>/dev/null) || got=

# Restore before asserting, so a failure still leaves the clipboard as found.
printf '%s' "$saved" | pbcopy 2>/dev/null || true

if [ "$rc" -ne 0 ]; then
  printf 'FAIL recite-clip exited %s\n' "$rc"
  exit 1
fi

if [ "$got" = "$payload" ]; then
  printf 'ok   clipboard round-trip\n'
else
  printf 'FAIL clipboard round-trip\n  want: %s\n  got:  %s\n' "$payload" "$got"
  exit 1
fi
