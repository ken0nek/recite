# recite

Notes for coding agents that work in this repository.

`recite` copies a command **and its output** as a pasteable ```console block, while the
output still prints normally. fish and zsh, macOS only.

```
alt-enter          per-shell: rewrites the typed line to end in `| recite --as …`
  │                  fish  functions/recite.fish + __recite_submit.fish (autoloaded)
  │                  zsh   the widget `recite init zsh` prints, eval-ed from .zshrc
  └── recite         POSIX sh: resolves both backends, tees, orders the pipeline
        └── recite-core  POSIX sh + one awk pass: stdin -> block on stdout
              └── recite-clip  POSIX sh: stdin -> clipboard, or OSC 52 to the terminal
```

Two splits, and both are load-bearing.

`recite-core` touches no clipboard, so it is golden-testable as a pure filter, and its
contract is *stdin + `--as` + `--version` + exit code* only. Nothing above it learns how it
works, which is what keeps a future Go core a drop-in.

`recite` is everything that is not per-shell: resolution, the tee, the ordering
constraints, the signal traps. A shell layer is a keybinding and nothing else, which is why
zsh cost ~25 lines rather than ~110 and why a pipeline fix is one edit rather than one per
shell. **Put new pipeline behavior in `recite`, never in a shell layer.**

`README.md` is the user-facing half. This file is what to do and what will break.

## Commands

```sh
test/all.sh                             # golden, shared, fish, zsh and install suites (no side effects)
test/run.sh redact-jwt cap-lines        # one or more golden cases by name
RECITE_TEST_CLIPBOARD=1 test/all.sh     # adds the real clipboard round-trip (clobbers clipboard)
RECITE_TEST_BINDING=1 test/all.sh       # adds the alt-enter pty cases; timing-sensitive
RECITE_TEST_CROSS_SHELL=1 test/all.sh   # adds the fish-vs-zsh byte comparison; timing-sensitive
./install.sh                            # symlink into ~/.local/bin + fish functions; idempotent
./install.sh --uninstall                # remove only symlinks pointing back into this checkout
recite init zsh                         # the zsh layer, on stdout
```

## Tests

`recite-tests.sh` covers the shared executable, and specifically what no shell layer can
reach: the version skew between `recite` and `recite-core`, the `init` subcommand, and the
INT/TERM/HUP traps. **Its signal cases run twice, and the second pass is the one with
teeth** — macOS `/bin/sh` is bash 3.2, which runs the EXIT trap even when it dies of an
untrapped signal, so under it the `TERM` and `HUP` traps can be DELETED and the cases still
pass. The second pass uses `/bin/dash`, which does not, and goes red.

The fish suite runs as `fish --no-config` children, hermetic: each sources `recite.fish` by
path inside a `mktemp -d` sandbox, with a stub `recite-clip` that records to a file. No
install is needed, the real clipboard is never touched, and a failure means the code is
wrong rather than the environment. They cover both resolution branches, `--version`, header
redaction, the absence of a header when no `--as` is given, and the order of the guard
against the `tee`. **Every sandbox channel needs a `recite` planted in it**; without one the
shim takes its no-backend branch and every assertion below becomes a test of an error
message.

The zsh suite sources what `recite init zsh` prints and calls the widget directly with
`zle` stubbed — zsh resolves a function name before a builtin, so a function named `zle`
shadows it. `zsh -f` is correct there and wrong in the pty harnesses, which reach the layer
through a generated rc that `-f` skips along with the system ones.

`cross-shell.sh` is milestone A-min's gate: the same command, through each shell's real
binding, must reach the clipboard as the same bytes. It compares only what both shells can
agree on — the `$ command` header where they parse a line differently, the whole block
otherwise. zsh leaves `interactive_comments` off, so a typed `#` is literal there and a
comment in fish; both shells are right and no port can close it.

`install-links.sh` is about deletion rather than installation: `install.sh` prunes dangling links out of a directory the user also keeps
their own functions in, so the cases pin what it must NOT take — a dangling link that is
not ours, a real file, a live link. Sandboxed through `RECITE_BINDIR` and `RECITE_FISHDIR`,
so it never touches a real config.

`clip-tests.sh` is `recite-clip`'s own suite, hermetic through `RECITE_TTY` (the OSC 52
target) and `RECITE_BACKEND` (selection). The real clipboard is never touched. Four things
about it will cost you a case that green-lights the bug it names:

- **No write-path case can see `have_osc52`.** The emitter refuses the same situations by
  its own route and reaches the same exit 4, so a probe check that is deleted stays green
  across every write case in the file — measured for both the open and the `base64` check.
  `--which` is the only caller that runs the probe and nothing else, so **every probe check
  needs a `--which` case**, and that is what pins the open and the encoder.
- **A sandbox `PATH` replaces the whole system.** `plant` puts `mktemp` and `rm` in every
  one, because the emitter stages its encode in a file and the traps remove it. Without
  them a mutation dies on the missing `mktemp` and the case goes red for the wrong reason,
  which is the same as having no teeth.
- **The no-newline case does not exercise a wrap here.** macOS `base64` emits 400
  characters on one line, so deleting `| tr -d` reddens it via the single TRAILING newline;
  the wrap it is named for is only reachable on a GNU `base64`. The companion assertion is
  a guard on the fixture, not evidence.
- **The staging-file cases run under two interpreters**, for the reason `recite-tests.sh`
  does: under macOS `/bin/sh` the `TERM` and `HUP` traps can be deleted and they still
  pass.

Do not write the assertion counts into this file. They were wrong here once already.

Traps that made earlier versions of these cases pass against broken code:

- **On a pty, expect reads only while an `expect` is running.** During a `sleep` the pty
  output queue fills and the recited pipeline BLOCKS inside its `tee`. A `send "\003"` in
  that window is the worst thing to send: INTR flushes the terminal queues, the blocked
  write completes with the output discarded, and a block with an EMPTY body is copied —
  which reads exactly like the tee having been skipped. Wait for `recite: copied` rather
  than sleeping.
- **BSD `grep` has no GNU `\|` alternation**, and does not say so. `grep -c '^A$\|^B$'`
  matched one of two lines here while the GNU grep on the same machine matched both: green
  on one box, red on the next. Use `grep -E`.
- **A trailing-`#` case cannot assert that the rewritten line PARSES.** An appended suffix
  parses there too — it is simply commented out. Assert on what the sink received.
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
- **`recite.fish` is a shim and must stay one.** Its only job is the thing a portable script
  cannot do: ask fish where an autoloaded function came from, so the fisher channel can
  find its siblings. PATH first, then that directory. Whatever you are tempted to add there
  belongs in `recite`, where zsh gets it for free.
- **`recite.fish` keeps an empty `--on-signal INT` handler, and it is load-bearing.** With
  no handler registered, a non-interactive fish takes SIGINT as a request to abandon the
  rest of the script — so the function never returns and the 130 that `recite` exited with
  is never seen. It cleans nothing up; `recite` does that itself.
- **The zsh widget is a quoted heredoc inside `recite`, not a fifth file.** `recite init
  zsh` would otherwise have to find a sibling from `$0`, which is a symlink in
  `~/.local/bin` — and `readlink -f` is not reliably present on the older macOS this
  supports. `<<'ZSH'` also keeps the apostrophe rule above out of scope.
- **The OSC 52 emitter encodes into a file first, and that split is the bug fix.** One
  command group exits with its LAST command's status — a `printf` of the terminator, which
  cannot fail — so a `base64` that exists and then fails used to put a well-formed OSC 52
  with an EMPTY payload on the wire: the terminal reads that as "set the clipboard to
  nothing", and the run reported a send, exit 0. `base64 > "$enc"` has its own status and
  nothing reaches the terminal until it passes. The emit is an `&&` chain for the same
  reason. The staging file is the user's captured output, so `recite-clip` traps EXIT, INT,
  TERM and HUP for it exactly as `recite` does for its buffers.
- **`have_osc52` still checks for `base64` even though the emitter now catches it.** The
  probe's job is SELECTION: it is what `--which` answers from and what the `auto` chain
  decides on, and naming a backend that cannot encode is the dishonesty this tool exists to
  avoid. The `tr` check is load-bearing on both paths — without it the ESC prefix is
  already on the wire when `tr` fails to run.
- **The backend chain lives in `recite-clip`, and `recite` learns the backend only from its
  one line of stdout** — `<backend> <confirmed|unconfirmed>`. `recite` owns every string on
  the success path, so a new backend is one `have_` helper and its `case` arms in
  `recite-clip`, and zero in `recite`. An empty or unparseable line is the SKEW path, not an
  error: it degrades to the bare `recite: copied` that shipped before.
- **That `$(…)` around the clip call captures a status LINE, not the output.** The
  no-command-substitution rule is about the captured text — which still reaches the sink as
  a stream through `< "$out"` — and it still holds for it. Here a stripped trailing newline
  is the wanted behavior.
- **Test tty openability with `true 2> /dev/null 3>> "$tty"`.** All three parts are
  load-bearing. `[ -w ]` is `access(2)` and returns true with no controlling tty, where the
  open then fails. `: > "$tty"` truncates — harmless against a real `/dev/tty`, destructive
  against a `RECITE_TTY` test file. And `:` is a special builtin, so a redirection error on
  it kills a non-interactive `dash` outright; `true` returns false instead. Redirections
  apply left to right, so `2>` has to come first or the failure prints.
- **`recite-clip --which` is called with stdin CLOSED (`<&-`), never `< /dev/null`.** A
  `recite-clip` predating `--which` is `exec pbcopy`, and `pbcopy --which` handed a readable
  `/dev/null` exits 0 and **wipes the clipboard**. With stdin closed it aborts instead and
  the clipboard survives. The stub in `recite-tests.sh` must REJECT anything but `--which`:
  with it ignoring argv, dropping the flag left every assertion green, including the one
  named for it — and against the real clip on the osc52 backend that regression makes
  `--version` clear the clipboard it exists to describe. This is a different trap from the
  `--version` core call, which needs `< /dev/null` because its hazard is blocking, not
  wiping — do not unify them.
- **fish does not move to `init`, and that is forced rather than chosen.** fisher's whole
  contract is autoloading `functions/*.fish`; an init form would break that channel.
- **Never install a keybinding, and never write to a shell config.** A shipped one turns
  any change of the default key into a migration. `install.sh` PRINTS the lines — `bind
  alt-enter __recite_submit` for fish, `eval "$(recite init zsh)"` plus `bindkey '^[^M'`
  for zsh — and the README carries them. There is deliberately no `conf.d/`.
- **No `setopt` in the user's zsh.** Changing their shell options so zsh's output matches
  fish's would be the tool editing the shell it is a guest in.
- **Both version strings move together.** `recite` and `recite-core` carry one each, because
  they are two links now and a channel can upgrade one without the other;
  `recite-tests.sh` holds them equal. A release moves four pins: those two,
  `test/cases/version.expected`, and the tag `install.sh` fetches.

## Docs

Two: `README.md` and this one. The README carries install, use, options, redaction and the
known limits — everything a user needs and nothing else. Keep both lean.
