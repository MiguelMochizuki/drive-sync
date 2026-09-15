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
    [[ "$output" == *"drive_sync version 1.0.2"* ]]
}

@test "--help prints usage and exits 0" {
    run "$REPO_ROOT/drive-sync.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"USAGE:"* ]]
}

@test "no arguments exits 1 and prints usage today" {
    run "$REPO_ROOT/drive-sync.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"USAGE:"* ]]
}

@test "an unknown command exits 1 and names the command" {
    run "$REPO_ROOT/drive-sync.sh" bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown command: bogus"* ]]
}

@test "an unknown flag exits 1 and names the flag" {
    run "$REPO_ROOT/drive-sync.sh" push --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option: --bogus"* ]]
}

@test "status runs end to end against the mocked remote" {
    run "$REPO_ROOT/drive-sync.sh" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"drive_sync v1.0.2"* ]]
    [[ "$output" == *"Local:"* ]]
    [[ "$output" == *"Remote: drive:"* ]]
}

@test "push on an empty directory succeeds end to end" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    run "$REPO_ROOT/drive-sync.sh" push
    [ "$status" -eq 0 ]
}
