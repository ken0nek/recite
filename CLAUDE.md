# recite

Notes for coding agents that work in this repository.

`recite` copies a command **and its output** as a pasteable ```console block, while the
output still prints normally. Milestone M0: fish + macOS only.

```
recite (fish fn)   resolves the command string, tees to terminal, delegates
  └── recite-core  POSIX sh + one awk pass: stdin -> formatted block on stdout
        └── recite-clip  POSIX sh: stdin -> clipboard
```

The split is load-bearing: `recite-core` touches no clipboard, so it is golden-testable as
a pure filter, and its contract is *stdin + `--as` + `--version` + exit code* only. The
fish layer never learns how it works, which is what keeps a future Go core a drop-in.

`README.md` is the user-facing half. This file is what to do and what will break.

## Commands

```sh
test/all.sh                             # golden + fish suites (no side effects)
test/run.sh redact-jwt cap-lines        # one or more golden cases by name
RECITE_TEST_CLIPBOARD=1 test/all.sh     # adds the real clipboard round-trip (clobbers clipboard)
RECITE_TEST_BINDING=1 test/all.sh       # adds the alt-enter pty case; timing-sensitive
./install.sh                            # symlink into ~/.local/bin + fish functions; idempotent
./install.sh --uninstall                # remove only symlinks pointing back into this checkout
```

## Tests

The fish suite runs as `fish --no-config` children, hermetic: each sources `recite.fish` by
path inside a `mktemp -d` sandbox, with a stub `recite-clip` that records to a file. No
install is needed, the real clipboard is never touched, and a failure means the code is
wrong rather than the environment. They cover both resolution branches, `--version`, header
redaction, the absence of a header when no `--as` is given, and the order of the guard
against the `tee`.

Do not write the assertion counts into this file. They were wrong here once already.

Three traps that made earlier versions of those cases pass against broken code:

- **`2>&1 | …` does not carry stderr in fish** — it wants `&|`. An assertion that greps a
  subshell's stderr silently matches nothing and reports `ok`. Assert on a file the stub
  touched, not on a stream.
- **A fixture missing one half proves nothing.** The cwd-execution case needs a plausible
  `recite-clip` beside the planted `recite-core`, or the guard rejects the *clip* and
  returns before the plant is ever reached.
- **fish `printf` has no `--`, and `$history` is read at startup.** Both empty a fixture in
  silence. Handed `--`, fish prints the two dashes and DROPS the format after it; and
  `XDG_DATA_HOME`/`fish_history` set inside the `-c` string arrive after fish resolved its
  history file. Either one leaves `$history` empty, which is what a passing header case
  looks like whether or not the fallback is back.

**Reintroduce the bug that every new case covers** and confirm that the case fails. Three
of the first drafts passed against broken code.

### Goldens

Compared with `cmp`, not `$(...)` — trailing newlines are part of the expected output. A
case is `test/cases/<name>.{in,expected,args,env,exit}`. There is no `--bless`. To rebuild
an expectation, invoke the core the way `run.sh` does, with env from `<name>.env` and argv
from `<name>.args` (one argument per line, so pass those by hand). Then read the diff before
you commit it.

```sh
env $(tr '\n' ' ' < test/cases/cap-lines.env) ./functions/recite-core < test/cases/cap-lines.in > test/cases/cap-lines.expected
```

**Bump `test/cases/version.expected` at every release.** It pins `--version`, which is
part of the core's contract precisely so a reimplementation cannot pass the suite and
still break `recite --version`.

`RECITE_CORE` and `RECITE_CLIP` point the suites at a different binary, so a Go core can
reuse these goldens as its acceptance criteria.

## Rules

- **No apostrophe anywhere in `recite-core`'s awk program**, comments included. It is one sh
  single-quoted string, and one apostrophe closes it mid-awk. The symptom names neither awk
  nor the quote — the shell reads the remainder as commands and reports its own syntax error
  at a line *inside* the program.
- **Every credential pattern goes through `redact_re`**, which anchors it at a token
  boundary. A bare `gsub` puts mid-word matching back: `feature/task-1234-fix` becomes
  `feature/ta[REDACTED]`, and only the clipboard shows it. Over-redacting is the correct
  direction of error. Matching mid-word never was.
- **Keep `LC_ALL=C` in `recite-core`** — byte-counting for `RECITE_MAX_BYTES`, deterministic
  matching for the byte-exact goldens.
- **POSIX `sh`, and awk rather than sed** for text work. Use `+`, never `{n,}` intervals:
  BWK awk `20070501` lacked them, and the portability matrix spans BWK, gawk and mawk.
- **Do not move `recite-core` and `recite-clip` into `bin/`.** All four files live in a root
  `functions/`, one copy each, no symlinks — fisher ships that directory regardless of file
  type, and any other layout costs either a duplicate or a symlink to feed it.
- **There is no `$history[1]` fallback for the hand-typed `cmd | recite` path, and do not add
  one back.** `recite` runs as the tail of the very line it would be reading, and fish does
  not commit a line to history until it finishes executing — so `$history[1]` there is
  structurally always the PREVIOUS line, never this one. It does not degrade to no header, it
  confidently attaches someone else's command to this output. No header beats a wrong one;
  `--as` is the only way hand-typed usage gets one.
- **Keep the PATH-first resolution branch in `recite.fish` and nowhere else** — the same file
  that owns the one command-string path (`--as`), whether the user passes it directly or
  `__recite_submit` fills it in for the binding.
- **Never install a keybinding.** A shipped one turns any change of the default key into a
  migration. The README tells the user to paste `bind alt-enter __recite_submit`. There is
  deliberately no `conf.d/`.

## Docs

Two: `README.md` and this one. The README carries install, use, options, redaction and the
known limits — everything a user needs and nothing else. Keep both lean.
