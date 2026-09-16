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

@test "build_rclone_flags includes --dry-run when requested" {
    result="$(build_rclone_flags "true")"
    [[ "$result" == *"--dry-run"* ]]
}

@test "build_rclone_flags omits --dry-run by default" {
    result="$(build_rclone_flags "false")"
    [[ "$result" != *"--dry-run"* ]]
}

@test "sync_to_drive returns 0 and records success state" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    run sync_to_drive "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "$STATE_FILE" "$LOCK_FILE" "false"
    [ "$status" -eq 0 ]
    [ "$(get_state_value "$STATE_FILE" "sync_status")" = "success" ]
}

@test "sync_to_drive returns 2 on rate limit exit codes 5 and 6" {
    export MOCK_RCLONE_EXIT_SEQUENCE="5"
    run sync_to_drive "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "$STATE_FILE" "$LOCK_FILE" "false"
    [ "$status" -eq 2 ]

    export MOCK_RCLONE_EXIT_SEQUENCE="6"
    run sync_to_drive "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "$STATE_FILE" "$LOCK_FILE" "false"
    [ "$status" -eq 2 ]
}

@test "sync_to_drive returns 3 and marks state failed on fatal exit code 7" {
    export MOCK_RCLONE_EXIT_SEQUENCE="7"
    run sync_to_drive "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "$STATE_FILE" "$LOCK_FILE" "false"
    [ "$status" -eq 3 ]
    [ "$(get_state_value "$STATE_FILE" "sync_status")" = "failed" ]
}

@test "sync_to_drive returns 1 on an unrecognized exit code" {
    export MOCK_RCLONE_EXIT_SEQUENCE="99"
    run sync_to_drive "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "$STATE_FILE" "$LOCK_FILE" "false"
    [ "$status" -eq 1 ]
}

@test "sync_from_drive returns 0 on success without touching state" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    run sync_from_drive "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "false"
    [ "$status" -eq 0 ]
}

@test "sync_from_drive returns 2 on a temporary error" {
    export MOCK_RCLONE_EXIT_SEQUENCE="5"
    run sync_from_drive "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "false"
    [ "$status" -eq 2 ]
}

@test "sync_from_drive uses rclone copy, never sync, so it never deletes local files" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    sync_from_drive "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "false"
    grep -q '^copy ' "$MOCK_STATE_DIR/rclone_calls.log"
    ! grep -q '^sync ' "$MOCK_STATE_DIR/rclone_calls.log"
}

@test "sync_to_drive still uses rclone sync, mirroring deletions to the remote" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    sync_to_drive "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "$STATE_FILE" "$LOCK_FILE" "false"
    grep -q '^sync ' "$MOCK_STATE_DIR/rclone_calls.log"
    ! grep -q '^copy ' "$MOCK_STATE_DIR/rclone_calls.log"
}
