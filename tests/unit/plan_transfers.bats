#!/usr/bin/env bats

# The transfers and deletions section of the plan, built from rclone dry runs.

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/logging.sh"
    source "$REPO_ROOT/lib/state.sh"
    source "$REPO_ROOT/lib/limit.sh"
    source "$REPO_ROOT/lib/sync_ops.sh"
    source "$REPO_ROOT/lib/safety.sh"
    source "$REPO_ROOT/lib/plan.sh"

    mkdir -p "$TEST_TMP_DIR/local"
}

teardown() {
    common_teardown
}

@test "push counts copies and deletions from the dry run" {
    export MOCK_RCLONE_PLAN_COPIES=3 MOCK_RCLONE_PLAN_DELETES=2 MOCK_RCLONE_LSF_COUNT=10
    run plan_transfer_json "$LOG_FILE" push "$TEST_TMP_DIR/local" "drive:"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.copy_files' <<< "$output")" = "3" ]
    [ "$(jq -r '.delete.count' <<< "$output")" = "2" ]
    [ "$(jq -r '.delete.total' <<< "$output")" = "10" ]
    [ "$(jq -r '.delete.percent' <<< "$output")" = "20" ]
    [ "$(jq -r '.delete.limit' <<< "$output")" = "50" ]
    [ "$(jq -r '.delete.would_abort' <<< "$output")" = "false" ]
}

@test "would_abort is true above the limit and false at it" {
    export MOCK_RCLONE_LSF_COUNT=10
    MOCK_RCLONE_PLAN_DELETES=6 run plan_transfer_json "$LOG_FILE" push "$TEST_TMP_DIR/local" "drive:"
    [ "$(jq -r '.delete.would_abort' <<< "$output")" = "true" ]
    MOCK_RCLONE_PLAN_DELETES=5 run plan_transfer_json "$LOG_FILE" push "$TEST_TMP_DIR/local" "drive:"
    [ "$(jq -r '.delete.would_abort' <<< "$output")" = "false" ]
}

@test "no deletions means a zero count and no abort" {
    export MOCK_RCLONE_LSF_COUNT=10
    run plan_transfer_json "$LOG_FILE" push "$TEST_TMP_DIR/local" "drive:"
    [ "$(jq -r '.delete.count' <<< "$output")" = "0" ]
    [ "$(jq -r '.delete.would_abort' <<< "$output")" = "false" ]
}

@test "pull uses copy and reports no deletions" {
    export MOCK_RCLONE_PLAN_COPIES=4
    run plan_transfer_json "$LOG_FILE" pull "$TEST_TMP_DIR/local" "drive:"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.copy_files' <<< "$output")" = "4" ]
    [ "$(jq -r '.delete' <<< "$output")" = "null" ]
    grep -q "^copy drive: $TEST_TMP_DIR/local " "$MOCK_STATE_DIR/rclone_plan.log"
}

@test "update runs sync with the remote first" {
    run plan_transfer_json "$LOG_FILE" update "$TEST_TMP_DIR/local" "drive:"
    [ "$status" -eq 0 ]
    grep -q "^sync drive: $TEST_TMP_DIR/local " "$MOCK_STATE_DIR/rclone_plan.log"
}

@test "push runs sync with the local directory first" {
    export MOCK_RCLONE_LSF_COUNT=1
    run plan_transfer_json "$LOG_FILE" push "$TEST_TMP_DIR/local" "drive:"
    grep -q "^sync $TEST_TMP_DIR/local drive: " "$MOCK_STATE_DIR/rclone_plan.log"
}

@test "the real sync and copy are never called" {
    export MOCK_RCLONE_LSF_COUNT=1
    plan_transfer_json "$LOG_FILE" push "$TEST_TMP_DIR/local" "drive:" > /dev/null
    plan_transfer_json "$LOG_FILE" pull "$TEST_TMP_DIR/local" "drive:" > /dev/null
    ! grep -qE "^(sync|copy) " "$MOCK_STATE_DIR/rclone_calls.log" 2>/dev/null
}

@test "a failing dry run returns 1, logs an error and prints nothing" {
    export MOCK_RCLONE_PLAN_EXIT=1
    run --separate-stderr plan_transfer_json "$LOG_FILE" push "$TEST_TMP_DIR/local" "drive:"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}
