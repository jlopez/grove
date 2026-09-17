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
   The match is the **shared matcher** (issue #18; also used by `grove rm`): **title
   first** — grove sets `--name <branch>` at create, so `title == branch`, and it's
   **scoped to the repo group's members** (cross-reference `workspace-group list --json`
   member refs against `workspace list --json` titles), so a same-named branch in another
   repo's group never false-matches. On a title miss, the **env fallback**: sweep the
   group's members' stamped `GROVE_WORKTREE_PATH` (see [Workspace identity](#workspace-identity--the-grove_-env-stamp))
   against the branch's worktree path — which the gate resolves first, read-only, from
   `wt list` — so a manually-renamed tab no longer defeats the gate. Both missing (or no
   worktree yet) → nothing attached → proceed. No group yet → same.
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
4. **Sync the untracked paths** (`sync.paths`) — copy the configured gitignored files/dirs
   from the main checkout into the worktree, *before* the workspace exists so the agent's
   first command already sees them. See
   [Synced untracked paths](#synced-untracked-paths--syncpaths) below.
5. **Spawn the workspace** — `cmux workspace create --cwd <wt> --command <launch> --json`.
   cmux *types* the launch line into the new pty, whose canonical-mode input buffer caps a
   line at ~1KB — so the prompt never rides the line itself (issue #26). A non-empty prompt
   is written to a private `mktemp` file outside the worktree (kept clean for `wt remove`),
   and the typed line reads and immediately reclaims it:
   `p=$(cat -- <file>) && rm -f -- <file> && claude "$p"` — short and length-invariant, and
   the agent still receives the prompt as a single initial-prompt arg. Empty prompt → bare
   agent launch. The create also **stamps grove's identity into the workspace env**
   (`--env GROVE_WORKTREE_PATH/GROVE_REPO_PATH/GROVE_VERSION`, issue #18) — create time is
   the only chance, cmux has no post-hoc env setter; see
   [Workspace identity](#workspace-identity--the-grove_-env-stamp).
6. **File it under the repo group** — add to the existing group, or create it on first
   use with the **main checkout as the anchor/header**.
7. **Adopt orphans** (issue #23) — closing a group's anchor tab *dissolves* the group
   but its member workspaces survive **ungrouped**, and recreating the group only
   attaches the new spawn (the matchers are deliberately group-scoped). So once the
   group is ensured, sweep `workspace list --json` for workspaces in **no** group whose
   `current_directory` canonicalizes (`pwd -P`, like the guards) to one of **this
   repo's** linked worktrees per `wt list` — main checkout excluded (that's the
   header's job) — and `workspace-group add` each. Conservative and idempotent:
   a workspace in *any* group is never touched, other repos' paths never match, and
   any failure (listings, vanished dirs) degrades to adopting nothing — so group
   dissolution is self-healing on the next `grove go`.

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
branch (the same shared matcher that powers the `grove go` gate). So `grove rm`:

1. **Resolve the target branch** — the argument, or the current worktree's branch if omitted
   (mirroring `wt remove`'s "current" default), so `grove rm` from inside the worktree you're
   finished with just works.
2. **Primary-checkout guard** — refuse if the branch resolves to the repo's main checkout (the
   group's anchor/header); canonicalized-path compare, as `grove go` does. Removing a *member*
   leaves the group intact — only closing the **anchor** dissolves it — so teardown never
   collapses the sidebar group out from under your other worktrees. This path guard only covers
   grove's own invariant (anchor = main-checkout header); the **anchor guard** in step 6 covers
   groups where that invariant doesn't hold (issue #22).
3. **Synced-path guard** (`sync.paths`) — refuse the teardown while any synced untracked path
   differs from the main checkout, reporting per path *what* differs (keys and lengths, never
   values; `--unmask` for the real diff). This is the half of
   the feature that can't live in worktrunk: `.env` is gitignored, so `wt remove`'s dirty-tree
   refusal is structurally blind to it, and deleting the worktree would take an edited secret
   with it silently. See [Synced untracked paths](#synced-untracked-paths--syncpaths).
4. **Refresh the merge baseline** — fetch just `origin/<default>` (the teardown mirror of
   issue #14's freshness-by-default). `wt`'s merged-branch checks compare against
   `origin/<default>` *as last fetched*, so run right after `gh pr merge -sd` a stale ref would
   make the just-squash-merged branch look unmerged and leak it. `--no-fetch` opts out; a
   failed fetch warns and proceeds (worst case the branch is kept, never lost).
5. **Remove the worktree** — delegate to `wt remove <branch> -y`, which is **safe by default**:
   it *"Remove[s the] worktree; delete[s the] branch if merged"*, and **refuses a dirty
   worktree** without `-f`. This runs **before** the tab is closed (step 6): `grove rm` is meant
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
6. **Close the cmux workspace** attached to the branch — the **shared matcher**
   (`grove_workspace_for`, issue #18; the same one behind the `grove go` gate) finds the ref,
   then `cmux workspace close <ref>`. Title match first; on a miss, the env fallback keyed on
   the stamped `GROVE_WORKTREE_PATH`, compared against the worktree path **canonicalized
   before step 5 deleted the directory**. That covers the motivating incident: a branch
   renamed after `grove go` keeps its creation-title tab *and* its original worktree dir name
   (wt doesn't move it), so the title misses but the path stamp still hits — the tab is
   closed instead of left orphaned. Done **last**, so closing `grove`'s own tab can't abort
   the removal above. Both title and stamp missing (legacy/unstamped tab) → no ref, skipped
   (fails safe).

   **Anchor guard (issue #22).** In a *legacy or UI-created* group the anchor can be any member
   tab — not the repo header — and closing it would dissolve the group and orphan every other
   member (the cmux contract above). So before the close, grove compares the target ref against
   the group's `anchor_workspace_ref` (from the `workspace-group list --json` already fetched
   for the match). If the target **is** the anchor, `grove_reanchor_group` first moves the
   anchor to the repo-header workspace at the main checkout, restoring grove's invariant:
   it reuses a group member whose `current_directory` is the main checkout
   (`grove_member_at_cwd`, skipping the close target), or — mirroring how `grove go` anchors a
   fresh group — creates the header workspace (`workspace create --cwd <main-checkout> --name
   <repo>`) and files it under the group, then runs `workspace-group set-anchor` and
   **verifies** via a fresh listing that the anchor actually moved. Only then is the tab
   closed. If any of that fails, `grove rm` refuses to close the tab (warn, not die — the
   worktree is already removed) rather than dissolve the group; the warning names the manual
   fix (`cmux workspace-group set-anchor`).

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
| `workspace env <ref> --json` | `{count, env: {KEY: VALUE, …}, window_ref, workspace_ref}` | `.env.GROVE_WORKTREE_PATH`, for the shared matcher's env fallback (issue #18) |
| `workspace close <ref>` | — | — (`grove rm` closes the branch's tab; closing a *member* keeps the group) |
| `workspace-group add --group <ref> --workspace <ref>` | — | — |
| `workspace-group set-color <g> --hex #RRGGBB` / `set-icon <g> --symbol <sf>` | — | — (styling; see below) |

`workspace create` flags: `--cwd`, `--name`, `--command` (types text + Enter into the new
shell), `--env KEY=VALUE`, `--env-file`, `--json`, `--focus`.

### Workspace identity — the `GROVE_*` env stamp

Every workspace `grove go` **creates** is stamped with per-workspace env
(`workspace create --env`, issue #18). Env persists in cmux's session manifest — it
survives app restart, daemon restart, and session restore — but is **create-time only**:
cmux has no post-hoc env setter, so workspaces grove *reused or adopted* (and legacy or
UI-created tabs) can never be backfilled.

| Var | Value |
|---|---|
| `GROVE_WORKTREE_PATH` | canonicalized (`pwd -P`) worktree path — the authoritative match key |
| `GROVE_REPO_PATH` | canonicalized main-checkout path |
| `GROVE_VERSION` | grove version that created the workspace (provenance) |

Every shell in the tab inherits these, so they're also usable by user scripts and hooks.

**Why the path, not the branch:** the motivating incident was a branch renamed after
`grove go` — the tab kept its creation title, so `grove rm`'s title match missed and the
tab was left orphaned pointing at a deleted worktree. The worktree *path* survives a
branch rename (wt keeps the original dir name), so the durable key is the path; a
`GROVE_BRANCH` stamp would be a creation-time copy of a mutable fact — the same staleness
class as the title bug. Other rejected alternatives: caller-supplied workspace IDs (cmux
mints its own UUIDs), `--description` (human-facing and user-editable — not machine
storage), an external ref-map file (violates the self-contained convention).

**The shared matcher** (`grove_workspace_for` — `grove go`'s attach gate and `grove rm`'s
close-target lookup):

1. **Title match first** (pure, zero extra calls) — under the attach-gate invariant a
   title hit is always correct.
2. **On miss: env sweep** — cmux intentionally omits env from `workspace list` (secrets
   policy), so grove runs one `workspace env <ref> --json` per member of the repo's group
   (few) and matches `.env.GROVE_WORKTREE_PATH` against the canonical worktree path — for
   `grove rm`, canonicalized *before* `wt remove` deletes the dir. Fine on a miss path,
   never for hot loops.
3. **Both missing: fail-safe no-op** (today's behavior) — permanently covers unstamped
   workspaces (legacy, UI-created, reused/adopted).

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
array, `printf %q`-quoting each token into the command cmux types; the prompt itself travels
via a read-and-reclaimed temp file, not the typed line (issue #26). `grove
doctor` resolves the same `agent.command` to decide which binary to probe, instead of a
hardcoded `claude`.

**Third consumer:** `sync.paths` (below) — the first pure-array key, read with
`grove_config_get_array`. Worth noting what the merge semantics mean for it: jq's `*`
**replaces** arrays, so a `sync.paths` in `.grove.local.json` *supersedes* the committed one
rather than appending to it. That's uniform with every other key (last layer wins) and needs
no special case; the cost is that a personal extra path means restating the shared list. A
concat-for-this-one-key exception was considered and rejected — an inconsistent merge rule is
worse to reason about than a restated array.

## Synced untracked paths — `sync.paths`

Some files every worktree needs are exactly the ones git refuses to carry: `.env`,
`.env.local`, `.claude/settings.local.json`. A fresh worktree starts without them, and the
agent's first command fails on a missing secret. `sync.paths` is an **allow-list** of
repo-relative gitignored paths that `grove go` copies from the main checkout into the new
worktree (step 4), and that `grove rm` diffs against the main checkout before teardown
(step 3).

**Why not worktrunk.** worktrunk already ships `wt step copy-ignored` and `pre-start` hooks,
and either could do the *copy*. Neither fits:

- `copy-ignored` is a **deny-list, all-or-nothing** sweep of everything gitignored — you'd
  have to enumerate `node_modules/`, `.venv/`, `dist/`, `target/`… as exclusions to get the
  three files you actually wanted. The allow-list is the different (and much smaller) ask.
- Neither knows anything at **`wt remove` time**. The guard is the point of the feature, and
  worktrunk has nowhere to hang it. grove owns both `go` and `rm`, so the pair stays
  symmetric here.

The one thing this design *can't* do that a `pre-start` hook can: run **before** worktrunk's
own hooks. grove copies after `wt switch` returns, so a `post-start` hook that itself needs
`.env` (docker, mise) must still be handled inside worktrunk. That's the honest boundary.

### Copy side (`grove_sync_copy`)

Three rules, each a deliberate failure-mode choice:

- **Never overwrite an existing destination.** The worktree's own copy always wins. This is
  what makes the reuse case (`grove go` on an existing worktree, flow step 2) safe — it fills
  gaps instead of clobbering a deliberately-diverged `.env` — without branching on how the
  worktree came to exist.
- **Sync only gitignored paths.** The disqualifier is *anything git would notice*: a tracked
  file is already carried by git, and an untracked-but-not-ignored one would land in the
  worktree as an untracked file — and a dirty worktree makes `wt remove` refuse, so a
  convenience quietly becomes a teardown blocker. `git check-ignore -q` is the real gate;
  `git ls-files -- <path>` runs first only to diagnose the tracked case separately (it also
  answers correctly for directories, listing any tracked file underneath).
- **Symlinks are copied as symlinks, not dereferenced.** `cp -Rp` preserves the link, which is
  the right call: a symlinked `.env` is a deliberate "one shared file" setup, and materializing
  a second copy would defeat it *and* start blocking `grove rm` once the copy diverged. The
  guard reporting "in sync" is likewise correct — the content lives outside the worktree, so
  removal destroys a link, not data. The one real failure is a *relative* link, which resolves
  against a different depth in the worktree and can land dangling; that's warned about after the
  copy.
- **Nothing here is fatal.** An absent source (a fresh clone has no `.env`), an unsafe entry
  (absolute or `..`-escaping), a failed `cp` — each warns and continues. A half-synced worktree
  still beats no worktree; the agent's error message about the missing file is clearer than
  grove refusing to spawn.

### Which roots the path list comes from

The layers don't all live in the same place, so no single root resolves them all.
`.grove.json` is committed — branch-scoped, rightly read from the worktree you're in.
`.grove.local.json` is **gitignored**, so it can only exist where it was written (normally
the main checkout) and is simply *absent* from a fresh worktree. Rooting at the worktree
drops every personal path; rooting at the main checkout drops paths a branch just added.

So `grove_sync_resolve_paths` takes the **union** across roots — the invoking worktree, the
worktree being torn down (for `rm`), and the main checkout — rather than choosing one. The
two errors aren't symmetric: an extra candidate costs one `git diff` and is skipped when it
isn't present in the destination, while a missing one means `grove rm` deletes a secret it
never knew to check. **The guard is monotone in candidates, deliberately.**

This is not hypothetical: `grove sync add --local .env` writes a gitignored file that exists
only in the main checkout, so any worktree-rooted read would resolve to *nothing* and
silently disable the guard for precisely the workflow the command exists to support.

### Guard side (`grove_sync_check`)

**Stateless by design.** The alternative — hash each file at copy time and compare at removal
— needs somewhere to keep the hashes: inside the worktree dirties it, outside it (`~/.local/
state/…`) adds a lifecycle to manage and leaks on every manual `wt remove`. And it answers the
narrower question. Comparing against the **main checkout** needs no state at all, and its one
"false positive" — main rotated its `.env` after the copy — is information you want before
deleting the only other copy.

Divergence is reported per path so the decision ("I don't care about that one line") can be
made without leaving the terminal — and **masked by default** (issue #37): `sync.paths` exist
to carry secrets, so a diff of them *is* the secrets, printed into a terminal that may be
screen-shared, logged, or — as happened the night #35 merged — read into a Claude transcript,
which cost two token rotations. The default report says what differs, never what it is:

```
grove: sync: .env differs from the main checkout (values masked — --unmask shows them):
    PORT: differs (main 4 chars, worktree 4 chars)
    EXTRA: only in worktree
    DEEPINFRA_API_KEY: empty in main, worktree 32 chars ('grove sync' fills it)
```

Three shapes, chosen per pair. Two **dotenv** files get one line per key — the shape the
`grove sync` conflict report already used — and the placeholder case names its remedy. A
**directory** is walked per entry (`only in main` / `only in worktree`, recursing into entries
that differ), the same per-entry view `grove sync` takes of it. Anything else gets the
stripped diff with every `-`/`+` line replaced by its byte length (`- [21 bytes]`) and the
**context lines dropped** — a neighbour both sides agree on is still a secret; the `@@`
headers stay, as the only thing left to act on. `--unmask` (on `grove sync check` and
`grove rm`) prints the real colored `git diff --no-index` instead:

```
grove: sync: .env differs from the main checkout (- main, + worktree):
@@ -1,3 +1,4 @@
 API_KEY=abc
-PORT=3000
+PORT=3001
+EXTRA=yes
```

Masking is a *display* decision layered over an unchanged verdict; nothing below this
paragraph changes with it. Why not mask `grove sync list` too: it never printed content.

**Divergence is decided by git's exit status, never by whether a diff printed.** This is the
single most important line in the feature. `git diff --no-index` reports a difference while
printing *nothing* in at least three reachable cases: a file↔directory type change (exit 1,
zero bytes), an unreadable file (exit 128, zero bytes), and a `.gitattributes` `diff=` driver
that redacts both sides to identical text. A guard that inferred "same" from empty output
would hand each of those to `wt remove`. `grove_sync_differs` returns 0/1/2 (same / differs /
**could not compare**), and 2 fails closed with its own message — "I couldn't tell" must never
render as "they match". `--no-textconv` for the same reason: a redacting diff driver must not
be able to blind the guard protecting the file. `grove_sync_check` and `grove_sync_list` share
that one function, so the two commands cannot disagree about the same file. One correction
found while fixing #37: git reports an **unreadable** side as a plain difference (exit 1), not
as an error, so "differs" was what `--force` would have acted on; `grove_sync_differs` now asks
the filesystem for readability first and returns 2 itself.

The unmasked rendering is separate from the verdict, and only runs once divergence is already
decided. git's file headers are stripped — they carry absolute paths and the line above already names
the file — and so is the **function context** git appends to every `@@` hunk header: the
nearest preceding line that looks like a definition, which in a `.env` is *the line above the
change*, i.e. a neighbouring secret pasted verbatim onto a header that gets quoted into
summaries and chat. Line numbers stay, the rest goes. The stripping is done by matching each
line against a **color-stripped copy** of itself in `awk`, so the printed line keeps its ANSI
attributes. Three cases get special handling: a **directory**
`sync.path` spans many files, so there the `+++` line is rewritten to a short relative label
instead of dropped (anonymous hunks are useless to act on); a **mode-only** change produces a
diff with no hunks at all, so `old mode`/`new mode` become `mode changed 100644 -> 100755`
rather than an empty body; and **binary** files collapse to `binary files differ` instead of
leaking the absolute paths the stripping exists to hide. `awk` runs under `LC_ALL=C`, because
a file git judged textual can still carry bytes that abort a locale-aware `awk` mid-stream.
Output is capped at 40 lines per path, counted **after** stripping so the "truncated" notice
is honest.

A path present in the worktree but **absent from the main checkout** is divergence too: there
is nothing to fall back on, so it's the case with the most to lose. The inverse (present in
main, gone from the worktree) is not — nothing disappears.

**One exception to "bytes decide": two dotenv files with the same keys and the same values.**
That is exactly what the key merge below leaves behind — it appends to each file in place, so
the two never become byte-identical again, only comment- and order-different. The guard's
question is "does a secret live on one side only", and the answer there is no, so
`grove_sync_differs` reports them as the same. What this knowingly gives up is a *comment*
that exists only in the worktree (a commented-out alternate value, say): `grove rm` will no
longer stop for it. The alternative was worse — a guard that blocks forever after every merge
teaches people to reach for `--force`, which costs far more than a comment.

`--force` doesn't silence the finding, it downgrades it to a one-line warning per path. The
removal really is discarding content that exists nowhere else; that deserves a line in the
scrollback even when it was the intent. `--force --unmask` shows the full diff and removes:
asking to see the values is the stronger signal, so it wins over quiet mode.

### Both directions (`grove_sync_exchange`) — issue #34

The copy side above has one built-in assumption: **the main checkout is the origin of every
synced path.** It isn't. A path is naturally *born* on the branch that introduces it — run
`grove sync add 260916-book-club/.env` from a feature worktree, where the file already exists,
and the old one-way copy printed `absent from the main checkout (skipped)` and did nothing;
`grove rm` on that worktree then demanded `--force`, because the guard (rightly) saw a secret
that existed nowhere else. The feature contradicted itself.

So bare `grove sync` fills the gap **in whichever direction it finds it**, with the
never-overwrite rule untouched — only *which side may be the source* changed:

- missing in the worktree → copied from the main checkout (what it always did);
- missing in the main checkout → seeded from the worktree
  (`seeded the main checkout from this worktree: <path>`);
- a **directory** `sync.path` is resolved **per entry**, so it behaves like a bag of files:
  each entry can be gap-filled on its own side rather than the whole tree being all-or-nothing;
- `grove sync add` runs the same gap-fill for the added paths immediately, so the case that
  motivated the issue is one command, not add-then-sync.

The disqualifiers are checked on **both** roots now: `check-ignore` because the *receiving*
side is the one that would be left dirty (and the two sides are on different branches, so
their `.gitignore`s can differ), and `ls-files` because a path git tracks on the receiving
side but that is missing from its working tree reads as a gap, and filling it would silently
resurrect a file git is managing.

`grove go` deliberately stays one-way. At spawn the worktree is new, and a reused one is not
the moment to start writing into the main checkout behind the user's back; `grove sync` is the
command you type when you mean it.

**No `grove sync push` verb.** "Present on one side, absent on the other" has exactly one safe
resolution, so a second word would only be one more thing to remember before getting the one
outcome available.

### dotenv key merge

Gap-filling leaves the case where **both sides exist and differ**, which one-way copy never had
to answer. For a `.env` the honest answer is usually *neither side is wrong*: it's a set of
keys, and two checkouts that each added their own key have a union, not a conflict. So when
both sides parse as dotenv, grove merges the key sets — keys present on one side only are
**appended verbatim** to the other, carrying the author's own quoting and `export` prefix, and
each file keeps its own order and comments. Nothing already written is ever rewritten.

The parse is deliberately strict: every line must be blank, a `#` comment, or
`[export ]KEY=VALUE`. A multi-line quoted value, JSON, a symlink (a deliberate "one shared
file" setup — never ours to rewrite), or any byte of NUL takes the file out of scope entirely,
and it falls back to the old behaviour: warn, point at `grove sync check`. The merge is a
convenience for a shape it recognizes, never a guess about a file it doesn't.

Values are compared **normalized** — surrounding whitespace dropped, one layer of matching
quotes stripped, an unquoted trailing ` # comment` dropped (bash and python-dotenv semantics;
`a#b` stays `a#b`) — because `KEY=foo`, `KEY="foo"`, `KEY='foo'` and `KEY=foo # prod` are the
same value, and quoting style is precisely the difference two hands introduce independently.

**An empty placeholder is not a value** (issue #36). `.env.example` ships `DEEPINFRA_API_KEY=`,
the main checkout inherits the empty line, the real key gets pasted into whichever checkout
needed it first — and the first `grove sync` after #35 called that `differs (main 0 chars,
worktree 32 chars)` and refused. Empty (`KEY=`, `KEY=""`, `KEY=''`, `KEY= # paste here`) on
one side and set on the other is the placeholder being **filled**, in either direction: the
empty side's line is replaced **in place** by the other side's — same position, the comment
above it kept, a placeholder written `export KEY=` keeps its `export`, a CRLF line stays CRLF.
This is the one exception to "nothing already written is rewritten", and it is a narrow one:
the line being replaced carries no information. Empty on both sides is nothing to fill and no
conflict. The report names the keys that were filled, never the value that travelled.

A key both sides define with genuinely different **non-empty** values is a **conflict**: that
path is left untouched on both sides — not even the fills are written, a half-merged `.env` is
worse than an unmerged one — and `grove sync` exits **1**, after processing every other path,
because a conflict in one secret must not strand the other four.

**A conflict report names keys and prints no values.** Not the conflicting ones, and not — via
a diff's context lines — the neighbours that agree. `KEY: differs (main 9 chars, worktree 3
chars)` is enough to tell "mine is the long one" from a typo and to go reconcile it by hand,
and a `grove sync` that someone runs on a screen-shared or logged terminal should not be the
thing that sprays a `.env` across it. The full diff is still one command away
(`grove sync check --unmask`), which is the right shape: seeing secrets should be an explicit
choice, not a side effect of syncing — or, since #37, of checking.

### `grove sync` — the verb

Both halves above only ever fire at `go`/`rm` time, which leaves a gap the lifecycle can't
close: you add `.env` to the main checkout *after* spawning five agents, and the attach gate
(flow step 1) rightly refuses to re-run `grove go` for any of them. So the machinery is also
exposed directly:

```
grove sync                    # fill the gaps both ways; merge dotenv keys (exit 1 on conflict)
grove sync check [--unmask]   # compare vs the main checkout (rm's step 3); exit 1 if any differ
grove sync list               # each path's config + worktree state
grove sync add [--local] <p>… # edit .grove.json / .grove.local.json
grove sync rm  [--local] <p>…
```

**Subcommands, not flags.** `add`/`rm` take variadic positionals, and a flag that swallows
positionals is the wrong shape; once those are subcommands, a `--list` alongside them would be
the worst of both. Bare `grove sync` is the verb (the `git stash` precedent: bare = the common
action, named = the rest). `copy` is the internal name for the bare form.

`copy` and `check` refuse to run **in the main checkout** — both need a worktree distinct from
it, and with nothing on the other side there is neither a gap to fill nor a diff to take. `check`'s exit status is the point of it: it
composes into scripts and pre-remove hooks.

**The setter is the thin part**, and deliberately so. Unlike `restyle`, whose reason to exist
is *applying* style to cmux (writing `.grove.json` is a convenience bolted on), `sync.paths`
has no apply step — so `add`/`rm` ride along on a command that earns its place anyway.
Two things they do that hand-editing wouldn't:

- **`add` validates.** A **tracked** path is refused outright — unambiguously a mistake, git
  already carries it (checked on both roots: a branch may have committed it). Not-gitignored,
  or existing in *neither* checkout, only *warn* and still write: you may be about to add the
  `.gitignore` line or create the file. Silently accepting either would
  just defer the confusion to the next `grove go`.
- **The write direction matters.** `--local` seeds from the *effective* (merged) list, because
  jq's `*` replaces arrays and a local layer holding only the new path would silently supersede
  the committed one. The committed file seeds from **its own** list instead — seeding it from
  the merged one would run the layering backwards, promoting personal (`.grove.local.json`) and
  machine-wide (XDG) paths into the file everyone shares.
- **A write that can't take effect says so.** Writing a lower-precedence layer is a no-op when a
  higher one replaces the whole array; after the write, the effective list is re-derived and any
  path that didn't move is reported. An `rm` that silently leaves a path synced is the dangerous
  direction.
- **A malformed target file is never overwritten.** `grove_config_load` only *skips* an
  unparseable layer; writing one would discard every other key in it (`color`, `icon`, `agent`).
  The write refuses instead.
- **`--local` carries the effective list forward.** jq's `*` **replaces** arrays (see
  [Merge](#merge--nearly-free)), so a `.grove.local.json` holding only the newly added path
  would silently supersede the committed list. Writing the merged result is the only shape
  that means what it looks like. Emptying the list deletes the key rather than leaving `[]`.

`grove sync list` and `grove doctor`'s "Synced paths" section are the **same renderer**
(`grove_sync_list`), with one distinction worth keeping: a *misconfigured* path (unsafe,
tracked, not ignored) fails the doctor, while mere *divergence* doesn't — that's a state,
not a config error, and it's what `grove sync check` is for.

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
