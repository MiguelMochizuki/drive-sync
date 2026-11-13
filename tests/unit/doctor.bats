#!/usr/bin/env bats

load '../test_helper'

setup() {
    common_setup
    mkdir -p "$HOME/drive"
    export MOCK_RCLONE_REMOTES="drive:"
    export MOCK_RCLONE_ABOUT_JSON='{"used":0,"total":0}'
}

teardown() {
    common_teardown
}

# Build a PATH holding only the commands drive-sync needs, minus the ones
# named in the arguments, so a missing tool can be simulated.
path_without() {
    local bin="$TEST_TMP_DIR/bin" cmd skip
    mkdir -p "$bin"
    for cmd in bash env dirname basename cat mkdir touch date jq flock bc sed grep \
               cut head tail find wc du stat tr mv rm cp sha256sum readlink sleep \
               seq sort tee gs rclone; do
        for skip in "$@"; do [[ "$cmd" == "$skip" ]] && continue 2; done
        if [[ "$cmd" == "gs" || "$cmd" == "rclone" ]]; then
            ln -sf "$REPO_ROOT/tests/mocks/$cmd" "$bin/$cmd"
        else
            ln -sf "$(command -v "$cmd")" "$bin/$cmd" 2>/dev/null || true
        fi
    done
    echo "$bin"
}

@test "doctor exits 0 and reports every check when the environment is healthy" {
    run "$REPO_ROOT/drive-sync.sh" doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ok] rclone"* ]]
    [[ "$output" == *"[ok] gs"* ]]
    [[ "$output" == *"[ok] jq"* ]]
    [[ "$output" == *"[ok] flock"* ]]
    [[ "$output" == *"[ok] remote drive:"* ]]
    [[ "$output" == *"[ok] local directory"* ]]
    [[ "$output" == *"[ok] state"* ]]
}

@test "doctor exits 69 and names the tool when a required tool is missing" {
    local bin; bin=$(path_without gs)
    PATH="$bin" run "$bin/bash" "$REPO_ROOT/drive-sync.sh" doctor
    [ "$status" -eq 69 ]
    [[ "$output" == *"[FAIL] gs"* ]]
    [[ "$output" == *"[ok] jq"* ]]
}

@test "doctor only warns when the optional bc is missing" {
    local bin; bin=$(path_without bc)
    PATH="$bin" run "$bin/bash" "$REPO_ROOT/drive-sync.sh" doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"[warn] bc"* ]]
}

@test "doctor keeps going past a missing remote and exits 69" {
    export MOCK_RCLONE_REMOTES="other:"
    run "$REPO_ROOT/drive-sync.sh" doctor
    [ "$status" -eq 69 ]
    [[ "$output" == *"[FAIL] remote drive:"* ]]
    [[ "$output" == *"[ok] local directory"* ]]
}

@test "doctor reports an unreachable remote" {
    export MOCK_RCLONE_ABOUT_EXIT=1
    run "$REPO_ROOT/drive-sync.sh" doctor
    [ "$status" -eq 69 ]
    [[ "$output" == *"[FAIL] remote drive: is not reachable"* ]]
}

@test "doctor reports a missing local directory" {
    rmdir "$HOME/drive"
    run "$REPO_ROOT/drive-sync.sh" doctor
    [ "$status" -eq 69 ]
    [[ "$output" == *"[FAIL] local directory"* ]]
}

@test "doctor reports a corrupt state file" {
    mkdir -p "$HOME/.drive-sync"
    echo "not json" > "$HOME/.drive-sync/state.json"
    run "$REPO_ROOT/drive-sync.sh" doctor
    [ "$status" -eq 69 ]
    [[ "$output" == *"[FAIL] state"* ]]
}

@test "doctor shows the active safety settings" {
    run "$REPO_ROOT/drive-sync.sh" doctor
    [[ "$output" == *"tracking: hash"* ]]
    [[ "$output" == *"delete limit: 50%"* ]]
}

@test "doctor never calls rclone sync" {
    run "$REPO_ROOT/drive-sync.sh" doctor
    ! grep -q '^sync \|^copy ' "$MOCK_STATE_DIR/rclone_calls.log" 2>/dev/null
}

@test "the help text lists doctor" {
    run "$REPO_ROOT/drive-sync.sh" --help
    [[ "$output" == *"doctor"* ]]
}
