# grove — working in this repo

grove is a thin shell layer gluing **worktrunk** (`wt`) + **cmux** + **Claude Code**:
`grove go <branch> <prompt>` creates a git worktree and opens a cmux workspace running
Claude on the prompt, filed under the repo's sidebar group. See **[docs/design.md](docs/design.md)**
for the full architecture and the reverse-engineered cmux/worktrunk CLI contract.

## Layout

```
bin/grove                  # the CLI (single self-contained bash script): go / init / doctor / version
install.sh                 # curl|sh installer (POSIX sh)
Formula/grove.rb           # Homebrew formula (activated on first release)
test/grove.bats            # smoke tests
docs/design.md             # architecture + CLI internals
.github/workflows/ci.yml   # shellcheck + bats
```

## Conventions

- `bin/grove` is **bash**; `install.sh` is **POSIX sh**. Both must pass `shellcheck`
  cleanly — CI runs `shellcheck bin/grove install.sh`.
- Tests are **bats** in `test/`. CI runs them; keep them dependency-light (no cmux in CI),
  so cmux/worktrunk flows are validated manually, not in `test/`.
- Keep `grove` self-contained (no extra runtime files). `grove go` derives the repo from
  git and needs no config; `grove init` only adds *optional* conveniences.
- Update `CHANGELOG.md` (Unreleased) and bump `GROVE_VERSION` in `bin/grove` for releases.

## Testing safely ⚠️

Exercising `grove go` for real spawns cmux workspaces and launches agents. To test the
plumbing without any of that:

- **`GROVE_AGENT=echo grove go <branch> <words>`** — swaps `claude` for a benign command,
  so nothing real launches.
- **Clean up surgically.** Close only the workspace you created and `wt remove --force`
  only your test branch. Two traps:
  - **Never `cmux workspace-group delete <g>`** on a group that holds real work — it closes
    every member. Close individual workspaces instead.
  - When finding a workspace id from `cmux workspace list`, match **`workspace:[0-9]+`** —
    do **not** take the first field, because the *selected* row is prefixed with `*`.

## Dependencies

`wt` (worktrunk), the cmux CLI, `jq`, `claude`, `git`; `direnv` for the optional
multi-account feature. `grove doctor` checks them all.
