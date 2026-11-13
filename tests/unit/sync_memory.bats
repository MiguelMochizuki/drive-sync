#!/usr/bin/env bats

# sync honors removals and renames made on either side since the last
# successful sync, using the manifest.

load '../test_helper'

setup() {
    common_setup
    mkdir -p "$HOME/.drive-sync" "$HOME/drive"
    cat > "$HOME/.drive-sync/drive-sync.conf" <<'CONF'
RATE_LIMIT_BACKOFF_SECONDS=0
RETRY_DELAY=0
MAX_RETRIES=3
CONF
    export MOCK_RCLONE_REMOTES="drive:"
    export MOCK_RCLONE_ABOUT_JSON='{"used":0,"total":0}'
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    MANIFEST="$HOME/.drive-sync/manifest"
    CALLS="$MOCK_STATE_DIR/rclone_calls.log"
}

teardown() {
    common_teardown
}

cli() {
    "$REPO_ROOT/drive-sync.sh" "$@"
}

mkfiles() {
    local f
    for f in "$@"; do
        mkdir -p "$HOME/drive/$(dirname "$f")"
        echo "$f" > "$HOME/drive/$f"
    done
}

@test "the first sync has no memory: it removes nothing and creates the manifest" {
    mkfiles a.txt b.txt
    export MOCK_RCLONE_LSF_NAMES="a.txt b.txt c.txt"
    run cli sync
    [ "$status" -eq 0 ]
    [ "$(cat "$MANIFEST")" = $'a.txt\nb.txt' ]
    run grep -q '^delete ' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "a file removed locally is removed from Drive before the pull" {
    mkfiles a.txt b.txt c.txt d.txt e.txt
    printf 'a.txt\nb.txt\nc.txt\nd.txt\ne.txt\ngone.txt\n' > "$MANIFEST"
    export MOCK_RCLONE_LSF_NAMES="a.txt b.txt c.txt d.txt e.txt gone.txt"
    run cli sync
    [ "$status" -eq 0 ]
    [ "$(cat "$MOCK_STATE_DIR/deleted_files.txt")" = "gone.txt" ]
    delete_line=$(grep -n '^delete ' "$CALLS" | head -1 | cut -d: -f1)
    copy_line=$(grep -n '^copy ' "$CALLS" | head -1 | cut -d: -f1)
    [ "$delete_line" -lt "$copy_line" ]
    grep -q -- "--drive-use-trash" "$CALLS"
}

@test "a rename here removes the old name from Drive and leaves one file" {
    mkfiles keep1 keep2 keep3 keep4 new_name.pdf
    printf 'keep1\nkeep2\nkeep3\nkeep4\nold_name.pdf\n' > "$MANIFEST"
    export MOCK_RCLONE_LSF_NAMES="keep1 keep2 keep3 keep4 old_name.pdf"
    run cli sync
    [ "$status" -eq 0 ]
    [ "$(cat "$MOCK_STATE_DIR/deleted_files.txt")" = "old_name.pdf" ]
}

@test "a file removed on Drive is archived locally and not pushed" {
    mkfiles a.txt b.txt c.txt d.txt e.txt old.txt
    printf 'a.txt\nb.txt\nc.txt\nd.txt\ne.txt\nold.txt\n' > "$MANIFEST"
    export MOCK_RCLONE_LSF_NAMES="a.txt b.txt c.txt d.txt e.txt"
    run cli sync
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/drive/old.txt" ]
    [ -n "$(find "$HOME/.drive-sync/archive" -name old.txt -type f)" ]
    run grep -q '^delete ' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "a new file on Drive that is not in the manifest is left for the pull" {
    mkfiles a.txt b.txt c.txt d.txt e.txt
    printf 'a.txt\nb.txt\nc.txt\nd.txt\ne.txt\n' > "$MANIFEST"
    export MOCK_RCLONE_LSF_NAMES="a.txt b.txt c.txt d.txt e.txt brand_new.txt"
    run cli sync
    [ "$status" -eq 0 ]
    run grep -q '^delete ' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "removals over the limit abort the sync before anything is pulled" {
    mkfiles keep.txt
    printf 'keep.txt\n1\n2\n3\n4\n5\n' > "$MANIFEST"
    export MOCK_RCLONE_LSF_NAMES="keep.txt 1 2 3 4 5"
    run --separate-stderr cli sync
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"5 of 6"* ]]
    run grep -qE '^(delete|copy|sync) ' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "the manifest follows the local files after a successful sync" {
    mkfiles a.txt new.txt
    printf 'a.txt\n' > "$MANIFEST"
    export MOCK_RCLONE_LSF_NAMES="a.txt"
    run cli sync
    [ "$status" -eq 0 ]
    [ "$(cat "$MANIFEST")" = $'a.txt\nnew.txt' ]
}

@test "push and update write the manifest, pull and dry runs do not" {
    mkfiles a.txt
    run cli pull
    [ ! -e "$MANIFEST" ]
    run cli sync -n
    [ ! -e "$MANIFEST" ]
    run cli push -n
    [ ! -e "$MANIFEST" ]
    run cli push
    [ "$(cat "$MANIFEST")" = "a.txt" ]
    rm "$MANIFEST"
    run cli update
    [ "$(cat "$MANIFEST")" = "a.txt" ]
}

@test "a failed sync leaves the manifest as it was" {
    mkfiles a.txt b.txt
    printf 'a.txt\n' > "$MANIFEST"
    export MOCK_RCLONE_LSF_NAMES="a.txt" MOCK_RCLONE_EXIT_SEQUENCE="3"
    run cli sync
    [ "$status" -ne 0 ]
    [ "$(cat "$MANIFEST")" = "a.txt" ]
}

@test "sync aborts when the remote cannot be listed against a manifest" {
    mkfiles a.txt
    printf 'a.txt\n' > "$MANIFEST"
    export MOCK_RCLONE_LSF_EXIT=1
    run cli sync
    [ "$status" -ne 0 ]
    run grep -qE '^(delete|copy|sync) ' "$CALLS"
    [ "$status" -ne 0 ]
}
