#!/bin/sh
# recite-clip: backend selection, the OSC 52 emitter, --which, and the report line.
#
# recite-clip had no suite before B-crit. It gets its own file rather than cases
# bolted into recite-tests.sh, matching the one-suite-per-component layout the
# rest of test/ already has.
#
# Hermetic: a mktemp -d sandbox with RECITE_TTY pointed at a file inside it and
# RECITE_BACKEND forcing selection. The real clipboard is never touched — no case
# here lets the pbcopy branch run to completion against the system pasteboard
# except through RECITE_BACKEND=pbcopy, which is only used where the assertion is
# about SELECTION rather than about the write.
set -u

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
# REINTRODUCE THE BUG before trusting this case: delete `| tr -d "\n"` from
# recite-clip and confirm this line goes red.
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

# ------------------------------------------------- the report line's shape ----
#
# Two fields, and the SECOND one is what recite maps to a verb. pbcopy is queried
# rather than run, so nothing reaches the real clipboard.
p=$(RECITE_BACKEND=pbcopy "$clip" --which <&- 2> /dev/null)
o=$(RECITE_TTY=$box/tty8 RECITE_BACKEND=osc52 "$clip" --which <&- 2> /dev/null)
check "the report line is <backend> <state>, two fields" "$p|$o" \
  "pbcopy confirmed|osc52 unconfirmed"

echo
if [ "$fails" -eq 0 ]; then
  echo "all clip assertions passed"
else
  echo "$fails failed"
fi
exit "$fails"
