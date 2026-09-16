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

@test "push without -v prints nothing but the storage line on success" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    run "$REPO_ROOT/drive-sync.sh" push
    [ "$status" -eq 0 ]
    [[ "$output" != *"Starting PDF optimization"* ]]
}

@test "push with -v prints INFO progress lines" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    run "$REPO_ROOT/drive-sync.sh" push -v
    [ "$status" -eq 0 ]
    [[ "$output" == *"Starting PDF optimization"* ]]
}

@test "push with --verbose prints INFO progress lines" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    run "$REPO_ROOT/drive-sync.sh" push --verbose
    [ "$status" -eq 0 ]
    [[ "$output" == *"Starting PDF optimization"* ]]
}

@test "no arguments exits 2 with usage on stderr" {
    run --separate-stderr "$REPO_ROOT/drive-sync.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == "" ]]
    [[ "$stderr" == *"USAGE:"* ]]
}

@test "an unknown command exits 2 with usage on stderr" {
    run --separate-stderr "$REPO_ROOT/drive-sync.sh" bogus
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"USAGE:"* ]]
}

@test "an unknown flag exits 2 with usage on stderr" {
    run --separate-stderr "$REPO_ROOT/drive-sync.sh" push --bogus
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"USAGE:"* ]]
}

@test "-h still exits 0 with full help on stdout" {
    run --separate-stderr "$REPO_ROOT/drive-sync.sh" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"USAGE:"* ]]
    [[ "$output" == *"EXAMPLES:"* ]]
}

@test "-V prints the version and exits 0" {
    run "$REPO_ROOT/drive-sync.sh" -V
    [ "$status" -eq 0 ]
    [[ "$output" == *"drive_sync version 1.0.2"* ]]
}

@test "-v is now the short form of --verbose" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    run "$REPO_ROOT/drive-sync.sh" push -v
    [ "$status" -eq 0 ]
    [[ "$output" == *"Starting PDF optimization"* ]]
}
