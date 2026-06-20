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
