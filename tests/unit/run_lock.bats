#!/usr/bin/env bats

# One mutating run at a time: a second push, pull, sync, update or restore
# exits 75 while another run holds ~/.drive-sync/run.lock. Read-only
# commands and dry runs are not blocked.

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
    export MOCK_RCLONE_EXIT_SEQUENCE="0"
    HOLDER=""
}

teardown() {
    [[ -n "$HOLDER" ]] && kill "$HOLDER" 2>/dev/null || true
    common_teardown
}

hold_lock() {
    flock "$HOME/.drive-sync/run.lock" sleep 30 &
    HOLDER=$!
    for _ in $(seq 1 50); do
        flock -n "$HOME/.drive-sync/run.lock" true 2>/dev/null || return 0
        sleep 0.1
    done
    return 1
}

cli() {
    "$REPO_ROOT/drive-sync.sh" "$@"
}

@test "push exits 75 while another run holds the lock" {
    hold_lock
    run --separate-stderr cli push
    [ "$status" -eq 75 ]
    [[ "$stderr" == *"another drive-sync run is in progress"* ]]
}

@test "pull, sync and update are blocked too" {
    hold_lock
    run cli pull
    [ "$status" -eq 75 ]
    run cli sync
    [ "$status" -eq 75 ]
    run cli update
    [ "$status" -eq 75 ]
}

@test "restore of a file is blocked but restore --list is not" {
    hold_lock
    run cli restore a.pdf
    [ "$status" -eq 75 ]
    run cli restore --list
    [ "$status" -eq 0 ]
}

@test "dry runs, plan, status and doctor are not blocked" {
    hold_lock
    run cli push -n
    [ "$status" -eq 0 ]
    run cli plan push
    [ "$status" -eq 0 ]
    run cli status
    [ "$status" -eq 0 ]
    run cli doctor
    [ "$status" -eq 0 ]
}

@test "a push runs once the lock is free" {
    run cli push
    [ "$status" -eq 0 ]
    [ -f "$HOME/.drive-sync/run.lock" ]
}

@test "two pushes in a row both succeed" {
    run cli push
    [ "$status" -eq 0 ]
    run cli push
    [ "$status" -eq 0 ]
}
