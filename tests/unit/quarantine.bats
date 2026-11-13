#!/usr/bin/env bats

# The quarantine keeps every original that compression replaces, prunes by
# age, and lets restore put one back. It does not source config.sh, so the
# settings below can be changed per test.

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/logging.sh"
    source "$REPO_ROOT/lib/state.sh"
    source "$REPO_ROOT/lib/quarantine.sh"
    source "$REPO_ROOT/lib/compression.sh"

    TRACKING_MODE="hash"
    QUARANTINE_DIR="$TEST_TMP_DIR/originals"
    QUARANTINE_RETENTION_DAYS=30
    ARCHIVE_DIR="$TEST_TMP_DIR/archive"
    LOG_FILE="$TEST_TMP_DIR/test.log"
    STATE_FILE="$TEST_TMP_DIR/state.json"
    LOCK_FILE="$TEST_TMP_DIR/state.lock"
    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"

    LOCAL_PATH="$TEST_TMP_DIR/drive"
    mkdir -p "$LOCAL_PATH"
    export MOCK_GS_BEHAVIOR="smaller"
}

teardown() {
    common_teardown
}

compress_one() {
    compress_pdf "$LOG_FILE" ".optimized.pdf" "pdfwrite" 1024 "$1" "$LOCAL_PATH"
}

run_batch() {
    compress_drive_pdfs "$LOG_FILE" "$LOCAL_PATH" ".optimized.pdf" "$STATE_FILE" \
        "$LOCK_FILE" "pdfwrite" 1024 "$LOCAL_PATH"
}

stamp() {
    date -u -d "$1 days ago" +%Y%m%dT%H%M%S
}

entries() {
    find "$QUARANTINE_DIR" -type f 2>/dev/null | sort
}

@test "compression keeps the original in the quarantine and replaces the file" {
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 50000
    cp "$LOCAL_PATH/a.pdf" "$TEST_TMP_DIR/a.copy"
    run compress_one "$LOCAL_PATH/a.pdf"
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$LOCAL_PATH/a.pdf")" -eq 25000 ]
    [ "$(entries | wc -l)" -eq 1 ]
    cmp "$(entries)" "$TEST_TMP_DIR/a.copy"
    [[ "$(entries)" == "$QUARANTINE_DIR/a.pdf/"* ]]
}

@test "a file that did not shrink is not quarantined" {
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 50000
    MOCK_GS_BEHAVIOR="no-reduction" run compress_one "$LOCAL_PATH/a.pdf"
    [ "$status" -eq 0 ]
    [ -z "$(entries)" ]
}

@test "retention 0 turns the quarantine off" {
    QUARANTINE_RETENTION_DAYS=0
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 50000
    run compress_one "$LOCAL_PATH/a.pdf"
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$LOCAL_PATH/a.pdf")" -eq 25000 ]
    [ -z "$(entries)" ]
}

@test "suffix mode does not quarantine" {
    TRACKING_MODE="suffix"
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 50000
    run compress_one "$LOCAL_PATH/a.pdf"
    [ "$status" -eq 0 ]
    [ -z "$(entries)" ]
}

@test "an unwritable quarantine keeps the original and fails the file" {
    : > "$TEST_TMP_DIR/blocker"
    QUARANTINE_DIR="$TEST_TMP_DIR/blocker/sub"
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 50000
    run compress_one "$LOCAL_PATH/a.pdf"
    [ "$status" -eq 1 ]
    [ "$(stat -c%s "$LOCAL_PATH/a.pdf")" -eq 50000 ]
    [ "$(ls -A "$LOCAL_PATH")" = "a.pdf" ]
}

@test "two compressions of one path keep two versions" {
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 50000
    compress_one "$LOCAL_PATH/a.pdf"
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 60000
    compress_one "$LOCAL_PATH/a.pdf"
    [ "$(entries | wc -l)" -eq 2 ]
}

@test "a name clash within one second adds a suffix" {
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 50000
    quarantine_keep "$LOG_FILE" "$LOCAL_PATH/a.pdf" "a.pdf"
    quarantine_keep "$LOG_FILE" "$LOCAL_PATH/a.pdf" "a.pdf"
    quarantine_keep "$LOG_FILE" "$LOCAL_PATH/a.pdf" "a.pdf"
    [ "$(entries | wc -l)" -eq 3 ]
}

@test "a relative path with a dot dot component is rejected" {
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 50000
    run quarantine_keep "$LOG_FILE" "$LOCAL_PATH/a.pdf" "../evil.pdf"
    [ "$status" -eq 1 ]
    [ -z "$(entries)" ]
}

@test "prune uses the timestamp in the name, not the file mtime" {
    mkdir -p "$QUARANTINE_DIR/old.pdf" "$QUARANTINE_DIR/new.pdf"
    echo x > "$QUARANTINE_DIR/old.pdf/$(stamp 40)"
    echo y > "$QUARANTINE_DIR/new.pdf/$(stamp 5)"
    touch -d 2001-01-01 "$QUARANTINE_DIR/old.pdf/$(stamp 40)" "$QUARANTINE_DIR/new.pdf/$(stamp 5)"
    quarantine_prune "$LOG_FILE"
    [ ! -e "$QUARANTINE_DIR/old.pdf" ]
    [ -f "$QUARANTINE_DIR/new.pdf/$(stamp 5)" ]
}

@test "prune removes only timestamp named archive directories that are old" {
    mkdir -p "$ARCHIVE_DIR/20200101T000000" "$ARCHIVE_DIR/notes" "$ARCHIVE_DIR/$(stamp 2)"
    quarantine_prune "$LOG_FILE"
    [ ! -e "$ARCHIVE_DIR/20200101T000000" ]
    [ -d "$ARCHIVE_DIR/notes" ]
    [ -d "$ARCHIVE_DIR/$(stamp 2)" ]
}

@test "prune does nothing at retention 0 or under a dry run" {
    mkdir -p "$ARCHIVE_DIR/20200101T000000"
    QUARANTINE_RETENTION_DAYS=0 quarantine_prune "$LOG_FILE"
    [ -d "$ARCHIVE_DIR/20200101T000000" ]
    DRY_RUN=true quarantine_prune "$LOG_FILE"
    [ -d "$ARCHIVE_DIR/20200101T000000" ]
}

@test "list prints path, timestamp and size, oldest first" {
    mkdir -p "$QUARANTINE_DIR/b.pdf" "$QUARANTINE_DIR/a/c.pdf"
    head -c 10 /dev/zero > "$QUARANTINE_DIR/b.pdf/$(stamp 3)"
    head -c 20 /dev/zero > "$QUARANTINE_DIR/a/c.pdf/$(stamp 9)"
    run quarantine_list
    [ "${lines[0]}" = "$(printf 'a/c.pdf\t%s\t20' "$(stamp 9)")" ]
    [ "${lines[1]}" = "$(printf 'b.pdf\t%s\t10' "$(stamp 3)")" ]
}

@test "summary prints the count and the total bytes" {
    mkdir -p "$QUARANTINE_DIR/b.pdf" "$QUARANTINE_DIR/c.pdf"
    head -c 10 /dev/zero > "$QUARANTINE_DIR/b.pdf/$(stamp 3)"
    head -c 20 /dev/zero > "$QUARANTINE_DIR/c.pdf/$(stamp 4)"
    [ "$(quarantine_summary)" = "$(printf '2\t30')" ]
}

@test "restore puts the original back and the next run leaves it alone" {
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 50000
    cp "$LOCAL_PATH/a.pdf" "$TEST_TMP_DIR/a.copy"
    run_batch
    [ "$(stat -c%s "$LOCAL_PATH/a.pdf")" -eq 25000 ]
    run quarantine_restore "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "$LOCAL_PATH" "a.pdf"
    [ "$status" -eq 0 ]
    cmp "$LOCAL_PATH/a.pdf" "$TEST_TMP_DIR/a.copy"
    [ -z "$(entries)" ]
    [ "$(jq -r '.files["a.pdf"].size' "$STATE_FILE")" = "50000" ]
    [ "$(jq -r '.files["a.pdf"].original_size' "$STATE_FILE")" = "50000" ]
    : > "$LOG_FILE"
    run_batch
    [ "$(stat -c%s "$LOCAL_PATH/a.pdf")" -eq 50000 ]
    grep -q "All PDFs are already optimized" "$LOG_FILE"
}

@test "restore takes the newest version and accepts an absolute path" {
    mkdir -p "$QUARANTINE_DIR/a.pdf"
    printf old > "$QUARANTINE_DIR/a.pdf/$(stamp 9)"
    printf newest > "$QUARANTINE_DIR/a.pdf/$(stamp 2)"
    run quarantine_restore "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "$LOCAL_PATH" "$LOCAL_PATH/a.pdf"
    [ "$status" -eq 0 ]
    [ "$(cat "$LOCAL_PATH/a.pdf")" = "newest" ]
    [ -f "$QUARANTINE_DIR/a.pdf/$(stamp 9)" ]
}

@test "restore of a path with nothing quarantined returns 1" {
    run quarantine_restore "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "$LOCAL_PATH" "nope.pdf"
    [ "$status" -eq 1 ]
}

@test "restore rejects a path outside the synced directory" {
    run quarantine_restore "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "$LOCAL_PATH" "/etc/passwd"
    [ "$status" -eq 1 ]
    run quarantine_restore "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "$LOCAL_PATH" "../outside.pdf"
    [ "$status" -eq 1 ]
}
