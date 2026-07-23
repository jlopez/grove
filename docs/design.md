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

1. **Fail-fast cmux gate** (before touching git) — if a workspace in this repo's group
   is already attached to `<branch>`, stop with a clear message. Two orthogonal axes
   drive `grove go`: **cmux** (is a workspace attached?) and **git** (does the branch/
   worktree exist?); they're independent, so the gate is checked first and on its own.
   The match keys on the workspace **`title`** (grove sets `--name <branch>` at create,
   so `title == branch`) and is **scoped to the repo group's members** — cross-reference
   `workspace-group list --json` member refs against `workspace list --json` titles — so
   a same-named branch in another repo's group never false-matches. No group yet → nothing
   attached → proceed. *Limitation:* a manual right-click Rename mutates the title and
   defeats the match (fails safe — you get the error, never a silent duplicate); the real
   fix is a grove-owned workspace→branch map (issue #18).
2. **Resolve-or-create the worktree** — by branch/worktree existence:
   worktree exists (`wt list --format json` has a path) → **reuse** it, no `wt switch`;
   branch exists (`git show-ref --verify refs/heads/<branch>`) but no worktree →
   `wt switch <branch>` to **materialize** it; neither → `wt switch -c <branch>` to
   **create** both. `wt switch` fires any worktrunk `pre-start` hooks (e.g. the optional
   multi-account hook below). Plain `wt switch -c` without grove stays agent-less.
   For the **create-both** case grove first picks a **fresh base** (issue #14):
   `wt switch -c` would branch from the *local* default, which goes stale after a
   squash-merge the local default never pulled. So grove detects the default branch
   from `origin/HEAD` (no network), `git fetch origin <def>`es that one ref, and hands
   `wt --base origin/<def>` — wt's earliest hook runs *after* the worktree exists, too
   late to choose a base, so grove owns the fetch. `--base <ref>` overrides the base
   (e.g. `@` = current HEAD) and `--no-fetch` stays offline; every failure (no
   `origin/HEAD`, fetch failure) degrades gracefully to the local default rather than
   hard-failing. Materialize/reuse have existing history → no base to choose, untouched.
   *Reuse intentionally skips `wt switch`*, so `pre-start` hooks don't re-run on an
   existing worktree — they're creation-time, and grove-created worktrees already ran
   them. (A worktree created by plain `wt switch` before grove existed, then reopened,
   won't retroactively get hook-written files like `.envrc`.)
3. **Primary-checkout guard** — if the resolved path is the repo's main checkout (the
   group's anchor/header), stop: grove targets *linked* worktrees, not the header. Paths
   are canonicalized before comparison. Often redundant with `wt switch`'s own refusal,
   but a clean message beats a raw `wt` error.
4. **Spawn the workspace** — `cmux workspace create --cwd <wt> --command 'claude "<prompt>"' --json`.
   The prompt is shell-quoted so the agent receives it as a single initial-prompt arg.
5. **File it under the repo group** — add to the existing group, or create it on first
   use with the **main checkout as the anchor/header**.

### Why cmux is drivable from a hook/alias

`cmux workspace create` targets "the caller's window," resolved from `CMUX_WORKSPACE_ID`.
Those `CMUX_*` env vars (`CMUX_WORKSPACE_ID`, `CMUX_SOCKET_PATH`, …) are present in every
shell inside a cmux workspace, and subprocesses inherit them — so a command run from a
cmux tab can drive cmux back into the same window. Run `grove go` from a cmux tab.

## The `grove rm` flow

`grove rm [<branch>]` is the **inverse of `grove go`** — the teardown for when you're done
with a feature. It exists because grove owns a bridge nobody else does: the
**workspace↔branch mapping**. `wt remove` and `wt merge` both know how to drop the *worktree*,
but they leave the *cmux tab* dangling — only grove knows which tab is attached to which
branch (the same title-match that powers the `grove go` gate). So `grove rm`:

1. **Resolve the target branch** — the argument, or the current worktree's branch if omitted
   (mirroring `wt remove`'s "current" default), so `grove rm` from inside the worktree you're
   finished with just works.
2. **Primary-checkout guard** — refuse if the branch resolves to the repo's main checkout (the
   group's anchor/header); canonicalized-path compare, as `grove go` does. Removing a *member*
   leaves the group intact — only closing the **anchor** dissolves it — so teardown never
   collapses the sidebar group out from under your other worktrees.
3. **Refresh the merge baseline** — fetch just `origin/<default>` (the teardown mirror of
   issue #14's freshness-by-default). `wt`'s merged-branch checks compare against
   `origin/<default>` *as last fetched*, so run right after `gh pr merge -sd` a stale ref would
   make the just-squash-merged branch look unmerged and leak it. `--no-fetch` opts out; a
   failed fetch warns and proceeds (worst case the branch is kept, never lost).
4. **Remove the worktree** — delegate to `wt remove <branch> -y`, which is **safe by default**:
   it *"Remove[s the] worktree; delete[s the] branch if merged"*, and **refuses a dirty
   worktree** without `-f`. This runs **before** the tab is closed (step 4): `grove rm` is meant
   to be run from inside the worktree's *own* tab, and closing that tab first could kill `grove`
   before `wt remove` ran — the inverse of the command's purpose. wt renames the worktree out and
   deletes the branch synchronously (only the final `rm -rf` is detached — *"Removal runs in the
   background by default"*), so the call returns once the outcome (success or a dirty-tree
   refusal) is known. `-y` skips worktrunk's **hook-approval** prompts — as `grove go` does on
   `wt switch` — so a repo with `pre-remove` hooks doesn't hang non-interactively (it does *not*
   bypass the dirty-tree refusal, which is a hard `--force` gate, not a prompt). grove forwards
   `--force` → `wt --force` (also needed for the untracked-`.envrc` wrinkle above),
   `-D`/`--force-delete` → `wt --force-delete` (delete a genuinely unmerged branch — also
   needed when a squash merge falls outside `wt`'s capped history walk),
   `--keep-branch` → `wt --no-delete-branch`, and `--reap` → `wt --reap` (kill stray dev
   servers/watchers under the worktree before removal). No worktree for the branch → nothing to
   remove.
5. **Close the cmux workspace** attached to the branch — `grove_attached_workspace_ref` returns
   the ref (the pure matcher whose boolean face powers the `grove go` gate), then `cmux
   workspace close <ref>`. Done **last**, so closing `grove`'s own tab can't abort the removal
   above. A missing or manually-renamed tab yields no ref and is skipped (fails safe).

**Safety model (ratifying issue #15).** #15 proposed a GitHub-PR-state merge guard
(`gh pr view --json state`) because a naive `git branch --merged` reports squash-merged
branches as unmerged forever. That guard is consciously **superseded**: `wt`'s branch cleanup
runs six merged-checks — same-commit, ancestor, three-dot diff, tree match, **simulated
merge**, and **patch-id** — that are already squash-aware, need no network or `gh`, and cover
branches that never had a PR. And where #15 said *refuse* removal of an unmerged branch, `wt`'s
model is **proceed-but-preserve**: the worktree is removed and the tab closed, but the branch —
and every commit on it — is kept unless `-D`. Nothing committed is ever destroyed, and
`grove go <branch>` re-materializes the worktree from the kept branch (the issue #2 flow), so
an early `grove rm` fully recomposes. The only hard gates are the dirty-tree refusal
(`--force`) and unmerged-branch deletion (`-D`).

Because the safety lives in `wt` (dirty-tree refusal, merged-only branch deletion) and `-y`
suppresses only *approval* prompts, `grove rm` needs no confirmation prompt of its own — it
stays as non-interactive as `grove go`. For the **merged-and-done** case, `wt merge`
(squash→rebase→ff→remove) and `grove rm` compose: merge with `wt`, then `grove rm` closes the
now-orphaned tab (and no-ops the already-gone worktree).

## cmux CLI contract (reverse-engineered)

The cmux binary lives at `/Applications/cmux.app/Contents/Resources/bin/cmux` (grove
auto-detects it; override with `GROVE_CMUX`). Relevant JSON shapes:

| Command | Returns | grove reads |
|---|---|---|
| `workspace create … --json` | `{surface_ref, window_ref, workspace_ref}` | `.workspace_ref` |
| `workspace-group create … --json` | `{group: {ref, anchor_workspace_ref, member_workspace_refs, …}}` | `.group.ref` |
| `workspace-group list --json` | `{groups: [{ref, name, anchor_workspace_ref, member_workspace_refs, custom_color, icon_symbol}]}` | `.groups[] | select(.name==…) | .ref` |
| `workspace list --json` | `{window_ref, workspaces: [{ref, title, custom_title, current_directory, …}]}` | member `ref` → `title`, for the attach gate (below) and `grove rm`'s close target |
| `workspace close <ref>` | — | — (`grove rm` closes the branch's tab; closing a *member* keeps the group) |
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

- **Source of truth: the layered config store** (`color`/`icon` keys; see
  [Configuration](#configuration--the-layered-store) below) — both optional, parsed with `jq`
  (never sourced — no code execution from a cloned repo). In practice you set them in
  `<repo-root>/.grove.json`, but any layer works. Read from the
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

## Configuration — the layered store

All of grove reads config through one resolver (`grove_config_load` / `grove_config_get`
/ `grove_config_get_array` in `bin/grove`), rather than each feature doing its own `jq`.
Four layers, **low → high precedence**:

1. `${XDG_CONFIG_HOME:-~/.config}/grove/config.json` — machine-wide defaults.
2. `<repo-root>/.grove.json` — committed, repo-shared (repo identity: color/icon, and
   any shared agent defaults).
3. `<repo-root>/.grove.local.json` — gitignored, personal per-repo overrides.
4. a per-keypath **`ENV_VAR`** — applied at read time, **only** where a call site opts in.

The repo-local files (2, 3) are read from the **root of the worktree grove is invoked in**
(`git rev-parse --show-toplevel`) — the same rationale as the styling file before it: a
worktree-local file is committable on your branch and takes effect immediately, instead of
dirtying the main checkout. The `.grove.json` / `.grove.local.json` split mirrors the
familiar `settings.json` / `settings.local.json` convention. `grove init` appends
`.grove.local.json` to the repo's `.gitignore` when run inside a repo.

### Merge — nearly free

Files merge with a single jq deep-merge: `jq -s 'reduce .[] as $x ({}; . * $x)'`. jq's `*`
operator **recurses into objects** and **replaces arrays/scalars**, which is exactly
last-layer-wins *per key* (arrays included) — no custom merge code. Missing files are
skipped; a file that isn't valid JSON is warned about and skipped, so one bad layer never
breaks reads (matching the defensive style read it replaces). The merged blob is held in a
single in-memory string (`GROVE_CONFIG_JSON`); reads `jq` into it.

### Reading — env override per keypath, no central registry

`grove_config_get <keypath> [ENV_VAR]` returns the scalar at a dotted keypath (e.g. `color`,
`agent.command`). If `ENV_VAR` is passed **and** set to a non-empty value, it wins (highest
precedence); omitting it means no env fallback. So the env-override "registry" is
**distributed at call sites** — there is no central table to keep in sync. `grove_config_get_array
<keypath>` emits an array's elements one per line, for `mapfile -t`.

**First consumer:** group color/icon. `grove_resolve_style` reads `color`/`icon` through the
store (replacing its bespoke per-file `jq`), so styling now resolves across all layers — e.g.
a machine-wide default color in the XDG layer, a committed team color in `.grove.json`, a
personal tweak in `.grove.local.json`. This proves the abstraction with a real second reader.

**Second consumer:** the launched agent. `grove go` reads `agent.command` (the executable,
default `claude`, with `GROVE_COMMAND` as its per-keypath env override) and the `agent.args`
array, `printf %q`-quoting each token plus the prompt into the command cmux types. `grove
doctor` resolves the same `agent.command` to decide which binary to probe, instead of a
hardcoded `claude`.

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
- ~~Keeping the default branch fresh~~ — done at branch-creation time: new worktrees
  branch from a freshly fetched `origin/<default>` (issue #14), so there's no need to
  eagerly refresh the local default after every merge.
- ~~`grove rm` teardown, graceful handling of existing branches~~ — both done:
  `grove rm` (below) closes the cmux tab + `wt remove`s the worktree, and `grove go`
  resolves-or-creates existing branches (issue #2).

See the [issue tracker](https://github.com/jlopez/grove/issues) for the live backlog.
