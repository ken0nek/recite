#!/usr/bin/env fish
# Unit tests for the fish-side command-string recovery.
#
# The one piece of the fish layer with real logic, and its failure mode is the
# nasty kind: silently labelling output with the WRONG command.

set -g fails 0

function check -a desc input want
    # Collected, or a multi-line result arrives here already split into a list and
    # "$got" compares it space-joined — which would silently flatten exactly the
    # newlines the last two cases exist to pin. Single-line cases are unaffected.
    set -l got (__recite_strip_suffix $input | string collect)
    if test "$got" = "$want"
        echo "ok   $desc"
    else
        echo "FAIL $desc"
        echo "     input: [$input]"
        echo "     want:  [$want]"
        echo "     got:   [$got]"
        set -g fails (math $fails + 1)
    end
end

check "plain suffix"          'echo hi | recite'                  'echo hi'
check "2>&1 suffix"           'echo hi 2>&1 | recite'             'echo hi'
check "suffix with flags"     'echo hi 2>&1 | recite --no-redact' 'echo hi'
check "no spaces around pipe" 'echo hi|recite'                    'echo hi'
check "pipeline preserved"    'ls | sort | recite'                'ls | sort'

# The safety guard: a line NOT ending in a recite suffix is not this command, so
# returning nothing (and omitting the header) is correct. Guessing would attach
# someone else's command to this output.
check "unrelated history line" 'brew list' ''
check "empty history line"     '' ''

# Asserted so the best-effort limit is a known quantity: a literal '| recite'
# inside a quoted string still survives, because the match anchors on the LAST.
check "quoted pipe inside" 'echo "a | recite b" | recite' 'echo "a | recite b"'

# fish stores a multi-line command as ONE history entry containing newlines.
# Without `string collect` both cases below yield a flattened, wrong command
# string: the substitution splits the entry into a list, so the guard compares a
# space-joined list against a newline-carrying original — never equal, so the
# guard never fires. The first case is the dangerous one; it is how someone
# else's command gets attached to this output.
check "multi-line, unrelated" 'for i in 1 2
echo hello
end' ''
check "multi-line with suffix" 'for i in 1 2
echo hello
end | recite' 'for i in 1 2
echo hello
end'

# ---------------------------------------------------------------------------
# The `recite` function itself.
#
# Everything above tests one pure string function. Nothing else covers the
# pipeline — not the resolver, not the tee, not the ORDER between them — and
# without that a guard that destroys the command's output passes green.
#
# Two properties make these safe unattended: a stub `recite-clip` means the real
# clipboard is never touched, and each case runs in a `fish --no-config` child
# that `source`s recite.fish by path. So unlike the assertions above they do NOT
# need `./install.sh`, and a failure means the code is wrong, not the environment.

function check_eq -a desc got want
    if test "$got" = "$want"
        echo "ok   $desc"
    else
        echo "FAIL $desc"
        echo "     want: [$want]"
        echo "     got:  [$got]"
        set -g fails (math $fails + 1)
    end
end

set -l repo (path resolve (dirname (status -f))/..)
set -l box (mktemp -d)
mkdir -p $box/onpath $box/fisher $box/lonely $box/plant $box/checkout $box/autoload $box/tmp $box/tmp-refuse $box/slowcore $box/tmp2

# Stand-in clipboard: records what it was handed instead of running pbcopy.
printf '#!/bin/sh\ncat > "%s"\n' $box/copied >$box/onpath/recite-clip
chmod 755 $box/onpath/recite-clip
cp $repo/functions/recite-core $box/onpath/recite-core

# PATH channel (Homebrew, install.sh): both halves on PATH, none beside it.
cp $repo/functions/recite.fish $box/lonely/recite.fish
set -l onpath "set -x PATH $box/onpath /usr/bin /bin; source $box/lonely/recite.fish"

# The output must reach the terminal exactly as the command produced it — the
# clipboard is the only place redaction belongs.
set -l printed (fish --no-config -c "$onpath; printf 'total 5\nsk-abc123XYZ\n' | recite --as 'ls -la'" 2>/dev/null | string join '|')
check_eq "output reaches the terminal unredacted" $printed 'total 5|sk-abc123XYZ'
check_eq "clipboard block is fenced, headed and redacted" (command cat $box/copied | string join '|') '```console|$ ls -la|total 5|[REDACTED]|```'

# The header is the one line the user did not choose: with the binding it is
# `commandline -b` verbatim, so a credential typed on the command line reaches
# the clipboard unless the header goes through redaction too.
rm -f $box/copied
fish --no-config -c "$onpath; printf 'x\n' | recite --as 'deploy --token sk-live-AAABBB'" >/dev/null 2>&1
check_eq "the \$ command header is redacted too" (command cat $box/copied | string join '|') '```console|$ deploy --token [REDACTED]|x|```'

# A version query must not have side effects.
rm -f $box/copied
fish --no-config -c "$onpath; printf 'x\n' | recite --version" >/dev/null 2>&1
set -l touched no
test -f $box/copied; and set touched yes
check_eq "--version never touches the clipboard" $touched no

# Sibling fallback — the fisher shape: nothing on PATH, both halves beside
# recite.fish. Unreachable in CI's PATH-based install, so without this case the
# branch is never executed anywhere.
cp $repo/functions/recite.fish $repo/functions/recite-core $box/fisher/
cp $box/onpath/recite-clip $box/fisher/recite-clip
rm -f $box/copied
fish --no-config -c "set -x PATH /usr/bin /bin; source $box/fisher/recite.fish; printf 'sib\n' | recite --as 'fisher shape'" >/dev/null 2>&1
check_eq "sibling fallback resolves with an empty PATH" (command cat $box/copied 2>/dev/null | string join '|') '```console|$ fisher shape|sib|```'

# install.sh shape, and why `path resolve` is in there: the autoload path is a
# SYMLINK and only its target's directory holds the executables. The fisher case
# above cannot catch this — it copies real files, where resolving is a no-op.
cp $repo/functions/recite.fish $repo/functions/recite-core $box/checkout/
cp $box/onpath/recite-clip $box/checkout/recite-clip
ln -s $box/checkout/recite.fish $box/autoload/recite.fish
rm -f $box/copied
fish --no-config -c "set -x PATH /usr/bin /bin; source $box/autoload/recite.fish; printf 'sym\n' | recite --as symlinked" >/dev/null 2>&1
check_eq "a symlinked function resolves through to its checkout" (command cat $box/copied 2>/dev/null | string join '|') '```console|$ symlinked|sym|```'

# Failing to copy is recoverable; destroying the output is not. The guard has to
# sit BELOW the tee, so this must still print and still exit non-zero.
set -l survived (fish --no-config -c "set -x PATH /usr/bin /bin; source $box/lonely/recite.fish; printf 'MUST SURVIVE\n' | recite --as x" 2>/dev/null)
check_eq "output survives when neither half resolves" $survived 'MUST SURVIVE'

fish --no-config -c "set -x PATH /usr/bin /bin; source $box/lonely/recite.fish; printf 'x\n' | recite --as x" >/dev/null 2>&1
check_eq "unresolvable halves exit 2" $status 2

# Sourced from stdin there is no defining file, so the sibling directory must
# come out EMPTY rather than `.` — otherwise a resolution miss hands the captured
# stream to whatever ./recite-core is in the cwd.
#
# The plant touches a file rather than printing: asserting on a stream would need
# fish's `&|` to carry stderr, and `2>&1 |` silently does not — so a stream
# assertion reports ok against code that executes the plant.
cp $repo/functions/recite.fish $box/plant/recite.fish
printf '#!/bin/sh\ntouch "%s"\ncat >/dev/null\n' $box/planted-ran >$box/plant/recite-core
# A plausible recite-clip has to sit here too: without it the guard rejects the
# CLIP and returns before reaching the planted core, which makes this case pass
# for the wrong reason and prove nothing about $here.
printf '#!/bin/sh\ncat >/dev/null\n' >$box/plant/recite-clip
chmod 755 $box/plant/recite-core $box/plant/recite-clip
rm -f $box/planted-ran
fish --no-config -c "cd $box/plant; set -x PATH /usr/bin /bin; command cat recite.fish | source; printf 'secret\n' | recite --as x" >/dev/null 2>&1
set -l planted safe
test -f $box/planted-ran; and set planted ran
check_eq "cwd is never used as the sibling directory" $planted safe

# A refusal has to mean nothing happened. The core exits 3 before writing a byte,
# and a pipeline starts both halves at once — so the clip runs anyway, is handed
# an empty stream, and pbcopy destroys whatever the user had.
#
# Three facts in one string, because an untouched clipboard is also what a run
# that never reached the core at all leaves behind:
#   SENTINEL — seeded BEFORE the run, so "the stub never ran" is distinguishable
#              from "the stub rewrote the file as empty". This is the one fact
#              that fails against a pipeline.
#   yes      — the core really was reached and really did refuse.
#   0        — the refusal path takes BOTH temp files with it. Its own TMPDIR, so
#              the interrupt case below still counts only what it created.
printf 'SENTINEL' >$box/copied
fish --no-config -c "$onpath; set -x TMPDIR $box/tmp-refuse; printf 'a\000b\n' | recite --as binary" >/dev/null 2>$box/refusal
set -l refused_st $status
set -l kept (command cat $box/copied)
set -l refused no
grep -q refusing $box/refusal; and set refused yes
set -l stranded (command ls -A $box/tmp-refuse | string match -r '^recite\.' | count)
check_eq "a refused capture leaves the clipboard alone" "$kept/$refused/$stranded" SENTINEL/yes/0

# Not copying is one thing; reporting success for it would be another. Read off
# the run above — repeating the identical command would test nothing further.
check_eq "a refused capture still exits 3" $refused_st 3

# Ctrl-C on a recited command must not strand the capture buffer: it holds the
# UNREDACTED output, which is the one thing this tool exists to keep off a
# clipboard, and $TMPDIR on macOS is only swept after three days.
#
# Four facts in one string, because "no file left behind" on its own passes
# against code that never got as far as creating one:
#   SECRET_PAYLOAD — the output still reached the terminal, so the interrupt
#                    check sits BELOW the tee; above it, an early return would
#                    destroy the output and SIGPIPE the producer.
#   130            — reachable only through that check, and only because the
#                    handler stops fish aborting the function outright.
#   0 / no         — nothing left in TMPDIR, nothing handed to the clipboard.
#
# The signal goes to the child PROCESS GROUP, the way Ctrl-C does. A function in
# a pipeline runs in a forked fish child, so signalling the shell's own pid would
# miss the process actually holding the buffer. That needs job control, and it
# needs an `sh` harness: fish abandons the rest of its script when a job dies of
# SIGINT, so the runner cannot deliver the signal and then still assert.
printf '#!/bin/sh\necho SECRET_PAYLOAD\nsleep 8\n' >$box/slow
chmod 755 $box/slow
printf '%s\n' 'set -l box $argv[1]' \
    'set -x PATH $box/onpath /usr/bin /bin' \
    'set -x TMPDIR $box/tmp' \
    'source $box/lonely/recite.fish' \
    '$box/slow | recite --as slow' \
    'echo "RECITE-EXIT=$status"' >$box/int.fish
# `command rm`, unlike the bare ones above: a user function named `rm` would
# leave the previous case's file here and fail this one for the wrong reason.
command rm -f $box/copied
sh -c '
set -m
box=$1
fish --no-config "$box/int.fish" "$box" > "$box/int.out" 2>&1 &
p=$!
# Polls until the payload is IN the buffer rather than sleeping a fixed time:
# that is the proof the tee is running, so the signal cannot land too early.
i=0
while [ $i -lt 100 ]; do
    grep -q SECRET_PAYLOAD "$box"/tmp/recite.* 2>/dev/null && break
    i=$((i + 1))
    sleep 0.1
done
g=$(ps -o pgid= $p | tr -d " ")
[ -n "$g" ] && [ "$g" != "$(ps -o pgid= $$ | tr -d " ")" ] && kill -INT -"$g"
wait $p
exit 0' recite-int $box >$box/int.log 2>&1
set -l printed no
grep -q SECRET_PAYLOAD $box/int.out; and set printed yes
set -l code (string replace -f 'RECITE-EXIT=' '' <$box/int.out | string trim)
test -n "$code"; or set code aborted
set -l left (command ls -A $box/tmp | string match -r '^recite\.' | count)
set -l copied no
test -f $box/copied; and set copied yes
check_eq "an interrupted run strands no unredacted buffer" "$printed/$code/$left/$copied" yes/130/0/no

# The SECOND interrupt window, which the check above cannot see: the tee is long
# done, and the signal lands between formatting the block and copying it. The
# handler deleted the formatted file by then, so the copy redirects from a
# path that is gone — measured, and what the user sees is
#     warning: An error occurred while redirecting file '…/recite.aYlAVs'
#     warning: Path '…/recite.aYlAVs' does not exist
# with an exit of 1 rather than 130.
#
# The status check does NOT cover this. A core the signal KILLS exits non-zero
# and is refused there; this case is the other one, so the stub core ignores INT
# and exits 0 with its block written. That is what puts the signal in the gap
# rather than in the core, and it needs no timing luck: the core touches a file
# on entry and the harness polls for it, exactly as the case above polls for the
# payload to reach the buffer.
printf '%s\n' '#!/bin/sh' \
    'trap "" INT' \
    'cat >/dev/null' \
    ": > $box/core-running" \
    'sleep 2' \
    'printf "BLOCK\n"' >$box/slowcore/recite-core
printf '#!/bin/sh\ncat > "%s"\n' $box/copied2 >$box/slowcore/recite-clip
chmod 755 $box/slowcore/recite-core $box/slowcore/recite-clip
printf '%s\n' 'set -l box $argv[1]' \
    'set -x PATH $box/slowcore /usr/bin /bin' \
    'set -x TMPDIR $box/tmp2' \
    'source $box/lonely/recite.fish' \
    'printf "GAP_PAYLOAD\n" | recite --as gap' \
    'echo "RECITE-EXIT=$status"' >$box/int2.fish
command rm -f $box/copied2 $box/core-running
sh -c '
set -m
box=$1
fish --no-config "$box/int2.fish" "$box" > "$box/int2.out" 2>&1 &
p=$!
i=0
while [ $i -lt 200 ]; do
    [ -f "$box/core-running" ] && break
    i=$((i + 1))
    sleep 0.1
done
g=$(ps -o pgid= $p | tr -d " ")
[ -n "$g" ] && [ "$g" != "$(ps -o pgid= $$ | tr -d " ")" ] && kill -INT -"$g"
wait $p
exit 0' recite-gap $box >$box/int2.log 2>&1
set -l printed2 no
grep -q GAP_PAYLOAD $box/int2.out; and set printed2 yes
# The symptom itself, not just the exit code: the two warnings are what the user
# actually sees, and they are printed by fish rather than by anything here.
set -l warned no
grep -q '^warning:' $box/int2.out; and set warned yes
set -l code2 (string replace -f 'RECITE-EXIT=' '' <$box/int2.out | string trim)
test -n "$code2"; or set code2 aborted
set -l left2 (command ls -A $box/tmp2 | string match -r '^recite\.' | count)
set -l copied2 no
test -f $box/copied2; and set copied2 yes
check_eq "an interrupt between format and copy is caught too" "$printed2/$warned/$code2/$left2/$copied2" yes/no/130/0/no

rm -rf $box

if test $fails -eq 0
    echo
    echo "all fish assertions passed"
else
    echo
    echo "$fails failed"
end
exit $fails
