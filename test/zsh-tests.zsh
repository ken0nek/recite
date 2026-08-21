#!/usr/bin/env zsh
# zsh-layer tests: the widget `recite init zsh` emits.
#
# The counterpart of fish-tests.fish, and deliberately much shorter, because the
# zsh layer is much smaller. Everything the fish function used to do — resolve
# the backends, tee, order the guard below it, clean up on a signal — moved into
# `recite`, the POSIX executable. What is left in either shell is one job:
# decide what the keystroke does to the command line. That is all this file
# tests, and it is all there is to test.
#
# Two properties make these safe unattended, the same two fish-tests.fish keeps:
# a stub sink means the real clipboard is never touched, and every case runs
# under `zsh -f` against the layer sourced by path — so no install is needed and
# a failure means the code is wrong rather than the environment.
#
# Three traps, each of which made a draft of this file report ok against a
# widget that did nothing at all:
#
# - `zle` has to be STUBBED, and stubbed before the layer is sourced. zsh
#   resolves a function name before a builtin, so a function named `zle` shadows
#   the real one; without it `zle accept-line` aborts with "widgets can only be
#   called when ZLE is active" and the case never reaches its assertion. (`zle
#   -N` outside ZLE is silently fine, so the missing stub shows up only on the
#   line that matters.)
# - `zsh -f` is right HERE and wrong in cross-shell.exp, for the same reason in
#   reverse: this file sources the layer by path, so there is no rc for `-f` to
#   skip. The pty harness reaches the layer THROUGH a generated rc, and `-f`
#   skips that too — which fails as though the widget were broken.
# - A wrapped buffer that PARSES proves nothing about the trailing-`#` case: an
#   appended suffix parses there too, it is just commented out and copies
#   nothing. Those cases run the rewritten buffer and assert on what the sink
#   received.

emulate -L zsh
setopt no_unset

typeset -g fails=0

check() {
  local desc=$1 got=$2 want=$3
  if [[ $got == $want ]]; then
    print -r -- "ok   $desc"
  else
    print -r -- "FAIL $desc"
    print -r -- "     want: [$want]"
    print -r -- "     got:  [$got]"
    (( fails++ ))
  fi
}

local repo=${0:A:h:h}
local box=$(mktemp -d)
trap 'rm -rf $box' EXIT

"$repo/functions/recite" init zsh > $box/init.zsh || {
  print -r -- "FAIL recite init zsh did not emit"
  exit 1
}

# Sink A: a spy `recite` that records the exact bytes of --as and drains stdin.
# Raw with `printf %s` rather than a line per argument — the header case is about
# byte-for-byte fidelity, and a helper that appends a newline would hide a
# trailing one that was lost.
mkdir -p $box/spy
cat > $box/spy/recite <<SPY
#!/bin/sh
: > "$box/ran"
while [ \$# -gt 0 ]; do
  case \$1 in
    --as) printf '%s' "\$2" > "$box/as"; shift 2 ;;
    *) shift ;;
  esac
done
cat > "$box/stdin"
SPY
chmod 755 $box/spy/recite

# Sink B: the real recite and the real core, with only the clipboard stubbed.
# The end-to-end cases go through this one, so what they assert is the block a
# user would actually paste.
mkdir -p $box/real
cp "$repo/functions/recite" "$repo/functions/recite-core" $box/real/
printf '#!/bin/sh\ncat > "%s"\n' "$box/copied" > $box/real/recite-clip
chmod 755 $box/real/recite-clip

# submit <buffer> — run the widget over a command line and leave the result in
# $BUFFER, $LBUFFER and $zle_calls. In-process, because the widget's whole job is
# what it does to those variables and a child would take them with it.
typeset -g zle_calls=
submit() {
  BUFFER=$1
  LBUFFER=$1
  zle_calls=
  __recite_submit
}

zle() { zle_calls="$zle_calls $*" }
source $box/init.zsh

# The layer's one contract with the user's rc: a widget by that name exists for
# `bindkey` to point at. Nothing else here would notice if `zle -N` were dropped.
check "the layer registers a widget" "${zle_calls## }" "-N __recite_submit"

# Empty is enter. Wrapping nothing produces a block with no command and no
# output, and reports a copy for it.
submit ""
check "an empty line submits unchanged" "$BUFFER/${zle_calls## }" "/accept-line"

submit "   "
check "a whitespace-only line submits unchanged" "$BUFFER/${zle_calls## }" "   /accept-line"

# A half-typed construct is not a command to submit. Inserting a newline is
# alt-enter's own default, so this is the keystroke's other job rather than a
# fallback: wrapped, the fragment refuses to parse and the next press wraps the
# wrapping.
submit 'echo "unterminated'
check "an incomplete command line is not wrapped" \
  "$BUFFER/$LBUFFER/${zle_calls## }" \
  'echo "unterminated/echo "unterminated'$'\n''/'

submit 'for i in 1 2; do'
check "an incomplete loop is not wrapped either" \
  "$BUFFER/${zle_calls## }" \
  'for i in 1 2; do/'

# The shape itself. Newlines rather than semicolons: a `#` comment ends at its
# line, so only a newline puts the closing brace out of its reach.
submit 'echo hi'
check "a complete line is wrapped in a block" \
  "$BUFFER" \
  "{"$'\n'"echo hi"$'\n'"} 2>&1 | recite --as 'echo hi'"
check "a wrapped line is submitted" "${zle_calls## }" "accept-line"

# run_wrapped <sink> <buffer> — execute a rewritten command line the way the
# shell would after accept-line. `zsh -f`, so the case is not at the mercy of
# whatever is in the tester's rc.
run_wrapped() {
  rm -f $box/as $box/stdin $box/copied $box/ran
  PATH="$box/$1:/usr/bin:/bin" zsh -f -c "$2" > /dev/null 2>&1
}

# The header is the one line the user did not choose, so it has to be the line
# they typed. Round-tripped through ${(qq)} and back out through the shell that
# runs the wrapper — which is the only place the quoting can be wrong.
local typed='echo "it is $HOME"'
submit $typed
run_wrapped spy $BUFFER
check "--as carries the typed line verbatim" "$(cat $box/as)" "$typed"

# The awkward halves of the quoting, in one line: an embedded single quote is
# what ${(qq)} has to escape out of its own quoting, and a backslash is what a
# naive escape doubles.
#
# The quote is inside DOUBLE quotes, and it has to be. A bare `echo it's a\b` is
# an unterminated string — the widget refuses to wrap it, correctly, and the case
# then asserts against a --as that was never passed. What is under test here is
# the quoting of a valid line, not the rejection of an invalid one.
typed=$'echo "it\'s" a\\b'
submit $typed
run_wrapped spy $BUFFER
check "quoting round-trips through --as" "$(cat $box/as)" "$typed"

# Trailing syntax. Appended rather than wrapped, each of these collides with the
# suffix — and the assertion is what the sink RECEIVED, never that the buffer
# parses: with a trailing `#` an appended suffix parses perfectly well, it is
# just commented out, so the command runs bare and nothing is copied.
#
# zsh leaves interactive_comments off, so a typed `#` is a literal argument here
# rather than a comment. That is zsh being zsh — what this pins is that the
# wrapper does not care either way.
submit 'echo RECITE_COMMENT_CASE # note'
run_wrapped real $BUFFER
check "a trailing comment does not swallow the suffix" \
  "$(grep -c RECITE_COMMENT_CASE $box/copied)" 2

submit 'echo RECITE_SEMI_CASE;'
run_wrapped real $BUFFER
check "a trailing semicolon still parses and runs" \
  "$(grep -c RECITE_SEMI_CASE $box/copied)" 2

submit 'echo RECITE_AMP_CASE &'
run_wrapped real $BUFFER
check "a trailing ampersand still parses and runs" \
  "$(grep -c RECITE_AMP_CASE $box/copied)" 2

# stderr is captured too — the `2>&1` in the wrapper is half of what recite is
# for, and a block that shows only stdout is a block that hides the error the
# user wanted to paste.
submit 'echo OUT; echo ERR >&2'
run_wrapped real $BUFFER
# `grep -E`, never a BRE with `\|` in it: BSD grep has no GNU alternation there,
# and it does not fail loudly — it matched exactly ONE of these two lines while
# the GNU grep on the same machine matched both, which is a green suite on one
# box and a red one on the next.
check "stderr lands in the block" \
  "$(grep -cE '^(OUT|ERR)$' $box/copied)" 2

# End to end through the real core: the fence and the header. The zsh half of
# the same claim fish-tests.fish makes for fish.
submit 'echo total 5'
run_wrapped real $BUFFER
check "the block is fenced and headed" \
  "$(tr '\n' '|' < $box/copied)" \
  '```console|$ echo total 5|total 5|```|'

# Redaction, with the credential in a FILE rather than on the command line. The
# header goes through redaction too, so a token typed into the command would be
# redacted there as well — and the case would pass without the OUTPUT ever having
# been read.
print -r -- 'sk-abc123def456ghi789jkl012mno345pqr678stu' > $box/secret
submit "cat $box/secret"
run_wrapped real $BUFFER
check "output is redacted on the way to the clipboard" \
  "$(grep -c REDACTED $box/copied)/$(grep -c sk-abc123 $box/copied)" "1/0"

print
if (( fails == 0 )); then
  print "all zsh assertions passed"
else
  print "$fails failed"
fi
exit $fails
