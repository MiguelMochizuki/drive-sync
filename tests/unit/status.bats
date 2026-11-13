#!/usr/bin/env bats

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/logging.sh"
    source "$REPO_ROOT/lib/state.sh"
    source "$REPO_ROOT/lib/storage.sh"
    source "$REPO_ROOT/lib/cli.sh"

    init_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE"
    mkdir -p "$LOCAL_PATH"
    export MOCK_RCLONE_ABOUT_JSON='{"used":0,"total":0}'
}

teardown() {
    common_teardown
}

status_output() {
    show_status "$LOG_FILE" "$STATE_FILE" "drive:" "$LOCAL_PATH" ".optimized.pdf"
}

@test "status prints plain ASCII only: no emoji, symbols or box drawing" {
    export MOCK_RCLONE_ABOUT_JSON='{"used":536870912,"total":1073741824}'
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 2000
    run status_output
    [ "$status" -eq 0 ]
    ! printf '%s' "$output" | LC_ALL=C grep -qP '[^\x00-\x7F]'
}

@test "status groups its output under Paths, Sync and Files headings" {
    run status_output
    [[ "$output" == *$'\nPaths\n'* ]]
    [[ "$output" == *$'\nSync\n'* ]]
    [[ "$output" == *$'\nFiles\n'* ]]
}

@test "status indents the values under their heading" {
    run status_output
    [[ "$output" == *$'\n  Local: '* ]]
    [[ "$output" == *$'\n  Remote: drive:'* ]]
    [[ "$output" == *$'\n  Status: idle'* ]]
}

@test "status shows a Storage section with the Drive quota when it is known" {
    export MOCK_RCLONE_ABOUT_JSON='{"used":536870912,"total":1073741824}'
    run status_output
    [[ "$output" == *$'\nStorage\n  Drive: '* ]]
}

@test "status omits the Storage section when the quota is unknown" {
    run status_output
    [[ "$output" != *"Storage"* ]]
}

@test "status suggests a push only when files are pending" {
    run status_output
    [[ "$output" != *"drive-sync.sh push"* ]]
    make_pdf_fixture "$LOCAL_PATH/b.pdf" 2000
    run status_output
    [[ "$output" == *"Next: drive-sync.sh push"* ]]
}

@test "in hash mode a tracked file counts as optimized, not pending" {
    make_pdf_fixture "$LOCAL_PATH/a.pdf" 2000
    make_pdf_fixture "$LOCAL_PATH/b.pdf" 2000
    record_file_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "a.pdf" "h" 4000 2000 1
    run status_output
    [[ "$output" == *"PDFs: 2 total"* ]]
    [[ "$output" == *"Optimized: 1"* ]]
    [[ "$output" == *"Pending: 1"* ]]
}

@test "a tracked entry whose file is gone is not counted" {
    make_pdf_fixture "$LOCAL_PATH/b.pdf" 2000
    record_file_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "gone.pdf" "h" 4000 2000 1
    run status_output
    [[ "$output" == *"Optimized: 0"* ]]
    [[ "$output" == *"Pending: 1"* ]]
}

@test "legacy .optimized.pdf files still count as optimized in hash mode" {
    make_pdf_fixture "$LOCAL_PATH/old.optimized.pdf" 2000
    run status_output
    [[ "$output" == *"Optimized: 1"* ]]
    [[ "$output" == *"Pending: 0"* ]]
}

@test "status uses no color codes when output is not a terminal" {
    run status_output
    [[ "$output" != *$'\033'* ]]
}

@test "status colors the headings and the sync status when color is enabled" {
    use_color() { return 0; }
    update_state "$LOG_FILE" "$STATE_FILE" "$LOCK_FILE" "sync_status" "failed"
    run status_output
    [[ "$output" == *$'\033[36mPaths\033[0m'* ]]
    [[ "$output" == *$'\033[31mfailed\033[0m'* ]]
}

@test "status and doctor never use bold, only colors" {
    use_color() { return 0; }
    export MOCK_RCLONE_REMOTES="drive:"
    run status_output
    [[ "$output" != *$'\033[1m'* ]]
    run run_doctor "$LOG_FILE" "$STATE_FILE" "drive:" "$LOCAL_PATH"
    [[ "$output" != *$'\033[1m'* ]]
}

@test "doctor colors its tags and its title the same way status does" {
    use_color() { return 0; }
    export MOCK_RCLONE_REMOTES="drive:"
    run run_doctor "$LOG_FILE" "$STATE_FILE" "drive:" "$LOCAL_PATH"
    [[ "$output" == *$'\033[36mdrive_sync doctor\033[0m'* ]]
    [[ "$output" == *$'\033[36mSettings:\033[0m'* ]]
    [[ "$output" == *$'\033[32m[ok]\033[0m rclone'* ]]
}

@test "doctor colors a failure red and the closing line to match" {
    use_color() { return 0; }
    export MOCK_RCLONE_REMOTES="other:"
    run run_doctor "$LOG_FILE" "$STATE_FILE" "drive:" "$LOCAL_PATH"
    [[ "$output" == *$'\033[31m[FAIL]\033[0m remote drive:'* ]]
    [[ "$output" == *$'\033[31mSome required checks failed.\033[0m'* ]]
}

@test "doctor prints no escape codes when output is not a terminal" {
    export MOCK_RCLONE_REMOTES="drive:"
    run run_doctor "$LOG_FILE" "$STATE_FILE" "drive:" "$LOCAL_PATH"
    [[ "$output" != *$'\033'* ]]
    [[ "$output" == *"[ok] rclone"* ]]
}

@test "use_color is true on a terminal and NO_COLOR turns it off" {
    command -v script > /dev/null || skip "script(1) is not available"
    local probe='source "$REPO_ROOT/lib/config.sh"; source "$REPO_ROOT/lib/cli.sh"; use_color'
    export REPO_ROOT

    run script -qec "bash -c '$probe'" /dev/null
    [ "$status" -eq 0 ]

    NO_COLOR=1 run script -qec "bash -c '$probe'" /dev/null
    [ "$status" -ne 0 ]
}

# These run the real command under a pseudo-terminal, without overriding
# use_color. A color that only works when use_color is stubbed (for example
# one computed inside $(...), where stdout is a pipe) would fail here.

@test "on a real terminal doctor colors every tag, not only the title" {
    command -v script > /dev/null || skip "script(1) is not available"
    mkdir -p "$HOME/drive"
    export MOCK_RCLONE_REMOTES="drive:"
    run script -qec "$REPO_ROOT/drive-sync.sh doctor" /dev/null
    [[ "$output" == *$'\033[32m[ok]\033[0m rclone'* ]]
    [[ "$output" == *$'\033[32mAll required checks passed.\033[0m'* ]]
}

@test "on a real terminal status colors the sync status value" {
    command -v script > /dev/null || skip "script(1) is not available"
    mkdir -p "$HOME/drive"
    export MOCK_RCLONE_REMOTES="drive:"
    run script -qec "$REPO_ROOT/drive-sync.sh status" /dev/null
    [[ "$output" == *$'Status: \033[90midle\033[0m'* ]]
}

@test "on a real terminal NO_COLOR removes every escape code from doctor" {
    command -v script > /dev/null || skip "script(1) is not available"
    mkdir -p "$HOME/drive"
    export MOCK_RCLONE_REMOTES="drive:"
    NO_COLOR=1 run script -qec "$REPO_ROOT/drive-sync.sh doctor" /dev/null
    [[ "$output" != *$'\033'* ]]
    [[ "$output" == *"[ok] rclone"* ]]
}
