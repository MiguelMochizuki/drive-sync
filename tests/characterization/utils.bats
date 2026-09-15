#!/usr/bin/env bats

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/utils.sh"
}

teardown() {
    common_teardown
}

@test "validate_path accepts a path under an allowed prefix" {
    local allowed="$TEST_TMP_DIR/allowed"
    mkdir -p "$allowed"
    run validate_path "$allowed/file.pdf" "$allowed"
    [ "$status" -eq 0 ]
    [[ "$output" == "$allowed/file.pdf" ]]
}

@test "validate_path rejects a path outside every allowed prefix" {
    local allowed="$TEST_TMP_DIR/allowed"
    local outside="$TEST_TMP_DIR/outside"
    mkdir -p "$allowed" "$outside"
    run validate_path "$outside/file.pdf" "$allowed"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Path not allowed"* ]]
}

@test "calculate_percentage returns 0 without dividing when original is 0" {
    result="$(calculate_percentage 0 500)"
    [ "$result" = "0" ]
}

@test "calculate_percentage reduction, format depends on bc availability" {
    result="$(calculate_percentage 1000 600)"
    [[ "$result" =~ ^40(\.00)?$ ]]
}

@test "calculate_quota_percentage returns 0 without dividing when total is 0" {
    result="$(calculate_quota_percentage 250 0)"
    [ "$result" = "0" ]
}

@test "calculate_quota_percentage computes a used over total ratio" {
    result="$(calculate_quota_percentage 250 1000)"
    [[ "$result" =~ ^25(\.00)?$ ]]
}

@test "get_file_size returns the byte size of an existing file" {
    make_pdf_fixture "$TEST_TMP_DIR/f.pdf" 12345
    result="$(get_file_size "$TEST_TMP_DIR/f.pdf")"
    [ "$result" = "12345" ]
}

@test "get_file_size returns 0 and fails for a missing file" {
    run get_file_size "$TEST_TMP_DIR/missing.pdf"
    [ "$status" -eq 1 ]
    [ "$output" = "0" ]
}

@test "format_bytes_decimal below 1000 bytes uses the B unit" {
    result="$(format_bytes_decimal 999)"
    [ "$result" = "999 B" ]
}

@test "format_bytes_decimal at an exact multiple uses the KB unit" {
    result="$(format_bytes_decimal 5000)"
    [ "$result" = "5.00 KB" ]
}

@test "format_bytes_decimal at an exact multiple uses the MB unit" {
    result="$(format_bytes_decimal 3000000)"
    [ "$result" = "3.00 MB" ]
}

@test "format_bytes_decimal at an exact multiple uses the GB unit" {
    result="$(format_bytes_decimal 4000000000)"
    [ "$result" = "4.00 GB" ]
}
