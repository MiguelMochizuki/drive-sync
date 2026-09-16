#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/logging.sh"
    LOG_FILE="$TEST_TMP_DIR/test.log"
}

teardown() {
    common_teardown
}

@test "init_logging creates the log directory and file" {
    local nested="$TEST_TMP_DIR/nested/dir/test.log"
    init_logging "$nested"
    [ -d "$(dirname "$nested")" ]
}

@test "init_logging rotates a log file over 10 MB" {
    dd if=/dev/zero of="$LOG_FILE" bs=1M count=11 2>/dev/null
    init_logging "$LOG_FILE"
    [ -f "${LOG_FILE}.1" ]
    [ -f "$LOG_FILE" ]
    [ "$(stat -c%s "$LOG_FILE")" -eq 0 ]
}

@test "init_logging leaves a small log file alone" {
    printf 'existing line\n' > "$LOG_FILE"
    init_logging "$LOG_FILE"
    [ ! -f "${LOG_FILE}.1" ]
    grep -q "existing line" "$LOG_FILE"
}

@test "log_error goes to stderr, never stdout" {
    run --separate-stderr log_error "$LOG_FILE" "boom"
    [ -z "$output" ]
    [[ "$stderr" == *"[ERROR] boom"* ]]
    grep -q "\[ERROR\] boom" "$LOG_FILE"
}

@test "log_warning goes to stderr, never stdout" {
    run --separate-stderr log_warning "$LOG_FILE" "careful"
    [ -z "$output" ]
    [[ "$stderr" == *"[WARNING] careful"* ]]
    grep -q "\[WARNING\] careful" "$LOG_FILE"
}

@test "log_info is silent on the console by default" {
    run --separate-stderr log_info "$LOG_FILE" "hello"
    [ -z "$output" ]
    [ -z "$stderr" ]
    grep -q "\[INFO\] hello" "$LOG_FILE"
}

@test "log_success is silent on the console by default" {
    run --separate-stderr log_success "$LOG_FILE" "done"
    [ -z "$output" ]
    [ -z "$stderr" ]
    grep -q "\[SUCCESS\] done" "$LOG_FILE"
}
