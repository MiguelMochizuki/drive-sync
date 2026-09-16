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
    skip "short -v flag is reassigned to verbose in Task 25"
}

@test "push with --verbose prints INFO progress lines" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    run "$REPO_ROOT/drive-sync.sh" push --verbose
    [ "$status" -eq 0 ]
    [[ "$output" == *"Starting PDF optimization"* ]]
}
