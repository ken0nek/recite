#!/bin/sh
# Run every recite test suite.
#
#   run.sh            golden files for recite-core  (pure, no side effects)
#   fish-tests.fish   fish-side command recovery    (pure, needs fish)
#   clipboard.sh      recite-clip round-trip        (CLOBBERS the clipboard)
#   binding.sh        the alt-enter binding         (drives a real pty)
#
# The last two are skipped unless their variable is set, so the default run has
# no side effects and no timing-sensitive case in it.
set -u

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
status=0

echo "== recite-core goldens =="
"$dir/run.sh" || status=1

echo
echo "== fish command recovery =="
if command -v fish > /dev/null 2>&1; then
  fish "$dir/fish-tests.fish" || status=1
else
  echo "skip (fish not installed)"
fi

echo
echo "== recite-clip round-trip =="
if [ "${RECITE_TEST_CLIPBOARD:-}" = "1" ]; then
  "$dir/clipboard.sh" || status=1
else
  echo "skip (set RECITE_TEST_CLIPBOARD=1 — this overwrites your clipboard)"
fi

echo
echo "== alt-enter binding =="
if [ "${RECITE_TEST_BINDING:-}" = "1" ]; then
  "$dir/binding.sh" || status=1
else
  echo "skip (set RECITE_TEST_BINDING=1 — drives a real pty; timing-sensitive)"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SUITES PASSED"
else
  echo "FAILURES"
fi
exit $status
