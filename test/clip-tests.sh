#!/bin/sh
# recite-clip: backend selection, the OSC 52 emitter, --which, and the report line.
#
# recite-clip had nothing to test until it grew a backend chain — before that it
# was a single `exec pbcopy` line. It gets its own file rather than cases bolted
# into recite-tests.sh, matching the one-suite-per-component layout the rest of
# test/ already has.
#
# Hermetic: a mktemp -d sandbox with RECITE_TTY pointed at a file inside it and
# RECITE_BACKEND forcing selection. The real clipboard is never touched — no case
# here lets the pbcopy branch run to completion against the system pasteboard
# except through RECITE_BACKEND=pbcopy, which is only used where the assertion is
# about SELECTION rather than about the write.
set -u

# The auto cases below mean nothing if the tester exports these.
unset RECITE_BACKEND RECITE_TTY

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$dir/.." && pwd)
clip=${RECITE_CLIP:-"$repo/functions/recite-clip"}
fails=0

check() {
  desc=$1
  got=$2
  want=$3
  if [ "$got" = "$want" ]; then
    echo "ok   $desc"
  else
    echo "FAIL $desc"
    echo "     want: [$want]"
    echo "     got:  [$got]"
    fails=$((fails + 1))
  fi
}

# A sandbox PATH replaces the WHOLE system, not just the encoders. Anything
# recite-clip legitimately runs has to be planted beside whatever the case is
# withholding, or the case measures a broken fixture rather than the code:
# mktemp stages the encode, and rm is what the traps clean it up with. Both are
# hard dependencies of the tool — recite itself calls mktemp — so neither is in
# have_osc52's probe, and neither is what any case here is about.
plant() {
  _dir=$1
  shift
  mkdir -p "$_dir"
  for _tool in mktemp rm "$@"; do
    ln -s "$(command -v "$_tool")" "$_dir/$_tool"
  done
}

box=$(mktemp -d) || exit 1
trap 'chmod 700 "$box/nowrite" 2> /dev/null; rm -rf "$box"' EXIT
trap 'chmod 700 "$box/nowrite" 2> /dev/null; rm -rf "$box"; exit 130' INT
trap 'chmod 700 "$box/nowrite" 2> /dev/null; rm -rf "$box"; exit 143' TERM

# ------------------------------------------------------------- exact bytes ----
#
# cmp, not $(...): a command substitution strips trailing newlines, and the
# terminator here is a BEL that must be the LAST byte with nothing after it.
tty=$box/tty1
: > "$tty"
printf 'hello\n' | RECITE_TTY=$tty RECITE_BACKEND=osc52 "$clip" > "$box/out1" 2> /dev/null
rc=$?
{
  printf '\033]52;c;'
  printf 'hello\n' | base64 | tr -d '\n'
  printf '\007'
} > "$box/want1"
cmp -s "$tty" "$box/want1" && same=yes || same=no
check "osc52 emits exactly ESC ] 52 ; c ; <b64> BEL" "$rc/$same" "0/yes"

# ------------------------------------------- the named blocker: no wrapping ----
#
# GNU base64 wraps at 76 columns and -w0 is GNU-only on older releases; a wrapped
# payload silently corrupts the sequence. 300 bytes of input is 400 base64
# characters, comfortably over the wrap point on any implementation.
#
# WHAT THIS PINS, HONESTLY: `nl == 0` catches every newline, so on a GNU base64
# it is the wrap that reddens it. macOS base64 does NOT wrap — measured, 400
# characters on one line — so on the machine this is developed on, deleting
# `| tr -d "\n"` reddens it via the single TRAILING newline instead, and the
# wrap is never exercised. The second assertion is a guard on the FIXTURE, not
# evidence of a wrap: it pins that the input still crosses 76 characters, so
# this case keeps its meaning on the platforms that do wrap.
#
# REINTRODUCE THE BUG before trusting this case: delete `| tr -d "\n"` from
# recite-clip and confirm this line goes red — knowing that here it goes red
# for the trailing newline.
tty=$box/tty2
: > "$tty"
awk 'BEGIN { while (i++ < 300) printf "x" }' |
  RECITE_TTY=$tty RECITE_BACKEND=osc52 "$clip" > /dev/null 2>&1
nl=$(tr -dc '\n' < "$tty" | wc -c | tr -d ' ')
b64len=$(wc -c < "$tty" | tr -d ' ')
check "a >76-character payload carries no newline" "$nl" "0"
check "and it really is longer than 76 base64 characters" \
  "$(awk -v n="$b64len" 'BEGIN { print (n > 76) ? "yes" : "no" }')" "yes"

# ----------------------------------------------- a forced backend is forced ----
#
# pbcopy is present on this machine, so under `auto` it would win. The whole
# point of RECITE_BACKEND is that it is not advisory.
tty=$box/tty3
: > "$tty"
printf 'forced\n' | RECITE_TTY=$tty RECITE_BACKEND=osc52 "$clip" > "$box/out3" 2> /dev/null
check "RECITE_BACKEND=osc52 wins over an available pbcopy" \
  "$(cat "$box/out3")/$( [ -s "$tty" ] && echo wrote || echo empty )" \
  "osc52 unconfirmed/wrote"

# --------------------------------------------------- and auto is the chain ----
#
# Everything above forces a backend. `auto` is what a user without any
# configuration gets, and `pbcopy` first then `osc52` IS the feature — so
# without these two the suite stays green against either arm being deleted.
# Measured: it did.
#
# The first is queried, not run, so nothing reaches the real clipboard.
check "auto prefers pbcopy when it is there" \
  "$("$clip" --which <&- 2> /dev/null)" "pbcopy confirmed"

# The second needs a PATH with no pbcopy but WITH the encoder, or the probe
# correctly refuses and the case passes for the wrong reason.
plant "$box/noclip" base64 tr
tty=$box/tty12
: > "$tty"
printf 'auto\n' | PATH=$box/noclip RECITE_TTY=$tty "$clip" > "$box/out12" 2> /dev/null
check "auto falls back to osc52 with no pbcopy" \
  "$(cat "$box/out12")/$( [ -s "$tty" ] && echo wrote || echo empty )" \
  "osc52 unconfirmed/wrote"

# ------------------------------------------------- an unknown name is usage ----
tty=$box/tty4
printf 'SENTINEL' > "$tty"
printf 'x\n' | RECITE_TTY=$tty RECITE_BACKEND=nosuch "$clip" > "$box/out4" 2> /dev/null
rc=$?
check "an unknown RECITE_BACKEND exits 2 and writes nothing" \
  "$rc/$(cat "$tty")/$(wc -c < "$box/out4" | tr -d ' ')" "2/SENTINEL/0"

# ------------------------------------------- an unopenable target is exit 4 ----
#
# NOT a nonexistent path in a writable directory: append mode CREATES that, and
# the case would pass against a broken probe. A directory with no write
# permission is the honest unopenable target.
#
# Skipped as root, where mode 500 does not block a write.
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$box/nowrite" && chmod 500 "$box/nowrite"
  printf 'x\n' | RECITE_TTY=$box/nowrite/t RECITE_BACKEND=osc52 "$clip" \
    > "$box/out5" 2> /dev/null
  rc=$?
  check "an unopenable RECITE_TTY exits 4 and creates nothing" \
    "$rc/$( [ -e "$box/nowrite/t" ] && echo made || echo absent )" "4/absent"

  # ... and the case above does NOT pin the probe, which is why this one is
  # here. Delete `true 2> /dev/null 3>> "$tty"` from have_osc52 and the write
  # path reaches the same 4 by its own route — measured, every assertion in this
  # file stayed green. `--which` is the caller that runs the probe and nothing
  # else, so it is the only place the two answers differ: the real one refuses,
  # a probe-less one answers `osc52 unconfirmed` with the same confidence.
  #
  # REINTRODUCE THE BUG: delete that line and confirm this line goes red.
  w=$(RECITE_TTY=$box/nowrite/t RECITE_BACKEND=osc52 "$clip" --which <&- 2> /dev/null)
  check "--which refuses a tty it cannot open" "$?/$w" "4/"

  chmod 700 "$box/nowrite"
else
  echo "skip (running as root: mode 500 does not block a write)"
fi

# ------------------------------------------------- --which is side-effect free ----
#
# Two assertions, because "does not consume stdin" and "survives stdin being
# closed" are different claims and only the first can be tested with a readable
# stdin.
#
# 6a: stdin is a real file, and it must still be readable afterwards. A
# substitution inherits a DUP of fd 0, so a read inside it advances the shared
# offset on a regular file — which is exactly what makes this detectable.
tty=$box/tty6
printf 'SENTINEL' > "$tty"
printf 'STILL-HERE\n' > "$box/in6"
{
  which6=$(RECITE_TTY=$tty RECITE_BACKEND=osc52 "$clip" --which 2> /dev/null)
  rc=$?
  rest6=$(cat)
} < "$box/in6"
check "--which leaves stdin unread and the tty untouched" \
  "$rc/$which6/$rest6/$(cat "$tty")" "0/osc52 unconfirmed/STILL-HERE/SENTINEL"

# 6b: stdin CLOSED. `recite --version` calls it that way, because an older
# recite-clip is `exec pbcopy` and pbcopy handed a readable /dev/null exits 0 and
# WIPES the clipboard. Anything here that reaches for fd 0 breaks that caller.
which6b=$(RECITE_TTY=$tty RECITE_BACKEND=osc52 "$clip" --which <&- 2> /dev/null)
check "--which still answers with stdin closed" \
  "$?/$which6b" "0/osc52 unconfirmed"

# 6c: a trailing argument is usage, not something to ignore. The --which branch
# exits before the arity check further down, so this is the only thing pinning
# it — and an ignored argument is answered with the same confidence as a
# understood one, which is the shape of wrong this project refuses.
#
# REINTRODUCE THE BUG: delete the `$# -gt 1` check from the --which branch and
# confirm this line goes red.
which6c=$(RECITE_TTY=$tty RECITE_BACKEND=osc52 "$clip" --which --junk 2> /dev/null)
check "--which with a trailing argument is usage, not an answer" \
  "$?/$which6c" "2/"

# ---------------------------------------------- no backend touches nothing ----
#
# A refusal writes nothing at all, and that invariant now covers the new sink
# too. PATH is emptied so pbcopy cannot be found, and RECITE_TTY points into a
# directory with no write permission so osc52 cannot be selected either — so the
# assertion that carries weight is that the target was NOT CREATED. Append mode
# creates a missing file, which is the failure this pins.
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$box/nowrite" && chmod 500 "$box/nowrite"
  printf 'x\n' | PATH=$box/empty RECITE_TTY=$box/nowrite/t "$clip" \
    > "$box/out7" 2> /dev/null
  rc=$?
  check "no backend at all: exit 4, nothing created, stdout empty" \
    "$rc/$( [ -e "$box/nowrite/t" ] && echo made || echo absent )/$(wc -c < "$box/out7" | tr -d ' ')" \
    "4/absent/0"
  chmod 700 "$box/nowrite"
else
  echo "skip (running as root: mode 500 does not block a write)"
fi

# ---------------------------------------------- an encoder you do not have ----
#
# have_osc52 checks for base64 and for tr, and the two checks need ONE CASE
# EACH. A single sandbox missing both is green against either check on its own:
# measured here, deleting the `command -v tr` line left every assertion in this
# file passing. So there are two sandboxes below, each holding exactly the tool
# the other is missing.
#
# Seed a sentinel in both: the assertion that carries weight is that NOTHING was
# appended after it.
#
# `plant` puts mktemp and rm in both. Without them a deleted check cannot reach
# the emitter at all — it dies on the mktemp instead — and the case would go red
# for the wrong reason, which is the same thing as having no teeth.

# tr, no base64. TWO assertions, because two different guards refuse here and
# only one of them is this check.
#
# The write path is covered either way — the emitter now checks base64's own
# status, so a base64 that is missing dies there (127) exactly as one that fails
# dies there (1). Measured: with `command -v base64` deleted, the write
# assertion below stays green. What the probe's base64 check alone protects is
# SELECTION — `--which`, and the `auto` chain — from naming a backend that
# cannot encode. So that is the assertion carrying it.
#
# REINTRODUCE THE BUG: drop `command -v base64` from have_osc52 and confirm the
# `--which` line goes red.
plant "$box/onlytr" tr
tty=$box/tty11
printf 'SENTINEL' > "$tty"
w11=$(PATH=$box/onlytr RECITE_TTY=$tty RECITE_BACKEND=osc52 "$clip" --which <&- \
  2> /dev/null)
check "--which refuses osc52 without base64" "$?/$w11" "4/"

printf 'x\n' | PATH=$box/onlytr RECITE_TTY=$tty RECITE_BACKEND=osc52 "$clip" \
  > "$box/out11" 2> /dev/null
rc=$?
check "and the write emits nothing without base64" \
  "$rc/$(cat "$tty")" "4/SENTINEL"

# base64, no tr.
#
# REINTRODUCE THE BUG: drop `command -v tr` from have_osc52 and confirm this
# line goes red. Without the check the probe passes, the encode succeeds, and
# the emitter puts the ESC prefix on the wire before tr fails to run.
plant "$box/onlyb64" base64
tty=$box/tty14
printf 'SENTINEL' > "$tty"
printf 'x\n' | PATH=$box/onlyb64 RECITE_TTY=$tty RECITE_BACKEND=osc52 "$clip" \
  > "$box/out14" 2> /dev/null
rc=$?
check "osc52 is unavailable without tr, and emits nothing" \
  "$rc/$(cat "$tty")" "4/SENTINEL"

# ------------------------------------------- an encoder that exists and fails ----
#
# The probe can only ever see a MISSING encoder. One that is present and then
# exits nonzero passes it, and that is the case the emitter itself has to catch:
# a command GROUP exits with its LAST command's status — a printf of the
# terminator, which cannot fail — so before the encode was staged in a file,
# what reached the terminal here was a well-formed OSC 52 with an EMPTY payload.
# An xterm-family terminal reads that as "set the clipboard to nothing": the
# clipboard was cleared and the run reported a send, exit 0. Measured.
#
# REINTRODUCE THE BUG: put the emitter back to the one group,
# `{ printf ...; base64 | tr -d "\n"; printf ...; } >> "$tty" || exit 4`, and
# confirm this line goes red on all three fields.
plant "$box/badb64" tr
printf '#!/bin/sh\nexit 1\n' > "$box/badb64/base64"
chmod 755 "$box/badb64/base64"
tty=$box/tty13
printf 'SENTINEL' > "$tty"
printf 'x\n' | PATH=$box/badb64 RECITE_TTY=$tty RECITE_BACKEND=osc52 "$clip" \
  > "$box/out13" 2> /dev/null
rc=$?
check "a failing base64 emits nothing, and reports no send" \
  "$rc/$(cat "$tty")/$(cat "$box/out13")" "4/SENTINEL/"

# ------------------------------------------------- the report line's shape ----
#
# Two fields, and the SECOND one is what recite maps to a verb. pbcopy is queried
# rather than run, so nothing reaches the real clipboard.
p=$(RECITE_BACKEND=pbcopy "$clip" --which <&- 2> /dev/null)
o=$(RECITE_TTY=$box/tty8 RECITE_BACKEND=osc52 "$clip" --which <&- 2> /dev/null)
check "the report line is <backend> <state>, two fields" "$p|$o" \
  "pbcopy confirmed|osc52 unconfirmed"

# --------------------------------------------- the staging file is not left ----
#
# The encode stages the payload — the user's own captured output — in TMPDIR,
# where macOS sweeps only after three days. Both exits from that window have to
# clear it: the success path, and the failure path the encoder case above takes
# between the mktemp and the emit.
#
# REINTRODUCE THE BUG: delete the EXIT trap from recite-clip and confirm this
# line goes red.
tmpd=$box/tmp1
mkdir -p "$tmpd"
tty=$box/tty15
: > "$tty"
printf 'x\n' | TMPDIR=$tmpd RECITE_TTY=$tty RECITE_BACKEND=osc52 "$clip" \
  > /dev/null 2>&1
left_ok=$(ls -A "$tmpd" | wc -l | tr -d ' ')
printf 'x\n' | TMPDIR=$tmpd PATH=$box/badb64 RECITE_TTY=$tty RECITE_BACKEND=osc52 \
  "$clip" > /dev/null 2>&1
left_bad=$(ls -A "$tmpd" | wc -l | tr -d ' ')
check "the staging file is gone, on the success path and on the failure path" \
  "$left_ok/$left_bad" "0/0"

# ---------------------------------------------------------------- signals ----
#
# The same file, when the process is killed rather than allowed to exit. recite
# traps INT, TERM and HUP for its own buffers; a clip that trapped none would
# outlive every one of them and leave the payload behind.
#
# Run under TWO interpreters, and the second is the one with teeth. macOS
# /bin/sh is bash 3.2, which runs the EXIT trap even when it dies of a signal it
# has no trap for — so under it the explicit `trap ... TERM` and `trap ... HUP`
# lines can be DELETED and these cases still pass. dash does not, and goes red.
#
# The signal goes to the child PROCESS GROUP, the way a terminal delivers one,
# which needs job control and an `sh` harness — hence `set -m` and the pgid
# dance, the same shape recite-tests.sh uses.
#
# The producer keeps stdin OPEN so the clip is parked inside its base64 with the
# staging file already created; the poll waits for that file rather than
# sleeping, so the signal cannot land before there is anything to strand.
signal_clip() {
  _interp=$1
  _sig=$2
  _tmp=$3
  sh -c '
set -m
clip=$1; interp=$2; sig=$3; tmp=$4; tty=$5
TMPDIR=$tmp; export TMPDIR
RECITE_TTY=$tty; export RECITE_TTY
RECITE_BACKEND=osc52; export RECITE_BACKEND
# $interp unquoted so that empty means "use the shebang".
{ printf x; sleep 6; } | $interp "$clip" > /dev/null 2>&1 &
p=$!
i=0
while [ $i -lt 100 ]; do
  ls "$tmp"/recite-clip.* > /dev/null 2>&1 && break
  i=$((i + 1))
  sleep 0.1
done
g=$(ps -o pgid= $p | tr -d " ")
[ -n "$g" ] && [ "$g" != "$(ps -o pgid= $$ | tr -d " ")" ] && kill -"$sig" -"$g"
wait $p
exit 0' clip-signal "$clip" "$_interp" "$_sig" "$_tmp" "$box/tty16" 2> /dev/null
}

# check_clip_signal <label> <interpreter> <signal> <tmpdir>
check_clip_signal() {
  mkdir -p "$4" || return 1
  signal_clip "$2" "$3" "$4"
  check "$3 strands no staging file ($1)" \
    "$(ls -A "$4" 2>/dev/null | grep -c '^recite-clip\.')" "0"
}

check_clip_signal /bin/sh "" INT "$box/c1"
check_clip_signal /bin/sh "" TERM "$box/c2"
check_clip_signal /bin/sh "" HUP "$box/c3"

strict=
for sh_ in /bin/dash dash busybox; do
  sp=$(command -v "$sh_" 2> /dev/null) && [ -n "$sp" ] && { strict=$sp; break; }
done
if [ -n "$strict" ]; then
  case $strict in
    *busybox) strict="$strict sh" ;;
  esac
  check_clip_signal "$strict" "$strict" INT "$box/c4"
  check_clip_signal "$strict" "$strict" TERM "$box/c5"
  check_clip_signal "$strict" "$strict" HUP "$box/c6"
else
  # Printed, not silent: under /bin/sh alone the TERM and HUP traps are untested
  # and this suite would report a pass it only half made.
  echo "skip (no dash/busybox: TERM and HUP pass here on bash's EXIT fallback)"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "all clip assertions passed"
else
  echo "$fails failed"
fi
exit "$fails"
