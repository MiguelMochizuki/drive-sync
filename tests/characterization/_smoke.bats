#!/usr/bin/env bats

load '../test_helper'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

@test "HOME is isolated to a temp directory" {
    [[ "$HOME" == "$TEST_TMP_DIR/home" ]]
    [[ -d "$HOME" ]]
}

@test "mock rclone is first on PATH" {
    run command -v rclone
    [ "$status" -eq 0 ]
    [[ "$output" == "$REPO_ROOT/tests/mocks/rclone" ]]
}

@test "mock rclone sync exits per MOCK_RCLONE_EXIT_SEQUENCE, then holds the last value" {
    export MOCK_RCLONE_EXIT_SEQUENCE="5,0"

    run rclone sync /tmp/a drive:
    [ "$status" -eq 5 ]

    run rclone sync /tmp/a drive:
    [ "$status" -eq 0 ]

    run rclone sync /tmp/a drive:
    [ "$status" -eq 0 ]
}

@test "mock rclone logs every call" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    rclone sync /tmp/a drive: --dry-run
    [ "$(wc -l < "$MOCK_STATE_DIR/rclone_calls.log")" -eq 1 ]
    grep -q -- "--dry-run" "$MOCK_STATE_DIR/rclone_calls.log"
}

@test "mock gs writes a smaller output file by default" {
    local input="$TEST_TMP_DIR/in.pdf"
    local output="$TEST_TMP_DIR/out.pdf"
    make_pdf_fixture "$input" 1000
    gs -sDEVICE=pdfwrite -sOutputFile="$output" "$input"
    local out_size
    out_size=$(stat -c%s "$output")
    [ "$out_size" -lt 1000 ]
}

@test "mock gs fails when told to" {
    local input="$TEST_TMP_DIR/in.pdf"
    local output="$TEST_TMP_DIR/out.pdf"
    make_pdf_fixture "$input" 1000
    MOCK_GS_BEHAVIOR="fail" run gs -sDEVICE=pdfwrite -sOutputFile="$output" "$input"
    [ "$status" -eq 1 ]
    [ ! -f "$output" ]
}
