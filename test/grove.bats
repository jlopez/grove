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

@test "rm accepts -D and --no-fetch (wt passthrough + freshness opt-out parse)" {
  cd "$BATS_TEST_TMPDIR"
  run "$GROVE" rm -D --no-fetch feature/x
  [ "$status" -ne 0 ]                        # bails (no git repo / no deps)
  [[ "$output" != *"unknown option"* ]]
  [[ "$output" != *"unexpected argument"* ]]
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

@test "build_launch: command + args + prompt file → read-and-reclaim line" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/launch"; mkdir -p "$d"
  printf '%s\n' '{ "agent": { "command": "aider", "args": ["--model", "gpt 4"] } }' > "$d/.grove.json"
  grove_config_load "$d"
  local f="$d/pfile"; : > "$f"
  [ "$(grove_build_launch "$f")" = "p=\$(cat -- $f) && rm -f -- $f && aider --model gpt\\ 4 \"\$p\"" ]
}

@test "build_launch: GROVE_COMMAND overrides agent.command" {
  set +eu
  source "$GROVE"
  local d; d="$BATS_TEST_TMPDIR/launchenv"; mkdir -p "$d"
  printf '%s\n' '{ "agent": { "command": "claude" } }' > "$d/.grove.json"
  grove_config_load "$d"
  local f="$d/pfile"; : > "$f"
  [ "$(GROVE_COMMAND=echo grove_build_launch "$f")" = "p=\$(cat -- $f) && rm -f -- $f && echo \"\$p\"" ]
}

@test "prompt_tmpfile: verbatim content, private, outside any worktree" {
  set +eu
  source "$GROVE"
  local prompt=$'line one\nline "two" with $dollars and \\backslashes'
  local f; f=$(TMPDIR="$BATS_TEST_TMPDIR" grove_prompt_tmpfile "$prompt")
  [ -f "$f" ]
  case "$f" in "$BATS_TEST_TMPDIR"/grove-prompt.??????) ;; *) false ;; esac
  [ "$(cat "$f")" = "$prompt" ]
  # mktemp creates 0600 — the prompt is not world-readable
  [ "$(ls -l "$f" | cut -c1-10)" = "-rw-------" ]
  rm -f -- "$f"
}

@test "build_launch: typed line length is prompt-length-invariant (issue #26)" {
  set +eu
  source "$GROVE"
  GROVE_CONFIG_JSON='{}'
  local short long huge
  short=$(TMPDIR="$BATS_TEST_TMPDIR" grove_prompt_tmpfile "hi")
  huge=$(printf 'x%.0s' $(seq 1 10000))   # 10KB — far past the ~1KB pty line cap
  long=$(TMPDIR="$BATS_TEST_TMPDIR" grove_prompt_tmpfile "$huge")
  [ "${#huge}" -eq 10000 ]
  [ "$(grove_build_launch "$short" | wc -c)" -eq "$(grove_build_launch "$long" | wc -c)" ]
  rm -f -- "$short" "$long"
}

@test "build_launch: executing the line hands the prompt over and reclaims the file" {
  set +eu
  source "$GROVE"
  GROVE_CONFIG_JSON='{}'
  local prompt='multi word prompt with "quotes"'
  local f; f=$(TMPDIR="$BATS_TEST_TMPDIR" grove_prompt_tmpfile "$prompt")
  local launch; launch=$(GROVE_COMMAND=echo grove_build_launch "$f")
  [ "$(bash -c "$launch")" = "$prompt" ]   # echo "$p" prints the prompt verbatim
  [ ! -e "$f" ]                            # …and the temp file was reclaimed
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

# --- GROVE_* env stamp matcher (issue #18) -----------------------------------
# grove_workspace_for is the shared matcher (grove go's attach gate + grove rm's
# close-target lookup): title first, then a per-member `cmux workspace env`
# sweep keyed on the stamped GROVE_WORKTREE_PATH. The sweep is exercised with a
# stubbed cmux serving per-ref env JSON in the real `workspace env --json`
# shape ({count, env: {...}, window_ref, workspace_ref}); reuses the gate
# fixtures above (group 'grove' = workspace:19+34, 'other' = workspace:50).

_env_setup() { # populates $ESTUB — a cmux stub serving `workspace env <ref> --json`
  ESTUB="$BATS_TEST_TMPDIR/envstub"
  mkdir -p "$ESTUB/bin"
  # Every invocation is logged BEFORE any validation, so the no-cmux-call tests
  # below can assert the log's absence — a stub that merely fails would be
  # swallowed by the sweep's `|| continue` and prove nothing.
  cat > "$ESTUB/bin/cmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ESTUB/calls.log"
[ "\$1 \$2" = "workspace env" ] || exit 1
cat "$ESTUB/env-\${3//:/-}.json" 2>/dev/null   # no file for a ref → exit 1
SH
  chmod +x "$ESTUB/bin/cmux"
  # workspace:19 = unstamped header (empty env, e.g. pre-#18 legacy tab)
  cat > "$ESTUB/env-workspace-19.json" <<'JSON'
{ "count": 0, "env": {}, "window_ref": "window:1", "workspace_ref": "workspace:19" }
JSON
  # workspace:34 = grove-stamped; title has drifted from its branch
  cat > "$ESTUB/env-workspace-34.json" <<'JSON'
{ "count": 3,
  "env": { "GROVE_WORKTREE_PATH": "/repos/wt/renamed",
           "GROVE_REPO_PATH": "/repos/grove", "GROVE_VERSION": "0.1.0" },
  "window_ref": "window:1", "workspace_ref": "workspace:34" }
JSON
  # workspace:50 = stamped too, but a member of group 'other', not 'grove'
  cat > "$ESTUB/env-workspace-50.json" <<'JSON'
{ "count": 3,
  "env": { "GROVE_WORKTREE_PATH": "/repos/wt/other-feature",
           "GROVE_REPO_PATH": "/repos/other", "GROVE_VERSION": "0.1.0" },
  "window_ref": "window:1", "workspace_ref": "workspace:50" }
JSON
}

@test "group_member_refs: lists the repo group's member refs, one per line" {
  set +eu
  source "$GROVE"
  local out; out=$(grove_group_member_refs "$(_groups_json)" grove)
  [ "$out" = "$(printf 'workspace:19\nworkspace:34')" ]
}

@test "group_member_refs: unknown group / malformed listing → empty" {
  set +eu
  source "$GROVE"
  [ -z "$(grove_group_member_refs "$(_groups_json)" nope)" ]
  [ -z "$(grove_group_member_refs '{}' grove)" ]
  [ -z "$(grove_group_member_refs 'not json' grove)" ]
}

@test "env_ref_in_group: matches the stamped GROVE_WORKTREE_PATH (skips unstamped)" {
  set +eu
  source "$GROVE"
  _env_setup
  # workspace:19 (empty env) is swept first and skipped; workspace:34 matches.
  local r; r=$(grove_env_ref_in_group "$ESTUB/bin/cmux" "$(_groups_json)" grove /repos/wt/renamed)
  [ "$r" = "workspace:34" ]
}

@test "env_ref_in_group: empty canon-path → nothing, and no cmux calls at all" {
  set +eu
  source "$GROVE"
  _env_setup
  # An empty key must short-circuit before any sweep: the recording stub proves
  # cmux was never invoked (calls.log is written on EVERY invocation).
  [ -z "$(grove_env_ref_in_group "$ESTUB/bin/cmux" "$(_groups_json)" grove "")" ]
  [ ! -e "$ESTUB/calls.log" ]
}

@test "env_ref_in_group: scoped to the repo group (other group's stamp never matches)" {
  set +eu
  source "$GROVE"
  _env_setup
  # workspace:50 carries this exact stamp but belongs to 'other', not 'grove'.
  [ -z "$(grove_env_ref_in_group "$ESTUB/bin/cmux" "$(_groups_json)" grove /repos/wt/other-feature)" ]
}

@test "env_ref_in_group: failed env read is skipped, no member matches → empty" {
  set +eu
  source "$GROVE"
  _env_setup
  rm "$ESTUB/env-workspace-19.json"   # sweep hits a failing env read first
  [ -z "$(grove_env_ref_in_group "$ESTUB/bin/cmux" "$(_groups_json)" grove /repos/wt/nope)" ]
}

@test "workspace_for: title hit returns the ref with zero env sweeps" {
  set +eu
  source "$GROVE"
  _env_setup
  # A title hit must never reach the env sweep: the recording stub proves cmux
  # was never invoked (a merely-failing stub would be swallowed by the sweep's
  # `|| continue` and could not distinguish "not called" from "called, failed").
  local r
  r=$(grove_workspace_for "$ESTUB/bin/cmux" "$(_groups_json)" "$(_ws_json)" grove "fix/gh-2-reopen-workspace" /repos/wt/renamed)
  [ "$r" = "workspace:34" ]
  [ ! -e "$ESTUB/calls.log" ]
}

@test "workspace_for: title miss falls back to the env stamp (rename incident)" {
  set +eu
  source "$GROVE"
  _env_setup
  # The motivating incident: branch renamed after grove go, so no title in the
  # group matches the new name — but the worktree path survived the rename.
  local r
  r=$(grove_workspace_for "$ESTUB/bin/cmux" "$(_groups_json)" "$(_ws_json)" grove "feature/gh-450-renamed" /repos/wt/renamed)
  [ "$r" = "workspace:34" ]
}

@test "workspace_for: both title and env miss → empty (fail-safe, legacy tabs)" {
  set +eu
  source "$GROVE"
  _env_setup
  [ -z "$(grove_workspace_for "$ESTUB/bin/cmux" "$(_groups_json)" "$(_ws_json)" grove "feature/nope" /repos/wt/nope)" ]
}

# --- orphan adoption after group dissolution (issue #23) ---------------------
# grove_orphan_candidates is the pure half of the adoption sweep: it lists
# "ref<TAB>cwd" for every workspace in NO group. Fixtures mirror the real
# listing shapes (anchors also appear in member_workspace_refs).

_adopt_groups_json() {
  cat <<'JSON'
{ "groups": [
  { "ref": "workspace_group:1", "name": "grove",
    "anchor_workspace_ref": "workspace:10",
    "member_workspace_refs": ["workspace:10", "workspace:11"] },
  { "ref": "workspace_group:2", "name": "other",
    "anchor_workspace_ref": "workspace:20",
    "member_workspace_refs": ["workspace:21"] }
] }
JSON
}
_adopt_ws_json() {
  cat <<'JSON'
{ "workspaces": [
  { "ref": "workspace:10", "title": "grove",     "current_directory": "/repos/grove" },
  { "ref": "workspace:11", "title": "feature/a", "current_directory": "/repos/wt/a" },
  { "ref": "workspace:20", "title": "other",     "current_directory": "/repos/other" },
  { "ref": "workspace:30", "title": "feature/b", "current_directory": "/repos/wt/b" },
  { "ref": "workspace:31", "title": "feature/c", "current_directory": "/repos/wt/c" }
] }
JSON
}

# --- rm anchor guard (issue #22) ---------------------------------------------
# Pure matchers behind the anchor guard: grove rm must not close a workspace
# that still anchors its group (closing the anchor dissolves the group). The
# jq-only pieces are unit-tested here; the cmux re-anchor calls are manual-only.

_anchor_groups_json() {
  cat <<'JSON'
{ "groups": [
  { "name": "grove", "ref": "workspace_group:7",
    "anchor_workspace_ref": "workspace:34",
    "member_workspace_refs": ["workspace:19", "workspace:34"] },
  { "name": "other", "ref": "workspace_group:9",
    "anchor_workspace_ref": "workspace:50",
    "member_workspace_refs": ["workspace:50"] }
] }
JSON
}
_anchor_ws_json() {
  cat <<'JSON'
{ "workspaces": [
  { "ref": "workspace:19", "title": "grove",     "current_directory": "/repos/grove" },
  { "ref": "workspace:34", "title": "fix/gh-22", "current_directory": "/repos/wt/fix-gh-22" },
  { "ref": "workspace:50", "title": "feature/x", "current_directory": "/repos/grove" }
] }
JSON
}

@test "orphan_candidates: lists only workspaces in no group, with their cwd" {
  set +eu
  source "$GROVE"
  local out; out=$(grove_orphan_candidates "$(_adopt_groups_json)" "$(_adopt_ws_json)")
  [ "$out" = "$(printf 'workspace:30\t/repos/wt/b\nworkspace:31\t/repos/wt/c')" ]
}

@test "orphan_candidates: an anchor not listed among members is still grouped" {
  # workspace:20 is only the ANCHOR of group 'other' (not in its member refs) —
  # it must not be offered for adoption.
  set +eu
  source "$GROVE"
  local out; out=$(grove_orphan_candidates "$(_adopt_groups_json)" "$(_adopt_ws_json)")
  [[ "$out" != *"workspace:20"* ]]
}

@test "orphan_candidates: no groups at all → every workspace is a candidate" {
  set +eu
  source "$GROVE"
  local out; out=$(grove_orphan_candidates '{ "groups": [] }' "$(_adopt_ws_json)")
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "5" ]
}

@test "orphan_candidates: missing cwd → empty field, malformed listings → empty" {
  set +eu
  source "$GROVE"
  local ws='{ "workspaces": [ { "ref": "workspace:30" } ] }'
  [ "$(grove_orphan_candidates '{ "groups": [] }' "$ws")" = "$(printf 'workspace:30\t')" ]
  [ -z "$(grove_orphan_candidates '{}' '{}')" ]        # missing keys fail closed
  [ -z "$(grove_orphan_candidates 'not json' '{}')" ]  # malformed groups fail closed
}

# grove_adopt_orphans is the I/O half: stub cmux (serves the fixtures, records
# `workspace-group add` calls) and wt (serves this repo's worktree list) to
# verify the sweep attaches exactly the right workspaces — no real cmux needed.

_adopt_setup() { # populates $STUB — a fake repo layout + cmux/wt stubs on PATH
  STUB="$BATS_TEST_TMPDIR/adopt"
  mkdir -p "$STUB/bin" "$STUB/repo-main" "$STUB/wt-a" "$STUB/wt-b" "$STUB/elsewhere"
  ln -s "$STUB/wt-a" "$STUB/link-a"   # symlinked cwd must still match (pwd -P)
  cat > "$STUB/bin/cmux" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "workspace-group list") cat "$STUB/groups.json" ;;
  "workspace list")       cat "$STUB/workspaces.json" ;;
  "workspace-group add")  echo "\$*" >> "$STUB/adds.log" ;;
esac
SH
  cat > "$STUB/bin/wt" <<SH
#!/usr/bin/env bash
cat "$STUB/wt.json"
SH
  chmod +x "$STUB/bin/cmux" "$STUB/bin/wt"
  cat > "$STUB/wt.json" <<JSON
[ { "branch": "main",      "path": "$STUB/repo-main" },
  { "branch": "feature/a", "path": "$STUB/wt-a" },
  { "branch": "feature/b", "path": "$STUB/wt-b" } ]
JSON
  cat > "$STUB/groups.json" <<'JSON'
{ "groups": [ { "ref": "workspace_group:1", "name": "myrepo",
                "anchor_workspace_ref": "workspace:1",
                "member_workspace_refs": ["workspace:1", "workspace:2"] } ] }
JSON
  cat > "$STUB/workspaces.json" <<JSON
{ "workspaces": [
  { "ref": "workspace:1", "current_directory": "$STUB/repo-main" },
  { "ref": "workspace:2", "current_directory": "$STUB/wt-a" },
  { "ref": "workspace:3", "current_directory": "$STUB/link-a" },
  { "ref": "workspace:4", "current_directory": "$STUB/elsewhere" },
  { "ref": "workspace:5", "current_directory": "$STUB/repo-main" },
  { "ref": "workspace:6", "current_directory": "$STUB/gone" }
] }
JSON
}

@test "adopt_orphans: attaches exactly this repo's ungrouped worktree workspaces" {
  set +eu
  source "$GROVE"
  _adopt_setup
  # The call-site contract: <canon-repo> arrives already canonicalized (pwd -P),
  # exactly as grove_go computes it in the primary-checkout guard.
  local canon_main; canon_main=$(cd "$STUB/repo-main" && pwd -P)
  PATH="$STUB/bin:$PATH" \
    grove_adopt_orphans "$STUB/bin/cmux" myrepo workspace_group:1 "$canon_main" 2>/dev/null
  # workspace:2 grouped → untouched; :3 orphan via symlink → adopted (pwd -P);
  # :4 other repo → skipped; :5 orphan at MAIN checkout → skipped (header's job);
  # :6 vanished dir → skipped.
  [ -f "$STUB/adds.log" ]
  [ "$(cat "$STUB/adds.log")" = "workspace-group add --group workspace_group:1 --workspace workspace:3" ]
}

@test "adopt_orphans: nothing to adopt → no add calls (idempotent re-run)" {
  set +eu
  source "$GROVE"
  _adopt_setup
  # Everything grouped: promote workspace:3..6 into the group too.
  cat > "$STUB/groups.json" <<'JSON'
{ "groups": [ { "ref": "workspace_group:1", "name": "myrepo",
                "anchor_workspace_ref": "workspace:1",
                "member_workspace_refs": ["workspace:1", "workspace:2", "workspace:3",
                                          "workspace:4", "workspace:5", "workspace:6"] } ] }
JSON
  PATH="$STUB/bin:$PATH" \
    grove_adopt_orphans "$STUB/bin/cmux" myrepo workspace_group:1 "$STUB/repo-main" 2>/dev/null
  [ ! -f "$STUB/adds.log" ]
}

@test "group_ref: returns the ref of the named group; unknown → empty" {
  set +eu
  source "$GROVE"
  [ "$(grove_group_ref "$(_anchor_groups_json)" grove)" = "workspace_group:7" ]
  [ -z "$(grove_group_ref "$(_anchor_groups_json)" nope)" ]
}

@test "group_ref: malformed listing → empty, no jq crash" {
  set +eu
  source "$GROVE"
  [ -z "$(grove_group_ref '{}' grove)" ]
  [ -z "$(grove_group_ref 'not json' grove)" ]
}

@test "group_anchor_ref: returns the group's anchor workspace ref" {
  set +eu
  source "$GROVE"
  [ "$(grove_group_anchor_ref "$(_anchor_groups_json)" grove)" = "workspace:34" ]
}

@test "group_anchor_ref: unknown group / missing key / malformed → empty" {
  set +eu
  source "$GROVE"
  [ -z "$(grove_group_anchor_ref "$(_anchor_groups_json)" nope)" ]
  [ -z "$(grove_group_anchor_ref '{ "groups": [ { "name": "grove" } ] }' grove)" ]
  [ -z "$(grove_group_anchor_ref 'not json' grove)" ]
}

@test "member_at_cwd: finds the group member at the main checkout" {
  set +eu
  source "$GROVE"
  local r
  r=$(grove_member_at_cwd "$(_anchor_groups_json)" "$(_anchor_ws_json)" grove /repos/grove workspace:34)
  [ "$r" = "workspace:19" ]
}

@test "member_at_cwd: skips the workspace being closed" {
  set +eu
  source "$GROVE"
  # workspace:19 is the only 'grove' member at that cwd; skipping it must yield
  # empty even though workspace:50 (another group) sits at the same cwd.
  [ -z "$(grove_member_at_cwd "$(_anchor_groups_json)" "$(_anchor_ws_json)" grove /repos/grove workspace:19)" ]
}

@test "member_at_cwd: non-member at the cwd never matches (group-scoped)" {
  set +eu
  source "$GROVE"
  # workspace:50 lives at /repos/grove but belongs to 'other', not 'grove'.
  local ws='{ "workspaces": [ { "ref": "workspace:50", "title": "feature/x", "current_directory": "/repos/grove" } ] }'
  [ -z "$(grove_member_at_cwd "$(_anchor_groups_json)" "$ws" grove /repos/grove workspace:34)" ]
}

@test "member_at_cwd: no member at the cwd / malformed listings → empty" {
  set +eu
  source "$GROVE"
  [ -z "$(grove_member_at_cwd "$(_anchor_groups_json)" "$(_anchor_ws_json)" grove /repos/elsewhere workspace:34)" ]
  [ -z "$(grove_member_at_cwd '{}' '{}' grove /repos/grove workspace:34)" ]
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

# ---- sync.paths (untracked files carried into worktrees) --------------------

# A main checkout + a worktree-shaped sibling dir, with sync.paths configured on
# the source side (grove_config_load reads whichever root it's given).
_sync_fixture() {
  SRC="$BATS_TEST_TMPDIR/sync-main"; DST="$BATS_TEST_TMPDIR/sync-wt"
  mkdir -p "$SRC" "$DST"
  git -C "$SRC" init -q -b main
  printf '%s\n' '.env' '.env.local' 'cfg/' > "$SRC/.gitignore"
  git -C "$SRC" add .gitignore
  git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm init
  printf '%s\n' '{ "sync": { "paths": [".env", ".env.local", "cfg/keys"] } }' > "$SRC/.grove.json"
  grove_config_load "$SRC"; grove_sync_resolve_paths "$SRC"
}

@test "sync_path_ok: rejects absolute paths and .. escapes" {
  set +eu
  source "$GROVE"
  grove_sync_path_ok ".env"
  grove_sync_path_ok "cfg/keys/id"
  ! grove_sync_path_ok ""
  ! grove_sync_path_ok "/etc/passwd"
  ! grove_sync_path_ok "../outside"
  ! grove_sync_path_ok "cfg/../../outside"
}

@test "sync_copy: copies files and dirs, creating missing parents" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf 'SECRET=1\n' > "$SRC/.env"
  mkdir -p "$SRC/cfg/keys"; printf 'k\n' > "$SRC/cfg/keys/id"
  grove_sync_copy "$SRC" "$DST"
  [ "$(cat "$DST/.env")" = "SECRET=1" ]
  [ "$(cat "$DST/cfg/keys/id")" = "k" ]
}

@test "sync_copy: never overwrites an existing destination" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf 'FROM_MAIN\n' > "$SRC/.env"
  printf 'MINE\n'      > "$DST/.env"
  grove_sync_copy "$SRC" "$DST"
  [ "$(cat "$DST/.env")" = "MINE" ]
}

@test "sync_copy: skips a path that isn't gitignored (it would dirty the worktree)" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf '%s\n' '{ "sync": { "paths": ["loose.txt"] } }' > "$SRC/.grove.json"
  grove_config_load "$SRC"; grove_sync_resolve_paths "$SRC"
  printf 'LOOSE\n' > "$SRC/loose.txt"        # untracked, but not ignored either
  run grove_sync_copy "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [ ! -e "$DST/loose.txt" ]
  [[ "$output" == *"not gitignored"* ]]
}

@test "sync_copy: skips a tracked path (git already carries it)" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf 'TRACKED\n' > "$SRC/.env"
  git -C "$SRC" add -f .env
  git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm env
  grove_sync_copy "$SRC" "$DST" 2>/dev/null
  [ ! -e "$DST/.env" ]
}

@test "sync_copy: an absent source is skipped, not fatal" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf 'X=1\n' > "$SRC/.env"          # .env.local and cfg/keys never created
  run grove_sync_copy "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [ "$(cat "$DST/.env")" = "X=1" ]
}

@test "sync_check: identical copies pass" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf 'A=1\n' > "$SRC/.env"; printf 'A=1\n' > "$DST/.env"
  run grove_sync_check "$SRC" "$DST"
  [ "$status" -eq 0 ]
}

@test "sync_check: a differing copy fails and diffs the change" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf 'A=1\n' > "$SRC/.env"; printf 'A=2\n' > "$DST/.env"
  run grove_sync_check "$SRC" "$DST"
  [ "$status" -eq 1 ]
  [[ "$output" == *".env differs"* ]]
  [[ "$output" == *"-A=1"* ]]
  [[ "$output" == *"+A=2"* ]]
  [[ "$output" != *"diff --git"* ]]     # git's file headers are stripped
}

@test "sync_check: quiet mode reports the path without the diff" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf 'A=1\n' > "$SRC/.env"; printf 'A=2\n' > "$DST/.env"
  run grove_sync_check "$SRC" "$DST" 1
  [ "$status" -eq 1 ]
  [[ "$output" == *".env differs"* ]]
  [[ "$output" != *"+A=2"* ]]
}

@test "sync_check: a file only in the worktree is divergence (nothing to fall back on)" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf 'ONLY_HERE\n' > "$DST/.env"
  run grove_sync_check "$SRC" "$DST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"exists in the worktree but not in the main checkout"* ]]
}

@test "sync_check: a path missing from the worktree is not divergence" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf 'A=1\n' > "$SRC/.env"          # never copied into DST
  run grove_sync_check "$SRC" "$DST"
  [ "$status" -eq 0 ]
}

@test "sync_check: no sync.paths configured → nothing to check" {
  set +eu
  source "$GROVE"
  GROVE_CONFIG_JSON='{}'
  run grove_sync_check "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- grove sync (the sync.paths verb) ---------------------------------------

@test "sync -h prints the subcommands" {
  run "$GROVE" sync -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"list|check|add"* ]]
}

@test "sync rejects an unknown subcommand" {
  run "$GROVE" sync frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown subcommand"* ]]
}

@test "sync_list: flags misconfigured paths and returns 1; divergence does not" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf '%s\n' '{ "sync": { "paths": [".env", "loose.txt", ".gitignore", "gone"] } }' > "$SRC/.grove.json"
  grove_config_load "$SRC"; grove_sync_resolve_paths "$SRC"
  printf 'A=1\n' > "$SRC/.env"; printf 'A=2\n' > "$DST/.env"
  printf 'L\n'   > "$SRC/loose.txt"                    # untracked but not ignored
  run grove_sync_list "$SRC" "$DST"
  [ "$status" -eq 1 ]                                  # .gitignore/loose.txt are config errors
  [[ "$output" == *"differs from the main checkout"* ]] # .env — a state, not an error
  [[ "$output" == *"not gitignored"* ]]
  [[ "$output" == *"tracked by git"* ]]
  [[ "$output" == *"absent from the main checkout"* ]]
}

@test "sync_list: an in-sync path reads as in sync; no dst → plain ok" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf 'A=1\n' > "$SRC/.env"; printf 'A=1\n' > "$DST/.env"
  printf '%s\n' '{ "sync": { "paths": [".env"] } }' > "$SRC/.grove.json"
  grove_config_load "$SRC"; grove_sync_resolve_paths "$SRC"
  run grove_sync_list "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync"* ]]
  run grove_sync_list "$SRC"          # no worktree side → config status only
  [ "$status" -eq 0 ]
  [[ "$output" != *"in sync"* ]]
}

@test "sync_write: add appends, dedupes, and preserves other keys" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf '%s\n' '{ "color": "#123456", "sync": { "paths": [".env"] } }' > "$SRC/.grove.json"
  grove_config_load "$SRC"; grove_sync_resolve_paths "$SRC"
  grove_sync_write "$SRC" "" add ".env.local" ".env"
  [ "$(jq -r '.color' "$SRC/.grove.json")" = "#123456" ]
  [ "$(jq -c '.sync.paths' "$SRC/.grove.json")" = '[".env",".env.local"]' ]
}

@test "sync_write: rm drops entries, and emptying the list drops the key" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf '%s\n' '{ "color": "#123456", "sync": { "paths": [".env", ".env.local"] } }' > "$SRC/.grove.json"
  grove_config_load "$SRC"; grove_sync_resolve_paths "$SRC"
  grove_sync_write "$SRC" "" rm ".env.local"
  [ "$(jq -c '.sync.paths' "$SRC/.grove.json")" = '[".env"]' ]
  grove_sync_write "$SRC" "" rm ".env"
  [ "$(jq -r 'has("sync")' "$SRC/.grove.json")" = "false" ]
  [ "$(jq -r '.color' "$SRC/.grove.json")" = "#123456" ]
}

@test "sync_write: --local carries the effective list forward (arrays replace)" {
  set +eu
  source "$GROVE"
  _sync_fixture
  printf '%s\n' '{ "sync": { "paths": [".env", ".env.local"] } }' > "$SRC/.grove.json"
  grove_config_load "$SRC"; grove_sync_resolve_paths "$SRC"
  grove_sync_write "$SRC" 1 add "mine.txt"
  # The local layer must restate the committed paths — jq's `*` replaces arrays,
  # so a one-element local list would silently supersede the shared one.
  [ "$(jq -c '.sync.paths' "$SRC/.grove.local.json")" = '[".env",".env.local","mine.txt"]' ]
  [ "$(jq -c '.sync.paths' "$SRC/.grove.json")" = '[".env",".env.local"]' ]
}

# ---- the review's failure modes (regression tests) --------------------------

@test "sync_differs: status comes from git, not from whether a diff printed" {
  set +eu
  source "$GROVE"
  set +eu
  local d; d="$BATS_TEST_TMPDIR/differs"; mkdir -p "$d/a" "$d/b"
  printf 'A=1\n' > "$d/a/.env"; printf 'A=1\n' > "$d/b/.env"
  run grove_sync_differs "$d/a/.env" "$d/b/.env"
  [ "$status" -eq 0 ]                          # identical
  printf 'A=2\n' > "$d/b/.env"
  run grove_sync_differs "$d/a/.env" "$d/b/.env"
  [ "$status" -eq 1 ]                          # plain difference
  # A type change: git reports a difference but prints NOTHING. Deciding from
  # output emptiness would call this "in sync" and let grove rm delete it.
  rm -f "$d/b/.env"; mkdir "$d/b/.env"; printf 's\n' > "$d/b/.env/inner"
  run grove_sync_differs "$d/a/.env" "$d/b/.env"
  [ "$status" -eq 1 ]
}

@test "sync_differs: an unreadable file is 'could not compare', never 'same'" {
  [ "$(id -u)" != 0 ] || skip "root reads everything"
  set +eu
  source "$GROVE"
  set +eu
  local d; d="$BATS_TEST_TMPDIR/unreadable"; mkdir -p "$d/a" "$d/b"
  printf 'A=1\n' > "$d/a/.env"; printf 'A=2\n' > "$d/b/.env"; chmod 000 "$d/b/.env"
  run grove_sync_differs "$d/a/.env" "$d/b/.env"
  chmod 644 "$d/b/.env"
  [ "$status" -eq 2 ]
}

@test "sync_check: a textconv diff driver cannot make two files look identical" {
  set +eu
  source "$GROVE"
  set +eu
  _sync_fixture
  # A redacting driver collapses both sides to the same text — the guard must
  # still see a difference, because it asks git for a verdict, not for output.
  printf '.env diff=redact\n' > "$SRC/.gitattributes"
  git -C "$SRC" config diff.redact.textconv 'echo REDACTED'
  printf '%s\n' '{ "sync": { "paths": [".env"] } }' > "$SRC/.grove.json"
  grove_config_load "$SRC"; grove_sync_resolve_paths "$SRC"
  printf 'A=1\n' > "$SRC/.env"; printf 'A=2\n' > "$DST/.env"
  run grove_sync_check "$SRC" "$DST"
  [ "$status" -eq 1 ]
}

@test "sync_check and sync_list agree on divergence (they share one comparison)" {
  set +eu
  source "$GROVE"
  set +eu
  _sync_fixture
  printf '%s\n' '{ "sync": { "paths": [".env"] } }' > "$SRC/.grove.json"
  grove_config_load "$SRC"; grove_sync_resolve_paths "$SRC"
  printf 'A=1\n' > "$SRC/.env"
  local variant
  for variant in same differ type; do
    rm -rf "$DST/.env"
    case "$variant" in
      same)   printf 'A=1\n' > "$DST/.env" ;;
      differ) printf 'A=2\n' > "$DST/.env" ;;
      type)   mkdir "$DST/.env"; printf 's\n' > "$DST/.env/inner" ;;
    esac
    run grove_sync_check "$SRC" "$DST" 1
    local check_said="$status"
    run grove_sync_list "$SRC" "$DST"
    if [ "$variant" = same ]; then
      [ "$check_said" -eq 0 ]; [[ "$output" == *"in sync"* ]]
    else
      [ "$check_said" -eq 1 ]; [[ "$output" == *"differs"* ]]
    fi
  done
}

@test "sync_check: a directory path names each differing file in the diff" {
  set +eu
  source "$GROVE"
  set +eu
  _sync_fixture
  printf '%s\n' '{ "sync": { "paths": ["cfg"] } }' > "$SRC/.grove.json"
  grove_config_load "$SRC"; grove_sync_resolve_paths "$SRC"
  mkdir -p "$SRC/cfg" "$DST/cfg"
  printf 'a=1\n' > "$SRC/cfg/a"; printf 'a=2\n' > "$DST/cfg/a"
  printf 'c=1\n' > "$DST/cfg/c"
  run grove_sync_check "$SRC" "$DST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a:"* ]]                   # per-file labels, not anonymous hunks
  [[ "$output" == *"c:"* ]]
  [[ "$output" != *"$SRC"* ]]                 # and no absolute paths leaked
}

@test "sync_write: add without --local does not promote local-layer paths" {
  set +eu
  source "$GROVE"
  set +eu
  _sync_fixture
  printf '%s\n' '{ "color": "#112233", "sync": { "paths": [".env"] } }' > "$SRC/.grove.json"
  printf '%s\n' '{ "sync": { "paths": [".env", "personal.key"] } }' > "$SRC/.grove.local.json"
  grove_config_load "$SRC"; grove_sync_resolve_paths "$SRC"
  grove_sync_write "$SRC" "" add ".env.test"
  # personal.key is deliberately personal — writing the committed file must not
  # carry it upward into the layer everyone shares.
  [ "$(jq -c '.sync.paths' "$SRC/.grove.json")" = '[".env",".env.test"]' ]
  [ "$(jq -r '.color' "$SRC/.grove.json")" = "#112233" ]
}

@test "sync_write: warns when a higher layer shadows the write (rm is a no-op)" {
  set +eu
  source "$GROVE"
  set +eu
  _sync_fixture
  printf '%s\n' '{ "sync": { "paths": [".env"] } }' > "$SRC/.grove.json"
  printf '%s\n' '{ "sync": { "paths": [".env"] } }' > "$SRC/.grove.local.json"
  grove_config_load "$SRC"; grove_sync_resolve_paths "$SRC"
  run grove_sync_write "$SRC" "" rm ".env"
  [[ "$output" == *"no effect on the resolved config"* ]]
}

@test "sync_write: refuses to overwrite a malformed target file" {
  set +eu
  source "$GROVE"
  set +eu
  _sync_fixture
  printf '%s\n' '{ "color": "#112233",}' > "$SRC/.grove.json"   # trailing comma
  run grove_sync_write "$SRC" "" add ".env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid JSON"* ]]
  [[ "$(cat "$SRC/.grove.json")" == *'"#112233"'* ]]            # left intact
}

@test "config_get_array: a wrong-typed key degrades to empty, no jq crash" {
  set +eu
  source "$GROVE"
  set +eu
  GROVE_CONFIG_JSON='{"sync":"oops"}'
  run grove_config_get_array "sync.paths"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sync_path_ok: rejects a leading dash (it would parse as an option)" {
  set +eu
  source "$GROVE"
  set +eu
  ! grove_sync_path_ok "-rf"
  ! grove_sync_path_ok "--local"
}

@test "sync: check/list reject stray arguments instead of ignoring them" {
  run "$GROVE" sync list stray
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected argument"* ]]
}

@test "sync_resolve_paths: unions every root, dedupes, preserves GROVE_CONFIG_JSON" {
  set +eu
  source "$GROVE"
  set +eu
  local d; d="$BATS_TEST_TMPDIR/union"; mkdir -p "$d/main" "$d/wt"
  printf '%s\n' '{ "color": "#111111", "sync": { "paths": [".env", "shared"] } }' > "$d/main/.grove.json"
  printf '%s\n' '{ "sync": { "paths": ["personal"] } }' > "$d/main/.grove.local.json"
  printf '%s\n' '{ "sync": { "paths": ["shared", "branch-only"] } }' > "$d/wt/.grove.json"
  grove_config_load "$d/wt"
  local before="$GROVE_CONFIG_JSON"
  grove_sync_resolve_paths "$d/wt" "$d/main"
  [ "${GROVE_SYNC_PATHS[*]}" = "shared branch-only .env personal" ]
  [ "$GROVE_CONFIG_JSON" = "$before" ]     # callers still need their own root's config
}

@test "sync_resolve_paths: the gitignored personal layer survives a worktree root" {
  set +eu
  source "$GROVE"
  set +eu
  # .grove.local.json is gitignored, so it can only ever exist in the main
  # checkout — a worktree-only root would silently resolve to no paths at all,
  # disabling the teardown guard for exactly the 'sync add --local' workflow.
  local d; d="$BATS_TEST_TMPDIR/localonly"; mkdir -p "$d/main" "$d/wt"
  printf '%s\n' '{ "sync": { "paths": [".env"] } }' > "$d/main/.grove.local.json"
  grove_sync_resolve_paths "$d/wt"
  [ "${#GROVE_SYNC_PATHS[@]}" -eq 0 ]      # worktree alone sees nothing…
  grove_sync_resolve_paths "$d/wt" "$d/main"
  [ "${GROVE_SYNC_PATHS[*]}" = ".env" ]    # …the union still finds it
}

@test "sync_check: a mode-only change is reported as a mode change" {
  set +eu
  source "$GROVE"
  set +eu
  _sync_fixture
  printf 'A=1\n' > "$SRC/.env"; printf 'A=1\n' > "$DST/.env"; chmod +x "$DST/.env"
  run grove_sync_check "$SRC" "$DST"
  chmod 644 "$DST/.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode changed"* ]]
  [[ "$output" != *"not the same kind of file"* ]]   # the old, factually wrong message
}

@test "sync_check runs correctly under the script's own set -euo pipefail" {
  # Sourcing into a CHILD shell keeps errexit/nounset/pipefail active, which
  # sourcing into the test's own shell cannot (bats needs them off).
  local d; d="$BATS_TEST_TMPDIR/strict"; mkdir -p "$d/main" "$d/wt"
  git -C "$d/main" init -q -b main
  printf '.env\n' > "$d/main/.gitignore"
  git -C "$d/main" add .gitignore
  git -C "$d/main" -c user.email=t@t -c user.name=t commit -qm init
  printf '%s\n' '{ "sync": { "paths": [".env"] } }' > "$d/main/.grove.json"
  seq 1 100 > "$d/main/.env"; seq 101 200 > "$d/wt/.env"     # >40 lines: truncation path
  GROVE="$GROVE" MAIN="$d/main" WT="$d/wt" run bash -c '
    source "$GROVE"
    set -o | grep -qE "^errexit[[:space:]]+on" || { echo "errexit off"; exit 9; }
    grove_sync_resolve_paths "$MAIN"
    rc=0; grove_sync_check "$MAIN" "$WT" || rc=$?
    echo "RC=$rc"'
  [[ "$output" == *"RC=1"* ]]
  [[ "$output" == *"diff truncated"* ]]
  [[ "$output" != *"errexit off"* ]]
}

# ---- bidirectional gap-fill + dotenv merge (issue #34) ----------------------

# A real main checkout + a real linked worktree. Both sides must be inside a git
# repo, because the copy consults `check-ignore` on the *receiving* side too.
_pair_fixture() {
  SRC="$BATS_TEST_TMPDIR/pair-main"; DST="$BATS_TEST_TMPDIR/pair-wt"
  mkdir -p "$SRC"
  git -C "$SRC" init -q -b main
  printf '%s\n' '.env' '.env.local' 'cfg/' '*.bin' 'proj/' > "$SRC/.gitignore"
  git -C "$SRC" add .gitignore
  git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$SRC" -c user.email=t@t -c user.name=t worktree add -q -b feat "$DST"
  printf '%s\n' '{ "sync": { "paths": [".env"] } }' > "$SRC/.grove.json"
  grove_config_load "$SRC"; grove_sync_resolve_paths "$SRC"
}

_pair_paths() {   # reconfigure the fixture's sync.paths without rebuilding it
  local json; json=$(printf '"%s",' "$@"); json="[${json%,}]"
  printf '{ "sync": { "paths": %s } }\n' "$json" > "$SRC/.grove.json"
  grove_config_load "$SRC"; grove_sync_resolve_paths "$SRC"
}

@test "sync_exchange: a path only in the worktree seeds the main checkout" {
  set +eu
  source "$GROVE"
  _pair_fixture
  printf 'BORN_HERE=1\n' > "$DST/.env"
  run grove_sync_exchange "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"seeded the main checkout from this worktree"* ]]
  [ "$(cat "$SRC/.env")" = "BORN_HERE=1" ]
  # …and the rm guard now passes, which was the whole point of #34.
  run grove_sync_check "$SRC" "$DST"
  [ "$status" -eq 0 ]
}

@test "sync_exchange: a main-only path is still copied into the worktree" {
  set +eu
  source "$GROVE"
  _pair_fixture
  printf 'FROM_MAIN=1\n' > "$SRC/.env"
  run grove_sync_exchange "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"synced from the main checkout"* ]]
  [ "$(cat "$DST/.env")" = "FROM_MAIN=1" ]
}

@test "sync_exchange: identical sides are a no-op" {
  set +eu
  source "$GROVE"
  _pair_fixture
  printf 'A=1\n' > "$SRC/.env"; printf 'A=1\n' > "$DST/.env"
  run grove_sync_exchange "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$SRC/.env")" = "A=1" ]
  [ "$(cat "$DST/.env")" = "A=1" ]
}

@test "sync_exchange: absent from both sides is reported, not fatal" {
  set +eu
  source "$GROVE"
  _pair_fixture
  run grove_sync_exchange "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"present in neither checkout"* ]]
}

@test "sync_exchange: disjoint dotenv keys merge both ways" {
  set +eu
  source "$GROVE"
  _pair_fixture
  printf '# main\nA=1\n'   > "$SRC/.env"
  printf 'B=2\nexport C=3\n' > "$DST/.env"
  run grove_sync_exchange "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged dotenv keys"* ]]
  grep -qx 'A=1' "$DST/.env"
  grep -qx 'B=2' "$SRC/.env"
  grep -qx 'export C=3' "$SRC/.env"      # the verbatim line crosses, export and all
  grep -qx '# main' "$SRC/.env"          # each file keeps its own comments/order
  [ "$(head -n1 "$SRC/.env")" = "# main" ]
  # Both sides now hold the same keys, so the guard passes without byte equality.
  run grove_sync_check "$SRC" "$DST"
  [ "$status" -eq 0 ]
}

@test "sync_exchange: the same key with two values is a conflict — exit 1, diff, nothing written" {
  set +eu
  source "$GROVE"
  _pair_fixture
  printf 'A=1\nONLY_MAIN=m\n' > "$SRC/.env"
  printf 'A=2\nONLY_WT=w\n'   > "$DST/.env"
  run grove_sync_exchange "$SRC" "$DST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sets these keys differently"* ]]
  [[ "$output" == *"A"* ]]
  [[ "$output" == *"-A=1"* ]]            # the diff is printed
  [[ "$output" == *"+A=2"* ]]
  [ "$(cat "$SRC/.env")" = "$(printf 'A=1\nONLY_MAIN=m')" ]   # untouched…
  [ "$(cat "$DST/.env")" = "$(printf 'A=2\nONLY_WT=w')" ]     # …on both sides
}

@test "sync_exchange: a conflicting path doesn't stop the other paths" {
  set +eu
  source "$GROVE"
  _pair_fixture
  _pair_paths ".env" ".env.local"
  printf 'A=1\n' > "$SRC/.env"; printf 'A=2\n' > "$DST/.env"
  printf 'LATER=1\n' > "$DST/.env.local"
  run grove_sync_exchange "$SRC" "$DST"
  [ "$status" -eq 1 ]
  [ "$(cat "$SRC/.env.local")" = "LATER=1" ]        # the innocent path still synced
}

@test "sync_exchange: a non-dotenv divergence is left alone with a warning" {
  set +eu
  source "$GROVE"
  _pair_fixture
  printf '{ "a": 1 }\n' > "$SRC/.env"
  printf '{ "a": 2 }\n' > "$DST/.env"
  run grove_sync_exchange "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"aren't dotenv"* ]]
  [[ "$output" == *"grove sync check"* ]]
  [ "$(cat "$SRC/.env")" = '{ "a": 1 }' ]
}

@test "sync_exchange: a directory path is filled per entry, in both directions" {
  set +eu
  source "$GROVE"
  _pair_fixture
  _pair_paths "cfg"
  mkdir -p "$SRC/cfg/keys" "$DST/cfg"
  printf 'm\n' > "$SRC/cfg/keys/from-main"
  printf 'w\n' > "$DST/cfg/from-wt"
  run grove_sync_exchange "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [ "$(cat "$DST/cfg/keys/from-main")" = "m" ]      # nested parents created
  [ "$(cat "$SRC/cfg/from-wt")" = "w" ]
}

@test "sync_exchange: a receiving side whose parent directory is missing" {
  set +eu
  source "$GROVE"
  _pair_fixture
  _pair_paths "proj/deep/.env"
  mkdir -p "$DST/proj/deep"; printf 'K=v\n' > "$DST/proj/deep/.env"
  run grove_sync_exchange "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [ "$(cat "$SRC/proj/deep/.env")" = "K=v" ]
}

@test "sync_exchange: a path that isn't gitignored on the receiving side is skipped" {
  set +eu
  source "$GROVE"
  _pair_fixture
  _pair_paths "loose.txt"
  printf 'LOOSE=1\n' > "$DST/loose.txt"             # untracked, but not ignored
  run grove_sync_exchange "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not gitignored"* ]]
  [ ! -e "$SRC/loose.txt" ]
}

@test "sync_exchange: a symlink is copied, never merged" {
  set +eu
  source "$GROVE"
  _pair_fixture
  printf 'S=1\n' > "$BATS_TEST_TMPDIR/shared.env"
  ln -s "$BATS_TEST_TMPDIR/shared.env" "$DST/.env"
  run grove_sync_exchange "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [ -L "$SRC/.env" ]
  [ "$(cat "$SRC/.env")" = "S=1" ]
}

# ---- the dotenv parser/merger itself ----------------------------------------

@test "dotenv_scan: accepts comments, blanks, export and CRLF; rejects the rest" {
  set +eu
  source "$GROVE"
  local f="$BATS_TEST_TMPDIR/e"
  printf '# c\n\n  export A=1\nB = 2\n' > "$f"
  grove_dotenv_scan "$f"
  [ "${GROVE_DOTENV_VAL[A]}" = "1" ]
  [ "${GROVE_DOTENV_VAL[B]}" = "2" ]
  printf 'A=1\r\nB=2\r\n' > "$f"                    # CRLF
  grove_dotenv_scan "$f"
  [ "${GROVE_DOTENV_VAL[A]}" = "1" ]
  [ "${GROVE_DOTENV_LINE[A]}" = "A=1" ]             # the CR never crosses over
  printf 'A=1\nnot a dotenv line\n' > "$f"
  ! grove_dotenv_scan "$f"
  printf 'A="multi\nline"\n' > "$f"                 # multi-line values: not ours
  ! grove_dotenv_scan "$f"
  printf 'A=1\n' > "$f"; printf '\000' >> "$f"      # binary
  ! grove_dotenv_scan "$f"
  ln -s "$f" "$BATS_TEST_TMPDIR/link.env"
  ! grove_dotenv_scan "$BATS_TEST_TMPDIR/link.env"
  : > "$f"                                          # empty file parses, no keys
  grove_dotenv_scan "$f"
  [ "${#GROVE_DOTENV_KEYS[@]}" -eq 0 ]
}

@test "dotenv_norm: quoting and surrounding space don't make a value different" {
  set +eu
  source "$GROVE"
  [ "$(grove_dotenv_norm 'foo')" = "foo" ]
  [ "$(grove_dotenv_norm '"foo"')" = "foo" ]
  [ "$(grove_dotenv_norm "'foo'")" = "foo" ]
  [ "$(grove_dotenv_norm '  foo  ')" = "foo" ]
  [ "$(grove_dotenv_norm '"a=b#c"')" = 'a=b#c' ]    # = and # inside quotes survive
  [ "$(grove_dotenv_norm '"')" = '"' ]              # a lone quote isn't a pair
}

@test "dotenv_merge: same value written two ways is not a conflict" {
  set +eu
  source "$GROVE"
  local a="$BATS_TEST_TMPDIR/a" b="$BATS_TEST_TMPDIR/b"
  printf 'A=foo\nM=1\n' > "$a"
  printf 'A="foo"\nW=2\n' > "$b"
  grove_dotenv_merge "$a" "$b"
  grep -qx 'W=2' "$a"
  grep -qx 'M=1' "$b"
  [ "$(grep -c '^A=' "$a")" -eq 1 ]                 # the shared key isn't duplicated
  [ "$(grep -c '^A=' "$b")" -eq 1 ]
}

@test "dotenv_merge: a file with no trailing newline gains one before the append" {
  set +eu
  source "$GROVE"
  local a="$BATS_TEST_TMPDIR/a" b="$BATS_TEST_TMPDIR/b"
  printf 'A=1' > "$a"                               # no final newline
  printf 'B=2\n' > "$b"
  grove_dotenv_merge "$a" "$b"
  grep -qx 'A=1' "$a"
  grep -qx 'B=2' "$a"
  [ "$(wc -l < "$a")" -eq 2 ]
}

@test "dotenv_merge: a duplicated key takes its last value, like a loader would" {
  set +eu
  source "$GROVE"
  local a="$BATS_TEST_TMPDIR/a" b="$BATS_TEST_TMPDIR/b"
  printf 'A=1\nA=2\n' > "$a"
  printf 'A=2\n' > "$b"
  grove_dotenv_merge "$a" "$b"                      # last-wins ⇒ no conflict
  [ "$(cat "$b")" = "A=2" ]
}

@test "sync_differs: dotenv files equal up to comments and order read as in sync" {
  set +eu
  source "$GROVE"
  local a="$BATS_TEST_TMPDIR/a" b="$BATS_TEST_TMPDIR/b"
  printf '# mine\nA=1\nB=2\n' > "$a"
  printf 'B="2"\nA=1\n'       > "$b"
  grove_sync_differs "$a" "$b"                      # 0 — same keys, same values
  printf 'B=3\nA=1\n' > "$b"
  ! grove_sync_differs "$a" "$b"                    # a changed value still differs
  printf 'A=1\n' > "$b"
  ! grove_sync_differs "$a" "$b"                    # a missing key still differs
}

# ---- the verb, end to end ---------------------------------------------------

@test "sync add: seeds the main checkout from this worktree immediately" {
  set +eu
  source "$GROVE"
  _pair_fixture
  rm -f "$SRC/.grove.json"
  printf 'BORN_HERE=1\n' > "$DST/.env"
  run bash -c "cd '$DST' && XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$GROVE' sync add .env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"seeded the main checkout from this worktree"* ]]
  [ "$(cat "$SRC/.env")" = "BORN_HERE=1" ]
  [ "$(jq -c '.sync.paths' "$DST/.grove.json")" = '[".env"]' ]
}

@test "sync: bare sync from the main checkout still refuses" {
  set +eu
  source "$GROVE"
  _pair_fixture
  run bash -c "cd '$SRC' && XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$GROVE' sync"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not the main checkout"* ]]
}

@test "sync: a conflict exits 1 from the command, not just the helper" {
  set +eu
  source "$GROVE"
  _pair_fixture
  printf 'A=1\n' > "$SRC/.env"; printf 'A=2\n' > "$DST/.env"
  run bash -c "cd '$DST' && XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$GROVE' sync"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sync incomplete"* ]]
}

@test "sync_exchange: a directory entry whose name contains a newline is one entry" {
  set +eu
  source "$GROVE"
  _pair_fixture
  _pair_paths "cfg"
  mkdir -p "$SRC/cfg" "$DST/cfg"
  printf 'x\n' > "$SRC/cfg/$(printf 'we\nird')"
  run grove_sync_exchange "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [ "$(cat "$DST/cfg/$(printf 'we\nird')")" = "x" ]
  [[ "$output" != *"present in neither"* ]]     # no phantom half-entries
}

@test "sync_exchange: a path git tracks on the receiving side is never resurrected" {
  set +eu
  source "$GROVE"
  _pair_fixture
  _pair_paths ".env"
  printf 'TRACKED=1\n' > "$SRC/.env"
  git -C "$SRC" add -f .env
  git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm env
  rm -f "$SRC/.env"                              # tracked in main, absent on disk
  printf 'MINE=1\n' > "$DST/.env"
  run grove_sync_exchange "$SRC" "$DST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracked by git"* ]]
  [ ! -e "$SRC/.env" ]
}
