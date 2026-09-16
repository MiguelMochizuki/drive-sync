#!/usr/bin/env bats

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/config.sh"
}

teardown() {
    common_teardown
}

@test "exit code constants match the documented contract" {
    [ "$EX_OK" -eq 0 ]
    [ "$EX_FAILURE" -eq 1 ]
    [ "$EX_USAGE" -eq 2 ]
    [ "$EX_UNAVAILABLE" -eq 69 ]
    [ "$EX_TEMPFAIL" -eq 75 ]
}

@test "get_version returns the version string" {
    result="$(get_version)"
    [ "$result" = "2.0.0" ]
}
