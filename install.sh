#!/bin/sh
# Install recite: executables onto PATH, fish functions into the fish config.
# Idempotent; safe to re-run.
#
# Deliberately installs NO keybinding: writing one into your config would make
# changing the default key a migration later, and the right key depends on your
# terminal. The README has the line to paste.
#
# Ownership contract: only ever replaces symlinks that already point into this
# repo, and refuses to clobber anything else. --uninstall is the same contract in
# reverse.
#
# Usage: install.sh [--uninstall]
#
# Environment:
#   RECITE_BINDIR   where the executables are linked  (default ~/.local/bin)
#   RECITE_FISHDIR  where the fish functions are linked
#   RECITE_SRC      where a curl-piped run unpacks    (default XDG data dir)
#   RECITE_REF      git ref to fetch in that case     (default the pinned tag)
set -u

action=install
for arg in "$@"; do
  case $arg in
    --uninstall) action=uninstall ;;
    -h|--help)   printf 'Usage: install.sh [--uninstall]\n'; exit 0 ;;
    *)           printf 'install.sh: unknown argument %s\n' "$arg" >&2; exit 2 ;;
  esac
done

repo=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bindir=${RECITE_BINDIR:-"$HOME/.local/bin"}
fishdir=${RECITE_FISHDIR:-"${XDG_CONFIG_HOME:-$HOME/.config}/fish/functions"}

# Piped to sh there is no script for $0, so the line above resolves to the
# dirname of the SHELL — `printf 'echo $0' | /bin/sh` prints /bin/sh, making
# $repo /bin and every link MISSING. Fetch a real checkout instead.
#
# A heuristic, since it probes the filesystem rather than being told: an
# install.sh reached by a path whose dirname is not a checkout (symlinked onto
# PATH, say) fetches upstream rather than using the tree it came from.
#
# The destination is deliberately UNVERSIONED. link() repoints any symlink into
# $repo, so re-running upgrades in place; a versioned path would make each
# upgrade look like a foreign symlink and print CONFLICT.
if [ ! -f "$repo/functions/recite-core" ]; then
  repo=${RECITE_SRC:-"${XDG_DATA_HOME:-$HOME/.local/share}/recite"}
  if [ "$action" = install ]; then
    # Pinned to a tag, not `main`: reading install.sh only audits install.sh, so
    # a moving branch would mean the file that actually handles your credentials
    # is whatever was pushed most recently. Bump at each release; RECITE_REF
    # overrides for testing main.
    #
    # NOT checksummed, deliberately: GitHub generates archive tarballs on demand
    # rather than storing them, and their bytes changed before (a 2023 gzip
    # change broke sha256 pins ecosystem-wide). A pin that upstream can
    # invalidate fails closed on every install at once, and looks exactly like an
    # attack. Revisit if a release ships a real uploaded asset.
    ref=${RECITE_REF:-v0.1.1}
    printf 'fetch    %s@%s\n' "$repo" "$ref"
    mkdir -p "$repo" || exit 1

    # Downloaded whole, then extracted — not `curl | tar`. A transfer that dies
    # mid-stream leaves that pipeline with a PARTIALLY extracted tree and a zero
    # exit, which then gets symlinked onto PATH. A half install is worse than none.
    tgz=$(mktemp "${TMPDIR:-/tmp}/recite.XXXXXX") || exit 1
    # INT and TERM need their own handlers that exit. Sharing one with EXIT would
    # clean up and then CARRY ON, so Ctrl-C during the download would be swallowed
    # and the install would complete anyway, reporting success.
    trap 'rm -f "$tgz"' EXIT
    trap 'rm -f "$tgz"; exit 130' INT
    trap 'rm -f "$tgz"; exit 143' TERM
    if ! curl -fsSL \
      "https://github.com/ken0nek/recite/archive/$ref.tar.gz" -o "$tgz"; then
      printf 'FAILED   could not download ref %s\n' "$ref" >&2
      exit 1
    fi
    tar -xzf "$tgz" -C "$repo" --strip-components=1 || exit 1
  fi
fi

status=0

# link <source> <destination>
link() {
  src=$1
  dst=$2

  if [ ! -e "$src" ]; then
    printf 'MISSING  %s\n' "$src"
    status=1
    return
  fi

  if [ -L "$dst" ]; then
    current=$(readlink "$dst")
    case $current in
      "$src")
        printf 'ok       %s\n' "$dst"
        return
        ;;
      "$repo"/*)
        ln -sfn "$src" "$dst"
        printf 'repoint  %s\n' "$dst"
        return
        ;;
      *)
        printf 'CONFLICT %s -> %s (not ours, left alone)\n' "$dst" "$current"
        status=1
        return
        ;;
    esac
  fi

  if [ -e "$dst" ]; then
    printf 'CONFLICT %s exists and is not a symlink (left alone)\n' "$dst"
    status=1
    return
  fi

  ln -s "$src" "$dst"
  printf 'link     %s\n' "$dst"
}

# remove_link <destination> — delete it only if it is a symlink into this repo.
# Silent on anything else: a real file at that path is Homebrew's copy or the
# user's own, and neither is ours to delete.
removed=0
remove_link() {
  dst=$1
  [ -L "$dst" ] || return 0
  case $(readlink "$dst") in
    "$repo"/*)
      rm -f "$dst"
      printf 'remove   %s\n' "$dst"
      removed=$((removed + 1))
      ;;
  esac
}

if [ "$action" = uninstall ]; then
  for name in recite-core recite-clip; do
    remove_link "$bindir/$name"
  done
  # Walk the fish directory rather than this repo's: readlink still names the
  # old target after a checkout is deleted, so this also clears stale links.
  for f in "$fishdir"/*.fish; do
    remove_link "$f"
  done

  if [ "$removed" -eq 0 ]; then
    printf 'Nothing to remove — no symlinks into %s found.\n' "$repo"
  else
    printf '\nRemoved %d symlink(s). The checkout at %s is left in place.\n' "$removed" "$repo"
    printf 'A `bind alt-enter __recite_submit` line in your fish config is yours to remove.\n'
  fi
  exit 0
fi

mkdir -p "$bindir" || exit 1
for name in recite-core recite-clip; do
  if [ ! -x "$repo/functions/$name" ]; then
    printf 'MISSING  %s is not executable\n' "$repo/functions/$name"
    status=1
    continue
  fi
  link "$repo/functions/$name" "$bindir/$name"
done

if command -v fish > /dev/null 2>&1; then
  mkdir -p "$fishdir" || exit 1
  for f in "$repo"/functions/*.fish; do
    link "$f" "$fishdir/${f##*/}"
  done

  # The loop above only ever ADDS, so an upgrade in place keeps a link to every
  # function this repo has ever shipped. Walk the destination too and drop the
  # ones whose source is gone.
  #
  # Two conditions, and both are the safety: a DANGLING link cannot be a live
  # install, and a link into $repo cannot be anyone else's. A real file there is
  # Homebrew's copy or the user's own, and neither is ours to touch — the same
  # contract remove_link keeps on the way out.
  for f in "$fishdir"/*.fish; do
    [ -L "$f" ] || continue
    [ -e "$f" ] && continue
    case $(readlink "$f") in
      "$repo"/*)
        rm -f "$f"
        printf 'prune    %s\n' "$f"
        ;;
    esac
  done
else
  printf 'skip     fish not installed, so fish functions are not linked\n'
fi

case ":$PATH:" in
  *":$bindir:"*) ;;
  *) printf '\nNOTE     %s is not on PATH\n' "$bindir"; status=1 ;;
esac

if [ "$status" -eq 0 ]; then
  printf '\nInstalled. To bind alt-enter, add to your fish config:\n'
  printf '    bind alt-enter __recite_submit\n'
fi

exit $status
