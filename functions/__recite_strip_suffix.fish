function __recite_strip_suffix --description 'Recover the user command from a history line ending in a recite suffix'
    set -l line $argv[1]
    test -n "$line"
    or return 1

    # The leading group is GREEDY on purpose, anchoring on the LAST '| recite' so
    # a literal one inside a quoted string survives instead of truncating the
    # command at the quote.
    #
    # (?s) so '.' crosses newlines: PCRE excludes them by default, which leaves
    # the suffix attached on every multi-line entry.
    #
    # Collecting keeps the result ONE string. fish stores a multi-line command as
    # a single history entry, and uncollected the substitution splits that into a
    # list of lines — which the guard below then compares space-joined against a
    # newline-carrying original. Never equal, so the guard stops firing exactly
    # where it is needed most.
    set -l stripped (string replace -r '(?s)^(.*)\|\s*recite(\s.*)?$' '$1' -- $line | string collect)

    # string replace echoes the input unchanged when nothing matched. A line not
    # ending in a recite suffix is NOT this command but whatever ran before, and
    # attaching that to this output would be silently, plausibly wrong.
    if test "$stripped" = "$line"
        return 1
    end

    # Drop the stderr redirect the binding appends (or the user typed).
    set stripped (string replace -r '\s*2>&1\s*$' '' -- $stripped | string collect)

    set -l trimmed (string trim -- $stripped | string collect)
    test -n "$trimmed"
    or return 1

    echo $trimmed
end
