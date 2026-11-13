#!/usr/bin/env bats

# drive-sync init: a safe, repeatable first-run setup.

load '../test_helper'

setup() {
    common_setup
    export MOCK_RCLONE_ABOUT_JSON='{"used":0,"total":0}'
    export MOCK_RCLONE_REMOTES="gdrive:"
    CONF="$HOME/.drive-sync/drive-sync.conf"
}

teardown() {
    common_teardown
}

cli() {
    "$REPO_ROOT/drive-sync.sh" "$@"
}

@test "init writes a config naming the only Google Drive remote and creates the local directory" {
    run cli init
    [ "$status" -eq 0 ]
    grep -q '^REMOTE_NAME="gdrive:"$' "$CONF"
    [ -d "$HOME/drive" ]
    [[ "$output" == *"[ok] remote gdrive:"* ]]
    [[ "$output" == *"drive-sync.sh plan"* ]]
}

@test "init keeps an existing config untouched" {
    mkdir -p "$HOME/.drive-sync" "$HOME/drive"
    printf 'REMOTE_NAME="gdrive:"\n# mine\n' > "$CONF"
    cp "$CONF" "$TEST_TMP_DIR/conf.before"
    run cli init
    [ "$status" -eq 0 ]
    cmp "$CONF" "$TEST_TMP_DIR/conf.before"
    [[ "$output" == *"config kept"* ]]
}

@test "init run twice gives the same result" {
    run cli init
    cp "$CONF" "$TEST_TMP_DIR/conf.first"
    run cli init
    [ "$status" -eq 0 ]
    cmp "$CONF" "$TEST_TMP_DIR/conf.first"
}

@test "init without a Google Drive remote says how to create one and exits 69" {
    export MOCK_RCLONE_REMOTES="other:" MOCK_RCLONE_REMOTE_TYPE="s3"
    run cli init
    [ "$status" -eq 69 ]
    [[ "$output" == *"rclone config"* ]]
    grep -q '^REMOTE_NAME="drive:"$' "$CONF"
}

@test "init does not guess among several Google Drive remotes" {
    export MOCK_RCLONE_REMOTES="a: b:"
    run cli init
    [[ "$output" == *"several Google Drive remotes"* ]]
    grep -q '^REMOTE_NAME="drive:"$' "$CONF"
}

@test "the written config sets the remote that doctor then checks" {
    run cli init
    run cli doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ok] remote gdrive:"* ]]
}

@test "init does not touch an existing synced directory" {
    mkdir -p "$HOME/drive"; echo keep > "$HOME/drive/a.txt"
    run cli init
    [ "$(cat "$HOME/drive/a.txt")" = "keep" ]
    [ "$(ls "$HOME/drive")" = "a.txt" ]
}

@test "init rejects extra arguments" {
    run cli init now
    [ "$status" -eq 2 ]
}
