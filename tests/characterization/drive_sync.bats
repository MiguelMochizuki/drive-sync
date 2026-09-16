#!/usr/bin/env bats

load '../test_helper'

setup() {
    common_setup
    mkdir -p "$HOME/.drive-sync"
    cat > "$HOME/.drive-sync/drive-sync.conf" <<'EOF'
RATE_LIMIT_BACKOFF_SECONDS=0
RETRY_DELAY=0
MAX_RETRIES=3
EOF
    export MOCK_RCLONE_REMOTES="drive:"
    export MOCK_RCLONE_ABOUT_JSON='{"used":0,"total":0}'
}

teardown() {
    common_teardown
}

@test "--version prints the version and exits 0" {
    run "$REPO_ROOT/drive-sync.sh" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"drive_sync version 2.0.0"* ]]
}

@test "--help prints usage and exits 0" {
    run "$REPO_ROOT/drive-sync.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"USAGE:"* ]]
}

@test "no arguments exits 2 and prints usage to stderr" {
    run --separate-stderr "$REPO_ROOT/drive-sync.sh"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"USAGE:"* ]]
}

@test "an unknown command exits 2 and prints usage to stderr" {
    run --separate-stderr "$REPO_ROOT/drive-sync.sh" bogus
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"USAGE:"* ]]
}

@test "an unknown flag exits 2 and prints usage to stderr" {
    run --separate-stderr "$REPO_ROOT/drive-sync.sh" push --bogus
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"USAGE:"* ]]
}

@test "status runs end to end against the mocked remote" {
    run "$REPO_ROOT/drive-sync.sh" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"drive_sync v2.0.0"* ]]
    [[ "$output" == *"Local:"* ]]
    [[ "$output" == *"Remote: drive:"* ]]
}

@test "push on an empty directory succeeds end to end" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    run "$REPO_ROOT/drive-sync.sh" push
    [ "$status" -eq 0 ]
}
