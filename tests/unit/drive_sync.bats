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
    [[ "$output" == *"drive_sync version 2.2.0"* ]]
}

@test "-v is now the short form of --verbose" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    run "$REPO_ROOT/drive-sync.sh" push -v
    [ "$status" -eq 0 ]
    [[ "$output" == *"Starting PDF optimization"* ]]
}

@test "a fatal rclone error exits 69, EX_UNAVAILABLE" {
    export MOCK_RCLONE_EXIT_SEQUENCE="7"
    run "$REPO_ROOT/drive-sync.sh" push
    [ "$status" -eq 69 ]
}

@test "retries exhausted after only temporary errors exits 75, EX_TEMPFAIL" {
    export MOCK_RCLONE_EXIT_SEQUENCE="5,5,5"
    run "$REPO_ROOT/drive-sync.sh" push
    [ "$status" -eq 75 ]
}

@test "an unconfigured remote exits 69, EX_UNAVAILABLE" {
    export MOCK_RCLONE_REMOTES="other:"
    run "$REPO_ROOT/drive-sync.sh" status
    [ "$status" -eq 69 ]
}

@test "push retries twice on temporary errors then succeeds on the third attempt" {
    export MOCK_RCLONE_EXIT_SEQUENCE="5,5,0"
    run "$REPO_ROOT/drive-sync.sh" push
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$MOCK_STATE_DIR/rclone_calls.log")" -ge 3 ]
}

@test "push aborts immediately on a fatal error, without retrying" {
    export MOCK_RCLONE_EXIT_SEQUENCE="7"
    run "$REPO_ROOT/drive-sync.sh" push

    local sync_calls
    sync_calls=$(grep -c '^sync ' "$MOCK_STATE_DIR/rclone_calls.log" || true)
    [ "$status" -eq 69 ]
    [ "$sync_calls" -eq 1 ]
}

@test "push aborts with exit 1 before syncing when deletions exceed the limit" {
    export MOCK_RCLONE_PLAN_DELETES=9 MOCK_RCLONE_LSF_COUNT=10 MOCK_RCLONE_EXIT_SEQUENCE="0"
    run --separate-stderr "$REPO_ROOT/drive-sync.sh" push
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"9 of 10"* ]]
    [ ! -f "$MOCK_STATE_DIR/rclone_calls.log" ] || ! grep -q '^sync ' "$MOCK_STATE_DIR/rclone_calls.log"
}

@test "push -f still aborts when deletions exceed the limit" {
    export MOCK_RCLONE_PLAN_DELETES=9 MOCK_RCLONE_LSF_COUNT=10 MOCK_RCLONE_EXIT_SEQUENCE="0"
    run "$REPO_ROOT/drive-sync.sh" push -f
    [ "$status" -eq 1 ]
}

@test "push proceeds when deletions are within the limit" {
    export MOCK_RCLONE_PLAN_DELETES=2 MOCK_RCLONE_LSF_COUNT=10 MOCK_RCLONE_EXIT_SEQUENCE="0"
    run "$REPO_ROOT/drive-sync.sh" push
    [ "$status" -eq 0 ]
    grep -q '^sync ' "$MOCK_STATE_DIR/rclone_calls.log"
}

@test "update aborts with exit 1 when the mirror would delete too much locally" {
    export MOCK_RCLONE_PLAN_DELETES=9 MOCK_RCLONE_EXIT_SEQUENCE="0"
    mkdir -p "$HOME/drive" && for i in 1 2 3 4 5 6 7 8 9 10; do touch "$HOME/drive/f$i"; done
    run "$REPO_ROOT/drive-sync.sh" update
    [ "$status" -eq 1 ]
    ! grep -q '^sync ' "$MOCK_STATE_DIR/rclone_calls.log" 2>/dev/null
}

@test "push --dry-run does not compute a deletion plan" {
    export MOCK_RCLONE_PLAN_DELETES=9 MOCK_RCLONE_LSF_COUNT=10 MOCK_RCLONE_EXIT_SEQUENCE="0"
    run "$REPO_ROOT/drive-sync.sh" push -n
    [ "$status" -eq 0 ]
    [ ! -f "$MOCK_STATE_DIR/rclone_plan.log" ]
}

@test "pull never computes a deletion plan" {
    export MOCK_RCLONE_PLAN_DELETES=9 MOCK_RCLONE_LSF_COUNT=10 MOCK_RCLONE_EXIT_SEQUENCE="0"
    run "$REPO_ROOT/drive-sync.sh" pull
    [ "$status" -eq 0 ]
    [ ! -f "$MOCK_STATE_DIR/rclone_plan.log" ]
}

@test "sync plans deletions only for its push half" {
    export MOCK_RCLONE_PLAN_DELETES=1 MOCK_RCLONE_LSF_COUNT=10 MOCK_RCLONE_EXIT_SEQUENCE="0"
    run "$REPO_ROOT/drive-sync.sh" sync
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$MOCK_STATE_DIR/rclone_plan.log")" -eq 1 ]
}

@test "push -n does not compress a PDF or record it in state" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0" MOCK_GS_BEHAVIOR="fail"
    mkdir -p "$HOME/drive" && make_pdf_fixture "$HOME/drive/big.pdf" 50000
    run "$REPO_ROOT/drive-sync.sh" push -n
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$HOME/drive/big.pdf")" -eq 50000 ]
    [ "$(jq -r '.files | length' "$HOME/.drive-sync/state.json")" = "0" ]
}

@test "sync -n does not compress a PDF or record it in state" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0" MOCK_GS_BEHAVIOR="fail"
    mkdir -p "$HOME/drive" && make_pdf_fixture "$HOME/drive/big.pdf" 50000
    run "$REPO_ROOT/drive-sync.sh" sync -n
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$HOME/drive/big.pdf")" -eq 50000 ]
    [ "$(jq -r '.files | length' "$HOME/.drive-sync/state.json")" = "0" ]
}

@test "push without -n still compresses a PDF" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0" MOCK_GS_BEHAVIOR="smaller"
    mkdir -p "$HOME/drive" && make_pdf_fixture "$HOME/drive/big.pdf" 50000
    run "$REPO_ROOT/drive-sync.sh" push
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$HOME/drive/big.pdf")" -eq 25000 ]
}

@test "push -n -v prints the Would compress line on stdout" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0" MOCK_GS_BEHAVIOR="fail"
    mkdir -p "$HOME/drive" && make_pdf_fixture "$HOME/drive/big.pdf" 50000
    run "$REPO_ROOT/drive-sync.sh" push -n -v
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would compress: "*"big.pdf"* ]]
}

@test "push -n leaves last_sync and sync_status as they were" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    run "$REPO_ROOT/drive-sync.sh" push -n
    [ "$status" -eq 0 ]
    [ "$(jq -r '.last_sync' "$HOME/.drive-sync/state.json")" = "null" ]
    [ "$(jq -r '.sync_status' "$HOME/.drive-sync/state.json")" = "idle" ]
}

@test "a DRY_RUN=true inherited from the environment does not turn a real push into a half dry run" {
    export MOCK_RCLONE_EXIT_SEQUENCE="0" MOCK_GS_BEHAVIOR="smaller"
    mkdir -p "$HOME/drive" && make_pdf_fixture "$HOME/drive/big.pdf" 50000
    DRY_RUN=true run "$REPO_ROOT/drive-sync.sh" push
    [ "$status" -eq 0 ]
    [ "$(stat -c%s "$HOME/drive/big.pdf")" -eq 25000 ]
    ! grep -q -- "--dry-run" "$MOCK_STATE_DIR/rclone_calls.log"
}

@test "push -n that hits a rate limit runs no cleanup and writes no recovery state" {
    export MOCK_RCLONE_EXIT_SEQUENCE="5,0"
    run "$REPO_ROOT/drive-sync.sh" push -n
    [ "$status" -eq 0 ]
    ! grep -q '^cleanup\|^cache' "$MOCK_STATE_DIR/rclone_calls.log"
    [ "$(jq -r '.rate_limit_recoveries' "$HOME/.drive-sync/state.json")" = "0" ]
}
