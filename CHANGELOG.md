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
- **`grove sync [list|check|add|rm]`** — the same machinery as a verb. Bare
  `grove sync` copies the missing paths into *this* worktree, covering the case
  `grove go` structurally can't: you add `.env` to the main checkout after
  spawning five agents, and the attach gate rightly refuses to re-run `grove go`
  for any of them. `check` runs `grove rm`'s guard on demand and **exits 1** on
  divergence, so it composes into scripts and hooks. `list` reports each path's
  config *and* worktree state (in sync / not copied yet / differs), and is the
  same renderer `grove doctor` uses. `add`/`rm [--local] <path>...` edit
  `.grove.json` (or `.grove.local.json`) so hand-editing a JSON array is
  optional, mirroring what `restyle --color` does for styling: `add` refuses a
  tracked path outright and warns-but-writes on one that isn't gitignored or
  doesn't exist yet, and `--local` **carries the effective list forward** rather
  than writing a one-element array that would silently supersede the committed
  one (jq's `*` replaces arrays).

### Fixed
- **`sync.paths` assumed the main checkout was the origin of every synced path**
  ([#34](https://github.com/jlopez/grove/issues/34)). A path is naturally *born*
  on the branch that introduces it, so `grove sync add 260916-book-club/.env`
  from a feature worktree printed `absent from the main checkout (skipped)`, did
  nothing, and left `grove rm` demanding `--force` — the guard rightly seeing a
  secret that existed nowhere else. Bare `grove sync` now fills the gap **in
  whichever direction it finds it**, with the never-overwrite rule intact: only
  which side may be the *source* changed. Seeding prints `seeded the main
  checkout from this worktree: <path>`, a directory `sync.path` is resolved per
  entry, and `grove sync add` runs the same gap-fill immediately so the case that
  motivated the issue is one command. The disqualifiers (`ls-files`,
  `check-ignore`) are now checked on **both** roots — the receiving side is the
  one that would be left dirty, and a path git tracks there must not be silently
  resurrected. `grove go` deliberately stays one-way.
- **A `.env` both sides have is merged by key, not reported as a wall of diff.**
  When both sides of a divergence parse as dotenv (blank / `#` comment /
  `[export ]KEY=VALUE`, CRLF tolerated), keys present on one side only are
  **appended verbatim** to the other — each file keeps its own order, comments
  and quoting, and nothing already written is rewritten. Values compare
  normalized, so `KEY=foo`, `KEY="foo"` and `KEY='foo'` are not a conflict. A key
  both sides define with genuinely different values *is*: that path is left
  untouched on both sides and `grove sync` exits **1** — after processing every
  other path — reporting `KEY: differs (main 9 chars, worktree 3 chars)`: the
  keys, **never the values**, so a sync on a screen-shared or logged terminal
  can't spray a `.env` across it. `grove sync check` still shows the full diff
  when you ask for it. Anything that
  isn't dotenv-shaped (multi-line values, JSON, a symlink, any NUL byte) keeps
  the old behaviour: warn and point at `grove sync check`. Consequently the
  teardown guard treats two dotenv files with the same keys and values as in
  sync, so `grove rm` passes after a merge; the knowing cost is a comment that
  exists only in the worktree no longer stopping the removal.
- **The sync diff leaked a neighbouring secret through the hunk header.** git
  appends "function context" to every `@@` line — the nearest preceding line that
  looks like a definition, which in a `.env` is *the line above the change*. So
  `grove sync check` (and `grove rm`'s refusal) printed
  `@@ -4,5 +4,5 @@ ABS_TOKEN=eyJhbGciOi…`, pasting an unrelated secret onto the
  one line most likely to be quoted into a summary or chat. Hunk headers now keep
  their line numbers and drop everything after the second `@@`.
- **The teardown guard decided divergence from whether a diff *printed*, not from
  git's exit status** — so `grove rm` deleted the worktree in three reachable
  cases where `git diff --no-index` reports a difference while emitting nothing:
  a file↔directory type change (exit 1, zero bytes), an unreadable file (exit
  128, zero bytes), and a `.gitattributes` `diff=` driver that redacts both sides
  to identical text. Comparison now goes through one `grove_sync_differs`
  returning same / differs / **could-not-compare**, with the last failing closed
  and `--no-textconv` so a redacting driver can't blind the guard protecting the
  file. `grove sync check` and `grove sync list` share that function and can no
  longer disagree about the same file.
- **`sync.paths` is resolved as the union across roots**, not from a single one.
  `.grove.local.json` is gitignored, so it exists only where it was written
  (normally the main checkout) and is absent from every fresh worktree — a
  worktree-rooted read resolved to *no paths at all*, silently disabling the
  guard for exactly the `grove sync add --local` workflow. `grove rm` now unions
  the invoking worktree, the worktree being torn down, and the main checkout.
  The guard is monotone in candidates by design: an extra one costs a `git diff`
  and is skipped when absent; a missing one loses a secret.
- **`grove sync add` no longer promotes personal paths into the committed file.**
  Seeding the write from the merged list ran the layering backwards, copying
  `.grove.local.json` and XDG entries into the shared `.grove.json`. Only
  `--local` seeds from the effective list (where array-replace semantics require
  it); the committed file seeds from its own.
- **`grove sync rm` reported success for a write that didn't take effect** when a
  higher-precedence layer still listed the path. The effective list is now
  re-derived after every write and any unmoved path is called out.
- **A malformed `.grove.json` was silently overwritten**, discarding `color`,
  `icon` and `agent` keys; the write now refuses. A wrong-typed `sync` key
  (`{"sync": "x"}`) crashed jq with a raw error instead of degrading to "nothing
  configured".
- Diff rendering fixes: a **directory** `sync.path` showed anonymous hunks with no
  filenames; a **mode-only** change printed an empty body under a message that
  was factually wrong; **binary** files leaked the absolute paths the header
  stripping exists to hide; `awk` aborted mid-stream on bytes invalid in the
  ambient locale (now `LC_ALL=C`); and the "diff truncated" notice counted raw
  lines rather than printed ones, so it could claim truncation that hadn't
  happened.
- `grove sync check|list` reject stray arguments instead of silently discarding
  them, and a relative symlink that lands dangling in the worktree is warned
  about.
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
