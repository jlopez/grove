# Changelog

All notable changes to grove are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[SemVer](https://semver.org/).

## [Unreleased]

### Added
- `grove rm [--force] [--keep-branch] [--reap] [<branch>]` — the inverse of
  `grove go`: tear down a worktree you're done with. grove owns the workspace↔branch
  bridge nobody else knows, so it closes the cmux tab that `wt remove`/`wt merge`
  would otherwise strand, then delegates the git side to `wt remove`. It defaults to
  the current worktree's branch, guards the primary checkout (never dissolves the
  group), and closes the tab *before* removing the worktree so no shell is left
  cwd'd in a vanishing directory. Safe by default via `wt`: it refuses a dirty tree
  without `--force` and deletes the branch only when merged (`--keep-branch` maps to
  `wt remove --no-delete-branch`; `--reap` kills stray processes in the worktree).
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
