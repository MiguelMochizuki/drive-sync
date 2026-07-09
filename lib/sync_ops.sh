#!/usr/bin/env bash
#
# sync_ops.sh — Rclone synchronization operations
#
# Wrappers around rclone sync that add consistent performance and safety flags.
# Distinguishes temporary errors (exit 5/6 → retry), fatal errors (exit 7 → abort),
# and unknown errors (exit 1/other → retry once).

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This script should be sourced, not executed directly" >&2
    exit 1
}

#=============================================================================
# Rclone Flag Builder
#=============================================================================

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

sync_to_drive() {
    local log_file="$1"
    local local_path="$2"
    local remote_name="$3"
    local state_file="$4"
    local lock_file="$5"
    local dry_run="${6:-false}"

    local flags
    flags=$(build_rclone_flags "$dry_run")

    log_info "$log_file" "Uploading to Google Drive..."

    if rclone sync "$local_path" "$remote_name" $flags; then
        log_success "$log_file" "Upload completed successfully"
        update_state "$state_file" "$lock_file" "last_sync" "$(date -Iseconds)"
        update_state "$state_file" "$lock_file" "sync_status" "success"
        return 0
    else
        local exit_code=$?
        if is_fatal_error "$exit_code"; then
            log_error "$log_file" "Upload failed with fatal error $exit_code (permanent)"
            update_state "$state_file" "$lock_file" "sync_status" "failed"
            return 3
        elif is_rate_limit_error "$exit_code"; then
            log_warning "$log_file" "Temporary error detected (code $exit_code)"
            return 2
        else
            log_error "$log_file" "Upload failed with code $exit_code"
            update_state "$state_file" "$lock_file" "sync_status" "failed"
            return 1
        fi
    fi
}

sync_from_drive() {
    local log_file="$1"
    local local_path="$2"
    local remote_name="$3"
    local dry_run="${4:-false}"

    local flags
    flags=$(build_rclone_flags "$dry_run")

    log_info "$log_file" "Downloading from Google Drive..."

    if rclone sync "$remote_name" "$local_path" $flags; then
        log_success "$log_file" "Download completed successfully"
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
