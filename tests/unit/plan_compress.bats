#!/usr/bin/env bats

# The compress section of the plan: candidate list, savings estimate from
# state.json history, and the optional measured figure.

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/logging.sh"
    source "$REPO_ROOT/lib/state.sh"
    source "$REPO_ROOT/lib/compression.sh"
    source "$REPO_ROOT/lib/plan.sh"

    TRACKING_MODE="hash"
    LOG_FILE="$TEST_TMP_DIR/test.log"
    STATE_FILE="$TEST_TMP_DIR/state.json"
    LOCK_FILE="$TEST_TMP_DIR/state.lock"
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"

    LOCAL_PATH="$TEST_TMP_DIR/drive"
    mkdir -p "$LOCAL_PATH"

    export TMPDIR="$TEST_TMP_DIR/tmp"
    mkdir -p "$TMPDIR"
}

teardown() {
    common_teardown
}

seed_history() {
    record_file_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "x.pdf" "h1" 1000 500 1
    record_file_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "y.pdf" "h2" 2000 2000 1
}

section() {
    plan_compress_json "$LOG_FILE" "$LOCAL_PATH" ".optimized.pdf" "$STATE_FILE" \
        "$LOCK_FILE" "pdfwrite" 1024 "${1:-false}"
}

@test "ratio comes from every entry in state" {
    seed_history
    [ "$(plan_estimate_ratio "$STATE_FILE")" = "0.1667" ]
}

@test "ratio is null on an empty state" {
    [ "$(plan_estimate_ratio "$STATE_FILE")" = "null" ]
}

@test "ratio is null when original sizes sum to zero" {
    record_file_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "z.pdf" "h3" 0 0 1
    [ "$(plan_estimate_ratio "$STATE_FILE")" = "null" ]
}

@test "history estimate applies the ratio to pending bytes" {
    seed_history
    make_pdf_fixture "$LOCAL_PATH/p.pdf" 30000
    out=$(section)
    [ "$(jq -r '.estimate.method' <<< "$out")" = "history" ]
    [ "$(jq -r '.estimate.saved_bytes' <<< "$out")" = "5000" ]
    [ "$(jq -r '.total_bytes' <<< "$out")" = "30000" ]
    [ "$(jq -r '.candidates[0].path' <<< "$out")" = "p.pdf" ]
}

@test "no estimate without history" {
    make_pdf_fixture "$LOCAL_PATH/p.pdf" 30000
    out=$(section)
    [ "$(jq -r '.estimate.method' <<< "$out")" = "null" ]
    [ "$(jq -r '.estimate.saved_bytes' <<< "$out")" = "null" ]
}

@test "small files are not candidates in hash mode" {
    make_pdf_fixture "$LOCAL_PATH/small.pdf" 5000
    out=$(section)
    [ "$(jq -r '.candidates | length' <<< "$out")" = "0" ]
    [ "$(jq -r '.total_bytes' <<< "$out")" = "0" ]
}

@test "measure reports the real saving and leaves nothing behind" {
    make_pdf_fixture "$LOCAL_PATH/p.pdf" 50000
    before=$(cd "$LOCAL_PATH" && find . | sort)
    MOCK_GS_BEHAVIOR="smaller" run section true
    out="$output"
    [ "$(jq -r '.candidates[0].measured_saved' <<< "$out")" = "25000" ]
    [ "$(jq -r '.estimate.method' <<< "$out")" = "measured" ]
    [ "$(jq -r '.estimate.saved_bytes' <<< "$out")" = "25000" ]
    [ "$(stat -c%s "$LOCAL_PATH/p.pdf")" = "50000" ]
    [ "$(cd "$LOCAL_PATH" && find . | sort)" = "$before" ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "measure with a failing gs gives null, exits 0 and leaves nothing" {
    make_pdf_fixture "$LOCAL_PATH/p.pdf" 50000
    MOCK_GS_BEHAVIOR="fail" run section true
    [ "$status" -eq 0 ]
    [ "$(jq -r '.candidates[0].measured_saved' <<< "$output")" = "null" ]
    [ "$(jq -r '.estimate.saved_bytes' <<< "$output")" = "0" ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "measure counts a too small output as zero saved" {
    make_pdf_fixture "$LOCAL_PATH/p.pdf" 50000
    MOCK_GS_BEHAVIOR="too-small" run section true
    [ "$(jq -r '.candidates[0].measured_saved' <<< "$output")" = "0" ]
}

@test "a path with a quote and spaces stays valid JSON" {
    make_pdf_fixture "$LOCAL_PATH/my \"odd\" doc.pdf" 50000
    out=$(section)
    jq -e . <<< "$out" > /dev/null
    [ "$(jq -r '.candidates[0].path' <<< "$out")" = 'my "odd" doc.pdf' ]
}

@test "the section leaves state.json byte-identical, even for a touched tracked file" {
    make_pdf_fixture "$LOCAL_PATH/p.pdf" 50000
    MOCK_GS_BEHAVIOR="smaller" compress_drive_pdfs "$LOG_FILE" "$LOCAL_PATH" \
        ".optimized.pdf" "$STATE_FILE" "$LOCK_FILE" "pdfwrite" 1024 "$LOCAL_PATH"
    touch -d "2001-01-01" "$LOCAL_PATH/p.pdf"
    cp "$STATE_FILE" "$TEST_TMP_DIR/state.copy"
    section > /dev/null
    cmp "$STATE_FILE" "$TEST_TMP_DIR/state.copy"
}
