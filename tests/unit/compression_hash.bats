#!/usr/bin/env bats

# compress_pdf and compress_drive_pdfs in TRACKING_MODE=hash: the file keeps
# its name, and state.json remembers which content is already optimized.

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

run_batch() {
    compress_drive_pdfs "$LOG_FILE" "$LOCAL_PATH" ".optimized.pdf" "$STATE_FILE" \
        "$LOCK_FILE" "pdfwrite" 1024 "$LOCAL_PATH"
}

@test "compress_pdf replaces the file in place when compression shrinks it" {
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    MOCK_GS_BEHAVIOR="smaller" run compress_pdf "$LOG_FILE" ".optimized.pdf" \
        "pdfwrite" 1024 "$LOCAL_PATH/big.pdf" "$LOCAL_PATH"
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$LOCAL_PATH/big.pdf")" -eq 25000 ]
    [ ! -e "$LOCAL_PATH/big.optimized.pdf" ]
}

@test "compress_pdf leaves a small file untouched and unrenamed" {
    make_pdf_fixture "$LOCAL_PATH/small.pdf" 5000
    run compress_pdf "$LOG_FILE" ".optimized.pdf" "pdfwrite" 1024 \
        "$LOCAL_PATH/small.pdf" "$LOCAL_PATH"
    [ "$status" -eq 0 ]
    [ -f "$LOCAL_PATH/small.pdf" ]
    [ ! -e "$LOCAL_PATH/small.optimized.pdf" ]
}

@test "compress_pdf leaves the file untouched when compression gains nothing" {
    make_pdf_fixture "$LOCAL_PATH/same.pdf" 50000
    MOCK_GS_BEHAVIOR="no-reduction" run compress_pdf "$LOG_FILE" ".optimized.pdf" \
        "pdfwrite" 1024 "$LOCAL_PATH/same.pdf" "$LOCAL_PATH"
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$LOCAL_PATH/same.pdf")" -eq 50000 ]
    [ ! -e "$LOCAL_PATH/same.optimized.pdf" ]
}

@test "compress_pdf keeps the original when gs fails" {
    make_pdf_fixture "$LOCAL_PATH/bad.pdf" 50000
    MOCK_GS_BEHAVIOR="fail" run compress_pdf "$LOG_FILE" ".optimized.pdf" \
        "pdfwrite" 1024 "$LOCAL_PATH/bad.pdf" "$LOCAL_PATH"
    [ "$status" -eq 1 ]
    [ "$(stat -c%s "$LOCAL_PATH/bad.pdf")" -eq 50000 ]
}

@test "compress_drive_pdfs records the new hash and the original size in state" {
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    run_batch
    [ "$(jq -r '.files["big.pdf"].hash' "$STATE_FILE")" = "$(sha256sum "$LOCAL_PATH/big.pdf" | cut -d' ' -f1)" ]
    [ "$(jq -r '.files["big.pdf"].original_size' "$STATE_FILE")" = "50000" ]
    [ "$(jq -r '.files["big.pdf"].size' "$STATE_FILE")" = "25000" ]
}

@test "compress_drive_pdfs records files in subdirectories by relative path" {
    mkdir -p "$LOCAL_PATH/sub"
    make_pdf_fixture "$LOCAL_PATH/sub/x.pdf" 50000
    run_batch
    [ "$(jq -r '.files | keys[0]' "$STATE_FILE")" = "sub/x.pdf" ]
}

@test "a second run skips files whose content is already tracked" {
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    run_batch
    MOCK_GS_BEHAVIOR="fail" run run_batch
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$LOCAL_PATH/big.pdf")" -eq 25000 ]
}

@test "a tracked file whose mtime changed but content did not is skipped without gs" {
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    run_batch
    touch -d "2001-01-01" "$LOCAL_PATH/big.pdf"
    MOCK_GS_BEHAVIOR="fail" run run_batch
    [ "$status" -eq 0 ]
}

@test "a tracked file whose content changed is processed again" {
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    run_batch
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 80000
    run_batch
    [ "$(stat -c%s "$LOCAL_PATH/big.pdf")" -eq 40000 ]
}

@test "a failed compression is not recorded and is retried on the next run" {
    make_pdf_fixture "$LOCAL_PATH/bad.pdf" 50000
    MOCK_GS_BEHAVIOR="fail" run run_batch
    [ "$status" -eq 1 ]
    [ "$(jq -r '.files | length' "$STATE_FILE")" = "0" ]
    MOCK_GS_BEHAVIOR="smaller" run run_batch
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$LOCAL_PATH/bad.pdf")" -eq 25000 ]
}

@test "legacy .optimized.pdf files are skipped and never renamed" {
    make_pdf_fixture "$LOCAL_PATH/old.optimized.pdf" 50000
    MOCK_GS_BEHAVIOR="fail" run run_batch
    [ "$status" -eq 0 ]
    [ -f "$LOCAL_PATH/old.optimized.pdf" ]
    [ "$(jq -r '.files | length' "$STATE_FILE")" = "0" ]
}
