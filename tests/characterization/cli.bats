#!/usr/bin/env bats

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/logging.sh"
    source "$REPO_ROOT/lib/state.sh"
    source "$REPO_ROOT/lib/storage.sh"
    source "$REPO_ROOT/lib/cli.sh"

    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"

    mkdir -p "$LOCAL_PATH"

    export MOCK_RCLONE_ABOUT_JSON='{"used":0,"total":0}'
}

teardown() {
    common_teardown
}

@test "show_help lists every command" {
    run show_help
    [[ "$output" == *"push"* ]]
    [[ "$output" == *"pull"* ]]
    [[ "$output" == *"sync"* ]]
    [[ "$output" == *"status"* ]]
    [[ "$output" == *"ratelimit"* ]]
}

@test "show_status reports zero pdfs on an empty directory" {
    run show_status "$LOG_FILE" "$STATE_FILE" "drive:" "$LOCAL_PATH" ".optimized.pdf"
    [[ "$output" == *"PDFs: 0 total"* ]]
}

@test "show_status counts optimized and pending pdfs separately" {
    make_pdf_fixture "$LOCAL_PATH/a.optimized.pdf" 1000
    make_pdf_fixture "$LOCAL_PATH/b.pdf" 2000
    run show_status "$LOG_FILE" "$STATE_FILE" "drive:" "$LOCAL_PATH" ".optimized.pdf"
    [[ "$output" == *"PDFs: 2 total"* ]]
    [[ "$output" == *"Optimized: 1"* ]]
    [[ "$output" == *"Pending: 1"* ]]
}

@test "show_status reflects last_sync from state" {
    update_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "last_sync" "2026-01-01T00:00:00+00:00"
    run show_status "$LOG_FILE" "$STATE_FILE" "drive:" "$LOCAL_PATH" ".optimized.pdf"
    [[ "$output" == *"2026-01-01T00:00:00+00:00"* ]]
}

@test "show_status reports total size using format_size units" {
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 2097152
    run show_status "$LOG_FILE" "$STATE_FILE" "drive:" "$LOCAL_PATH" ".optimized.pdf"
    [[ "$output" =~ Size:\ [0-9]+(\.[0-9]+)?\ (B|KiB|MiB|GiB) ]]
}
