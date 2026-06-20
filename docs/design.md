# grove — design & internals

How grove glues [worktrunk](https://worktrunk.dev) + [cmux](https://cmux.dev) +
[Claude Code](https://claude.com/claude-code), and what was learned reverse-engineering
the cmux and worktrunk CLIs. Useful for contributors and for understanding the
roadmap.

## Philosophy: three focused tools, thin glue

grove builds nothing that an existing tool already does well. The division of labor:

- **worktrunk (`wt`)** owns the worktree lifecycle — create, list, merge, remove —
  plus agent-activity markers and per-worktree hooks.
- **cmux** is the sidebar cockpit — an explicit two-level **Repository → Worktrees**
  tree, a native per-tab "working / waiting" indicator, and `gh` PR status.
- **Claude Code** is the agent.

grove is the ~250-line shell layer that wires them together so one command does the
whole dance.

## The `grove go` flow

`grove go <branch> <prompt>`:

1. **Create the worktree** — `wt switch -c <branch> --no-cd -y`. This fires any
   worktrunk `pre-start` hooks (e.g. the optional multi-account hook below). Plain
   `wt switch -c` without grove stays agent-less.
2. **Resolve the path** — `wt list --format json | jq '.[] | select(.branch==…) | .path'`.
3. **Spawn the workspace** — `cmux workspace create --cwd <wt> --command 'claude "<prompt>"' --json`.
   The prompt is shell-quoted so the agent receives it as a single initial-prompt arg.
4. **File it under the repo group** — add to the existing group, or create it on first
   use with the **main checkout as the anchor/header**.

### Why cmux is drivable from a hook/alias

`cmux workspace create` targets "the caller's window," resolved from `CMUX_WORKSPACE_ID`.
Those `CMUX_*` env vars (`CMUX_WORKSPACE_ID`, `CMUX_SOCKET_PATH`, …) are present in every
shell inside a cmux workspace, and subprocesses inherit them — so a command run from a
cmux tab can drive cmux back into the same window. Run `grove go` from a cmux tab.

## cmux CLI contract (reverse-engineered)

The cmux binary lives at `/Applications/cmux.app/Contents/Resources/bin/cmux` (grove
auto-detects it; override with `GROVE_CMUX`). Relevant JSON shapes:

| Command | Returns | grove reads |
|---|---|---|
| `workspace create … --json` | `{surface_ref, window_ref, workspace_ref}` | `.workspace_ref` |
| `workspace-group create … --json` | `{group: {ref, anchor_workspace_ref, member_workspace_refs, …}}` | `.group.ref` |
| `workspace-group list --json` | `{groups: [{ref, name, anchor_workspace_ref, member_workspace_refs, custom_color, icon_symbol}]}` | `.groups[] | select(.name==…) | .ref` |
| `workspace-group add --group <ref> --workspace <ref>` | — | — |
| `workspace-group set-color <g> --hex #RRGGBB` / `set-icon <g> --symbol <sf>` | — | — (styling; see below) |

`workspace create` flags: `--cwd`, `--name`, `--command` (types text + Enter into the new
shell), `--env KEY=VALUE`, `--env-file`, `--json`, `--focus`.

### Groups, anchors, styling

- **Groups are explicit and fully scriptable** — NOT auto-derived from directory.
  Managed via `cmux workspace-group {create,add,remove,new-workspace,set-color,set-icon,
  rename,collapse,expand,pin,ungroup,set-anchor,move,focus,list}`.
- **The anchor workspace IS the group header.** grove makes the **main checkout** the
  anchor (so worktrees nest under a stable repo header). `workspace-group create
  --name <repo> --cwd <main-checkout> --from <ws>` creates a fresh header anchor at
  `--cwd` and files `--from` as a member.
- **Closing the anchor dissolves the group but preserves members** (they become
  ungrouped). `workspace-group delete` is destructive — it closes every member. Use
  `ungroup` to keep them.
- **`workspaceGroups.byCwd`** in `~/.config/cmux/cmux.json` is **declarative styling
  only**, matched on a group's **anchor cwd**, longest match wins. Per-group keys
  (authoritative, from cmux's JSON schema): `color` (hex), `icon` (SF Symbol, default
  `folder.fill`), `contextMenu` (custom items on the group's `+` right-click menu), and
  `newWorkspacePlacement` (`afterCurrent`/`top`/`end`). ⚠️ Keys **must be absolute
  paths** — `~` is expanded only for glob keys (containing `*`/`?`), not plain prefix
  keys. `cmux reload-config` live-reloads without restart.

### Group styling — the two stores and their precedence

There are **two independent stores** for a group's color/icon, and grove relies on how
they layer (all reverse-engineered + verified empirically):

- **Imperative** — `cmux workspace-group set-color <g> --hex` / `set-icon <g> --symbol`.
  Persists to cmux's **session state** (`~/Library/Application Support/cmux/session-*.json`),
  on the group-header object keyed by `anchorWorkspaceId`. Surfaced in
  `workspace-group list --json` as `custom_color` / `icon_symbol`. Does **not** write
  `cmux.json`.
- **Declarative** — `byCwd` in `cmux.json` (above).
- **Precedence is per-attribute**: an imperatively-set attribute **wins**; `byCwd` fills
  in only the attributes left unset. (cmux's own schema says `byCwd.color` applies "when
  the group has no explicit customColor.") So imperative-red + `byCwd`-green/flame renders
  **red + flame**; adding an imperative icon makes it **red + bolt**.
- **Only `color` and `icon` are settable imperatively** — `contextMenu` and
  `newWorkspacePlacement` are `byCwd`-only. That boundary defines grove's lane: grove
  manages color/icon imperatively and never touches `cmux.json`; `byCwd` stays the user's
  for context menus, placement, and umbrella folders.
- **Durability:** imperative styling **survives a cmux restart** (session state restores
  the anchor's UUID) but is **lost when the group is recreated** — closing the anchor
  dissolves the group, and the next `grove go` mints a *new* anchor UUID, so the old
  style is orphaned (verified: recreated group comes back `custom_color: null`). grove
  closes this gap by re-applying style on every `go` (see below).

### Per-repo group styling — `.grove.json`

grove gives each repo's group a distinct, at-a-glance color (and optional icon) using the
imperative store, reconciled from a per-repo source of truth so it survives group
recreation:

- **Source of truth: `<repo-root>/.grove.json`** — `{ "color"?, "icon"? }`, both optional,
  parsed with `jq` (never sourced — no code execution from a cloned repo). Read from the
  **root of the worktree grove is invoked in** (`git rev-parse --show-toplevel`), *not* the
  main checkout. The group identity (name + anchor + the deterministic color) still keys off
  the main checkout (`REPO`/`REPO_PATH`); only the override *file* is worktree-local. This is
  deliberate: a main-checkout file can't be committed on your feature branch and dirties the
  main checkout when written, whereas a worktree-local file is committable, takes effect
  immediately, and matches how every other repo file (`.gitignore`, `package.json`) is read.
  The shared group could in principle flap if two live worktrees carry *different uncommitted*
  `.grove.json` — but it's a committed repo-identity file, so worktrees agree except while you
  are editing it, which is exactly when you want that branch's preview. Commit it to share a
  style; gitignore it to keep it personal/per-machine.
- **Value semantics, per attribute** — both fully reconcile (removing a key reverts grove's
  imperative state for it, so persistent styling lives in `.grove.json` or `byCwd`, never a
  manual `cmux set-color`):
  - `color`: `"#RRGGBB"` → explicit · **absent** (or `"auto"`) → **deterministic** ·
    `"inherit"` → grove **clears** its imperative color so a `byCwd` umbrella shows through.
  - `icon`: a symbol → explicit · **absent** → grove **clears** its imperative icon so the
    `byCwd`/`folder.fill` default shows. No *deterministic* icon — auto-icons are noise; a
    meaningful icon is the point — but absence still reconciles (it doesn't leave a stale one).
- **Deterministic color** = a baked **48-cell OKLCH palette** (24 hues × 2 contrast-safe
  lightness tiers, `L≈0.74/0.62 C≈0.13`), chosen offline so every color clears contrast on
  light *and* dark sidebars; the repo name is hashed to a cell. OKLCH (not HSL) so all
  cells share *perceived* contrast — varying hue in HSL would not. Collisions follow the
  birthday bound, but what matters is clashes among *simultaneously-visible* groups (few),
  and any clash is a one-line `.grove.json` override.
- **Reconcile, don't set-once:** every `grove go` re-applies the resolved style (both the
  create and the add path), so editing `.grove.json` takes effect on the next `go` and
  group recreation self-heals. **`grove restyle`** is the no-spawn equivalent (operates on
  the current repo's group); `grove restyle [--color #RRGGBB|auto|random|inherit]
  [--icon <symbol>|none]` writes this worktree's `.grove.json` then applies, so JSON editing
  is optional. `--color random` stamps a random palette hex (the picked color, never the word
  "random"); `--icon none` drops the icon key.

### The "reversal" insight — no directory moves needed

Group membership is assigned by **workspace ID**, so the main checkout and its worktrees
do **not** need a shared parent folder. The main checkout can stay wherever it is (keeping
any per-directory env intact), worktrees can live anywhere (e.g. a hidden
`~/.worktrunk/worktrees/<repo>/<branch>`), and they still share one sidebar group because
grove adds them explicitly.

## worktrunk integration

- **Worktree location** is a template: `worktree-path = "~/.worktrunk/worktrees/{{ repo }}/{{ branch | sanitize }}"`.
  grove doesn't require any particular value — it reads the actual path from `wt list`.
- **Hooks** (`pre-start`, `post-start`, `pre-merge`, …) get rich template vars
  (`{{ branch }}`, `{{ worktree_path }}`, `{{ primary_worktree_path }}`, `{{ repo }}`, …)
  and the full context as JSON on stdin. `pre-start` blocks; `post-start` runs in the
  background.
- **`wt list --format json`** is rich: branch, path, working-tree status, remote
  ahead/behind, repo owner/host; `--full` adds CI + diffstat + LLM summaries.

### Agent activity — worktrunk's marker vs cmux's native indicator

worktrunk's Claude Code plugin tracks agent state via session hooks, stored in **git
config**: `worktrunk.state.<branch>.marker = {"marker":"🤖"}` (working) / `{"marker":"💬"}`
(waiting/idle). Read it with `wt config state marker get --branch <b> --format json`.

In practice **cmux already shows a native per-workspace activity indicator** in the
sidebar, so the "working vs waiting" badge needs no extra work for the sidebar. The
worktrunk marker remains the right *programmatic* source for `wt list` and for a future
orchestrator.

## Multi-account `gh` in worktrees (optional)

A common pain point: people use [direnv](https://direnv.net) to switch `gh` accounts per
directory (`export GH_CONFIG_DIR=…`). Worktrees created outside those directories lose the
account, producing blank PR badges.

grove's optional hook (installed by `grove init --with-multi-account`) solves it without a
mapping table: it asks the **main checkout's** direnv what it resolves and writes a
matching `.envrc` into each new worktree.

```toml
[pre-start]
gh-account = """
ghdir=$(direnv exec {{ primary_worktree_path }} sh -c 'printf %s "$GH_CONFIG_DIR"')
if [ -n "$ghdir" ]; then
  printf 'export GH_CONFIG_DIR=%s\n' "$ghdir" > {{ worktree_path }}/.envrc
  direnv allow {{ worktree_path }}
fi
"""
```

Single source of truth (the main checkout), no drift, and a no-op for repos that don't use
direnv (empty `GH_CONFIG_DIR` → the guard skips). cmux polls `gh` in each tab's cwd, so the
generated `.envrc` gives every worktree the right account.

> Known wrinkle: the generated `.envrc` is untracked, so `wt remove` reports "uncommitted
> changes" and needs `--force` until `.envrc` is gitignored. See the issue tracker.

## Roadmap

- An orchestrator that takes a set of issues, sequences them by dependency across parallel
  worktrees, runs to completion, merges PRs, refreshes the default branch, and removes
  worktrees — interrupting only for blocking questions. Buildable on `wt` + the cmux CLI
  (`wt merge` already does squash→rebase→merge→remove→hooks).
- Keeping the default branch fresh (`pre-switch` fetch / `wt step prune`).
- `grove rm` teardown, graceful handling of existing branches.

See the [issue tracker](https://github.com/jlopez/grove/issues) for the live backlog.
