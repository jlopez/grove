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
| `workspace-group list --json` | `{groups: [{ref, name, anchor_workspace_ref, member_workspace_refs}]}` | `.groups[] | select(.name==…) | .ref` |
| `workspace-group add --group <ref> --workspace <ref>` | — | — |

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
  only** (color/icon/placement), matched on a group's **anchor cwd**, longest match wins.
  ⚠️ Keys **must be absolute paths** — `~` is expanded only for glob keys (containing
  `*`/`?`), not plain prefix keys. `cmux reload-config` live-reloads without restart.

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
- Per-repo group color/icon, `grove rm` teardown, graceful handling of existing branches.

See the [issue tracker](https://github.com/jlopez/grove/issues) for the live backlog.
