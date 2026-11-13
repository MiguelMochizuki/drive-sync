#!/usr/bin/env bash
#
# sync_ops.sh: Rclone synchronization operations
#
# Wrappers around rclone sync that add consistent performance and safety flags.
# Distinguishes temporary errors (exit 5/6: retry), fatal errors (exit 7: abort),
# and unknown errors (exit 1/other: retry once).

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This script should be sourced, not executed directly" >&2
    exit 1
}

#=============================================================================
# Rclone Flag Builder
#=============================================================================

# Build the shared rclone flag string for both push and pull.
#
# Parameters:
#   dry_run: "true" to append --dry-run, anything else to omit it
#
# Returns: the flag string on stdout.
build_rclone_flags() {
    local dry_run="$1"

    local flags="--size-only --fast-list --progress --stats 10s"
    flags+=" --transfers $RCLONE_TRANSFERS --checkers $RCLONE_CHECKERS"
    flags+=" --tpslimit $RCLONE_TPSLIMIT --tpslimit-burst $RCLONE_TPSLIMIT_BURST"
    flags+=" --timeout $RCLONE_TIMEOUT --retries $RCLONE_RETRIES"
    flags+=" --drive-chunk-size $RCLONE_DRIVE_CHUNK_SIZE"
    flags+=" --drive-skip-gdocs --drive-skip-shortcuts"
    flags+=" --ignore-errors --contimeout 30s"
    flags+=" --create-empty-src-dirs"

    [[ "$dry_run" == "true" ]] && flags+=" --dry-run"

    echo "$flags"
}

#=============================================================================
# Sync Operations
#=============================================================================

# Upload local_path to remote_name with rclone sync, updating state on
# success or failure. A dry run never writes state.
#
# Parameters:
#   log_file: path to the active log file
#   local_path: directory to upload
#   remote_name: the configured rclone remote
#   state_file: path to state.json
#   lock_file: path to the lock file
#   dry_run: "true" to preview without transferring, default "false"
#
# Returns: 0 on success; 2 on a temporary/rate-limit error (rclone exit
#   5 or 6); 3 on a fatal error (rclone exit 7); 1 on any other
#   nonzero exit.
sync_to_drive() {
    local log_file="$1"
    local local_path="$2"
    local remote_name="$3"
    local state_file="$4"
    local lock_file="$5"
    local dry_run="${6:-false}"

    local flags
    flags=$(build_rclone_flags "$dry_run")

    # Deleted remote files go to Drive's trash (or REMOTE_BACKUP_DIR).
    local -a safety=(--drive-use-trash)
    [[ -n "${REMOTE_BACKUP_DIR:-}" ]] && \
        safety+=(--backup-dir "${REMOTE_BACKUP_DIR}/$(date +%Y%m%dT%H%M%S)")

    log_info "$log_file" "Uploading to Google Drive..."

    if rclone sync "$local_path" "$remote_name" $flags "${safety[@]}"; then
        if [[ "$dry_run" == "true" ]]; then
            log_success "$log_file" "Dry run finished, nothing was uploaded"
        else
            log_success "$log_file" "Upload completed successfully"
        fi
        if [[ "$dry_run" != "true" ]]; then
            update_state "$log_file" "$state_file" "$lock_file" "last_sync" "$(date -Iseconds)"
            update_state "$log_file" "$state_file" "$lock_file" "sync_status" "success"
        fi
        return 0
    else
        local exit_code=$?
        if is_fatal_error "$exit_code"; then
            log_error "$log_file" "Upload failed with fatal error $exit_code (permanent)"
            [[ "$dry_run" != "true" ]] && update_state "$log_file" "$state_file" "$lock_file" "sync_status" "failed"
            return 3
        elif is_rate_limit_error "$exit_code"; then
            log_warning "$log_file" "Temporary error detected (code $exit_code)"
            return 2
        else
            log_error "$log_file" "Upload failed with code $exit_code"
            [[ "$dry_run" != "true" ]] && update_state "$log_file" "$state_file" "$lock_file" "sync_status" "failed"
            return 1
        fi
    fi
}

# Download remote_name to local_path with rclone copy: adds and updates
# files locally, but never deletes local files absent from the remote.
# Push (sync_to_drive) mirrors deletions to the remote; pull never
# mirrors deletions to local: work happens locally, then push sends it.
#
# Parameters:
#   log_file: path to the active log file
#   local_path: directory to download into
#   remote_name: the configured rclone remote
#   dry_run: "true" to preview without transferring, default "false"
#
# Returns: 0 on success; 2 on a temporary/rate-limit error; 3 on a
#   fatal error; 1 on any other nonzero exit. Does not touch state,
#   since only push tracks last_sync/sync_status today.
sync_from_drive() {
    local log_file="$1"
    local local_path="$2"
    local remote_name="$3"
    local dry_run="${4:-false}"

    local flags
    flags=$(build_rclone_flags "$dry_run")

    log_info "$log_file" "Downloading from Google Drive..."

    if rclone copy "$remote_name" "$local_path" $flags; then
        if [[ "$dry_run" == "true" ]]; then
            log_success "$log_file" "Dry run finished, nothing was downloaded"
        else
            log_success "$log_file" "Download completed successfully"
        fi
        return 0
    else
        local exit_code=$?
        if is_fatal_error "$exit_code"; then
            log_error "$log_file" "Download failed with fatal error $exit_code (permanent)"
            return 3
        elif is_rate_limit_error "$exit_code"; then
            log_warning "$log_file" "Temporary error detected (code $exit_code)"
            return 2
        else
            log_error "$log_file" "Download failed with code $exit_code"
            return 1
        fi
    fi
}

# Mirror remote_name onto local_path with rclone sync: adds, updates,
# AND deletes local files absent from the remote. Unlike sync_from_drive
# (which never deletes locally), this makes local match Drive exactly.
#
# Parameters:
#   log_file: path to the active log file
#   local_path: directory to mirror into
#   remote_name: the configured rclone remote
#   dry_run: "true" to preview without transferring, default "false"
#
# Returns: 0 on success; 2 on a temporary/rate-limit error; 3 on a
#   fatal error; 1 on any other nonzero exit. Does not touch state.
update_from_drive() {
    local log_file="$1"
    local local_path="$2"
    local remote_name="$3"
    local dry_run="${4:-false}"

    local flags
    flags=$(build_rclone_flags "$dry_run")

    # Local files the mirror would delete are moved here instead.
    local archive="${ARCHIVE_DIR}/$(date +%Y%m%dT%H%M%S)"

    log_info "$log_file" "Mirroring from Google Drive (local files not on Drive are archived in $archive)..."

    if rclone sync "$remote_name" "$local_path" $flags --backup-dir "$archive"; then
        if [[ "$dry_run" == "true" ]]; then
            log_success "$log_file" "Dry run finished, nothing was changed locally"
        else
            log_success "$log_file" "Mirror completed successfully"
        fi
        return 0
    else
        local exit_code=$?
        if is_fatal_error "$exit_code"; then
            log_error "$log_file" "Mirror failed with fatal error $exit_code (permanent)"
            return 3
        elif is_rate_limit_error "$exit_code"; then
            log_warning "$log_file" "Temporary error detected (code $exit_code)"
            return 2
        else
            log_error "$log_file" "Mirror failed with code $exit_code"
            return 1
        fi
    fi
}
