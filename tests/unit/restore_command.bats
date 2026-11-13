#!/usr/bin/env bats

# End to end behavior of "drive-sync.sh restore" and its quarantine source.

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
    export MOCK_RCLONE_EXIT_SEQUENCE="0" MOCK_GS_BEHAVIOR="smaller"
    make_pdf_fixture "$HOME/drive/big.pdf" 50000
}

teardown() {
    common_teardown
}

cli() {
    "$REPO_ROOT/drive-sync.sh" "$@"
}

@test "restore brings the original back and tells you to push" {
    cli push > /dev/null
    [ "$(stat -c%s "$HOME/drive/big.pdf")" -eq 25000 ]
    run --separate-stderr cli restore big.pdf
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$HOME/drive/big.pdf")" -eq 50000 ]
    [[ "$output" == *"Restored big.pdf"* ]]
    [[ "$output" == *"drive-sync.sh push"* ]]
}

@test "a push after restore does not compress the file again" {
    cli push > /dev/null
    cli restore big.pdf > /dev/null
    cli push > /dev/null
    [ "$(stat -c%s "$HOME/drive/big.pdf")" -eq 50000 ]
}

@test "restore --list shows the quarantined originals" {
    cli push > /dev/null
    run --separate-stderr cli restore --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"big.pdf"* ]]
    [[ "$output" == *"50000"* ]]
}

@test "restore --list on an empty quarantine succeeds and prints nothing" {
    run --separate-stderr cli restore --list
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "restore of a path with nothing quarantined exits 1" {
    run cli restore nope.pdf
    [ "$status" -eq 1 ]
}

@test "restore without a path or --list is a usage error" {
    run cli restore
    [ "$status" -eq 2 ]
}

@test "restore with two paths is a usage error" {
    run cli restore a.pdf b.pdf
    [ "$status" -eq 2 ]
}

@test "restore --list with a path is a usage error" {
    run cli restore --list big.pdf
    [ "$status" -eq 2 ]
}

@test "restore rejects the plan flags" {
    run cli restore --json
    [ "$status" -eq 2 ]
}
