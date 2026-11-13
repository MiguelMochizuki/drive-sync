#!/usr/bin/env bats

# The sync memory: a manifest of paths both sides shared at the last
# successful sync, and the two sets of changes since then.

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/logging.sh"
    source "$REPO_ROOT/lib/state.sh"
    source "$REPO_ROOT/lib/limit.sh"
    source "$REPO_ROOT/lib/sync_ops.sh"
    source "$REPO_ROOT/lib/safety.sh"
    source "$REPO_ROOT/lib/memory.sh"

    mkdir -p "$LOCAL_PATH"
    MANIFEST="$TEST_TMP_DIR/manifest"
    OUT_R="$TEST_TMP_DIR/removed_local"
    OUT_L="$TEST_TMP_DIR/removed_remote"
}

teardown() {
    common_teardown
}

mkfiles() {
    local f
    for f in "$@"; do
        mkdir -p "$LOCAL_PATH/$(dirname "$f")"
        echo "$f" > "$LOCAL_PATH/$f"
    done
}

@test "list_local_files prints sorted relative paths" {
    mkfiles b.txt a/c.txt a.txt
    run list_local_files "$LOCAL_PATH"
    [ "$output" = $'a.txt\na/c.txt\nb.txt' ]
}

@test "write_manifest records the local files and a dry run writes nothing" {
    mkfiles a.txt b.txt
    memory_write_manifest "$LOG_FILE" "$LOCAL_PATH" "$MANIFEST"
    [ "$(cat "$MANIFEST")" = $'a.txt\nb.txt' ]
    rm "$MANIFEST"
    DRY_RUN=true memory_write_manifest "$LOG_FILE" "$LOCAL_PATH" "$MANIFEST"
    [ ! -e "$MANIFEST" ]
}

@test "memory_diff returns 2 without a manifest" {
    run memory_diff "$LOG_FILE" "$LOCAL_PATH" "drive:" "$MANIFEST" "$OUT_R" "$OUT_L"
    [ "$status" -eq 2 ]
}

@test "memory_diff finds files removed locally and removed on Drive" {
    printf 'a.txt\ngone_here.txt\ngone_there.txt\nboth.txt\n' > "$MANIFEST"
    mkfiles a.txt both.txt gone_there.txt new_here.txt
    # Drive has: a, both, gone_here (we deleted it), new_remote (new there)
    export MOCK_RCLONE_LSF_NAMES="a.txt both.txt gone_here.txt new_remote.txt"
    run memory_diff "$LOG_FILE" "$LOCAL_PATH" "drive:" "$MANIFEST" "$OUT_R" "$OUT_L"
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT_R")" = "gone_here.txt" ]
    [ "$(cat "$OUT_L")" = "gone_there.txt" ]
}

@test "memory_diff fails when the remote cannot be listed" {
    printf 'a.txt\n' > "$MANIFEST"
    export MOCK_RCLONE_LSF_EXIT=1
    run memory_diff "$LOG_FILE" "$LOCAL_PATH" "drive:" "$MANIFEST" "$OUT_R" "$OUT_L"
    [ "$status" -eq 1 ]
}

@test "memory_apply removes the first set from Drive through the trash" {
    printf 'x.txt\ny z.txt\n' > "$OUT_R"; : > "$OUT_L"
    export MOCK_RCLONE_LSF_COUNT=10
    run memory_apply "$LOG_FILE" "$LOCAL_PATH" "drive:" "$OUT_R" "$OUT_L" false
    [ "$status" -eq 0 ]
    [ "$(cat "$MOCK_STATE_DIR/deleted_files.txt")" = $'x.txt\ny z.txt' ]
    grep -q -- "--drive-use-trash" "$MOCK_STATE_DIR/rclone_calls.log"
}

@test "memory_apply archives the second set locally" {
    mkfiles d/old.txt keep.txt
    : > "$OUT_R"; printf 'd/old.txt\n' > "$OUT_L"
    export MOCK_RCLONE_LSF_COUNT=10
    run memory_apply "$LOG_FILE" "$LOCAL_PATH" "drive:" "$OUT_R" "$OUT_L" false
    [ "$status" -eq 0 ]
    [ ! -e "$LOCAL_PATH/d/old.txt" ]
    [ -f "$LOCAL_PATH/keep.txt" ]
    [ -n "$(find "$ARCHIVE_DIR" -path '*/d/old.txt' -type f)" ]
}

@test "memory_apply does nothing in a dry run" {
    mkfiles old.txt
    printf 'x.txt\n' > "$OUT_R"; printf 'old.txt\n' > "$OUT_L"
    run memory_apply "$LOG_FILE" "$LOCAL_PATH" "drive:" "$OUT_R" "$OUT_L" true
    [ "$status" -eq 0 ]
    [ -f "$LOCAL_PATH/old.txt" ]
    [ ! -e "$MOCK_STATE_DIR/deleted_files.txt" ]
}

@test "memory_apply aborts above the deletion limit even with force" {
    printf 'a\nb\nc\nd\ne\nf\n' > "$OUT_R"; : > "$OUT_L"
    export MOCK_RCLONE_LSF_COUNT=10 FORCE=true
    run memory_apply "$LOG_FILE" "$LOCAL_PATH" "drive:" "$OUT_R" "$OUT_L" false
    [ "$status" -eq 1 ]
    [ ! -e "$MOCK_STATE_DIR/deleted_files.txt" ]
}

@test "memory_apply aborts when the local archive set is over the limit" {
    mkfiles a b c d
    : > "$OUT_R"; printf 'a\nb\nc\n' > "$OUT_L"
    export MOCK_RCLONE_LSF_COUNT=10
    run memory_apply "$LOG_FILE" "$LOCAL_PATH" "drive:" "$OUT_R" "$OUT_L" false
    [ "$status" -eq 1 ]
    [ -f "$LOCAL_PATH/a" ]
}
