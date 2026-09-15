#!/usr/bin/env bats

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/logging.sh"
    source "$REPO_ROOT/lib/state.sh"
    source "$REPO_ROOT/lib/compression.sh"

    LOG_FILE="$TEST_TMP_DIR/test.log"
    STATE_FILE="$TEST_TMP_DIR/state.json"
    LOCK_FILE="$TEST_TMP_DIR/state.lock"
    init_state "$STATE_FILE" "$LOCK_FILE"

    LOCAL_PATH="$TEST_TMP_DIR/drive"
    mkdir -p "$LOCAL_PATH"
}

teardown() {
    common_teardown
}

@test "compress_pdf marks a file under 10 KB as optimized without calling gs" {
    make_pdf_fixture "$LOCAL_PATH/small.pdf" 5000
    run compress_pdf "$LOG_FILE" ".optimized.pdf" "pdfwrite" 1024 \
        "$LOCAL_PATH/small.pdf" "$LOCAL_PATH"
    [ "$status" -eq 0 ]
    [ -f "$LOCAL_PATH/small.optimized.pdf" ]
    [ ! -f "$LOCAL_PATH/small.pdf" ]
}

@test "compress_pdf keeps the original and creates optimized on a size reduction" {
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    MOCK_GS_BEHAVIOR="smaller" run compress_pdf "$LOG_FILE" ".optimized.pdf" \
        "pdfwrite" 1024 "$LOCAL_PATH/big.pdf" "$LOCAL_PATH"
    [ "$status" -eq 0 ]
    [ -f "$LOCAL_PATH/big.optimized.pdf" ]
    [ ! -f "$LOCAL_PATH/big.pdf" ]
    [ "$(get_file_size "$LOCAL_PATH/big.optimized.pdf")" -lt 50000 ]
}

@test "compress_pdf renames to optimized without deleting when gs finds no reduction" {
    make_pdf_fixture "$LOCAL_PATH/same.pdf" 50000
    MOCK_GS_BEHAVIOR="no-reduction" run compress_pdf "$LOG_FILE" ".optimized.pdf" \
        "pdfwrite" 1024 "$LOCAL_PATH/same.pdf" "$LOCAL_PATH"
    [ "$status" -eq 0 ]
    [ -f "$LOCAL_PATH/same.optimized.pdf" ]
    [ ! -f "$LOCAL_PATH/same.pdf" ]
}

@test "compress_pdf preserves the original when gs output is too small" {
    make_pdf_fixture "$LOCAL_PATH/risky.pdf" 50000
    MOCK_GS_BEHAVIOR="too-small" run compress_pdf "$LOG_FILE" ".optimized.pdf" \
        "pdfwrite" 1024 "$LOCAL_PATH/risky.pdf" "$LOCAL_PATH"
    [ "$status" -eq 1 ]
    [ -f "$LOCAL_PATH/risky.pdf" ]
    [ ! -f "$LOCAL_PATH/risky.optimized.pdf" ]
}

@test "compress_pdf preserves the original when gs fails" {
    make_pdf_fixture "$LOCAL_PATH/fails.pdf" 50000
    MOCK_GS_BEHAVIOR="fail" run compress_pdf "$LOG_FILE" ".optimized.pdf" \
        "pdfwrite" 1024 "$LOCAL_PATH/fails.pdf" "$LOCAL_PATH"
    [ "$status" -eq 1 ]
    [ -f "$LOCAL_PATH/fails.pdf" ]
}

@test "compress_pdf rejects a path outside the allowed prefix" {
    local outside="$TEST_TMP_DIR/outside"
    mkdir -p "$outside"
    make_pdf_fixture "$outside/x.pdf" 50000
    run compress_pdf "$LOG_FILE" ".optimized.pdf" "pdfwrite" 1024 \
        "$outside/x.pdf" "$LOCAL_PATH"
    [ "$status" -eq 1 ]
}

@test "compress_drive_pdfs processes every pdf and reports a failure count" {
    make_pdf_fixture "$LOCAL_PATH/ok.pdf" 50000
    make_pdf_fixture "$LOCAL_PATH/broken.pdf" 50000
    MOCK_GS_BEHAVIOR="fail" run compress_drive_pdfs "$LOG_FILE" "$LOCAL_PATH" \
        ".optimized.pdf" "$STATE_FILE" "$LOCK_FILE" "pdfwrite" 1024 "$LOCAL_PATH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed (originals preserved): 2 files"* ]]
}

@test "compress_drive_pdfs skips files already carrying the optimized marker" {
    make_pdf_fixture "$LOCAL_PATH/already.optimized.pdf" 5000
    run compress_drive_pdfs "$LOG_FILE" "$LOCAL_PATH" ".optimized.pdf" \
        "$STATE_FILE" "$LOCK_FILE" "pdfwrite" 1024 "$LOCAL_PATH"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All PDFs are already optimized"* ]]
}

@test "compress_drive_pdfs logs total space saved on a successful batch compression" {
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    MOCK_GS_BEHAVIOR="smaller" run compress_drive_pdfs "$LOG_FILE" "$LOCAL_PATH" \
        ".optimized.pdf" "$STATE_FILE" "$LOCK_FILE" "pdfwrite" 1024 "$LOCAL_PATH"
    [ "$status" -eq 0 ]
    [[ "$output" =~ Total\ space\ saved:\ [0-9]+(\.[0-9]+)?\ (B|KiB|MiB|GiB) ]]
}
