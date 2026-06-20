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
  a `<main-checkout>/.grove.json` (`{ "color"?, "icon"? }`; `color` accepts `#RRGGBB`,
  `"auto"`, or `"inherit"`). Style is re-applied on every `grove go` (so it survives
  cmux group recreation), or on demand with `grove restyle` — which also accepts
  `--color`/`--icon` to write `.grove.json` for you. grove sets color/icon via cmux's
  imperative API and never writes `cmux.json`; `byCwd` stays yours for umbrellas.
- `grove init [--with-multi-account]` — optional wiring: cmux Claude plugin,
  `wt go` alias, and an opt-in direnv multi-account hook.
- `grove doctor` — dependency and wiring check.
- Homebrew formula and `curl | sh` installer.
