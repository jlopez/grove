#!/usr/bin/env bats
# Smoke tests for the grove CLI. cmux/worktrunk-dependent flows aren't exercised
# here (no cmux in CI); those are validated manually. See README "How it works".

GROVE="${BATS_TEST_DIRNAME}/../bin/grove"

# Isolate the machine-wide config layer so a real ~/.config/grove/config.json
# on the dev box can't leak into config/style assertions.
setup() {
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg"
}

@test "version prints a version string" {
  run "$GROVE" version
  [ "$status" -eq 0 ]
  [[ "$output" == *"grove v"* ]]
}

@test "help prints usage" {
  run "$GROVE" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "no args prints usage" {
  run "$GROVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"grove"* ]]
}

@test "unknown command fails" {
  run "$GROVE" frobnicate
  [ "$status" -ne 0 ]
}

@test "go without a branch fails" {
  run "$GROVE" go
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: grove go"* ]]
}

@test "go rejects an unknown option" {
  run "$GROVE" go --frobnicate some-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "go --base requires a value" {
  run "$GROVE" go --base
  [ "$status" -ne 0 ]
  [[ "$output" == *"--base needs a ref"* ]]
}

@test "go -h prints the new usage with --base/--no-fetch" {
  run "$GROVE" go -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"--base"* ]]
  [[ "$output" == *"--no-fetch"* ]]
}

@test "go accepts the --base=<ref> form (not rejected as an unknown option)" {
  # Run from a non-git temp dir so it bails at repo-identity BEFORE touching wt
  # or cmux — we only assert the parser CONSUMED --base=@ (didn't treat it as an
  # unknown option or as a missing-value error), mirroring the restyle tests.
  cd "$BATS_TEST_TMPDIR"
  run "$GROVE" go --base=@ some-branch
  [ "$status" -ne 0 ]                        # bails (no git repo / no cmux)
  [[ "$output" != *"unknown option"* ]]      # =-form was parsed, not rejected
  [[ "$output" != *"needs a ref"* ]]         # value was extracted, not missing
}

@test "rm -h prints usage" {
  run "$GROVE" rm -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: grove rm"* ]]
}

@test "rm rejects an unknown option" {
  run "$GROVE" rm --frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "help documents grove rm teardown" {
  run "$GROVE" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"grove rm"* ]]
}

@test "rm rejects a second positional argument (doesn't silently drop trailing tokens)" {
  run "$GROVE" rm feature/x extra
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected argument"* ]]
}

@test "rm accepts a flag after the branch (doesn't drop a post-branch --force)" {
  # The parser must not stop at the first positional: `grove rm <branch> --force`
  # must honor --force, not drop it. Run from a non-git tmpdir so it's the PARSER
  # under test — it bails later at repo-identity, but must not reject the flag.
  cd "$BATS_TEST_TMPDIR"
  run "$GROVE" rm feature/x --force
  [ "$status" -ne 0 ]                        # bails (no git repo / no deps)
  [[ "$output" != *"unexpected argument"* ]] # branch + trailing flag both parsed
  [[ "$output" != *"unknown option"* ]]
}

@test "doctor runs and reports sections" {
  run "$GROVE" doctor
  # status may be non-zero if deps are missing (expected in CI); just check output
  [[ "$output" == *"grove doctor"* ]]
  [[ "$output" == *"Required:"* ]]
}

@test "help documents per-repo styling and restyle" {
  run "$GROVE" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"grove restyle"* ]]
  [[ "$output" == *".grove.json"* ]]
}

@test "restyle rejects an unknown option" {
  run "$GROVE" restyle --frobnicate
  [ "$status" -ne 0 ]
}

@test "restyle --color requires a value" {
  run "$GROVE" restyle --color
  [ "$status" -ne 0 ]
}

@test "restyle --color rejects a non-hex value" {
  run "$GROVE" restyle --color notacolor
  [ "$status" -ne 0 ]
  [[ "$output" == *"#RRGGBB"* ]]
}

# --- unit tests on the styling functions (sourced; no cmux needed) -----------

@test "grove_color_for is deterministic and returns a palette hex" {
  set +eu
  source "$GROVE"
  local a b
  a=$(grove_color_for "my-repo"); b=$(grove_color_for "my-repo")
  [ "$a" = "$b" ]                                  # same name → same color
  [[ "$a" =~ ^#[0-9A-Fa-f]{6}$ ]]                  # valid hex
  printf '%s\n' "${GROVE_PALETTE[@]}" | grep -qx "$a"   # is a real palette cell
}

@test "grove_color_for differs across distinct repo names" {
  set +eu
  source "$GROVE"
  # at least a couple of these should differ (sanity, not a collision proof)
  local c1 c2 c3
  c1=$(grove_color_for "alpha"); c2=$(grove_color_for "bravo"); c3=$(grove_color_for "charlie")
  [ "$c1" != "$c2" ] || [ "$c2" != "$c3" ] || [ "$c1" != "$c3" ]
}

@test "resolve_style: no .grove.json → deterministic color, no icon" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/norc"; mkdir -p "$d"
  grove_resolve_style "norc" "$d"
  [ "$STYLE_COLOR" = "$(grove_color_for "norc")" ]
  [ -z "$STYLE_ICON" ]
}

@test "resolve_style: explicit color + icon are honored" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/explicit"; mkdir -p "$d"
  printf '%s\n' '{ "color": "#123ABC", "icon": "leaf.fill" }' > "$d/.grove.json"
  grove_resolve_style "explicit" "$d"
  [ "$STYLE_COLOR" = "#123ABC" ]
  [ "$STYLE_ICON" = "leaf.fill" ]
}

@test "resolve_style: inherit → clear sentinel" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/inherit"; mkdir -p "$d"
  printf '%s\n' '{ "color": "inherit" }' > "$d/.grove.json"
  grove_resolve_style "inherit" "$d"
  [ "$STYLE_COLOR" = "INHERIT" ]
}

@test "resolve_style: invalid JSON falls back to deterministic" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/bad"; mkdir -p "$d"
  printf '%s\n' '{ not json' > "$d/.grove.json"
  grove_resolve_style "bad" "$d"
  [ "$STYLE_COLOR" = "$(grove_color_for "bad")" ]
}

@test "write_style: creates and merges .grove.json, preserving keys" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/write"; mkdir -p "$d"
  grove_write_style "$d" "#ABCDEF" "" >/dev/null
  [ "$(jq -r '.color' "$d/.grove.json")" = "#ABCDEF" ]
  grove_write_style "$d" "" "star.fill" >/dev/null    # add icon, keep color
  [ "$(jq -r '.color' "$d/.grove.json")" = "#ABCDEF" ]
  [ "$(jq -r '.icon'  "$d/.grove.json")" = "star.fill" ]
}

@test "write_style: icon 'none' deletes the key, keeps color" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/del"; mkdir -p "$d"
  printf '%s\n' '{ "color": "#111111", "icon": "leaf.fill" }' > "$d/.grove.json"
  grove_write_style "$d" "" "none" >/dev/null
  [ "$(jq -r '.color' "$d/.grove.json")" = "#111111" ]
  [ "$(jq 'has("icon")' "$d/.grove.json")" = "false" ]
}

@test "grove_random_color returns a palette hex" {
  set +eu
  source "$GROVE"
  local c; c=$(grove_random_color)
  [[ "$c" =~ ^#[0-9A-Fa-f]{6}$ ]]
  printf '%s\n' "${GROVE_PALETTE[@]}" | grep -qx "$c"
}

@test "restyle --color random passes validation (no validation error)" {
  # Run from a non-git temp dir so it bails at repo-identity BEFORE writing
  # any .grove.json or touching cmux — we only assert validation accepted it.
  cd "$BATS_TEST_TMPDIR"
  run "$GROVE" restyle --color random
  [ "$status" -ne 0 ]                       # bails (no git repo / no cmux)
  [[ "$output" != *"must be #RRGGBB"* ]]    # but NOT a validation rejection
}

@test "restyle --color rejects a bogus keyword" {
  cd "$BATS_TEST_TMPDIR"
  run "$GROVE" restyle --color chartreuse
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be #RRGGBB"* ]]
}

# --- layered config store ----------------------------------------------------

@test "config_get: absent keypath → empty; present scalar is read" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/cfg"; mkdir -p "$d"
  printf '%s\n' '{ "color": "#ABCDEF" }' > "$d/.grove.json"
  grove_config_load "$d"
  [ "$(grove_config_get color)" = "#ABCDEF" ]
  [ -z "$(grove_config_get nope)" ]
}

@test "config_get: dotted keypath reads nested scalars" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/nested"; mkdir -p "$d"
  printf '%s\n' '{ "agent": { "command": "claude" } }' > "$d/.grove.json"
  grove_config_load "$d"
  [ "$(grove_config_get agent.command)" = "claude" ]
}

@test "config: .grove.local.json wins over .grove.json (last layer wins)" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/layer"; mkdir -p "$d"
  printf '%s\n' '{ "color": "#111111", "icon": "leaf.fill" }' > "$d/.grove.json"
  printf '%s\n' '{ "color": "#222222" }'                      > "$d/.grove.local.json"
  grove_config_load "$d"
  [ "$(grove_config_get color)" = "#222222" ]   # overridden by local
  [ "$(grove_config_get icon)"  = "leaf.fill" ] # untouched key persists
}

@test "config: XDG layer is the lowest precedence" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/xdglayer"; mkdir -p "$d" "$XDG_CONFIG_HOME/grove"
  printf '%s\n' '{ "color": "#000001", "icon": "globe" }' > "$XDG_CONFIG_HOME/grove/config.json"
  printf '%s\n' '{ "color": "#000002" }'                  > "$d/.grove.json"
  grove_config_load "$d"
  [ "$(grove_config_get color)" = "#000002" ]   # repo file beats machine default
  [ "$(grove_config_get icon)"  = "globe" ]     # but XDG-only key still shows
}

@test "config_get: ENV_VAR override wins when set non-empty" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/env"; mkdir -p "$d"
  printf '%s\n' '{ "agent": { "command": "claude" } }' > "$d/.grove.json"
  grove_config_load "$d"
  [ "$(GROVE_COMMAND=echo grove_config_get agent.command GROVE_COMMAND)" = "echo" ]
  [ "$(GROVE_COMMAND=""   grove_config_get agent.command GROVE_COMMAND)" = "claude" ]  # empty ⇒ no override
}

@test "config_get_array: emits elements; non-array → nothing" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/arr"; mkdir -p "$d"
  printf '%s\n' '{ "args": ["--a", "--b"], "color": "#abcdef" }' > "$d/.grove.json"
  grove_config_load "$d"
  local got; got=$(grove_config_get_array args | tr '\n' ',')
  [ "$got" = "--a,--b," ]
  [ -z "$(grove_config_get_array color)" ]   # scalar ⇒ nothing
}

@test "build_launch: default command, no args, no prompt" {
  set +eu
  source "$GROVE"
  GROVE_CONFIG_JSON='{}'
  [ "$(grove_build_launch)" = "claude" ]
}

@test "build_launch: command + args + prompt, each %q-quoted" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/launch"; mkdir -p "$d"
  printf '%s\n' '{ "agent": { "command": "aider", "args": ["--model", "gpt 4"] } }' > "$d/.grove.json"
  grove_config_load "$d"
  [ "$(grove_build_launch 'fix the bug')" = "aider --model gpt\\ 4 fix\\ the\\ bug" ]
}

@test "build_launch: GROVE_COMMAND overrides agent.command" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/launchenv"; mkdir -p "$d"
  printf '%s\n' '{ "agent": { "command": "claude" } }' > "$d/.grove.json"
  grove_config_load "$d"
  [ "$(GROVE_COMMAND=echo grove_build_launch hi)" = "echo hi" ]
}

@test "config_load: invalid layer is skipped, valid layers still merge" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/badlayer"; mkdir -p "$d"
  printf '%s\n' '{ not json'             > "$d/.grove.json"        # bad → skipped
  printf '%s\n' '{ "color": "#cccccc" }' > "$d/.grove.local.json" # good → kept
  grove_config_load "$d"
  [ "$(grove_config_get color)" = "#cccccc" ]
}

# --- cmux attachment gate (issue #2) -----------------------------------------
# grove_title_in_group is the pure matcher behind the fail-fast cmux gate; it
# needs only jq, so it's unit-testable without cmux. Fixtures mirror the real
# `workspace-group list --json` / `workspace list --json` shapes.

_groups_json() {
  cat <<'JSON'
{ "groups": [
  { "name": "grove", "member_workspace_refs": ["workspace:19", "workspace:34"] },
  { "name": "other", "member_workspace_refs": ["workspace:50"] }
] }
JSON
}
_ws_json() {
  cat <<'JSON'
{ "workspaces": [
  { "ref": "workspace:19", "title": "grove",                    "custom_title": "grove" },
  { "ref": "workspace:34", "title": "fix/gh-2-reopen-workspace", "custom_title": "renamed-tab" },
  { "ref": "workspace:50", "title": "feature/x",                "custom_title": "feature/x" }
] }
JSON
}

@test "title_in_group: matches a member workspace's title in the repo group" {
  set +eu
  source "$GROVE"
  run grove_title_in_group "$(_groups_json)" "$(_ws_json)" grove "fix/gh-2-reopen-workspace"
  [ "$status" -eq 0 ]
}

@test "title_in_group: matches a member at index 0 of member_workspace_refs" {
  # jq-truthiness guard: index($r)==0 is truthy in jq, so an index-0 member
  # must still match (workspace:19 is the first member ref of group 'grove').
  set +eu
  source "$GROVE"
  run grove_title_in_group "$(_groups_json)" "$(_ws_json)" grove "grove"
  [ "$status" -eq 0 ]
}

@test "title_in_group: matches on custom_title when title has drifted" {
  # workspace:34's title is the branch but custom_title was renamed; the reverse
  # case (custom_title == branch, title drifted) must also match.
  set +eu
  source "$GROVE"
  local ws='{ "workspaces": [ { "ref": "workspace:34", "title": "claude", "custom_title": "fix/gh-2-reopen-workspace" } ] }'
  run grove_title_in_group "$(_groups_json)" "$ws" grove "fix/gh-2-reopen-workspace"
  [ "$status" -eq 0 ]
}

@test "title_in_group: missing member_workspace_refs → no match (fails closed)" {
  set +eu
  source "$GROVE"
  local groups='{ "groups": [ { "name": "grove" } ] }'
  run grove_title_in_group "$groups" "$(_ws_json)" grove "grove"
  [ "$status" -ne 0 ]
}

@test "title_in_group: malformed listings (no keys) → no match, no jq crash" {
  set +eu
  source "$GROVE"
  run grove_title_in_group '{}' '{}' grove "grove"
  [ "$status" -ne 0 ]
}

@test "title_in_group: no match when no member has that title" {
  set +eu
  source "$GROVE"
  run grove_title_in_group "$(_groups_json)" "$(_ws_json)" grove "feature/nope"
  [ "$status" -ne 0 ]
}

@test "title_in_group: scoped to the repo group (cross-repo same name doesn't match)" {
  set +eu
  source "$GROVE"
  # 'feature/x' is attached, but only in the 'other' group — not in 'grove'.
  run grove_title_in_group "$(_groups_json)" "$(_ws_json)" grove "feature/x"
  [ "$status" -ne 0 ]
}

@test "title_in_group: no group for the repo → no match (first grove go)" {
  set +eu
  source "$GROVE"
  run grove_title_in_group '{ "groups": [] }' "$(_ws_json)" grove "grove"
  [ "$status" -ne 0 ]
}

# grove_ref_in_group is the value-returning sibling used by `grove rm` to find
# the tab to close; it prints the matched member's ref (or nothing), reusing the
# same fixtures/scoping as title_in_group above.

@test "ref_in_group: returns the ref of the matched member workspace" {
  set +eu
  source "$GROVE"
  local r; r=$(grove_ref_in_group "$(_groups_json)" "$(_ws_json)" grove "fix/gh-2-reopen-workspace")
  [ "$r" = "workspace:34" ]
}

@test "ref_in_group: matches on custom_title when title has drifted" {
  set +eu
  source "$GROVE"
  local ws='{ "workspaces": [ { "ref": "workspace:34", "title": "claude", "custom_title": "fix/gh-2-reopen-workspace" } ] }'
  local r; r=$(grove_ref_in_group "$(_groups_json)" "$ws" grove "fix/gh-2-reopen-workspace")
  [ "$r" = "workspace:34" ]
}

@test "ref_in_group: no match → empty (missing/renamed tab is safe to skip)" {
  set +eu
  source "$GROVE"
  [ -z "$(grove_ref_in_group "$(_groups_json)" "$(_ws_json)" grove "feature/nope")" ]
}

@test "ref_in_group: scoped to the repo group (cross-repo same name → empty)" {
  set +eu
  source "$GROVE"
  # 'feature/x' is attached only in the 'other' group, not in 'grove'.
  [ -z "$(grove_ref_in_group "$(_groups_json)" "$(_ws_json)" grove "feature/x")" ]
}

@test "ref_in_group: malformed listings → empty, no jq crash" {
  set +eu
  source "$GROVE"
  [ -z "$(grove_ref_in_group '{}' '{}' grove "grove")" ]
}

# --- base resolution for new worktrees (issue #14) ---------------------------
# grove_resolve_base sets GROVE_BASE_ARGS (an array) and never hard-fails. The
# escape-hatch and no-origin paths need no network, so they're unit-testable.

@test "resolve_base: --base escape hatch wins, no fetch attempted" {
  set +eu
  source "$GROVE"
  # Run from a non-git temp dir: if it tried to fetch/detect it would error, but
  # the explicit base must short-circuit before any git call.
  cd "$BATS_TEST_TMPDIR"
  grove_resolve_base "@" ""
  [ "${#GROVE_BASE_ARGS[@]}" -eq 2 ]
  [ "${GROVE_BASE_ARGS[0]}" = "--base" ]
  [ "${GROVE_BASE_ARGS[1]}" = "@" ]
}

@test "resolve_base: no origin/HEAD → empty base args (graceful, lets wt default)" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/noremote"; mkdir -p "$d"
  git -C "$d" init -q
  cd "$d"
  grove_resolve_base "" ""               # no remote → origin/HEAD unset
  [ "${#GROVE_BASE_ARGS[@]}" -eq 0 ]
}

@test "resolve_base: --no-fetch branches from the local default without fetching" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/nofetch"; mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m init
  # Point origin at a bare clone and set origin/HEAD, so def resolves to 'main'.
  local bare; bare="$BATS_TEST_TMPDIR/nofetch.git"; git init -q --bare "$bare"
  git -C "$d" remote add origin "$bare"; git -C "$d" push -q origin main
  git -C "$d" remote set-head origin main
  cd "$d"
  grove_resolve_base "" "1"              # --no-fetch
  [ "${GROVE_BASE_ARGS[0]}" = "--base" ]
  [ "${GROVE_BASE_ARGS[1]}" = "main" ]   # local ref, not origin/main
}

@test "resolve_style: .grove.local.json color overrides committed .grove.json" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/styleover"; mkdir -p "$d"
  printf '%s\n' '{ "color": "#111111" }' > "$d/.grove.json"
  printf '%s\n' '{ "color": "#999999" }' > "$d/.grove.local.json"
  grove_resolve_style "styleover" "$d"
  [ "$STYLE_COLOR" = "#999999" ]
}
