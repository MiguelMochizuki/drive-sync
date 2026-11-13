#!/usr/bin/env bash
#
# config.sh — Configuration constants and defaults
#
# All paths, performance tuning, compression profiles, and retry logic.
# Override any variable by creating ~/.drive-sync/drive-sync.conf.
#
# Service data (state, logs, lock) lives in ~/.drive-sync/, not in the
# synced directory — your ~/drive stays clean with only your files.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This script should be sourced, not executed directly" >&2
    exit 1
}

#=============================================================================
# Version — single source of truth
#=============================================================================

readonly VERSION="2.1.0"

#=============================================================================
# Service Directory
#=============================================================================

readonly DRIVE_SYNC_HOME="${HOME}/.drive-sync"

mkdir -p "$DRIVE_SYNC_HOME"

#=============================================================================
# Directory Paths
#=============================================================================

REMOTE_NAME="drive:"
DRIVE_ROOT="${HOME}/drive"
LOCAL_PATH="${DRIVE_ROOT}"
STATE_DIR="${DRIVE_SYNC_HOME}"
LOG_DIR="${DRIVE_SYNC_HOME}"
STATE_FILE="${STATE_DIR}/state.json"
LOCK_FILE="${STATE_DIR}/state.lock"
LOG_FILE="${LOG_DIR}/drive_sync.log"

#=============================================================================
# Rclone Performance Tuning
#=============================================================================

RCLONE_TRANSFERS="2"
RCLONE_CHECKERS="2"
RCLONE_TPSLIMIT="8"
RCLONE_TPSLIMIT_BURST="5"
RCLONE_TIMEOUT="5m"
RCLONE_RETRIES="3"
RCLONE_DRIVE_CHUNK_SIZE="128M"

#=============================================================================
# PDF Compression
#
# ⚠️  WARNING: Overriding these mid-flight can corrupt your workflow:
#   OPTIMIZED_MARKER — changing the suffix makes already-optimized PDFs invisible
#   GHOSTSCRIPT_DEVICE — must be a valid Ghostscript device or compression fails
#   MIN_VALID_COMPRESSED_SIZE — too low accepts corrupt PDFs as valid
#=============================================================================

OPTIMIZED_MARKER=".optimized.pdf"
GHOSTSCRIPT_DEVICE="pdfwrite"
MIN_VALID_COMPRESSED_SIZE=1024

#=============================================================================
# Rate Limiting and Retry
#=============================================================================

RATE_LIMIT_BACKOFF_SECONDS=300
MAX_RETRIES=3
RETRY_DELAY=60

#=============================================================================
# Safety
#
# MAX_DELETE_PERCENT: a push or update that would delete more than this
#   percentage of the destination's files aborts, even with -f. Set it to
#   100 to disable the limit.
# ARCHIVE_DIR: where `update` moves local files it would delete, in a
#   timestamped subdirectory (rclone --backup-dir).
# REMOTE_BACKUP_DIR: optional rclone --backup-dir for `push`. It must sit
#   OUTSIDE the destination (rclone refuses overlapping paths), so it only
#   works when REMOTE_NAME points at a subfolder, for example
#   REMOTE_NAME="drive:Sync" and REMOTE_BACKUP_DIR="drive:Sync-archive".
#   Empty by default: push relies on Google Drive's trash (--drive-use-trash).
#=============================================================================

MAX_DELETE_PERCENT="${MAX_DELETE_PERCENT:-50}"
ARCHIVE_DIR="${ARCHIVE_DIR:-${DRIVE_SYNC_HOME}/archive}"
REMOTE_BACKUP_DIR="${REMOTE_BACKUP_DIR:-}"

#=============================================================================
# Exit Codes (see docs/CONTRACT.md)
#=============================================================================

readonly EX_OK=0
readonly EX_FAILURE=1
readonly EX_USAGE=2
readonly EX_UNAVAILABLE=69
readonly EX_TEMPFAIL=75

#=============================================================================
# User Overrides — source ~/.drive-sync/drive-sync.conf if present
#=============================================================================

if [[ -f "${DRIVE_SYNC_HOME}/drive-sync.conf" ]]; then
    source "${DRIVE_SYNC_HOME}/drive-sync.conf"
    LOCAL_PATH="${DRIVE_ROOT}"
fi

#=============================================================================
# Derived Variables
#=============================================================================

ALLOWED_PATHS=("${DRIVE_ROOT}")

#=============================================================================
# Lock Down — all variables are now read-only
#=============================================================================

readonly REMOTE_NAME DRIVE_ROOT LOCAL_PATH STATE_DIR LOG_DIR
readonly STATE_FILE LOCK_FILE LOG_FILE
readonly RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_TPSLIMIT
readonly RCLONE_TPSLIMIT_BURST RCLONE_TIMEOUT RCLONE_RETRIES
readonly RCLONE_DRIVE_CHUNK_SIZE
readonly OPTIMIZED_MARKER GHOSTSCRIPT_DEVICE MIN_VALID_COMPRESSED_SIZE
readonly RATE_LIMIT_BACKOFF_SECONDS MAX_RETRIES RETRY_DELAY
readonly ALLOWED_PATHS
readonly MAX_DELETE_PERCENT ARCHIVE_DIR REMOTE_BACKUP_DIR

#=============================================================================
# Getters
#=============================================================================

get_version()                           { echo "$VERSION"; }
get_remote_name()                       { echo "$REMOTE_NAME"; }
get_drive_root()                        { echo "$DRIVE_ROOT"; }
get_local_path()                        { echo "$LOCAL_PATH"; }
get_log_file()                          { echo "$LOG_FILE"; }
get_state_file()                        { echo "$STATE_FILE"; }
get_lock_file()                         { echo "$LOCK_FILE"; }
get_optimized_marker()                  { echo "$OPTIMIZED_MARKER"; }
get_allowed_paths()                     { echo "${ALLOWED_PATHS[@]}"; }
get_max_retries()                       { echo "$MAX_RETRIES"; }
get_retry_delay()                       { echo "$RETRY_DELAY"; }
get_rate_limit_backoff()                { echo "$RATE_LIMIT_BACKOFF_SECONDS"; }
get_min_valid_compressed_size()         { echo "$MIN_VALID_COMPRESSED_SIZE"; }
