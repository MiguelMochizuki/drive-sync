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

@test "init_state creates the documented default schema" {
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
    [ "$(get_state_value "$STATE_FILE" "sync_status")" = "idle" ]
    [ "$(get_state_value "$STATE_FILE" "rate_limit_recoveries")" = "0" ]
    [ "$(get_state_value "$STATE_FILE" "last_sync")" = "null" ]
}

@test "init_state does nothing when the state file already exists" {
    cp "$REPO_ROOT/tests/fixtures/state/after_sync.json" "$STATE_FILE"
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
    [ "$(get_state_value "$STATE_FILE" "total_files_synced")" = "42" ]
}

@test "update_state changes one key and preserves the rest" {
    cp "$REPO_ROOT/tests/fixtures/state/idle.json" "$STATE_FILE"
    update_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "sync_status" "success"
    [ "$(get_state_value "$STATE_FILE" "sync_status")" = "success" ]
    [ "$(get_state_value "$STATE_FILE" "rate_limit_recoveries")" = "0" ]
}

@test "get_state_value returns null text for a missing key" {
    cp "$REPO_ROOT/tests/fixtures/state/idle.json" "$STATE_FILE"
    result="$(get_state_value "$STATE_FILE" "no_such_key")"
    [ "$result" = "null" ]
}

@test "acquire_lock then release_lock succeeds" {
    touch "$LOCK_FILE"
    run bash -c "source '$REPO_ROOT/lib/logging.sh'; source '$REPO_ROOT/lib/state.sh'; acquire_lock '$LOG_FILE' '$LOCK_FILE' && release_lock && echo OK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
