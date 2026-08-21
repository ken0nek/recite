#!/bin/sh
# Run every recite test suite.
#
#   run.sh            golden files for recite-core  (pure, no side effects)
#   recite-tests.sh   the shared `recite` executable (sandboxed)
#   fish-tests.fish   the fish shim and its widget  (sandboxed, needs fish)
#   zsh-tests.zsh     the zsh widget                (sandboxed, needs zsh)
#   install-links.sh  install.sh's link contract    (sandboxed, needs fish)
#   clipboard.sh      recite-clip round-trip        (CLOBBERS the clipboard)
#   binding.sh        the alt-enter binding         (drives a real pty)
#   cross-shell.sh    fish and zsh copy the same    (drives a real pty)
#
# The last three are skipped unless their variable is set, so the default run has
# no side effects and no timing-sensitive case in it.
set -u

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
status=0

echo "== recite-core goldens =="
"$dir/run.sh" || status=1

echo
echo "== shared layer =="
"$dir/recite-tests.sh" || status=1

echo
echo "== fish layer =="
if command -v fish > /dev/null 2>&1; then
  fish "$dir/fish-tests.fish" || status=1
else
  echo "skip (fish not installed)"
fi

echo
echo "== zsh layer =="
# `zsh -f`: this suite sources the layer by path, so there is no rc to skip and
# nothing in the tester's own config can change the result.
if command -v zsh > /dev/null 2>&1; then
  zsh -f "$dir/zsh-tests.zsh" || status=1
else
  echo "skip (zsh not installed)"
fi

echo
echo "== install.sh links =="
"$dir/install-links.sh" || status=1

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
echo "== cross-shell clipboard =="
if [ "${RECITE_TEST_CROSS_SHELL:-}" = "1" ]; then
  "$dir/cross-shell.sh" || status=1
else
  echo "skip (set RECITE_TEST_CROSS_SHELL=1 — drives a real pty; timing-sensitive)"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SUITES PASSED"
else
  echo "FAILURES"
fi
exit $status
