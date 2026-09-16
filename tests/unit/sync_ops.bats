#!/usr/bin/env bats

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/logging.sh"
    source "$REPO_ROOT/lib/state.sh"
    source "$REPO_ROOT/lib/limit.sh"
    source "$REPO_ROOT/lib/sync_ops.sh"

    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
}

teardown() {
    common_teardown
}

@test "three sequential sync_to_drive calls consume the mock sequence in order" {
    export MOCK_RCLONE_EXIT_SEQUENCE="5,5,0"

    run sync_to_drive "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "$STATE_FILE" "$LOCK_FILE" "false"
    [ "$status" -eq 2 ]

    run sync_to_drive "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "$STATE_FILE" "$LOCK_FILE" "false"
    [ "$status" -eq 2 ]

    run sync_to_drive "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "$STATE_FILE" "$LOCK_FILE" "false"
    [ "$status" -eq 0 ]

    [ "$(wc -l < "$MOCK_STATE_DIR/rclone_calls.log")" -eq 3 ]
}

@test "a fatal exit code on the first call needs no further calls" {
    export MOCK_RCLONE_EXIT_SEQUENCE="7,0,0"

    run sync_to_drive "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "$STATE_FILE" "$LOCK_FILE" "false"
    [ "$status" -eq 3 ]

    [ "$(wc -l < "$MOCK_STATE_DIR/rclone_calls.log")" -eq 1 ]
}

@test "sync_to_drive passes --dry-run through to rclone when requested" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    sync_to_drive "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "$STATE_FILE" "$LOCK_FILE" "true"
    grep -q -- "--dry-run" "$MOCK_STATE_DIR/rclone_calls.log"
}
