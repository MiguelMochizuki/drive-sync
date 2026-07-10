#!/usr/bin/env bash
#
# drive_sync.sh — Google Drive Sync Manager v1.0.1
#
# Safe, modular bidirectional sync with optional PDF compression.
# Originals are ALWAYS preserved if compression fails.
# Service data lives in ~/.drive-sync/, not in the synced directory.
#
# Usage:
#   ./drive_sync.sh [command] [options]
#
# See: ./drive_sync.sh --help

set -euo pipefail

#=============================================================================
# Module Loader
#=============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/state.sh"
source "${LIB_DIR}/storage.sh"
source "${LIB_DIR}/limit.sh"
source "${LIB_DIR}/compression.sh"
source "${LIB_DIR}/sync_ops.sh"
source "${LIB_DIR}/cli.sh"

#=============================================================================
# Environment Validation
#=============================================================================

validate_environment() {
    local log_file="$1"
    local remote_name="$2"
    local missing_deps=()

    for cmd in rclone gs jq; do
        command -v "$cmd" &> /dev/null || missing_deps+=("$cmd")
    done

    command -v bc &> /dev/null || \
        log_warning "$log_file" "bc not found, using integer arithmetic"

    if ! command -v flock &> /dev/null; then
        log_error "$log_file" "flock is required for safe concurrent execution"
        missing_deps+=("flock")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "$log_file" "Missing dependencies: ${missing_deps[*]}"
        echo "Install with: sudo apt-get install ${missing_deps[*]}" >&2
        exit 1
    fi

    if ! rclone listremotes 2>/dev/null | grep -q "^${remote_name}$"; then
        log_error "$log_file" "Rclone remote '${remote_name}' not configured"
        echo "Run 'rclone config' to configure Google Drive" >&2
        exit 1
    fi

    log_info "$log_file" "Environment validation passed"
}

#=============================================================================
# Sync Orchestrator
#=============================================================================

handle_sync_result() {
    local log_file="$1"
    local remote_name="$2"
    local state_file="$3"
    local lock_file="$4"
    local backoff_seconds="$5"
    local retry_delay="$6"
    local result="$7"
    local attempt="$8"
    local max_retries="$9"

    case $result in
        0)
            log_success "$log_file" "Sync completed successfully"
            show_storage_usage "$log_file" "$remote_name"
            return 0
            ;;
        2)
            log_warning "$log_file" "Temporary error detected"
            if recover_from_rate_limit "$log_file" "$remote_name" "$state_file" \
                                       "$lock_file" "$backoff_seconds"; then
                return 2
            else
                log_error "$log_file" "Failed to recover from temporary error"
                return 1
            fi
            ;;
        3)
            log_error "$log_file" "Fatal error (permanent, retries won't help)"
            return 1
            ;;
        *)
            log_error "$log_file" "Sync failed with error $result"
            if [[ $attempt -lt $max_retries ]]; then
                log_info "$log_file" "Retrying in ${retry_delay} seconds..."
                sleep "$retry_delay"
                return 2
            else
                return 1
            fi
            ;;
    esac
}

do_sync() {
    local log_file="$1"
    local local_path="$2"
    local remote_name="$3"
    local state_file="$4"
    local lock_file="$5"
    local optimized_marker="$6"
    local gs_device="$7"
    local min_valid_size="$8"
    local backoff_seconds="$9"
    local retry_delay="${10}"
    local max_retries="${11}"
    local direction="${12}"
    local dry_run="${13:-false}"
    shift 13
    local -a allowed_paths=("$@")

    local attempt=1

    while [[ $attempt -le $max_retries ]]; do
        log_info "$log_file" "Sync attempt $attempt of $max_retries"

        if [[ "$direction" == "push" ]] || [[ "$direction" == "sync" ]]; then
            if ! compress_drive_pdfs "$log_file" "$local_path" "$optimized_marker" \
                                     "$state_file" "$lock_file" \
                                     "$gs_device" "$min_valid_size" \
                                     "${allowed_paths[@]}"; then
                log_error "$log_file" "Compression failed — aborting sync"
                log_error "$log_file" "Failed files will be retried on next run"
                return 1
            fi
        fi

        local sync_result=0
        case "$direction" in
            push)
                sync_to_drive "$log_file" "$local_path" "$remote_name" \
                             "$state_file" "$lock_file" "$dry_run"
                sync_result=$?
                ;;
            pull)
                sync_from_drive "$log_file" "$local_path" "$remote_name" "$dry_run"
                sync_result=$?
                ;;
            sync)
                sync_from_drive "$log_file" "$local_path" "$remote_name" "$dry_run"
                local pull_result=$?
                if [[ $pull_result -eq 0 ]]; then
                    sync_to_drive "$log_file" "$local_path" "$remote_name" \
                                 "$state_file" "$lock_file" "$dry_run"
                    sync_result=$?
                elif [[ $pull_result -eq 2 ]]; then
                    sync_result=2
                elif [[ $pull_result -eq 3 ]]; then
                    sync_result=3
                else
                    sync_result=$pull_result
                fi
                ;;
        esac

        handle_sync_result "$log_file" "$remote_name" "$state_file" "$lock_file" \
                          "$backoff_seconds" "$retry_delay" "$sync_result" \
                          "$attempt" "$max_retries"
        local handle_result=$?

        case $handle_result in
            0) return 0 ;;
            1) return 1 ;;
            2) attempt=$((attempt + 1)); continue ;;
            3) return 1 ;;
        esac
    done

    log_error "$log_file" "Max retries exceeded"
    return 1
}

#=============================================================================
# Main Entry Point
#=============================================================================

main() {
    local log_file state_file lock_file local_path remote_name
    local optimized_marker gs_device min_valid_size backoff_seconds retry_delay max_retries
    local -a allowed_paths
    local command dry_run="false" force="false"

    log_file=$(get_log_file)
    state_file=$(get_state_file)
    lock_file=$(get_lock_file)
    local_path=$(get_local_path)
    remote_name=$(get_remote_name)
    optimized_marker=$(get_optimized_marker)
    gs_device="$GHOSTSCRIPT_DEVICE"
    min_valid_size=$(get_min_valid_compressed_size)
    backoff_seconds=$(get_rate_limit_backoff)
    retry_delay=$(get_retry_delay)
    max_retries=$(get_max_retries)
    read -r -a allowed_paths <<< "$(get_allowed_paths)"

    [[ $# -eq 0 ]] && { show_help; exit 1; }

    if [[ "$1" == -* ]]; then
        case "$1" in
            -v|--version) echo "drive_sync version ${VERSION}"; exit 0 ;;
            -h|--help)    show_help; exit 0 ;;
            *) echo "Unknown option: $1"; show_help; exit 1 ;;
        esac
    fi

    init_logging "$log_file"
    init_state "$state_file" "$lock_file"
    validate_environment "$log_file" "$remote_name"

    command="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run) dry_run="true"; shift ;;
            -f|--force)   force="true"; shift ;;
            -v|--version) echo "drive_sync version ${VERSION}"; exit 0 ;;
            -h|--help)    show_help; exit 0 ;;
            *) echo "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done

    case "$command" in
        push|pull|sync)
            log_info "$log_file" "${command^}ing $( [[ "$command" != "pull" ]] && echo "to" || echo "from" ) Drive"
            do_sync "$log_file" "$local_path" "$remote_name" "$state_file" \
                    "$lock_file" "$optimized_marker" "$gs_device" \
                    "$min_valid_size" "$backoff_seconds" "$retry_delay" \
                    "$max_retries" "$command" "$dry_run" "${allowed_paths[@]}"
            ;;
        status)
            show_status "$log_file" "$state_file" "$remote_name" \
                       "$local_path" "$optimized_marker"
            ;;
        ratelimit)
            recover_from_rate_limit "$log_file" "$remote_name" "$state_file" \
                                    "$lock_file" "$backoff_seconds"
            ;;
        *)
            echo "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
