# grove 🌳

**Spawn parallel Claude Code agents in git worktrees, grouped in your [cmux](https://cmux.dev) sidebar.**

`grove` is a thin glue layer over [worktrunk](https://worktrunk.dev) (`wt`) + cmux + [Claude Code](https://claude.com/claude-code). One command creates an isolated worktree and opens a cmux workspace running Claude on a prompt — filed under the repository's collapsible sidebar group, so a dozen parallel agents stay organized.

```sh
grove go fix/login-flow please fix the login redirect bug
```

→ creates the `fix/login-flow` worktree, opens a cmux tab running `claude "please fix the login redirect bug"`, and files it under the repo's group (whose header is your main checkout).

<!-- TODO: screenshot of the cmux sidebar: a repo group with worktree agents -->

## Why

Running many AI agents in parallel means many worktrees. Existing tools either bury worktrees in a hidden directory (breaking per-directory env like multi-account `gh`) or give you no cockpit to see which agent is working vs. waiting. grove leans on three focused tools instead:

- **worktrunk** owns worktree lifecycle (create, list, merge, remove) and agent-activity markers.
- **cmux** is the sidebar cockpit — a two-level **Repository → Worktrees** tree, with a native per-tab "working / waiting" indicator and `gh` PR status.
- **Claude Code** is the agent.

grove wires them together and gets out of the way.

## Install

### Homebrew

```sh
brew install jlopez/tap/grove   # (tap published with the first release)
grove init
```

### curl

```sh
curl -fsSL https://raw.githubusercontent.com/jlopez/grove/main/install.sh | sh
grove init
```

This drops `grove` into `~/.local/bin`. Then `grove init` wires the optional bits (see below).

## Usage

```
grove go <branch> [prompt...]        Create a worktree + spawn a cmux Claude agent
grove rm [--force] [--keep-branch] [--reap] [<branch>]
                                     Done with a feature: remove the worktree +
                                     close its cmux tab (defaults to current branch)
grove init [--with-multi-account]    Optional wiring (wt alias, cmux plugin, direnv)
grove doctor                         Check dependencies and wiring
grove version
```

Run `grove go` from inside a cmux tab — it spawns the new workspace into the same window.

### `grove init` (optional)

`grove go` works on its own. `init` adds conveniences:

- installs the cmux Claude Code plugin (activity markers for `wt list`),
- adds a `wt go` alias so you can type `wt go <branch> <prompt>`,
- with `--with-multi-account`, adds a worktrunk hook that gives each worktree the **same `gh` account as your main checkout** (see below).

### Config

grove reads a small layered config, low → high precedence: `~/.config/grove/config.json`
(machine-wide) → `<repo>/.grove.json` (committed) → `<repo>/.grove.local.json` (gitignored,
personal). Files deep-merge, last layer wins per key. This drives the per-repo group
**color/icon** (`{ "color"?, "icon"? }` — `color` is `#RRGGBB`, `"auto"`, or `"inherit"`;
`icon` is an SF Symbol); `grove restyle` can write `.grove.json` for you. It also drives the
**agent** grove launches (`{ "agent": { "command"?, "args"? } }` — `command` defaults to
`claude`, `args` is an array of argv tokens passed before the prompt). `grove init`
gitignores `.grove.local.json`.

### Multi-account `gh` in worktrees

If you use [direnv](https://direnv.net) to switch `gh` accounts per directory (e.g. `export GH_CONFIG_DIR=…`), worktrees created outside those directories lose the account. `grove init --with-multi-account` installs a worktrunk `pre-start` hook that asks the **main checkout's** direnv what it resolves and writes a matching `.envrc` into each new worktree — no mapping tables, no drift. It's a no-op for repos that don't use direnv.

## Requirements

| Tool | Required | Install |
|------|----------|---------|
| [worktrunk](https://worktrunk.dev) (`wt`) | ✅ | `brew install worktrunk` |
| [cmux](https://cmux.dev) | ✅ | install cmux.app |
| `jq` | ✅ | `brew install jq` |
| [Claude Code](https://claude.com/claude-code) | ✅ | `claude` on PATH |
| [direnv](https://direnv.net) | optional | `brew install direnv` (multi-account) |

`grove doctor` checks all of these.

## How it works

`grove go <branch> <prompt>`:

1. `wt switch -c <branch>` — creates the worktree (firing any worktrunk hooks).
2. reads the new worktree path from `wt list --format json`.
3. `cmux workspace create --cwd <worktree> --command 'claude "<prompt>"'`.
4. files the workspace under the repo's group via `cmux workspace-group add`, creating the group (anchor = main checkout) on first use.

cmux is reachable because grove runs from a cmux tab and inherits `CMUX_*` env, so the new workspace lands in the right window.

### Env

- `GROVE_COMMAND` — command to launch instead of `claude` (overrides `agent.command`; handy for testing, e.g. `GROVE_COMMAND=echo`).
- `GROVE_CMUX` — path to the cmux CLI (default: auto-detect).

## License

MIT © Jesus Lopez
