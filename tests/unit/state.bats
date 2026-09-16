#!/usr/bin/env bats

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/logging.sh"
    source "$REPO_ROOT/lib/state.sh"
    LOG_FILE="$TEST_TMP_DIR/test.log"
    STATE_FILE="$TEST_TMP_DIR/state.json"
    LOCK_FILE="$TEST_TMP_DIR/state.lock"
}

teardown() {
    common_teardown
}

@test "init_state accepts a log_file as its first argument" {
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
    [ -f "$STATE_FILE" ]
}

@test "update_state accepts a log_file as its first argument" {
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
    update_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "sync_status" "success"
    [ "$(get_state_value "$STATE_FILE" "sync_status")" = "success" ]
}

@test "update_state on a missing state file logs an error to the log file" {
    run --separate-stderr update_state "$LOG_FILE" "$TEST_TMP_DIR/missing.json" "$LOCK_FILE" "k" "v"
    [ "$status" -eq 1 ]
    grep -q "\[ERROR\]" "$LOG_FILE"
}
