# recite

Copy a command **and its output** as a pasteable console block, while the output
still prints normally.

```console
$ brew list --installed-on-request
asc
bat
eza
```

That block is what lands on the clipboard. `pbcopy` alone omits the command. On the
way, recite strips colors, progress-bar redraws and terminal escapes, so what you
paste is what you saw.

Terminals that do this natively — iTerm2's `Copy Last Command Output`, Warp's command
blocks — are terminal-locked. Session recorders and terminal-screenshot tools give you
a recording or an image, and whoever receives an image cannot quote, diff, or search
it. This is text, from any terminal.

## Status

fish and zsh, on macOS — and where there is no `pbcopy` to reach, on a remote
host or inside tmux, it writes to the terminal's own clipboard so the text lands
on the machine you are sitting at. No bash, no Linux clipboard tools, no
Windows.

## Use

Press **`alt-enter`** instead of `enter`, once you have added
[the binding](#the-keybinding-is-yours-to-add) — recite ships none. Nothing is
prefixed and nothing is wrapped, so completions, autosuggestions, abbreviations,
highlighting and line editing are untouched.

Or append the suffix by hand, which needs no keybinding:

```sh
brew list --installed-on-request 2>&1 | recite
```

Both print to the terminal as normal and put the block on the clipboard.

Prefer the binding: it reads the command line *before* it appends, so the command
string is exact. The suffix path **never emits a `$ command` header** — `recite` is
the tail of the very line it would need to read back, and no shell commits a line to
its history until that line finishes running, so there is no reliable way to recover
it from inside the pipeline itself. Pass `--as '<cmd>'` by hand if you want an exact
header without the binding.

## Install

Three channels. **Each is a complete install. You need only one.**

```sh
brew install ken0nek/tap/recite
```

```fish
fisher install ken0nek/recite
```

Or clone and run the installer:

```sh
git clone https://github.com/ken0nek/recite.git && ./recite/install.sh
```

`install.sh` symlinks `recite`, `recite-core` and `recite-clip` into `~/.local/bin`
and the fish functions into `~/.config/fish/functions`. It is idempotent, and it
replaces only symlinks that already point into its own checkout — anything else
prints `CONFLICT` and is left alone. `RECITE_BINDIR` and `RECITE_FISHDIR` override
the destinations. `--uninstall` removes exactly what it created. It writes nothing
into any shell config; the lines to paste are printed when it finishes.

It also runs from `curl`, in the form that lets you read it first:

```sh
curl -fsSL https://raw.githubusercontent.com/ken0nek/recite/main/install.sh -o install.sh
less install.sh && sh install.sh
```

**That audits `install.sh` only.** Outside a checkout it downloads a release
tarball and puts `recite-core` — the half that reads your command output — on
your `PATH`, unseen. The fetch is pinned to a release tag, not `main`. Clone to
read everything before anything runs. Four pieces, and only the top one is
per-shell:

```
alt-enter          fish function / zsh widget   rewrites the line you typed
  └── recite         POSIX sh      tees to the terminal, then delegates
        └── recite-core  POSIX sh+awk  stdin -> formatted block on stdout
              └── recite-clip  POSIX sh  stdin -> clipboard
```

**Do not install two channels.** Both write into `~/.config/fish/functions`, and
`install.sh` prints `CONFLICT` rather than overwrite what it does not own — the
loud case. The quiet one is the tap. That directory precedes Homebrew's
on `$fish_function_path`, so a fisher copy shadows a Homebrew one. `brew upgrade`
then has no visible effect, and nothing warns you. `recite --version` prints one
row per component — version beside path — so a half-upgraded install shows as two
versions rather than as nothing at all.

### The keybinding is yours to add

`install.sh` deliberately writes no keybinding: one written at install time makes
any later change of the default key a migration. Paste into your fish config:

```fish
bind alt-enter __recite_submit
```

**zsh** needs one line more, because zsh has no autoload for a line-editor widget.
Paste both into `~/.zshrc`:

```sh
eval "$(recite init zsh)"
bindkey '^[^M' __recite_submit
```

`^[^M` is `alt-enter`. Neither line names a path, so both are the same whether
you installed with Homebrew or `install.sh` — the two channels that put `recite`
on your `PATH`, which is what the widget needs. fisher is a fish plugin manager
and installs nothing for zsh. `recite init zsh` prints the widget on stdout and
touches nothing else; read it first if you like. The zsh widget expands no
abbreviations, because zsh has no built-in abbreviation to expand — so what you
typed is what runs, and the header is exact for free.

Ghostty leaves `alt-enter` alone, and fzf.fish owns `alt-c`, not this. **Your shell
does not leave it alone**: in both shells `alt-enter` inserts a newline, which is
how you build a multi-line command. In fish it is not even a binding — fish 4
handles it inside the reader, so `bind` never lists it and `bind --erase alt-enter`
is what restores it; in zsh it is `self-insert-unmeta`, which `bindkey -r '^[^M'`
restores. The recite binding costs you that keystroke but keeps the half that
matters. On a line the shell cannot yet parse, the binding inserts the newline
itself rather than submit a fragment. So `for`, `if` and an unclosed quote still
work. What you lose is adding a second *complete* line. `shift-enter` may cover
that, depending on whether your terminal sends a sequence distinct from `enter`.

**On macOS the keystroke can fail to arrive**, in three unrelated ways, and the fix
for one does nothing for the others. Measured per terminal:

| Terminal | `alt-enter` | What it needs |
|---|---|---|
| Ghostty 1.3.1 | arrives | nothing |
| iTerm2 3.6.11 | arrives in fish; in zsh nothing arrives at all | zsh only: Settings → Profiles → Keys → General → *Left option key* → `Esc+` |
| Terminal.app 2.15 | arrives as a bare `enter` | Settings → Profiles → Keyboard → "Use Option as Meta Key" |
| WezTerm 20240203 | never leaves the terminal | it is Toggle Full Screen — rebind it, or `{ key = 'Enter', mods = 'ALT', action = wezterm.action.DisableDefaultAssignment }` |

Terminal.app composes Option into a character, so the shell is handed a plain
`enter` and the binding never runs; that is what `macos-option-as-alt` and its
equivalents are for, and Ghostty needs no such setting here because Option+Enter
composes no character to begin with. WezTerm gets the modifier right and then
keeps the keystroke for itself. iTerm2 sends zsh no bytes at all, by a route fish
does not use — so it is the one row that depends on your shell, and the only one
where the binding can look broken while nothing reaches it. Older versions of any
of them may differ.

The suffix form works everywhere, with no configuration and no binding.

Three things to expect from it.

**What runs is not what you typed.** The binding wraps your line in a block —
`begin`/`end` in fish, `{ }` in zsh — and appends the pipe, so pressing the key
turns one line into three and echoes those before the output. Nothing is wrong.
The wrapper is what keeps a trailing `#`, `;` or `&` from colliding with the
suffix, and a newline is the only separator a `#` cannot comment out. How far the
middle lines indent depends on your prompt.

**In fish, `set -l` does not survive the command.** It is local to that block;
`set` and `set -g` do. zsh's `{ }` is a plain group rather than a scope, so a zsh
assignment survives either way.

**A command that redirects its own stdout** (`cmd > file`) copies a block with no
output in it. The output went to the file, and recite only sees what reaches the
pipe.

## Options

| | |
|---|---|
| `--as '<cmd>'` | The `$ command` header to use, for the hand-typed form |
| `--no-redact` | Skip credential redaction |
| `--version` | One row per component: version or backend, then its path |
| `recite init zsh` | Print the zsh widget on stdout, for `eval` in `~/.zshrc` |
| `RECITE_MAX_LINES` | Line cap, default `1000` |
| `RECITE_MAX_BYTES` | Byte cap, default `102400` |
| `RECITE_BACKEND` | `auto` (default), `pbcopy` or `osc52` — force one backend |

Over either cap the block ends with `[Output truncated: N lines omitted]`.
Truncation is always a suffix — the block never loses lines from the middle.

The fence grows past three backticks whenever the output carries a fence of its
own. So Markdown or a quoted snippet still pastes as one block, and does not end
early where the content's fence is.

**Export the two caps.** `recite-core` is a separate process, so an unexported
variable never reaches it — and in fish that is the default:

```fish
set -x RECITE_MAX_LINES 50    # works
set RECITE_MAX_LINES 50       # silently does nothing
```

```sh
export RECITE_MAX_LINES=50    # zsh, and any POSIX shell
```

`--version` never touches the clipboard, whatever is piped in.

## Over ssh, and inside tmux

With no `pbcopy` to reach — on a remote host, or anywhere the local one is the
wrong machine — recite writes the block to the **terminal's** clipboard with an
OSC 52 escape. The text lands on the computer whose keyboard you are typing on,
not on the host the command ran on.

Nothing acknowledges an OSC 52 write. That is why the message changes:

```console
$ ls | recite --as 'ls'
recite: copied (pbcopy)
$ ssh host
host$ ls | recite --as 'ls'
recite: sent (osc52)
```

`sent` means the bytes were emitted and no terminal answers for them. `copied`
means a backend confirmed the write. To ask before you paste rather than after,
`recite --version` names the backend on its clip row.

**Inside tmux, add one line to `~/.tmux.conf`:**

```tmux
set -g set-clipboard on
```

tmux forwards the sequence to the outer terminal *and* keeps a tmux buffer, so
the text pastes on both sides. At the default `external` it forwards nothing an
application inside it writes, and the paste comes up empty. tmux also has to
believe the outer terminal can take a clipboard write: the `Ms` capability, which
its own `terminal-features` grants to any `xterm*` TERM even when the terminfo
entry lacks it.

**On a remote macOS host**, the chain finds that machine's own `pbcopy` first
and the text lands there — on a screen you are not looking at. Force the
terminal route:

```sh
export RECITE_BACKEND=osc52
```

A forced backend never silently falls back. If it is unavailable, recite exits
`4` and names it, rather than writing somewhere else.

Exit codes: `0` ok · `2` usage · `3` binary input refused · `4` no clipboard
backend — no clipboard tool, and no terminal to write the sequence to · `129`
hung up · `130` interrupted · `143` terminated. On any of the last three the
unredacted capture is deleted and the clipboard is left as it was.

## Redaction is on by default

The paste target is Slack and GitHub, which is exactly where a credential becomes
an incident. Credentials of these shapes become `[REDACTED]` before the text
reaches the clipboard: `sk-…`, `gh[pousr]_…`, `github_pat_…`, `xox[a-z]-…`,
`xapp-…`, `AKIA…`/`ASIA…` and JWTs. So do Stripe keys (`sk_live_…`, `rk_test_…`),
Google `AIza…`, GitLab `glpat-…`, npm `npm_…` and Slack webhook URLs
(`hooks.slack.com/services/…`). The terminal still shows the real output.

**A credential embedded in a URL goes too**, whatever it looks like:
`https://alice:s3cr3t@github.com/o/r.git` copies as
`https://alice:[REDACTED]@github.com/o/r.git`. Only the password is replaced.
A bare `https://alice@github.com/o/r.git` is left alone — a user with no
password is not a credential.

**The body of a PEM private key goes too.** Every line between `-----BEGIN …
PRIVATE KEY-----` and `-----END … PRIVATE KEY-----` becomes `[REDACTED]`, one for
one. Both marker lines survive, so the paste still says what was removed.

**The `$ command` header is redacted too.** With the binding it is your command
line verbatim, so without that pass `curl -H "Authorization: Bearer sk-…"` would
be the one part of the block that leaks. Over-redacting is the safe direction of
error, and `--no-redact` is the escape hatch.

**The list is not exhaustive**, and one gap is worth knowing before you trust a
paste to it. Generic `NAME=value` secrets of the kind `env` and `cat .env` print
survive, because which names are secret is a judgment call rather than a pattern.
Redaction narrows what a slip costs. It does not replace reading what you pasted.

## Known limits

Documented behavior, not bugs.

- **No exit code.** In `cmd | recite`, `recite` is downstream and structurally
  cannot see `cmd`'s status. No shell hook can capture a command's stdout either,
  so this is not a missing feature — it is the shape of the problem.
- **Piping changes the output.** `brew list` prints multi-column to a tty and
  one-per-line to a pipe.
- **`2>&1` does not preserve interleaving.** A piped stdout is block-buffered
  while stderr stays unbuffered, so stderr jumps ahead.
- **History pollution.** `↑` recalls the wrapped form. Replay works.
- **Binary input is refused**, not supported — and a refusal leaves the clipboard
  untouched.
- **An OSC 52 write cannot be acknowledged.** No terminal replies to one, so
  recite reports `sent`, not `copied`. If the paste comes up empty, the terminal
  refused or ignored the sequence and nothing could have said so.
- **Inside tmux it needs one setting.** `set -g set-clipboard on`; the default
  `external` drops the write. The outer terminal must be one tmux grants `Ms`,
  which any `xterm*` TERM is by default.
- Interactive and TUI commands are out of scope under capture.

Out of scope by design: session recording, and images or SVG — the recorders and
screenshot tools own that.

## License

MIT — see [`LICENSE`](LICENSE).
