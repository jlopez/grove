# Changelog

All notable changes to grove are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[SemVer](https://semver.org/).

## [Unreleased]

### Added
- `grove go <branch> [prompt...]` — create a worktree and spawn a cmux workspace
  running Claude on the prompt, filed under the repo's sidebar group.
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
- `grove init [--with-multi-account]` — optional wiring: cmux Claude plugin,
  `wt go` alias, and an opt-in direnv multi-account hook.
- `grove doctor` — dependency and wiring check.
- Homebrew formula and `curl | sh` installer.
