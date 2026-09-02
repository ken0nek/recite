#!/bin/sh
# The shared layer: `recite`, the POSIX executable every shell delegates to.
#
# fish-tests.fish and zsh-tests.zsh both reach this file, but only through their
# own shell — so what they cover is the handoff, and what they cannot cover is
# anything that has no shell layer above it. That is what is here:
#
#   - the version skew between `recite` and `recite-core`, which exists at all
#     only because the extraction put two separately-installed links where one
#     used to be;
#   - `init`, which no shell layer calls;
#   - TERM and HUP, which kill an interactive shell outright, so no test driven
#     through one can watch what the tool does about them.
#
# Hermetic and side-effect free: every case runs against stubs inside a
# mktemp -d, and nothing here can reach a clipboard.
set -u

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$dir/.." && pwd)
recite=${RECITE_EXE:-"$repo/functions/recite"}
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
trap 'rm -rf "$box"' EXIT
trap 'rm -rf "$box"; exit 130' INT
trap 'rm -rf "$box"; exit 143' TERM
mkdir -p "$box/tmp" "$box/tmp2" || exit 1

printf '#!/bin/sh\ncat >/dev/null\n' > "$box/clip"
chmod 755 "$box/clip"

# ---------------------------------------------------------------- version ----
#
# The release gate. `recite` and `recite-core` are two links now, installed by
# separate channels and upgradable one at a time, so each carries its own version
# string and this holds them equal. Bump one and forget the other and the suite
# goes red — which is the whole reason the second string is allowed to exist.
ver_out=$(RECITE_CLIP=$box/clip "$recite" --version)
mine=$(printf '%s\n' "$ver_out" | awk '$1 == "recite" { print $2 }')
theirs=$(printf '%s\n' "$ver_out" | awk '$1 == "recite-core" { print $2 }')
check "recite and recite-core report the same version" "$mine" "$theirs"

# ... and it is a real version, not two copies of the same empty field. Without
# this the case above passes green on a --version that prints nothing at all.
check "and it is a version" "$(printf '%s\n' "$mine" | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+$')" 1

# The reason the two strings exist: a half-upgraded install has to SAY so. One
# row per component with the version beside the path, so the mismatch is on the
# screen rather than something the reader has to derive.
printf '#!/bin/sh\necho "recite-core 0.0.1-old"\n' > "$box/oldcore"
chmod 755 "$box/oldcore"
skew=$(RECITE_CORE=$box/oldcore RECITE_CLIP=$box/clip "$recite" --version |
  awk '$1 == "recite" { m = $2 } $1 == "recite-core" { c = $2 } END { print m "/" c }')
check "a skewed core is reported, not hidden" "$skew" "$mine/0.0.1-old"

# The diagnostic for a broken install has to survive the install being broken.
unres=$(RECITE_CORE=$box/nope RECITE_CLIP=$box/nope "$recite" --version 2>&1)
unres_st=$?
check "--version answers with nothing resolvable" \
  "$unres_st/$(printf '%s\n' "$unres" | awk '$1 == "recite-core" { print $2 }')" "0/-"

# ------------------------------------------------------------------- init ----
#
# `recite init zsh` is what a .zshrc evals. Nothing else in the repo calls it, so
# without these three the subcommand's error paths are unexecuted everywhere.
"$recite" init zsh > "$box/init.zsh" 2> /dev/null
check "init zsh emits a widget on stdout" \
  "$?/$(grep -c '^zle -N __recite_submit$' "$box/init.zsh")" "0/1"

"$recite" init > /dev/null 2>&1
check "init with no shell exits 2" "$?" 2

"$recite" init tcsh > /dev/null 2>&1
check "init with an unsupported shell exits 2" "$?" 2

# fish is refused rather than unsupported, and the difference is the message: its
# layer autoloads out of functions/*.fish, which is fisher's whole contract, so
# an init form would break that channel. Someone who reaches for it needs the
# `bind` line, not a shrug.
fishmsg=$("$recite" init fish 2>&1 >/dev/null)
check "init fish says what to do instead" \
  "$(printf '%s\n' "$fishmsg" | grep -c 'bind alt-enter __recite_submit')" 1

# --------------------------------------------------------- unknown option ----
"$recite" --nonesuch < /dev/null > /dev/null 2>&1
check "an unknown option exits 2" "$?" 2

# --------------------------------------------------------- the clip report ----
#
# recite-clip prints one line on stdout — `<backend> <confirmed|unconfirmed>` —
# and `recite` owns the wording. OSC 52 is write-only: no terminal replies, so
# "copied" about it would be a plausibly-correct claim with nothing behind it,
# which is the one thing this tool refuses to produce. The verb carries the
# caveat; the shape absorbs every backend added later.
printf '#!/bin/sh\ncat > /dev/null\nprintf "pbcopy confirmed\\n"\n' > "$box/clip_pb"
printf '#!/bin/sh\ncat > /dev/null\nprintf "osc52 unconfirmed\\n"\n' > "$box/clip_osc"
chmod 755 "$box/clip_pb" "$box/clip_osc"

msg=$(printf 'x\n' | RECITE_CLIP=$box/clip_pb "$recite" --as x 2>&1 > /dev/null)
check "a confirmed backend is copied, and named" "$msg" "recite: copied (pbcopy)"

msg=$(printf 'x\n' | RECITE_CLIP=$box/clip_osc "$recite" --as x 2>&1 > /dev/null)
check "an unconfirmed backend is SENT, not copied" "$msg" "recite: sent (osc52)"

# A recite-clip predating the report line prints nothing at all. Mixed-channel
# installs are live here — a fisher copy shadows a Homebrew one on
# $fish_function_path — so this is the case that proves an old sink does not
# produce a broken message.
msg=$(printf 'x\n' | RECITE_CLIP=$box/clip "$recite" --as x 2>&1 > /dev/null)
check "an older recite-clip still reports plainly" "$msg" "recite: copied"

# --version's clip row carries the backend, and the --which call must reach it
# with stdin CLOSED. An older recite-clip is `exec pbcopy`, and `pbcopy --which`
# handed a readable /dev/null exits 0 and WIPES the clipboard — measured. With
# stdin closed the same binary aborts and the clipboard survives.
#
# The stub records `cat`s EXIT STATUS, not what it read, and that is the whole
# design of this case. A closed fd 0 and /dev/null both produce an EMPTY
# capture, so a stub asserting on the bytes goes GREEN against `< /dev/null` —
# the exact shape of case this repo keeps shipping. The status separates them:
# measured here, `cat` exits 1 on a closed fd 0 and 0 on /dev/null.
#
# The stub also REFUSES anything that is not exactly `--which`, and that line is
# half of what this case is worth. Measured: with it ignoring argv, dropping
# `--which` from the call above left all of these assertions green — including
# this one, whose name claims to check it. Against the real recite-clip that
# regression runs the WRITE path from --version, and both backends then do the
# thing --version must never do. pbcopy is the wipe the closed stdin was chosen
# to prevent. osc52 is worse than it looks: macOS base64 handed a CLOSED fd 0
# exits 0 with empty output — measured — so the encode is clean, the emitter has
# nothing to refuse, and a well-formed OSC 52 with an empty payload clears the
# terminal's clipboard. --version cannot be allowed to reach that path at all.
#
# REINTRODUCE THE BUG: drop `--which` from the `"$clip"` call in recite's
# --version arm and confirm this line goes red.
printf '#!/bin/sh\n[ "${1:-}" = --which ] || exit 64\n' > "$box/clip_w"
printf 'cat > /dev/null 2> /dev/null\nprintf "catrc=%%s\\n" "$?" > "%s"\nprintf "osc52 unconfirmed\\n"\n' \
  "$box/which_rc" >> "$box/clip_w"
chmod 755 "$box/clip_w"
rm -f "$box/which_rc"
row=$(RECITE_CLIP=$box/clip_w "$recite" --version |
  awk '$1 == "recite-clip" { print $2 }')
check "--version names the backend, and hands --which a closed stdin" \
  "$row/$(cat "$box/which_rc" 2> /dev/null)" "osc52/catrc=1"

# `-` in the version column has to keep ONE meaning, and that meaning is NOT
# RUN: nothing resolved, or what resolved is missing or not executable. The path
# on the same line says which. Four situations used to print it, and the fourth
# was "it ran and said nothing" — two different installs wearing the same glyph
# as a typo in RECITE_CLIP, one of them the half-upgraded install this row is
# for.
#
# The two that ran are separated by STATUS. 4 is this clip refusing: no pbcopy
# here, and no terminal to write an escape sequence to. Anything else is a clip
# predating --which, which is `exec pbcopy` and does not answer the flag — the
# stub below models that by reading the stdin it was handed closed, and exiting
# nonzero without printing, exactly as the real one does.
#
# Asserted as the WHOLE ROW rather than a field, because both tokens contain a
# space and overflow the version column — `(no --version)` on the core row set
# that precedent, and a field-indexed assertion would silently pass on half a
# token.
#
# REINTRODUCE THE BUG: delete the `*)` arm from the clip `case` in recite's
# --version so both fall back to `-`, and confirm both of these go red.
printf '#!/bin/sh\nexit 4\n' > "$box/clip_none"
printf '#!/bin/sh\ncat > /dev/null\n' > "$box/clip_old"
chmod 755 "$box/clip_none" "$box/clip_old"

check "a clip that ran and refused says so" \
  "$(RECITE_CLIP=$box/clip_none "$recite" --version | grep '^recite-clip')" \
  "recite-clip  (no backend) $box/clip_none"

check "a clip too old to answer --which says that instead" \
  "$(RECITE_CLIP=$box/clip_old "$recite" --version | grep '^recite-clip')" \
  "recite-clip  (no --which) $box/clip_old"

# ... and `-` still means not run, for a path that is not there at all.
check "and a clip that cannot run is still a bare dash" \
  "$(RECITE_CLIP=$box/nope "$recite" --version | grep '^recite-clip')" \
  "recite-clip  -         $box/nope"

# ------------------------------------------------------- printing is first ----
#
# The guard sits BELOW the tee, and this is the reason: above it, an unresolved
# core would not merely skip the copy, it would destroy the output and SIGPIPE
# whatever is producing it. fish-tests.fish makes the same claim through the fish
# shim; this makes it about the file that now actually implements it.
survived=$(printf 'MUST SURVIVE\n' |
  RECITE_CORE=$box/nope RECITE_CLIP=$box/nope "$recite" --as x 2>/dev/null)
check "output survives when nothing resolves" "$survived" "MUST SURVIVE"

printf 'x\n' | RECITE_CORE=$box/nope RECITE_CLIP=$box/nope "$recite" --as x > /dev/null 2>&1
check "and it still exits 2" "$?" 2

# ---------------------------------------------------------------- signals ----
#
# The capture buffer holds the UNREDACTED output — the one thing this tool exists
# to keep off a clipboard — and $TMPDIR on macOS is only swept after three days.
# The fish function this replaced trapped INT alone, so TERM and HUP each left
# that file on disk. This is the gap the extraction closes.
#
# Run under TWO interpreters, and the second one is the whole point. macOS
# /bin/sh is bash 3.2, which runs the EXIT trap even when it dies of a signal it
# has no trap for — so under /bin/sh the explicit `trap ... TERM` and
# `trap ... HUP` lines can be DELETED and these cases still pass. Measured. A
# case that green-lights the bug it names is the failure mode this project keeps
# hitting, so the pair runs again under a shell that does not do that, where
# deleting either line goes red.
#
# The exit status is asserted too but proves little on its own: a process KILLED
# by TERM also exits 143, so the status is identical whether the trap ran or was
# never there. The count of what is left in TMPDIR is the assertion that
# distinguishes them.
#
# The signal goes to the child PROCESS GROUP, the way a terminal delivers one.
# That needs job control and an `sh` harness — hence `set -m` and the pgid dance,
# the same shape fish-tests.fish uses for its interrupt cases.
printf '#!/bin/sh\necho SECRET_PAYLOAD\nsleep 6\n' > "$box/slow"
chmod 755 "$box/slow"

# stderr goes to /dev/null on the HARNESS, never on recite: with job control on,
# the harness shell announces the reaped job (`[1]+ Done(143) ...`) and that
# would land in the middle of this suite output looking like a failure.
signal_case() {
  interp=$1
  sig=$2
  tmp=$3
  out=$4
  sh -c '
set -m
box=$1; recite=$2; interp=$3; sig=$4; tmp=$5; out=$6
TMPDIR=$tmp; export TMPDIR
RECITE_CLIP=$box/clip; export RECITE_CLIP
# $interp unquoted so that empty means "use the shebang".
"$box/slow" | $interp "$recite" --as slow > "$out" 2>&1 &
p=$!
# Polls until the payload is IN the buffer rather than sleeping a fixed time:
# that is the proof the tee is running, so the signal cannot land too early.
i=0
while [ $i -lt 100 ]; do
  grep -q SECRET_PAYLOAD "$tmp"/recite.* 2>/dev/null && break
  i=$((i + 1))
  sleep 0.1
done
g=$(ps -o pgid= $p | tr -d " ")
[ -n "$g" ] && [ "$g" != "$(ps -o pgid= $$ | tr -d " ")" ] && kill -"$sig" -"$g"
wait $p
echo "RECITE-EXIT=$?"
exit 0' recite-signal "$box" "$recite" "$interp" "$sig" "$tmp" "$out" 2> /dev/null
}

# check_signal <label> <interpreter> <signal> <expected status> <tmpdir>
check_signal() {
  mkdir -p "$5" || return 1
  st=$(signal_case "$2" "$3" "$5" "$box/sig.out" | sed -n 's/^RECITE-EXIT=//p')
  left=$(ls -A "$5" 2>/dev/null | grep -c '^recite\.')
  printed=no
  grep -q SECRET_PAYLOAD "$box/sig.out" && printed=yes
  check "$3 strands no unredacted buffer ($1)" "$printed/$st/$left" "yes/$4/0"
}

check_signal /bin/sh "" INT 130 "$box/s1"
check_signal /bin/sh "" TERM 143 "$box/s2"
check_signal /bin/sh "" HUP 129 "$box/s3"

# A shell that does NOT fall back to the EXIT trap on a fatal signal, so the
# per-signal traps are the only thing that can clean up. dash is the one macOS
# ships; the loop takes the first that is present.
strict=
for s in /bin/dash dash busybox; do
  p=$(command -v "$s" 2> /dev/null) && [ -n "$p" ] && { strict=$p; break; }
done
if [ -n "$strict" ]; then
  case $strict in
    *busybox) strict="$strict sh" ;;
  esac
  check_signal "$strict" "$strict" INT 130 "$box/s4"
  check_signal "$strict" "$strict" TERM 143 "$box/s5"
  check_signal "$strict" "$strict" HUP 129 "$box/s6"
else
  # Printed, not silent. Without this line the suite reports a signal pass it
  # only half made — under /bin/sh alone the TERM and HUP traps are untested.
  echo "skip (no dash/busybox: TERM and HUP pass here on bash's EXIT fallback)"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "all shared-layer assertions passed"
else
  echo "$fails failed"
fi
exit "$fails"
