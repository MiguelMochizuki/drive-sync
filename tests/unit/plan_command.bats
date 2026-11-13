#!/usr/bin/env bats

# End to end behavior of "drive-sync.sh plan".

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
    make_pdf_fixture "$HOME/drive/big.pdf" 50000
    export TMPDIR="$TEST_TMP_DIR/tmp"
    mkdir -p "$TMPDIR"
}

teardown() {
    common_teardown
}

plan() {
    "$REPO_ROOT/drive-sync.sh" plan "$@"
}

snapshot() {
    (cd "$HOME" && find drive -type f -print0 | sort -z | xargs -0 sha256sum
     sha256sum .drive-sync/state.json)
}

@test "plan --json prints one valid JSON document" {
    export MOCK_RCLONE_PLAN_COPIES=2
    run --separate-stderr plan --json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.schema_version' <<< "$output")" = "1" ]
    [ "$(jq -r '.direction' <<< "$output")" = "sync" ]
    [ "$(jq -r '.transfers.pull.copy_files' <<< "$output")" = "2" ]
    [ "$(jq -r '.compress.candidates[0].path' <<< "$output")" = "big.pdf" ]
}

@test "plan changes nothing, even with a failing gs" {
    export MOCK_GS_BEHAVIOR="fail"
    plan --json > /dev/null
    before=$(snapshot)
    ls -A "$HOME/drive" > "$TEST_TMP_DIR/ls.before"
    plan > /dev/null
    plan --json > /dev/null
    plan --measure > /dev/null
    [ "$(snapshot)" = "$before" ]
    ls -A "$HOME/drive" > "$TEST_TMP_DIR/ls.after"
    cmp "$TEST_TMP_DIR/ls.before" "$TEST_TMP_DIR/ls.after"
}

@test "plan never calls the real rclone sync or copy" {
    plan > /dev/null
    ! grep -qE "^(sync|copy) " "$MOCK_STATE_DIR/rclone_calls.log" 2>/dev/null
}

@test "plan text names the candidate, the estimate source and the deletion verdict" {
    export MOCK_RCLONE_PLAN_DELETES=1 MOCK_RCLONE_LSF_COUNT=10
    run --separate-stderr plan
    [ "$status" -eq 0 ]
    [[ "$output" == *"Compress"* ]]
    [[ "$output" == *"big.pdf"* ]]
    [[ "$output" == *"no estimate yet"* ]]
    [[ "$output" == *"Delete"* ]]
    [[ "$output" == *"would continue"* ]]
}

@test "plan text says the run would abort above the limit" {
    export MOCK_RCLONE_PLAN_DELETES=8 MOCK_RCLONE_LSF_COUNT=10
    run --separate-stderr plan push
    [[ "$output" == *"would abort"* ]]
}

@test "plan pull has no compress section" {
    run --separate-stderr plan pull --json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.compress' <<< "$output")" = "null" ]
    [ "$(jq -r '.transfers.push' <<< "$output")" = "null" ]
}

@test "plan --measure prints measured savings and leaves no temp files" {
    export MOCK_GS_BEHAVIOR="smaller"
    run --separate-stderr plan --measure --json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.compress.estimate.method' <<< "$output")" = "measured" ]
    [ "$(jq -r '.compress.estimate.saved_bytes' <<< "$output")" = "25000" ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "plan --json stays pure JSON with -v" {
    run --separate-stderr plan --json -v
    [ "$status" -eq 0 ]
    jq -e . <<< "$output" > /dev/null
}

@test "a failing rclone dry run exits 1 and --json prints nothing on stdout" {
    export MOCK_RCLONE_PLAN_EXIT=1
    run --separate-stderr plan --json
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "plan with an unknown direction or flag is a usage error" {
    run plan bogus
    [ "$status" -eq 2 ]
    run plan --nope
    [ "$status" -eq 2 ]
    run plan push pull
    [ "$status" -eq 2 ]
}

@test "--json and --measure are rejected by push" {
    run "$REPO_ROOT/drive-sync.sh" push --json
    [ "$status" -eq 2 ]
    run "$REPO_ROOT/drive-sync.sh" push --measure
    [ "$status" -eq 2 ]
}

@test "sync plan does not count deletions that the pull half would restore" {
    export MOCK_RCLONE_PLAN_COPY_NAMES="a.pdf b.pdf" MOCK_RCLONE_PLAN_DELETE_NAMES="a.pdf b.pdf c.pdf"
    export MOCK_RCLONE_LSF_COUNT=10
    run --separate-stderr plan --json
    [ "$(jq -r '.transfers.push.delete.count' <<< "$output")" = "1" ]
    run --separate-stderr plan push --json
    [ "$(jq -r '.transfers.push.delete.count' <<< "$output")" = "3" ]
}
