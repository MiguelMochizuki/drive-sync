#!/usr/bin/env bash
#
# state.sh: persistent state with file locking.
#
# Manages drive_sync state stored as JSON. Uses flock for concurrent run
# safety. Every function that can fail takes a log_file so failures are
# recorded in both the log file and, via log_error, on stderr.
#
# State schema (state.json):
#   last_sync: ISO 8601 timestamp of last successful sync, or null
#   last_compression: ISO 8601 timestamp of last compression run, or null
#   sync_status: "idle" | "success" | "failed"
#   rate_limit_recoveries: integer, number of rate limit recoveries
#   last_rate_limit: ISO 8601 timestamp of last rate limit, or null
#   total_files_synced: cumulative
#   total_bytes_synced: cumulative

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This script should be sourced, not executed directly" >&2
    exit 1
}

# Acquire the exclusive state lock on file descriptor 200, waiting up
# to 10 seconds.
#
# Parameters:
#   log_file: path to the active log file
#   lock_file: path to the lock file
#
# Returns: 0 once the lock is held; 1 and a logged error if the lock
#   file cannot be created or the lock cannot be acquired in time.
acquire_lock() {
    local log_file="$1"
    local lock_file="$2"

    touch "$lock_file" 2>/dev/null || {
        log_error "$log_file" "Cannot create lock file: $lock_file"
        return 1
    }

    exec 200>"$lock_file"
    if ! flock -w 10 200; then
        log_error "$log_file" "Failed to acquire state lock after 10 seconds"
        return 1
    fi
    return 0
}

# Release the state lock acquired by acquire_lock.
#
# Parameters: none.
#
# Returns: none. Best effort, never fails the caller.
release_lock() {
    flock -u 200 2>/dev/null || true
    exec 200>&- || true
}

# Create state.json with its default schema if it does not exist yet.
#
# Parameters:
#   log_file: path to the active log file
#   state_file: path to state.json
#   lock_file: path to the lock file
#
# Returns: 0 if the file already existed or was created successfully;
#   1 and a logged error on a lock or jq failure.
init_state() {
    local log_file="$1"
    local state_file="$2"
    local lock_file="$3"
    local state_dir
    state_dir=$(dirname "$state_file")

    mkdir -p "$state_dir"

    [[ -f "$state_file" ]] && return 0

    if ! acquire_lock "$log_file" "$lock_file"; then
        log_error "$log_file" "Failed to acquire lock for state initialization"
        return 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "$log_file" "jq is required for state management"
        release_lock
        exit 1
    fi

    jq -n '{
        "last_sync": null,
        "last_compression": null,
        "sync_status": "idle",
        "rate_limit_recoveries": 0,
        "last_rate_limit": null,
        "total_files_synced": 0,
        "total_bytes_synced": 0
    }' > "$state_file"

    release_lock
}

# Set one key in state.json to a new value, under the state lock.
#
# Parameters:
#   log_file: path to the active log file
#   state_file: path to state.json
#   lock_file: path to the lock file
#   key: the JSON key to update
#   value: the new value, always written as a JSON string
#
# Returns: 0 on success; 1 and a logged error on a lock, jq, or file
#   move failure.
update_state() {
    local log_file="$1"
    local state_file="$2"
    local lock_file="$3"
    local key="$4"
    local value="$5"

    if ! acquire_lock "$log_file" "$lock_file"; then
        log_error "$log_file" "Failed to acquire lock for state update"
        return 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "$log_file" "jq is required for state management"
        release_lock
        return 1
    fi

    local tmp_file="${state_file}.tmp.$$"

    if ! jq --arg key "$key" --arg value "$value" \
           '.[$key] = $value' "$state_file" > "$tmp_file" 2>/dev/null; then
        log_error "$log_file" "Failed to update state with jq"
        rm -f "$tmp_file"
        release_lock
        return 1
    fi

    if ! mv "$tmp_file" "$state_file"; then
        log_error "$log_file" "Failed to move updated state file"
        rm -f "$tmp_file"
        release_lock
        return 1
    fi

    release_lock
    return 0
}

# Read one key from state.json.
#
# Parameters:
#   state_file: path to state.json
#   key: the JSON key to read
#
# Returns: the value on stdout, or the text "null" if the key is
#   absent, jq is missing, or the file cannot be parsed. Returns 1 in
#   the jq-missing case, 0 otherwise.
get_state_value() {
    local state_file="$1"
    local key="$2"

    command -v jq &> /dev/null || { echo "null"; return 1; }

    jq -r --arg key "$key" '.[$key] // "null"' "$state_file" 2>/dev/null
}
