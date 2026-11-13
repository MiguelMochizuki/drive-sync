#!/usr/bin/env bats

# list_compress_candidates is the single source for "what a run would
# process". The real run and the plan command both read it.

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/logging.sh"
    source "$REPO_ROOT/lib/state.sh"
    source "$REPO_ROOT/lib/compression.sh"

    TRACKING_MODE="hash"
    LOG_FILE="$TEST_TMP_DIR/test.log"
    STATE_FILE="$TEST_TMP_DIR/state.json"
    LOCK_FILE="$TEST_TMP_DIR/state.lock"
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"

    LOCAL_PATH="$TEST_TMP_DIR/drive"
    mkdir -p "$LOCAL_PATH"
}

teardown() {
    common_teardown
}

candidates() {
    list_compress_candidates "$LOG_FILE" "$LOCAL_PATH" ".optimized.pdf" \
        "$STATE_FILE" "$LOCK_FILE"
}

run_batch() {
    compress_drive_pdfs "$LOG_FILE" "$LOCAL_PATH" ".optimized.pdf" "$STATE_FILE" \
        "$LOCK_FILE" "pdfwrite" 1024 "$LOCAL_PATH"
}

@test "lists an untracked pdf" {
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 50000
    mapfile -d '' -t out < <(candidates)
    [ "${#out[@]}" -eq 1 ]
    [ "${out[0]}" = "$LOCAL_PATH/a.pdf" ]
}

@test "skips a file carrying the optimized marker" {
    make_pdf_fixture "$LOCAL_PATH/a.optimized.pdf" 50000
    mapfile -d '' -t out < <(candidates)
    [ "${#out[@]}" -eq 0 ]
}

@test "skips a tracked unchanged file in hash mode" {
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 50000
    MOCK_GS_BEHAVIOR="smaller" run run_batch
    [ "$status" -eq 0 ]
    mapfile -d '' -t out < <(candidates)
    [ "${#out[@]}" -eq 0 ]
}

@test "keeps a path with spaces and a newline whole" {
    local name=$'odd name\nwith newline.pdf'
    make_pdf_fixture "$LOCAL_PATH/$name" 50000
    mapfile -d '' -t out < <(candidates)
    [ "${#out[@]}" -eq 1 ]
    [ "${out[0]}" = "$LOCAL_PATH/$name" ]
}

@test "compress_would_process is false for 5000 bytes in hash mode and true in suffix mode" {
    TRACKING_MODE="hash"
    run compress_would_process 5000
    [ "$status" -ne 0 ]
    TRACKING_MODE="suffix"
    run compress_would_process 5000
    [ "$status" -eq 0 ]
}

@test "compress_would_process is true for 50000 bytes in both modes" {
    TRACKING_MODE="hash"
    run compress_would_process 50000
    [ "$status" -eq 0 ]
    TRACKING_MODE="suffix"
    run compress_would_process 50000
    [ "$status" -eq 0 ]
}

@test "the real run still processes a small file in hash mode" {
    make_pdf_fixture "$LOCAL_PATH/small.pdf" 5000
    MOCK_GS_BEHAVIOR="fail" run run_batch
    [ "$status" -eq 0 ]
    [ "$(jq -r '.files | length' "$STATE_FILE")" = "1" ]
}

@test "dry run does not list a small file in hash mode" {
    make_pdf_fixture "$LOCAL_PATH/small.pdf" 5000
    DRY_RUN=true run run_batch
    [ "$status" -eq 0 ]
    run grep -q "Would compress" "$LOG_FILE"
    [ "$status" -ne 0 ]
    grep -q "All PDFs are already optimized" "$LOG_FILE"
}
