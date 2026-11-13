#!/usr/bin/env bats

# With DRY_RUN=true, compression must be a no-op: no gs call, no file change,
# no state.json write. It only reports what it would process.

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

    # A failing gs turns any accidental call into a test failure.
    export MOCK_GS_BEHAVIOR="fail"
}

teardown() {
    common_teardown
}

run_batch() {
    compress_drive_pdfs "$LOG_FILE" "$LOCAL_PATH" ".optimized.pdf" "$STATE_FILE" \
        "$LOCK_FILE" "pdfwrite" 1024 "$LOCAL_PATH"
}

@test "dry run leaves the file bytes unchanged" {
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    cp "$LOCAL_PATH/big.pdf" "$TEST_TMP_DIR/big.copy"
    DRY_RUN=true run run_batch
    [ "$status" -eq 0 ]
    cmp "$LOCAL_PATH/big.pdf" "$TEST_TMP_DIR/big.copy"
}

@test "dry run adds no entry to state.json and keeps last_compression null" {
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    DRY_RUN=true run run_batch
    [ "$(jq -r '.files | length' "$STATE_FILE")" = "0" ]
    [ "$(jq -r '.last_compression' "$STATE_FILE")" = "null" ]
}

@test "dry run logs a Would compress line with the path and size" {
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    DRY_RUN=true run run_batch
    grep -q "Would compress: .*big.pdf" "$LOG_FILE"
    grep -q "Would compress 1 files" "$LOG_FILE"
}

@test "dry run lists a path with spaces whole" {
    make_pdf_fixture "$LOCAL_PATH/my doc.pdf" 50000
    DRY_RUN=true run run_batch
    grep -q "Would compress: $LOCAL_PATH/my doc.pdf" "$LOG_FILE"
}

@test "dry run in suffix mode does not rename the file" {
    TRACKING_MODE="suffix"
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    DRY_RUN=true run run_batch
    [ "$status" -eq 0 ]
    [ -f "$LOCAL_PATH/big.pdf" ]
    [ ! -e "$LOCAL_PATH/big.optimized.pdf" ]
}

@test "dry run skips tracked files and says everything is optimized" {
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    MOCK_GS_BEHAVIOR="smaller" run run_batch
    [ "$status" -eq 0 ]
    : > "$LOG_FILE"
    DRY_RUN=true run run_batch
    [ "$status" -eq 0 ]
    grep -q "All PDFs are already optimized" "$LOG_FILE"
    ! grep -q "Would compress" "$LOG_FILE"
}

@test "dry run on an empty directory does not write last_compression" {
    DRY_RUN=true run run_batch
    [ "$status" -eq 0 ]
    [ "$(jq -r '.last_compression' "$STATE_FILE")" = "null" ]
}

@test "dry run does not refresh the mtime of a tracked file" {
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    MOCK_GS_BEHAVIOR="smaller" run run_batch
    before=$(jq -r '.files["big.pdf"].mtime' "$STATE_FILE")
    touch -d "2001-01-01" "$LOCAL_PATH/big.pdf"
    DRY_RUN=true run run_batch
    [ "$status" -eq 0 ]
    [ "$(jq -r '.files["big.pdf"].mtime' "$STATE_FILE")" = "$before" ]
}

@test "DRY_RUN=false compresses as usual" {
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    DRY_RUN=false MOCK_GS_BEHAVIOR="smaller" run run_batch
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$LOCAL_PATH/big.pdf")" -eq 25000 ]
}

@test "compress_pdf under dry run returns 0 and leaves the file untouched" {
    make_pdf_fixture "$LOCAL_PATH/big.pdf" 50000
    DRY_RUN=true run compress_pdf "$LOG_FILE" ".optimized.pdf" "pdfwrite" 1024 \
        "$LOCAL_PATH/big.pdf" "$LOCAL_PATH"
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$LOCAL_PATH/big.pdf")" -eq 50000 ]
}
