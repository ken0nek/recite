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

## Status: M0

fish + macOS. No zsh, no bash, no OSC 52, no Linux clipboard, no Windows.

## Use

Press **`alt-enter`** instead of `enter`, once you have added
[the binding](#the-keybinding-is-yours-to-add) — recite ships none. Nothing is
prefixed and nothing is wrapped, so completions, autosuggestions, abbreviations,
highlighting and line editing are untouched.

Or append the suffix by hand, which needs no keybinding:

```fish
brew list --installed-on-request 2>&1 | recite
```

Both print to the terminal as normal and put the block on the clipboard.

Prefer the binding: it reads the command line *before* it appends, so the command
string is exact. The suffix path recovers it from history and **emits no
`$ command` header at all** unless the history line ends in a recite suffix.

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

`install.sh` symlinks `recite-core` and `recite-clip` into `~/.local/bin` and the
fish functions into `~/.config/fish/functions`. It is idempotent, and it replaces
only symlinks that already point into its own checkout — anything else prints
`CONFLICT` and is left alone. `RECITE_BINDIR` and `RECITE_FISHDIR` override the
destinations. `--uninstall` removes exactly what it created.

It also runs from `curl`, in the form that lets you read it first:

```sh
curl -fsSL https://raw.githubusercontent.com/ken0nek/recite/main/install.sh -o install.sh
less install.sh && sh install.sh
```

**That audits `install.sh` only.** Outside a checkout it downloads a release
tarball and puts `recite-core` — the half that reads your command output — on
your `PATH`, unseen. The fetch is pinned to a release tag, not `main`. Clone to
read everything before anything runs. There are three pieces, and the middle one
is the whole of it:

```
recite            fish function   resolves the command string, tees, delegates
  └── recite-core   POSIX sh+awk  stdin -> formatted block on stdout
        └── recite-clip  POSIX sh  stdin -> clipboard
```

**Do not install two channels.** Both write into `~/.config/fish/functions`, and
`install.sh` prints `CONFLICT` rather than overwrite what it does not own — the
loud case. The quiet one is the tap. That directory precedes Homebrew's
on `$fish_function_path`, so a fisher copy shadows a Homebrew one. `brew upgrade`
then has no visible effect, and nothing warns you.
`recite --version` names the function file that is actually live.

### The keybinding is yours to add

`install.sh` deliberately writes no keybinding: one written at install time makes
any later change of the default key a migration. Paste into your fish config:

```fish
bind alt-enter __recite_submit
```

Ghostty leaves `alt-enter` alone, and fzf.fish owns `alt-c`, not this. **fish does
not leave it alone**: `alt-enter` inserts a newline, which is how you build a
multi-line command. It is not a binding — fish 4 handles it inside the reader, so
`bind` never lists it and `bind --erase alt-enter` is what restores it. The recite
binding costs you that keystroke but keeps the half that matters. On a line fish
cannot yet parse, the binding inserts the newline itself rather than submit a
fragment. So `for`, `if` and an unclosed quote still work. What you lose is adding
a second *complete* line. `shift-enter` may cover that, depending on whether your
terminal sends a sequence distinct from `enter`.

**On macOS the keystroke can fail to arrive**, because Option is composed as a
character by default. Ghostty needs `macos-option-as-alt`. Terminal.app has "Use
Option as Meta Key" **off**. iTerm2 sets it per profile. The suffix form works
regardless.

Two things to expect from it. The binding runs your line inside a `begin`/`end`
block. So `set -l` typed at the prompt is local to that block and does not
survive the command — `set` and `set -g` do. And a command that redirects its own
stdout (`cmd > file`) copies a block with no output in it. The output went to the
file, and recite only sees what reaches the pipe.

## Options

| | |
|---|---|
| `--no-redact` | Skip credential redaction |
| `--version` | Version, the live function file, the resolved executables |
| `RECITE_MAX_LINES` | Line cap, default `1000` |
| `RECITE_MAX_BYTES` | Byte cap, default `102400` |

Over either cap the block ends with `[Output truncated: N lines omitted]`.
Truncation is always a suffix — the block never loses lines from the middle.

The fence grows past three backticks whenever the output carries a fence of its
own. So Markdown or a quoted snippet still pastes as one block, and does not end
early where the content's fence is.

**Export the two caps.** `recite-core` is a separate process, and fish's `set`
does not export:

```fish
set -x RECITE_MAX_LINES 50    # works
set RECITE_MAX_LINES 50       # silently does nothing
```

`--version` also answers to `-v`, because fish's `argparse` derives a short flag
from every long option. Spelled in full it never touches the clipboard. As `-v`
with something piped in, it reports to stderr and still copies, so
`cmd | recite -v` cannot cost you the output.

Exit codes: `0` ok · `2` usage · `3` binary input refused · `4` no clipboard
backend · `130` interrupted.

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
- Interactive and TUI commands are out of scope under capture.

Out of scope by design: session recording, and images or SVG — the recorders and
screenshot tools own that.

## License

MIT — see [`LICENSE`](LICENSE).
