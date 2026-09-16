#!/usr/bin/env bats

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/logging.sh"
    source "$REPO_ROOT/lib/state.sh"
    source "$REPO_ROOT/lib/limit.sh"
    LOG_FILE="$TEST_TMP_DIR/test.log"
    STATE_FILE="$TEST_TMP_DIR/state.json"
    LOCK_FILE="$TEST_TMP_DIR/state.lock"
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
}

teardown() {
    common_teardown
}

@test "is_rate_limit_error is true for 5 and 6, false otherwise" {
    is_rate_limit_error 5
    is_rate_limit_error 6
    ! is_rate_limit_error 7
    ! is_rate_limit_error 0
}

@test "is_fatal_error is true only for 7" {
    is_fatal_error 7
    ! is_fatal_error 5
    ! is_fatal_error 0
}

@test "recover_from_rate_limit succeeds and increments the recovery count" {
    run recover_from_rate_limit "$LOG_FILE" "drive:" "$STATE_FILE" "$LOCK_FILE" 0
    [ "$status" -eq 0 ]
    [ "$(get_state_value "$STATE_FILE" "rate_limit_recoveries")" = "1" ]
}

@test "recover_from_rate_limit fails when the connection probe fails" {
    export MOCK_RCLONE_ABOUT_EXIT=1
    run recover_from_rate_limit "$LOG_FILE" "drive:" "$STATE_FILE" "$LOCK_FILE" 0
    [ "$status" -eq 1 ]
    [ "$(get_state_value "$STATE_FILE" "rate_limit_recoveries")" = "0" ]
}
