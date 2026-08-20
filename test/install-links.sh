#!/bin/sh
# install.sh's link contract, in a sandbox: RECITE_BINDIR and RECITE_FISHDIR
# point at a mktemp -d, so nothing here touches ~/.local/bin or a real fish
# config, and no install is needed to run it.
#
# The cases are all about what install.sh must NOT delete. It removes files from
# a directory the user also keeps their own functions in, so the blast radius of
# a wrong condition is someone else's config, not a failed install.
set -u

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$dir/.." && pwd)
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

if ! command -v fish > /dev/null 2>&1; then
  echo "skip (fish not installed — install.sh does not link the fish half without it)"
  exit 0
fi

box=$(mktemp -d)
trap 'rm -rf "$box"' EXIT
bindir=$box/bin
fishdir=$box/fish

# Planted BEFORE the first install, so one run covers both the linking and the
# walk that has to leave these three alone.
mkdir -p "$fishdir"
#   stale: what an upgrade leaves behind when a function is deleted upstream.
ln -s "$repo/functions/__recite_gone.fish" "$fishdir/__recite_gone.fish"
#   foreign: dangling too, so "dangling" alone is not the condition being tested.
ln -s "$box/not-ours/other.fish" "$fishdir/other.fish"
#   a real file, which is what Homebrew's copy or the user's own function is.
echo 'function mine; end' > "$fishdir/mine.fish"

out=$(PATH="$bindir:$PATH" RECITE_BINDIR=$bindir RECITE_FISHDIR=$fishdir sh "$repo/install.sh" 2>&1)
st=$?
check "install exits 0 with its dirs on PATH" "$st" 0

linked=1
for f in recite.fish __recite_submit.fish; do
  [ -L "$fishdir/$f" ] || linked=0
done
[ -L "$bindir/recite-core" ] && [ -L "$bindir/recite-clip" ] || linked=0
check "links both executables and every shipped function" "$linked" 1

# The fix. Without the prune walk this link survives every upgrade, pointing at
# a file the repo deleted.
gone=present
[ -e "$fishdir/__recite_gone.fish" ] || [ -L "$fishdir/__recite_gone.fish" ] || gone=pruned
check "a dangling link into this repo is pruned" "$gone" pruned

# ... and the three things a wrong condition would take with it.
kept=no
[ -L "$fishdir/other.fish" ] && kept=yes
check "a dangling link NOT into this repo is left alone" "$kept" yes

kept=no
[ -f "$fishdir/mine.fish" ] && [ ! -L "$fishdir/mine.fish" ] && kept=yes
check "a real file in the fish dir is left alone" "$kept" yes

kept=no
[ -L "$fishdir/recite.fish" ] && [ -e "$fishdir/recite.fish" ] && kept=yes
check "a LIVE link is not pruned" "$kept" yes

# Idempotent: the second run has nothing to prune and nothing to relink.
out2=$(PATH="$bindir:$PATH" RECITE_BINDIR=$bindir RECITE_FISHDIR=$fishdir sh "$repo/install.sh" 2>&1)
check "re-running prunes nothing" "$(echo "$out2" | grep -c '^prune')" 0
check "re-running reports every link as already ok" "$(echo "$out2" | grep -c '^link')" 0

# --uninstall still takes only what it owns, including from under the prune.
PATH="$bindir:$PATH" RECITE_BINDIR=$bindir RECITE_FISHDIR=$fishdir sh "$repo/install.sh" --uninstall > /dev/null 2>&1
left=no
[ -L "$fishdir/other.fish" ] && [ -f "$fishdir/mine.fish" ] && left=yes
check "--uninstall leaves the foreign link and the real file" "$left" yes
check "--uninstall removes what it linked" "$([ -L "$fishdir/recite.fish" ] && echo present || echo gone)" gone

echo
if [ "$fails" -eq 0 ]; then
  echo "all install assertions passed"
else
  echo "$fails failed"
fi
exit $fails
