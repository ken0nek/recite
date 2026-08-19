# Deletes AND flags, because neither alone is enough. Interactively fish aborts
# the function outright and only the delete runs; in a script fish resumes past
# the tee, and without the flag the core would then redirect from the file this
# just removed and print two `warning:` lines at the user.
#
# `command rm`: an unqualified one HERE would be the same shadowing bug this is
# meant to close, in the code meant to close it.
function __recite_on_int --on-signal INT --description 'Remove the capture buffers when a recited command is interrupted'
    set -q __recite_buf; and command rm -f $__recite_buf
    set -g __recite_interrupted 1
end

function recite --description 'Copy a command and its output as a pasteable console block'
    # argparse derives a short flag from every long option and has no long-only
    # form, so `--version` unavoidably also answers to `-v` — a reflex for
    # "verbose", not the same request. argparse normalizes both to $_flag_version,
    # so the spelling has to be read off raw argv before it is consumed. Only
    # consulted when _flag_version is set, so `recite --as '--version'` is safe.
    set -l version_is_explicit
    contains -- --version $argv; and set version_is_explicit 1

    argparse 'as=' 'no-redact' 'version' -- $argv
    or return 1

    # PATH first (Homebrew, install.sh), then beside this function (fisher). PATH
    # wins, so `brew upgrade` stays authoritative and a compiled core drops in.
    #
    # `path resolve` is load-bearing: `status -f` reports the AUTOLOAD path, which
    # for install.sh is a symlink in ~/.config/fish/functions — a directory holding
    # only the *.fish files, never the executables.
    #
    # $here stays EMPTY when no file defined the function (`cat recite.fish |
    # source`, where `status -f` is `-`); `dirname` of that is `.`, which would hand
    # the captured stream — credentials included — to whatever ./recite-core is in
    # the cwd.
    set -l self (status -f)
    set -l here
    test -f "$self"; and set here (command dirname (path resolve "$self"))

    set -l core (command -v recite-core)
    set -l clip (command -v recite-clip)
    set -l here_msg
    if test -n "$here"
        test -n "$core"; or set core $here/recite-core
        test -n "$clip"; or set clip $here/recite-clip
        set here_msg " or in $here"
    end

    # Answered before the executable guard and the stdin check: this is the
    # diagnostic for a broken or shadowed install, so it has to work when those
    # are exactly what is wrong.
    if set -q _flag_version
        set -l report
        if test -x "$core"
            # </dev/null or this hangs forever against a core predating the flag:
            # its catch-all swallows --version, then blocks reading the stdin it
            # inherited — precisely the mixed-channel install this diagnoses.
            set report ($core --version </dev/null)
        else
            set report "recite-core: not executable"
        end
        set -a report "function  $self"
        test -n "$core"; and set -a report "core      $core"; or set -a report "core      (unresolved)"
        test -n "$clip"; and set -a report "clip      $clip"; or set -a report "clip      (unresolved)"

        # A version query must never have side effects, so spelled in full it
        # short-circuits whatever stdin holds — no tee, no clipboard.
        if test -n "$version_is_explicit"; or isatty stdin
            printf '%s\n' $report
            return 0
        end

        # Reached only by `-v` with something actively piping in: nobody pipes
        # output into a version query, so they meant verbose and are about to
        # lose that output if this returns. Report on stderr, then do the job.
        printf '%s\n' $report >&2
    end

    if isatty stdin
        echo "recite: expects a command's output on stdin." >&2
        echo "     Press alt-enter instead of enter, or append '| recite' to a command." >&2
        return 2
    end

    # Two ways in, quarantined here so recite-core never knows which happened:
    #   - binding: __recite_submit read the line BEFORE mutating it, so --as is exact.
    #   - hand-typed suffix: recovered from history, best-effort.
    #     __recite_strip_suffix returns nothing unless the line ends in a recite
    #     suffix, so an unrelated line yields no header rather than a wrong one.
    set -l cmd
    if set -q _flag_as
        set cmd $_flag_as
    else if set -q history[1]
        set cmd (__recite_strip_suffix $history[1])
    end

    set -l core_args
    test -n "$cmd"; and set -a core_args --as $cmd
    set -q _flag_no_redact; and set -a core_args --no-redact

    set -l tmpdir /tmp
    set -q TMPDIR; and set tmpdir $TMPDIR
    # `command` throughout: fish functions shadow external commands, and aliasing
    # `rm` to a trash CLI is a common setup — which would move this buffer, raw
    # credentials and all, somewhere far more durable than $TMPDIR.
    set -l buf (command mktemp $tmpdir/recite.XXXXXX)
    or return 2

    # Published to the INT handler, which cannot see a `set -l`. Cleared HERE
    # rather than at the end of the last run, because that run may have been the
    # one that was aborted before it cleared anything.
    set -g __recite_buf $buf
    set -e __recite_interrupted

    # stdin goes to the terminal verbatim (the output must still look normal) and
    # to a buffer, because recite-core needs to read it too.
    command tee $buf

    # BELOW the tee for the same reason the executable guard is — see the comment
    # under it. Everything between the tee and this check runs *after* an
    # interrupt in the script case, so do not add anything here that assumes
    # $buf still exists: the handler already deleted it.
    if set -q __recite_interrupted
        set -e __recite_interrupted
        command rm -f $buf
        set -e __recite_buf
        return 130
    end

    # Checked HERE, after the tee, not up with the resolution above. The output is
    # already flowing through this function, so an early return would not merely
    # skip the copy — it would DESTROY the output and SIGPIPE whatever is still
    # producing it. Printing is the prime directive; failing to copy is the
    # recoverable half.
    #
    # Quoted: $core and $clip are EMPTY when nothing resolved, and an unquoted
    # empty variable expands to zero arguments in fish — leaving a bare `test -x`.
    if not test -x "$core"; or not test -x "$clip"
        # Deleted before it is untracked, never the reverse: an interrupt landing
        # between these two lines then finds a path already gone (`rm -f` is a
        # no-op) instead of a live buffer it can no longer see.
        command rm -f $buf
        set -e __recite_buf
        echo "recite: no recite-core/recite-clip on PATH$here_msg" >&2
        echo "     output above is intact. Nothing was copied." >&2
        echo "     run 'recite --version' to see what resolved." >&2
        return 2
    end

    # Formatted to a file, NOT piped straight into the clip: both sides of a
    # pipeline start together, so a core that REFUSES its input still hands the
    # clip an empty stream and pbcopy destroys whatever the user had. "Refusing"
    # has to mean the clipboard is left alone.
    #
    # A file rather than a variable: `set -l block ($core …)` would strip the
    # block's trailing newline, and "the paste lost its blank line" is a tedious
    # bug to find.
    set -l out (command mktemp $tmpdir/recite.XXXXXX)
    or begin
        command rm -f $buf
        set -e __recite_buf
        return 2
    end
    # APPENDED rather than given a second variable: $__recite_buf is a list, so
    # the handler's one `command rm -f $__recite_buf` already takes both paths.
    # Registered before anything can block — and because the `set -g` above
    # assigns rather than appends, a list left over from a run that was aborted
    # before it cleared anything is overwritten, not inherited.
    set -a __recite_buf $out

    $core $core_args <$buf >$out
    set -l core_st $status
    # The unredacted capture lives for the format, not for the copy: deleted as
    # soon as the core has read it, earlier than the pipeline managed. Its path
    # stays in the list, where `rm -f` on a vanished file is a no-op — which is
    # why no element ever has to be surgically removed from it.
    command rm -f $buf

    if test $core_st -ne 0
        command rm -f $buf $out
        set -e __recite_buf
        return $core_st
    end

    # The second blocking window, and the status check above does not cover it:
    # a core the interrupt killed exits non-zero and is caught there, but a core
    # that had already finished exits 0 — while the handler has meanwhile deleted
    # $out, so the copy below would redirect from a path that no longer exists
    # and print two `warning:` lines at the user.
    #
    # 130, not the core's 0: the core succeeding is not this run succeeding when
    # nothing reached the clipboard, and reporting success for that is exactly the
    # plausibly-wrong outcome this tool refuses elsewhere. It is also the code the
    # tee window above already returns — one event, one code.
    if set -q __recite_interrupted
        set -e __recite_interrupted
        command rm -f $buf $out
        set -e __recite_buf
        return 130
    end

    $clip <$out
    set -l clip_st $status
    command rm -f $buf $out
    set -e __recite_buf

    if test $clip_st -ne 0
        return $clip_st
    end

    echo "recite: copied" >&2
end
