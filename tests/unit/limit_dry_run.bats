#!/usr/bin/env bats

# A dry run must not clean up the remote or write state while recovering
# from a rate limit. rclone cleanup empties the Google Drive trash.

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/logging.sh"
    source "$REPO_ROOT/lib/state.sh"
    source "$REPO_ROOT/lib/limit.sh"
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
}

teardown() {
    common_teardown
}

@test "recover_from_rate_limit in dry run runs no cleanup and no cache clear" {
    DRY_RUN=true run recover_from_rate_limit "$LOG_FILE" "drive:" "$STATE_FILE" "$LOCK_FILE" 0
    [ "$status" -eq 0 ]
    ! grep -q '^cleanup\|^cache' "$MOCK_STATE_DIR/rclone_calls.log"
}

@test "recover_from_rate_limit in dry run leaves the state untouched" {
    DRY_RUN=true run recover_from_rate_limit "$LOG_FILE" "drive:" "$STATE_FILE" "$LOCK_FILE" 0
    [ "$(get_state_value "$STATE_FILE" "rate_limit_recoveries")" = "0" ]
    [ "$(get_state_value "$STATE_FILE" "last_rate_limit")" = "null" ]
}

@test "recover_from_rate_limit in dry run still probes the connection" {
    DRY_RUN=true run recover_from_rate_limit "$LOG_FILE" "drive:" "$STATE_FILE" "$LOCK_FILE" 0
    grep -q '^about' "$MOCK_STATE_DIR/rclone_calls.log"
}

@test "recover_from_rate_limit in dry run reports a failed probe" {
    export MOCK_RCLONE_ABOUT_EXIT=1
    DRY_RUN=true run recover_from_rate_limit "$LOG_FILE" "drive:" "$STATE_FILE" "$LOCK_FILE" 0
    [ "$status" -eq 1 ]
}

@test "recover_from_rate_limit never empties the Drive trash and records the recovery" {
    run recover_from_rate_limit "$LOG_FILE" "drive:" "$STATE_FILE" "$LOCK_FILE" 0
    [ "$status" -eq 0 ]
    [ "$(get_state_value "$STATE_FILE" "rate_limit_recoveries")" = "1" ]
    run grep -q '^cleanup' "$MOCK_STATE_DIR/rclone_calls.log"
    [ "$status" -ne 0 ]
}
