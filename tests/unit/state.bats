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

@test "init_state writes schema_version 2 and an empty files map in a new state" {
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
    [ "$(jq -r '.schema_version' "$STATE_FILE")" = "2" ]
    [ "$(jq -r '.files | length' "$STATE_FILE")" = "0" ]
}

@test "init_state migrates a v1 state: keeps its values and adds schema_version and files" {
    cp "$REPO_ROOT/tests/fixtures/state/after_sync.json" "$STATE_FILE"
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
    [ "$(jq -r '.schema_version' "$STATE_FILE")" = "2" ]
    [ "$(jq -r '.files | length' "$STATE_FILE")" = "0" ]
    [ "$(get_state_value "$STATE_FILE" "total_files_synced")" = "42" ]
}

@test "init_state backs up a v1 state before migrating it" {
    cp "$REPO_ROOT/tests/fixtures/state/after_sync.json" "$STATE_FILE"
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
    cmp "$REPO_ROOT/tests/fixtures/state/after_sync.json" "${STATE_FILE}.bak-v1"
}

@test "init_state does not back up or rewrite a state that is already v2" {
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
    [ ! -e "${STATE_FILE}.bak-v1" ]
}

@test "init_state leaves a corrupt state file alone and still returns 0" {
    echo "not json" > "$STATE_FILE"
    run init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE_FILE")" = "not json" ]
}

@test "record_file_state stores hash, sizes and mtime under the relative path" {
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
    record_file_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "docs/a b.pdf" "abc123" 1000 400 1700000000
    [ "$(jq -r '.files["docs/a b.pdf"].hash' "$STATE_FILE")" = "abc123" ]
    [ "$(jq -r '.files["docs/a b.pdf"].original_size' "$STATE_FILE")" = "1000" ]
    [ "$(jq -r '.files["docs/a b.pdf"].size' "$STATE_FILE")" = "400" ]
    [ "$(jq -r '.files["docs/a b.pdf"].mtime' "$STATE_FILE")" = "1700000000" ]
}

@test "record_file_state keeps the first original_size when a file is recorded again" {
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
    record_file_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "a.pdf" "h1" 1000 400 1
    record_file_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "a.pdf" "h1" 400 400 2
    [ "$(jq -r '.files["a.pdf"].original_size' "$STATE_FILE")" = "1000" ]
    [ "$(jq -r '.files["a.pdf"].mtime' "$STATE_FILE")" = "2" ]
}

@test "list_tracked_files prints path, hash, size and mtime separated by tabs" {
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
    record_file_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "a.pdf" "h1" 1000 400 5
    run list_tracked_files "$STATE_FILE"
    [ "$output" = "$(printf 'a.pdf\th1\t400\t5')" ]
}
