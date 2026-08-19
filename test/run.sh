#!/bin/sh
# Golden-file tests for recite-core.
#
# A case is a set of sibling files in cases/:
#   <name>.in         stdin fed to recite-core          (required)
#   <name>.expected   exact expected stdout          (required)
#   <name>.args       one argument per line          (optional)
#   <name>.exit       expected exit status, default 0 (optional)
#
# Byte-exact via cmp, not $(...), so trailing-newline differences are caught
# rather than silently stripped.
#
# Usage: recite/test/run.sh [name ...]     (no args = all cases)
set -u

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
core=${RECITE_CORE:-"$dir/../functions/recite-core"}
cases="$dir/cases"

if [ ! -x "$core" ]; then
  printf 'recite-core not executable at %s\n' "$core" >&2
  exit 2
fi

tmp=$(mktemp "${TMPDIR:-/tmp}/recitetest.XXXXXX") || exit 2
trap 'rm -f "$tmp"' EXIT INT TERM

pass=0
fail=0

if [ "$#" -gt 0 ]; then
  selected=$*
else
  selected=
fi

for expected in "$cases"/*.expected; do
  [ -e "$expected" ] || continue
  name=${expected##*/}
  name=${name%.expected}

  if [ -n "$selected" ]; then
    case " $selected " in
      *" $name "*) ;;
      *) continue ;;
    esac
  fi

  # Build argv from <name>.args, one argument per line.
  set --
  if [ -f "$cases/$name.args" ]; then
    while IFS= read -r line; do
      set -- "$@" "$line"
    done < "$cases/$name.args"
  fi

  want_rc=0
  [ -f "$cases/$name.exit" ] && want_rc=$(cat "$cases/$name.exit")

  # <name>.env holds VAR=value lines prepended to the invocation.
  envargs=
  [ -f "$cases/$name.env" ] && envargs=$(tr '\n' ' ' < "$cases/$name.env")

  # Word splitting on $envargs is intentional.
  # shellcheck disable=SC2086
  env $envargs "$core" "$@" < "$cases/$name.in" > "$tmp" 2>/dev/null
  rc=$?

  if cmp -s "$tmp" "$expected" && [ "$rc" -eq "$want_rc" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s (exit %s, want %s)\n' "$name" "$rc" "$want_rc"
    printf '     --- expected ---\n'
    sed 's/^/     /' "$expected"
    printf '     --- actual ---\n'
    sed 's/^/     /' "$tmp"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
