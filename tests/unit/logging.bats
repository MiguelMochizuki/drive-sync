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

@test "log_error goes to stderr by default, never stdout" {
    run --separate-stderr log_error "$LOG_FILE" "boom"
    [[ "$output" != *"boom"* ]]
    [[ "$stderr" == *"[ERROR] boom"* ]]
}

@test "log_warning goes to stderr by default, never stdout" {
    run --separate-stderr log_warning "$LOG_FILE" "careful"
    [[ "$output" != *"careful"* ]]
    [[ "$stderr" == *"[WARNING] careful"* ]]
}

@test "log_info is silent on the console by default, but reaches the log file" {
    run --separate-stderr log_info "$LOG_FILE" "hello"
    [ -z "$output" ]
    [ -z "$stderr" ]
    grep -q "\[INFO\] hello" "$LOG_FILE"
}

@test "log_success is silent on the console by default, but reaches the log file" {
    run --separate-stderr log_success "$LOG_FILE" "done"
    [ -z "$output" ]
    [ -z "$stderr" ]
    grep -q "\[SUCCESS\] done" "$LOG_FILE"
}

@test "with VERBOSE true, log_info reaches stdout" {
    VERBOSE="true" run --separate-stderr log_info "$LOG_FILE" "hello"
    [[ "$output" == *"[INFO] hello"* ]]
    [ -z "$stderr" ]
}

@test "with VERBOSE true, log_success reaches stdout" {
    VERBOSE="true" run --separate-stderr log_success "$LOG_FILE" "done"
    [[ "$output" == *"[SUCCESS] done"* ]]
}

@test "with VERBOSE true, log_error still goes to stderr, not stdout" {
    VERBOSE="true" run --separate-stderr log_error "$LOG_FILE" "boom"
    [[ "$output" != *"boom"* ]]
    [[ "$stderr" == *"[ERROR] boom"* ]]
}

@test "every level always reaches the log file regardless of VERBOSE" {
    log_error "$LOG_FILE" "a" >/dev/null 2>&1
    log_warning "$LOG_FILE" "b" >/dev/null 2>&1
    log_info "$LOG_FILE" "c" >/dev/null 2>&1
    log_success "$LOG_FILE" "d" >/dev/null 2>&1
    grep -q "\[ERROR\] a" "$LOG_FILE"
    grep -q "\[WARNING\] b" "$LOG_FILE"
    grep -q "\[INFO\] c" "$LOG_FILE"
    grep -q "\[SUCCESS\] d" "$LOG_FILE"
}
