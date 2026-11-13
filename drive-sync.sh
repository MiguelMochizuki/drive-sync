#!/usr/bin/env bash
#
# drive-sync.sh: Google Drive Sync Manager v2.2.0
#
# Safe, modular bidirectional sync with optional PDF compression.
# Originals are ALWAYS preserved if compression fails.
# Service data lives in ~/.drive-sync/, not in the synced directory.
#
# Usage:
#   ./drive-sync.sh [command] [options]
#
# See: ./drive-sync.sh --help

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
source "${LIB_DIR}/safety.sh"
source "${LIB_DIR}/cli.sh"

#=============================================================================
# Environment Validation
#=============================================================================

# Check that required tools are installed and the rclone remote exists.
# Exits the process with EX_UNAVAILABLE when anything required is missing;
# a missing bc is only a warning (integer arithmetic is used instead).
#
# Parameters:
#   log_file: path to the active log file
#   remote_name: the configured rclone remote that must be listed
#
# Returns: 0 when the environment is valid; does not return otherwise.
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
        exit "$EX_UNAVAILABLE"
    fi

    if ! rclone listremotes 2>/dev/null | grep -q "^${remote_name}$"; then
        log_error "$log_file" "Rclone remote '${remote_name}' not configured"
        echo "Run 'rclone config' to configure Google Drive" >&2
        exit "$EX_UNAVAILABLE"
    fi

    log_info "$log_file" "Environment validation passed"
}

#=============================================================================
# Sync Orchestrator
#=============================================================================

# Translate the private 0/1/2/3 result of a sync operation into a decision:
# done, retry, or give up. The code returned here is consumed by do_sync,
# not the process's final exit code.
#
# Parameters:
#   log_file: path to the active log file
#   remote_name: the configured rclone remote
#   state_file: path to state.json
#   lock_file: path to the flock file
#   backoff_seconds: wait used when recovering from a rate limit
#   retry_delay: seconds to wait before retrying an unclassified failure
#   result: sync_ops result (0 success, 2 temporary, 3 fatal, 1 other)
#   attempt: current attempt number, starting at 1
#   max_retries: maximum number of attempts
#
# Returns: 0 on success; 2 to ask do_sync to retry (after recovery or
#   delay); EX_TEMPFAIL when recovery failed or retries are exhausted;
#   EX_UNAVAILABLE on a fatal error.
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
                return "$EX_TEMPFAIL"
            fi
            ;;
        3)
            log_error "$log_file" "Fatal error (permanent, retries won't help)"
            return "$EX_UNAVAILABLE"
            ;;
        *)
            log_error "$log_file" "Sync failed with error $result"
            if [[ $attempt -lt $max_retries ]]; then
                log_info "$log_file" "Retrying in ${retry_delay} seconds..."
                sleep "$retry_delay"
                return 2
            else
                return "$EX_TEMPFAIL"
            fi
            ;;
    esac
}

# Run one direction (push, pull, update or sync) with retries. push and
# sync compress PDFs first and abort if compression fails; sync pulls
# before it pushes and stops at the first failing half.
#
# Parameters:
#   log_file: path to the active log file
#   local_path: local directory being synced
#   remote_name: the configured rclone remote
#   state_file: path to state.json
#   lock_file: path to the flock file
#   optimized_marker: suffix marking already-compressed PDFs
#   gs_device: Ghostscript device used for compression
#   min_valid_size: smallest size accepted as a valid compressed file
#   backoff_seconds: wait used when recovering from a rate limit
#   retry_delay: seconds to wait before retrying
#   max_retries: maximum number of attempts
#   direction: "push", "pull", "update" or "sync"
#   dry_run: "true" to preview without transferring, default "false"
#   allowed_paths: remaining arguments, the paths operations may touch
#
# Returns: 0 on success; 1 when compression failed or the deletion guard
#   aborted (see lib/safety.sh); EX_TEMPFAIL when retries are exhausted;
#   EX_UNAVAILABLE on a fatal error. Reads the FORCE environment variable.
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
    local guarded="false"

    while [[ $attempt -le $max_retries ]]; do
        log_info "$log_file" "Sync attempt $attempt of $max_retries"

        if [[ "$direction" == "push" ]] || [[ "$direction" == "sync" ]]; then
            if ! compress_drive_pdfs "$log_file" "$local_path" "$optimized_marker" \
                                     "$state_file" "$lock_file" \
                                     "$gs_device" "$min_valid_size" \
                                     "${allowed_paths[@]}"; then
                log_error "$log_file" "Compression failed, aborting sync"
                log_error "$log_file" "Failed files will be retried on next run"
                return 1
            fi
        fi

        local sync_result=0
        case "$direction" in
            push)
                if [[ "$guarded" != "true" ]]; then
                    guard_deletions "$log_file" "$local_path" "$remote_name" "$dry_run" || return 1
                    guarded="true"
                fi
                if sync_to_drive "$log_file" "$local_path" "$remote_name" \
                                 "$state_file" "$lock_file" "$dry_run"; then
                    sync_result=0
                else
                    sync_result=$?
                fi
                ;;
            pull)
                if sync_from_drive "$log_file" "$local_path" "$remote_name" "$dry_run"; then
                    sync_result=0
                else
                    sync_result=$?
                fi
                ;;
            update)
                if [[ "$guarded" != "true" ]]; then
                    guard_deletions "$log_file" "$remote_name" "$local_path" "$dry_run" || return 1
                    guarded="true"
                fi
                if update_from_drive "$log_file" "$local_path" "$remote_name" "$dry_run"; then
                    sync_result=0
                else
                    sync_result=$?
                fi
                ;;
            sync)
                if sync_from_drive "$log_file" "$local_path" "$remote_name" "$dry_run"; then
                    local pull_result=0
                else
                    local pull_result=$?
                fi
                if [[ $pull_result -eq 0 ]]; then
                    if [[ "$guarded" != "true" ]]; then
                        guard_deletions "$log_file" "$local_path" "$remote_name" "$dry_run" || return 1
                        guarded="true"
                    fi
                    if sync_to_drive "$log_file" "$local_path" "$remote_name" \
                                     "$state_file" "$lock_file" "$dry_run"; then
                        sync_result=0
                    else
                        sync_result=$?
                    fi
                elif [[ $pull_result -eq 2 ]]; then
                    sync_result=2
                elif [[ $pull_result -eq 3 ]]; then
                    sync_result=3
                else
                    sync_result=$pull_result
                fi
                ;;
        esac

        set +e
        handle_sync_result "$log_file" "$remote_name" "$state_file" "$lock_file" \
                          "$backoff_seconds" "$retry_delay" "$sync_result" \
                          "$attempt" "$max_retries"
        local handle_result=$?
        set -e

        case $handle_result in
            0) return 0 ;;
            2) attempt=$((attempt + 1)); continue ;;
            *) return "$handle_result" ;;
        esac
    done

    log_error "$log_file" "Max retries exceeded"
    return "$EX_TEMPFAIL"
}

#=============================================================================
# Main Entry Point
#=============================================================================

# Entry point: load settings, parse arguments, validate the environment
# and dispatch to push/pull/sync/update/status/doctor/ratelimit. Exit codes
# follow docs/CONTRACT.md: bare invocation is a usage error (EX_USAGE),
# while -h/--help and -V/--version exit 0.
#
# Parameters:
#   args: command-line arguments, [-v] <command> [options]
#
# Returns: the status of the dispatched command; usage errors and
#   environment failures exit the process directly.
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

    [[ $# -eq 0 ]] && { show_usage >&2; exit "$EX_USAGE"; }

    if [[ "$1" == -* ]]; then
        case "$1" in
            -V|--version) echo "drive_sync version ${VERSION}"; exit 0 ;;
            -h|--help)    show_help; exit 0 ;;
            -v|--verbose) export VERBOSE="true" ;;
            *) show_usage >&2; exit "$EX_USAGE" ;;
        esac
        [[ "$1" == "-v" || "$1" == "--verbose" ]] || exit 0
        shift
        [[ $# -eq 0 ]] && { show_usage >&2; exit "$EX_USAGE"; }
    fi

    init_logging "$log_file"
    init_state "$log_file" "$state_file" "$lock_file"
    # doctor reports every problem itself, so it must not stop at the first one.
    [[ "$1" == "doctor" ]] || validate_environment "$log_file" "$remote_name"

    command="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run)  dry_run="true"; shift ;;
            -f|--force)    force="true"; export FORCE="true"; shift ;;
            -v|--verbose)  export VERBOSE="true"; shift ;;
            -V|--version)  echo "drive_sync version ${VERSION}"; exit 0 ;;
            -h|--help)     show_help; exit 0 ;;
            *) show_usage >&2; exit "$EX_USAGE" ;;
        esac
    done

    case "$command" in
        push|pull|sync|update)
            log_info "$log_file" "${command^}ing $( [[ "$command" == "push" || "$command" == "sync" ]] && echo "to" || echo "from" ) Drive"
            do_sync "$log_file" "$local_path" "$remote_name" "$state_file" \
                    "$lock_file" "$optimized_marker" "$gs_device" \
                    "$min_valid_size" "$backoff_seconds" "$retry_delay" \
                    "$max_retries" "$command" "$dry_run" "${allowed_paths[@]}"
            ;;
        status)
            show_status "$log_file" "$state_file" "$remote_name" \
                       "$local_path" "$optimized_marker"
            ;;
        doctor)
            run_doctor "$log_file" "$state_file" "$remote_name" "$local_path"
            ;;
        ratelimit)
            recover_from_rate_limit "$log_file" "$remote_name" "$state_file" \
                                    "$lock_file" "$backoff_seconds"
            ;;
        *)
            show_usage >&2
            exit "$EX_USAGE"
            ;;
    esac
}

main "$@"
