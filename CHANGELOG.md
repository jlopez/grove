# Changelog

All notable changes to grove are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[SemVer](https://semver.org/).

## [Unreleased]

### Added
- **`sync.paths` — untracked files carried into worktrees, and guarded on the way
  out.** A new config key (any layer) names repo-relative gitignored paths —
  `{ "sync": { "paths": [".env", ".env.local"] } }` — that every worktree needs but
  git never carries. `grove go` copies them from the main checkout into the new
  worktree before the workspace is created, so the agent's first command already
  sees them. An existing file in the worktree is **never overwritten** (a reused
  worktree keeps its own), and only **gitignored** paths are synced — a tracked path
  is already carried by git, and copying an untracked-but-not-ignored one would
  leave the worktree dirty and make `wt remove` refuse. Absent sources and unsafe
  entries warn and are skipped, never fatal.

  The other half is teardown: `.env` lives only on disk, so git can't preserve it
  and `wt remove`'s dirty-tree refusal is structurally blind to it (it's
  gitignored, therefore never "dirty"). So `grove rm` now diffs each synced path
  against the main checkout **before** removing anything and refuses if any
  differs, printing a **colored `git diff`** per path — enough to judge "I don't
  care about that line" and re-run with `--force`, which removes anyway but keeps
  a one-line warning per diverged path. The check is deliberately stateless: it
  compares against the main checkout rather than a hash recorded at copy time, so
  there's no state file to manage and a rotated `.env` in main also surfaces.
  Deliberately *not* `wt step copy-ignored` (a deny-list that would drag
  `node_modules/`), and worktrunk has nowhere to hang the rm-side guard.
  `grove doctor` lists the configured paths, flagging any absent from the main
  checkout, already tracked, or not gitignored.

### Fixed
- `grove go` now delivers the prompt to the agent **via a temp file** instead of
  inlining it in the typed launch command (issue #26). cmux *types* the launch
  line into the new workspace's pty, whose canonical-mode input buffer caps a
  line at ~1KB — so long prompts (routine for agent-generated briefs) were
  silently truncated and the launch lost. The prompt is written to a private
  `mktemp` file outside the worktree (which must stay clean for `wt remove`),
  and the typed line reads and immediately reclaims it
  (`p=$(cat -- <file>) && rm -f -- <file> && claude "$p"`), staying short and
  length-invariant regardless of prompt size. The file path is used whenever a
  prompt is present — one code path, no length threshold; an empty prompt keeps
  the bare-agent launch, and `GROVE_COMMAND=echo` still prints the prompt for
  safe testing.
- `grove rm` no longer dissolves a cmux group whose **anchor** is the tab being
  closed (issue #22). The primary-checkout guard assumed the anchor is always
  the repo-header workspace at the main checkout — true for grove-created
  groups, but a legacy or UI-created group can be anchored on any member tab,
  and closing the anchor dissolves the group and orphans its members (cmux
  contract). `grove rm` now compares the close target against the group's
  `anchor_workspace_ref` and, on a match, first **re-anchors** the group to the
  repo header at the main checkout — reusing a member workspace already there,
  or creating the header as `grove go` does — and verifies the anchor actually
  moved before closing. If re-anchoring fails, it refuses to close the tab
  (with a clear warning) rather than dissolve the group.

### Added
- `grove go` now **stamps grove's identity into each workspace it creates** via
  per-workspace env (issue #18): `GROVE_WORKTREE_PATH` (canonicalized worktree
  path — the durable match key), `GROVE_REPO_PATH`, and `GROVE_VERSION`, all
  inherited by every shell in the tab (usable by user scripts/hooks). The
  workspace matcher shared by the `grove go` attach gate and `grove rm`'s
  close-target lookup is now **title-first with an env fallback**: a title hit
  costs nothing extra, and on a miss grove sweeps the repo group's members'
  stamped `GROVE_WORKTREE_PATH` (one `cmux workspace env` call each — cmux
  omits env from `workspace list`). This fixes the orphaned-tab incident where
  a branch renamed after `grove go` defeated the title match — the tab keeps
  its creation title but the worktree *path* survives the rename (wt keeps the
  original dir name), so `grove rm` now still finds and closes the tab, and the
  attach gate still refuses a duplicate for a manually-renamed tab. Both
  missing → today's fail-safe behavior, which permanently covers unstamped
  workspaces (legacy, UI-created, or reused/adopted — env is create-time only,
  cmux has no post-hoc setter).
- `grove go` now **adopts orphaned workspaces** after a group dissolution (issue #23).
  Closing a group's anchor tab dissolves the group but leaves its member workspaces
  alive and ungrouped, and recreating the group only attached the newly spawned
  workspace — stranding the survivors. Once the repo group is ensured, `grove go`
  sweeps for workspaces in *no* group whose directory canonicalizes to one of this
  repo's linked worktrees (main checkout excluded) and re-attaches them. Conservative
  and idempotent: workspaces already in any group are never touched, and other repos'
  workspaces never match — so the next `grove go` self-heals the sidebar.
- `grove rm [--force] [-D] [--keep-branch] [--reap] [--no-fetch] [<branch>]` — the
  inverse of `grove go`: tear down a worktree you're done with. grove owns the
  workspace↔branch bridge nobody else knows, so it closes the cmux tab that
  `wt remove`/`wt merge` would otherwise strand, then delegates the git side to
  `wt remove -y`. It defaults to the current worktree's branch and guards the
  primary checkout (never dissolves the group). It **removes the worktree first,
  then closes the tab** — so running it from inside the worktree's own tab can't
  kill grove before the removal runs. Safe by default via `wt`: it refuses a dirty
  tree without `--force` and deletes the branch only when merged — squash-aware
  (wt's six-condition check), with `origin/<default>` fetched first so a branch
  squash-merged moments ago already counts as merged (`--no-fetch` opts out). An
  unmerged branch is kept, never deleted, unless `-D`/`--force-delete`
  (`--keep-branch` maps to `wt remove --no-delete-branch`; `--reap` kills stray
  processes in the worktree; `-y` skips only worktrunk's hook-approval prompts,
  matching `grove go`).
- `grove go <branch> [prompt...]` — create a worktree and spawn a cmux workspace
  running Claude on the prompt, filed under the repo's sidebar group.
- `grove go` now branches **brand-new** worktrees from a freshly fetched
  `origin/<default>` instead of the stale local default (issue #14). It detects the
  default branch from `origin/HEAD` (no network), fetches just that one ref, and hands
  `wt --base origin/<default>` — so agents start from current code and PRs don't need
  rebasing. Two new flags (grove go's first flag parsing): `--base <ref>` overrides the
  base (e.g. `@` for current HEAD, or the local default when you have unpushed commits),
  and `--no-fetch` stays offline. Materialize/reuse of existing branches is untouched
  (they have history → no base to choose), and every failure (no `origin/HEAD`, fetch
  failure) degrades gracefully to the local default rather than hard-failing.
- `grove go` now **resolves-or-creates** the worktree instead of always running
  `wt switch -c` (which dead-ended on a branch/worktree that already existed,
  issue #2). Two orthogonal guards run first: a **fail-fast cmux gate** stops with
  a clear message if a workspace in the repo's group is already attached to the
  branch (keyed on workspace title, scoped to the group), and a **primary-checkout
  guard** refuses to spawn into the group header (the repo's main checkout). The
  worktree itself is then reused if present, materialized if the branch exists, or
  created otherwise — so revisiting a branch reopens it rather than failing.
- Layered config store — a single resolver all of grove reads through. Four layers,
  low → high: `${XDG_CONFIG_HOME:-~/.config}/grove/config.json` (machine-wide),
  `<repo-root>/.grove.json` (committed), `<repo-root>/.grove.local.json` (gitignored,
  personal), and an optional per-keypath `ENV_VAR`. Files deep-merge with jq's `*`
  (last layer wins per key, arrays included); missing files are skipped and an invalid
  layer is warned about and skipped. Group color/icon now resolve through the store, so
  they can be set in any layer. `grove init` gitignores `.grove.local.json` when run
  inside a repo.
- Per-repo group color/icon. Each repo's cmux group gets a deterministic, contrast-
  safe OKLCH color (hashed from the repo name) for at-a-glance scanning. Override via
  a `<repo-root>/.grove.json` (`{ "color"?, "icon"? }`) read from the worktree you run
  grove in — so it's committable on your branch. `color` accepts `#RRGGBB`, `"auto"`,
  or `"inherit"` (clear); `icon` is an SF Symbol, and both attributes fully reconcile
  (removing a key reverts grove's imperative state for it). Style is re-applied on every
  `grove go` (so it survives cmux group recreation), or on demand with `grove restyle` —
  which also accepts `--color #RRGGBB|auto|random|inherit` and `--icon <symbol>|none` to
  write `.grove.json` for you (`--color random` stamps a random palette color). grove
  sets color/icon via cmux's imperative API and never writes `cmux.json`; `byCwd` stays
  yours for umbrellas.
- Configurable agent invocation through the config store. `agent.command` (the
  executable, default `claude`) and `agent.args` (an array of argv tokens passed
  before the prompt) are read from any config layer; `grove go` quotes each token
  with `printf %q`. `grove doctor` checks the resolved command rather than a
  hardcoded `claude`.
- `grove init [--with-multi-account]` — optional wiring: cmux Claude plugin,
  `wt go` alias, and an opt-in direnv multi-account hook.
- `grove doctor` — dependency and wiring check.
- Homebrew formula and `curl | sh` installer.
