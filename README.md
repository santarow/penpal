# Penpal

A Mac app that helps you write to Claude. Made by SantaRow.

**Download:** https://www.santarow.com/penpal/ (signed and notarized, macOS 14 or later)

## What it does

- **Highlight:** hold ⌃⌥ and draw on the screen. The picture goes into Claude's message box.
- **Snippets:** lenses you type as `;name` that expand into instructions, like "explain it simply".
- **Dock:** a small panel pinned next to the Claude app, with search, new chat and a new window.
- **Guide me:** say what you want to do in an app. Penpal rings the next thing to click, one step at a time.
- **Enhance:** turns a rough ask, and its pictures, into a clear prompt before you send it.
- **Claude History:** every Claude Code session on this Mac, searchable, with resume and fork.
- **Usage:** your plan's limits and tokens over time.

## It runs on your own Claude

Penpal has no server and no account. Guide me and Enhance run the `claude` command (Claude Code) on
your Mac, on the account Claude Code is signed in to, and ignore API keys and API servers set in your
Mac's environment (`ANTHROPIC_*`). If Claude Code is signed in to a Console (API) account, or has an API
key in its own settings, that's what it uses.

You need:

- macOS 14 or later
- [Claude Code](https://code.claude.com/docs/en/overview), signed in (for Guide me, Enhance, History and Usage)
- Python 3 (comes with Apple's command line tools)

On first launch Penpal asks for Accessibility (to paste and to ring buttons) and Screen Recording (for
Highlight and Guide me).

## Build it yourself

You need Swift 6 from Apple's command line tools (`xcode-select --install`) or Xcode. Penpal is built
with Swift 6.4; older Swift 6 versions are untested.

```sh
app/scripts/build-app.sh          # app/build/Penpal Dev.app
open "app/build/Penpal Dev.app"
```

`app/scripts/install.sh` builds it and puts it in /Applications. The build signs with your Apple
Development certificate if you have one, else ad hoc (then macOS asks for Accessibility again after each
build). Set `KITE_SIGN_IDENTITY` to pick another.

A dev build reads its agents, lenses and engine from this folder. `RELEASE=1 app/scripts/build-app.sh`
puts them inside the app instead; `app/scripts/release.sh` makes a notarized .dmg, and needs a Developer
ID certificate and a notary profile.

## What's where

| Path | What |
|---|---|
| `app/Sources/Kite/` | the app (SwiftUI and AppKit) |
| `bin/kite` | the engine: starts `claude -p` for each run and reads your Claude Code history (`bin/penpal` inside the app) |
| `agents/` | Guide me and Enhance: each a `persona.md` (its instructions) and `agent.json` (model, tools) |
| `lenses/` | the snippets Penpal starts with |
| `data/claude-code.json` | Claude Code's commands and keys, for the Commands list |

Runs are plain files in `~/.kite/agents/<agent>/runs/`. Penpal's own settings live in
`~/.kite/apps/penpal/`, and its log in `~/Library/Logs/Penpal/`.

## License

Apache 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
