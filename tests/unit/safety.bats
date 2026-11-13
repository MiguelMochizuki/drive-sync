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
    source "$REPO_ROOT/lib/safety.sh"

    mkdir -p "$TEST_TMP_DIR/local"
}

teardown() {
    common_teardown
}

@test "count_planned_deletions counts the Skipped delete lines of a rclone dry-run" {
    export MOCK_RCLONE_PLAN_DELETES=4
    run count_planned_deletions "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:"
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
}

@test "count_planned_deletions fails when the rclone dry-run itself fails" {
    export MOCK_RCLONE_PLAN_EXIT=1
    run count_planned_deletions "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:"
    [ "$status" -eq 1 ]
}

@test "count_dest_files counts local files for a directory destination" {
    touch "$TEST_TMP_DIR/local/a" "$TEST_TMP_DIR/local/b"
    run count_dest_files "$LOG_FILE" "$TEST_TMP_DIR/local"
    [ "$output" = "2" ]
}

@test "count_dest_files asks rclone lsf for a remote destination" {
    export MOCK_RCLONE_LSF_COUNT=7
    run count_dest_files "$LOG_FILE" "drive:"
    [ "$output" = "7" ]
}

@test "guard_deletions passes without prompting when nothing would be deleted" {
    export MOCK_RCLONE_PLAN_DELETES=0
    run guard_deletions "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "false"
    [ "$status" -eq 0 ]
}

@test "guard_deletions aborts when deletions exceed MAX_DELETE_PERCENT" {
    export MOCK_RCLONE_PLAN_DELETES=6 MOCK_RCLONE_LSF_COUNT=10
    run --separate-stderr guard_deletions "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "false"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"6 of 10"* ]]
}

@test "guard_deletions allows deletions exactly at MAX_DELETE_PERCENT" {
    export MOCK_RCLONE_PLAN_DELETES=5 MOCK_RCLONE_LSF_COUNT=10
    run guard_deletions "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "false"
    [ "$status" -eq 0 ]
}

@test "guard_deletions still aborts over the limit when FORCE is true" {
    export MOCK_RCLONE_PLAN_DELETES=9 MOCK_RCLONE_LSF_COUNT=10
    FORCE=true run guard_deletions "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "false"
    [ "$status" -eq 1 ]
}

@test "guard_deletions aborts when the plan cannot be computed" {
    export MOCK_RCLONE_PLAN_EXIT=1
    run guard_deletions "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "false"
    [ "$status" -eq 1 ]
}

@test "guard_deletions skips planning on a dry run" {
    export MOCK_RCLONE_PLAN_DELETES=9 MOCK_RCLONE_LSF_COUNT=10
    run guard_deletions "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "true"
    [ "$status" -eq 0 ]
    [ ! -f "$MOCK_STATE_DIR/rclone_plan.log" ]
}

@test "guard_deletions proceeds without a prompt when not interactive" {
    export MOCK_RCLONE_PLAN_DELETES=2 MOCK_RCLONE_LSF_COUNT=10
    is_interactive() { return 1; }
    run guard_deletions "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "false"
    [ "$status" -eq 0 ]
}

@test "guard_deletions asks on a terminal and aborts on a negative answer" {
    export MOCK_RCLONE_PLAN_DELETES=2 MOCK_RCLONE_LSF_COUNT=10
    is_interactive() { return 0; }
    run guard_deletions "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "false" <<< "n"
    [ "$status" -eq 1 ]
}

@test "guard_deletions asks on a terminal and proceeds on yes" {
    export MOCK_RCLONE_PLAN_DELETES=2 MOCK_RCLONE_LSF_COUNT=10
    is_interactive() { return 0; }
    run guard_deletions "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "false" <<< "y"
    [ "$status" -eq 0 ]
}

@test "guard_deletions does not ask on a terminal when FORCE is true" {
    export MOCK_RCLONE_PLAN_DELETES=2 MOCK_RCLONE_LSF_COUNT=10
    is_interactive() { return 0; }
    FORCE=true run guard_deletions "$LOG_FILE" "$TEST_TMP_DIR/local" "drive:" "false" <<< "n"
    [ "$status" -eq 0 ]
}
