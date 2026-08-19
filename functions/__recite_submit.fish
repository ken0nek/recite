function __recite_submit --description 'Submit the current command line with output capture (recite)'
    # Before the buffer is read, so $cmd is the EXPANDED command: the abbreviation
    # is what the user typed, the expansion is what runs, and the header is a claim
    # about what ran. Without it the line executes verbatim and an
    # abbreviation-heavy config gets `Unknown command` on most of its keystrokes.
    commandline -f expand-abbr

    set -l cmd (commandline -b)
    set -l trimmed (string trim -- $cmd)

    # Empty line: behave exactly like enter.
    if test -z "$trimmed"
        commandline -f execute
        return
    end

    # A half-typed construct is not a command to submit. Inserting a newline is
    # alt-enter's own fish default, so this is the keystroke's other job rather
    # than a fallback: without it the fragment gets wrapped, refuses to parse,
    # execute declines, and the next press wraps the wrapped text again until the
    # line is cleared by hand.
    if not commandline --is-valid
        commandline -i \n
        return
    end

    # Wrapped, not appended to. Concatenating the suffix onto a line this
    # function never parses lets trailing syntax collide with it: `#` comments
    # the suffix out and copies nothing at all, silently; `;` and `&` make it a
    # syntax error that never runs the command; and `> file` still announces
    # "copied" over a block naming a command with empty output — the
    # plausibly-wrong artifact this project refuses to produce.
    #
    # Newlines rather than semicolons: a `#` comment ends at its line, so only a
    # newline puts `end` back out of its reach. They sit OUTSIDE the quotes
    # because fish expands `\n` in unquoted words only — inside double quotes it
    # is two characters, which lands the suffix back on the comment's line and
    # brings back every bug above. Adjacent quoted and unquoted parts are one
    # word.
    #
    # Stateless — no temp file, no pending-state variable, nothing to go stale —
    # and `--as` carries the TYPED command, embedded with fish's own quoting
    # primitive: the header names what the user ran, and begin/end is machinery
    # they did not type.
    commandline -r "begin"\n"$cmd"\n"end 2>&1 | recite --as "(string escape -- $cmd)
    commandline -f execute
end
