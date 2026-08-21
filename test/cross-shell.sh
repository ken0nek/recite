#!/bin/sh
# Milestone A-min's gate: the same command, through each shell's own binding,
# must reach the clipboard as the same bytes.
#
#   docs: same command, same keystroke -> byte-identical clipboard content.
#
# It runs a case in every shell that is INSTALLED, and compares each shell's
# artifact against the first shell's. One shell present is a valid run: it
# proves nothing about divergence, and it keeps this suite honest before a
# second shell layer exists.
#
# Opt-in for the same reason binding.sh is: driving a real pty is
# timing-sensitive by construction, and the default suite promises that a
# failure means the code is wrong rather than the environment.
#
# No side effects: cross-shell.exp puts a stub recite-clip on PATH inside a
# mktemp -d, so the real clipboard is never touched.
#
# Three traps, each of which produced a green run against broken code while
# this was being written:
#
# - `spawn fish` inside expect resolves against the SANDBOXED PATH, which has
#   no Homebrew in it. The fish half then produces nothing at all while zsh
#   works, which reads as a bug in the fish layer. Every shell is spawned by
#   absolute path, resolved out here where the real PATH still applies.
# - Two missing artifacts compare EQUAL. The first draft of this file printed
#   three `ok` lines over 0 bytes a side. A shell that is present must produce
#   a non-empty artifact or the case FAILS — it must never skip, because
#   "produced nothing" is exactly what the bug looks like.
# - A shell that is absent is skipped, and the skip is printed. A silent one
#   would let this suite report a cross-shell pass it never made.
set -u

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if ! command -v expect > /dev/null 2>&1; then
  echo "skip (expect not installed)"
  exit 0
fi

box=$(mktemp -d) || exit 1
trap 'rm -rf "$box"' EXIT
trap 'rm -rf "$box"; exit 130' INT
trap 'rm -rf "$box"; exit 143' TERM

mkdir -p "$box/bin" "$box/out" || exit 1
printf '#!/bin/sh\ncat > "%s"\n' "$box/copied" > "$box/bin/recite-clip"
chmod 755 "$box/bin/recite-clip"
cp "$dir/../functions/recite-core" "$box/bin/recite-core" || exit 1
[ -f "$dir/../functions/recite" ] && cp "$dir/../functions/recite" "$box/bin/recite"

# A shell is in the matrix when recite HAS A LAYER for it and the shell is
# installed — not merely when the shell is installed. zsh sitting on the machine
# before the zsh layer exists is not a failing comparison, it is a comparison
# nobody has written yet, and reporting it as red would train the reader to
# ignore this suite's red.
#
# Resolved out here, not inside expect: expect runs with the sandboxed PATH, so
# a bare `spawn fish` there would resolve against a PATH holding nothing but the
# stubs. Absolute paths are handed in instead.
shells=''
nshells=0
add_shell() {
  path=$(command -v "$1" 2> /dev/null) || return 0
  [ -n "$path" ] || return 0
  shells="$shells $1:$path"
  nshells=$((nshells + 1))
}

# fish: the layer is the autoloaded function pair.
if [ -f "$dir/../functions/recite.fish" ]; then
  add_shell fish
  cat > "$box/rc.fish" <<FISHRC
function fish_greeting; end
function fish_prompt; printf 'RDY> '; end
function fish_right_prompt; end
source $dir/../functions/recite.fish
source $dir/../functions/__recite_submit.fish
bind alt-enter __recite_submit
FISHRC
fi

# zsh and bash: the layer is whatever \`recite init <shell>\` emits. Absent or
# failing, the shell stays out of the matrix and a line says so.
for sh in zsh bash; do
  if [ -x "$box/bin/recite" ] && "$box/bin/recite" init "$sh" > "$box/init.$sh" 2> /dev/null; then
    add_shell "$sh"
    case $sh in
      zsh)
        cat > "$box/.zshrc" <<ZSHRC
PROMPT='RDY> '
RPROMPT=''
source $box/init.zsh
bindkey '^[^M' __recite_submit
ZSHRC
        ;;
      bash)
        cat > "$box/.bashrc" <<BASHRC
PS1='RDY> '
source $box/init.bash
BASHRC
        ;;
    esac
  else
    command -v "$sh" > /dev/null 2>&1 && printf 'skip %s (no recite layer yet)\n' "$sh"
  fi
done

if [ -z "$shells" ]; then
  echo "skip (no shell with a recite layer found)"
  exit 0
fi

fails=0

# The cases. A-min names three; the first one is split.
#
# The header and the body are SEPARATE questions and only the header is ours.
# `echo c # note` runs differently in the two shells — zsh leaves
# interactive_comments off, so a typed `#` is literal there and a comment in
# fish. Both shells are right, recite behaves identically in both, and no port
# can close that gap. Measured 2026-08-20. So the quoting case asserts the
# `$ command` header only, and the body cases use commands the shells agree on.
#
# Format: <name>|<mode>|<command>   where mode is `header` or `full`.
cases=$(cat <<'CASES'
quoting|header|echo "a  b"; echo c # note
core|full|printf 'a\rb\nsk-abc123def456ghi789jkl012mno345pqr678stu\n'
empty|full|true
CASES
)

# Reduce an artifact to the part a case compares.
extract() {
  if [ "$2" = header ]; then
    grep '^\$ ' "$1"
  else
    cat "$1"
  fi
}

run_case() {
  name=$1
  mode=$2
  cmd=$3
  first=''

  for entry in $shells; do
    sh=${entry%%:*}
    path=${entry#*:}
    rm -f "$box/copied"

    expect "$dir/cross-shell.exp" "$sh" "$path" "$box" "$cmd" > /dev/null 2>&1

    art="$box/out/$name.$sh.txt"
    if [ ! -s "$box/copied" ]; then
      # NOT a skip. An installed shell that copied nothing is the failure this
      # suite exists to catch.
      printf 'FAIL %s / %s: nothing reached the clipboard\n' "$name" "$sh"
      fails=$((fails + 1))
      continue
    fi
    extract "$box/copied" "$mode" > "$art"

    if [ -z "$first" ]; then
      first=$sh
      continue
    fi

    if cmp -s "$box/out/$name.$first.txt" "$art"; then
      printf 'ok   %s: %s matches %s (%s)\n' "$name" "$sh" "$first" "$mode"
    else
      printf 'FAIL %s: %s differs from %s (%s)\n' "$name" "$sh" "$first" "$mode"
      printf '     --- %s ---\n' "$first"
      sed 's/^/     /' "$box/out/$name.$first.txt"
      printf '     --- %s ---\n' "$sh"
      sed 's/^/     /' "$art"
      fails=$((fails + 1))
    fi
  done

  # One shell installed is a legitimate run, and saying so is the point: it
  # reports that no comparison was made rather than implying one passed.
  if [ -n "$first" ] && [ "$nshells" -eq 1 ]; then
    printf 'ok   %s: %s only, no cross-shell claim made\n' "$name" "$first"
  fi
}

printf 'shells:'
for entry in $shells; do printf ' %s' "${entry%%:*}"; done
printf '\n'

# Redirected, NOT piped: `... | while` runs the loop in a subshell, and every
# `fails` increment inside it is discarded at the closing `done` — so the suite
# would exit 0 while printing FAIL lines.
while IFS='|' read -r name mode cmd; do
  [ -n "$name" ] || continue
  run_case "$name" "$mode" "$cmd"
done <<CASES
$cases
CASES

echo
if [ "$fails" -eq 0 ]; then
  echo "cross-shell: all comparisons passed"
else
  echo "cross-shell: $fails failed"
fi
exit "$fails"
