# Changelog

All notable changes to grove are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[SemVer](https://semver.org/).

## [Unreleased]

### Added
- `grove go <branch> [prompt...]` — create a worktree and spawn a cmux workspace
  running Claude on the prompt, filed under the repo's sidebar group.
- `grove init [--with-multi-account]` — optional wiring: cmux Claude plugin,
  `wt go` alias, and an opt-in direnv multi-account hook.
- `grove doctor` — dependency and wiring check.
- Homebrew formula and `curl | sh` installer.
