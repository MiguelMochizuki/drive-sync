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
#   schema_version: 2 (v1 states are migrated by init_state, with a backup)
#   files: map of path relative to the synced directory to
#     {hash, original_size, size, mtime}, the content already optimized

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

# Take the run lock for this process, without waiting. Unlike the state
# lock (held only while state.json is written), it is held until the
# process exits, so only one push, pull, sync, update or restore runs at a
# time. A second run would otherwise overlap on the same files and state.
#
# Parameters:
#   log_file: path to the active log file
#   run_lock_file: path to the run lock file
#
# Returns: 0 once the lock is held; 1 and a logged error when another run
#   holds it or the file cannot be created.
acquire_run_lock() {
    local log_file="$1"
    local run_lock_file="$2"

    if ! { exec 201>"$run_lock_file"; } 2>/dev/null; then
        log_error "$log_file" "Cannot create run lock file: $run_lock_file"
        return 1
    fi
    if ! flock -n 201; then
        log_error "$log_file" "Another drive-sync run is in progress (lock: $run_lock_file)"
        echo "drive-sync: another drive-sync run is in progress, try again when it finishes" >&2
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

    if [[ -f "$state_file" ]]; then
        migrate_state "$log_file" "$state_file" "$lock_file" || \
            log_warning "$log_file" "State file could not be migrated; leaving it as is"
        return 0
    fi

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
        "total_bytes_synced": 0,
        "schema_version": 2,
        "files": {}
    }' > "$state_file"

    release_lock
}

# Upgrade a v1 state.json to schema 2 (adds schema_version and files),
# keeping a copy of the original next to it as state.json.bak-v1.
#
# Parameters:
#   log_file: path to the active log file
#   state_file: path to state.json
#   lock_file: path to the lock file
#
# Returns: 0 if the state is already v2 or was migrated; 1 and a logged
#   error if the file is not valid JSON or cannot be written. A failed
#   migration leaves the file untouched.
migrate_state() {
    local log_file="$1"
    local state_file="$2"
    local lock_file="$3"

    local version
    version=$(jq -r '.schema_version // 1' "$state_file" 2>/dev/null) || {
        log_error "$log_file" "State file is not valid JSON: $state_file"
        return 1
    }
    [[ "$version" -ge 2 ]] && return 0

    acquire_lock "$log_file" "$lock_file" || return 1

    local tmp_file="${state_file}.tmp.$$"
    if cp -p "$state_file" "${state_file}.bak-v1" && \
       jq '.schema_version = 2 | .files = (.files // {})' "$state_file" > "$tmp_file" && \
       mv "$tmp_file" "$state_file"; then
        log_info "$log_file" "Migrated state to schema 2 (backup: ${state_file}.bak-v1)"
        release_lock
        return 0
    fi

    log_error "$log_file" "Failed to migrate state file"
    rm -f "$tmp_file"
    release_lock
    return 1
}

# Remember that a file's current content is already optimized.
#
# Parameters:
#   log_file: path to the active log file
#   state_file: path to state.json
#   lock_file: path to the lock file
#   relpath: path relative to the synced directory
#   hash: SHA-256 of the file as it is now
#   original_size: size in bytes before optimization
#   size: size in bytes now
#   mtime: modification time (epoch seconds) now
#
# Returns: 0 on success; 1 and a logged error otherwise. When the hash
#   matches the recorded one, the recorded original_size is kept.
record_file_state() {
    local log_file="$1"
    local state_file="$2"
    local lock_file="$3"
    local relpath="$4"
    local hash="$5"
    local original_size="$6"
    local size="$7"
    local mtime="$8"

    acquire_lock "$log_file" "$lock_file" || return 1

    local tmp_file="${state_file}.tmp.$$"
    if jq --arg p "$relpath" --arg h "$hash" --argjson o "$original_size" \
          --argjson s "$size" --argjson m "$mtime" \
          '.files[$p] = {
              hash: $h,
              original_size: (if .files[$p].hash == $h then (.files[$p].original_size // $o) else $o end),
              size: $s,
              mtime: $m
          }' "$state_file" > "$tmp_file" 2>/dev/null && \
       mv "$tmp_file" "$state_file"; then
        release_lock
        return 0
    fi

    log_error "$log_file" "Failed to record file state for $relpath"
    rm -f "$tmp_file"
    release_lock
    return 1
}

# List the tracked files, one per line.
#
# Parameters:
#   state_file: path to state.json
#
# Returns: "path<TAB>hash<TAB>size<TAB>mtime" lines on stdout; nothing if
#   the state has no files or cannot be read. ponytail: jq escapes tabs
#   and newlines inside paths, so such paths are never matched as tracked
#   and are simply reprocessed; handle if it ever matters.
list_tracked_files() {
    local state_file="$1"

    jq -r '(.files // {}) | to_entries[]
           | [.key, .value.hash, .value.size, .value.mtime] | @tsv' \
        "$state_file" 2>/dev/null || true
}

# List the savings recorded for every tracked file, for status.
#
# Parameters:
#   state_file: path to state.json
#
# Returns: 0, printing one "path<TAB>original_size<TAB>size" line per entry
#   of the files map (nothing when the map is empty or the file is missing).
list_tracked_savings() {
    local state_file="$1"

    jq -r '(.files // {}) | to_entries[]
           | [.key, (.value.original_size // 0), (.value.size // 0)] | @tsv' \
        "$state_file" 2>/dev/null || true
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
