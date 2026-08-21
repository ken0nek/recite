# Empty, and load-bearing anyway. Nothing here cleans up — `recite` traps INT,
# TERM and HUP itself and deletes its own buffers. What this buys is fish's
# behavior on the OTHER side of the signal: with no handler registered, a
# non-interactive fish takes SIGINT as a request to abandon the rest of the
# script, so the function never returns and the 130 that `recite` exited with is
# never seen. Registering one makes fish resume past the interrupted job, which
# is what lets that status propagate.
#
# It is `--on-signal INT` and nothing else because that is the only signal fish
# is in the middle of a job for. TERM and HUP kill the shell outright, and
# `recite` still cleans up after itself under both.
function __recite_on_int --on-signal INT --description 'Let fish resume past an interrupted recite so its exit status survives'
end

function recite --description 'Copy a command and its output as a pasteable console block'
    # A shim, and only a shim. Everything this used to do lives in `recite`, the
    # POSIX executable beside this file — one copy for every shell rather than
    # one per shell. What stays here is the single thing fish knows and a
    # portable script cannot: where an autoloaded fish function came from.
    #
    # PATH first (Homebrew, install.sh), then beside this function (fisher).
    # PATH wins, so `brew upgrade` stays authoritative and a compiled drop-in
    # takes precedence. This is the one place that rule is implemented.
    #
    # `path resolve` is load-bearing: `status -f` reports the AUTOLOAD path,
    # which for install.sh is a symlink in ~/.config/fish/functions — a directory
    # holding only the *.fish files, never the executables.
    #
    # $here stays EMPTY when no file defined the function (`cat recite.fish |
    # source`, where `status -f` is `-`); `dirname` of that is `.`, which would
    # hand the captured stream — credentials included — to whatever ./recite
    # happens to be in the cwd.
    set -l self (status -f)
    set -l here
    test -f "$self"; and set here (command dirname (path resolve "$self"))

    set -l here_msg
    test -n "$here"; and set here_msg " or in $here"

    set -l exe (command -v recite)
    if test -z "$exe"; and test -n "$here"; and test -x "$here/recite"
        set exe $here/recite
    end

    if test -z "$exe"
        # NOT an early return. The output is already flowing through this
        # function, so returning here would not merely skip the copy — it would
        # destroy the output and SIGPIPE whatever is still producing it.
        # Printing is the prime directive; failing to copy is the recoverable
        # half. `cat` is the cheapest way to keep that promise with nothing left
        # to delegate to.
        if not isatty stdin
            command cat
        end
        echo "recite: no recite executable on PATH$here_msg" >&2
        echo "     output above is intact. Nothing was copied." >&2
        return 2
    end

    # Called, never `exec`ed. `exec` in fish replaces the shell itself, and
    # `recite --version` typed at a prompt is not in a pipeline — so it would
    # replace the user's interactive session.
    $exe $argv
end
