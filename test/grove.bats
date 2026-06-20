#!/usr/bin/env bats
# Smoke tests for the grove CLI. cmux/worktrunk-dependent flows aren't exercised
# here (no cmux in CI); those are validated manually. See README "How it works".

GROVE="${BATS_TEST_DIRNAME}/../bin/grove"

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
