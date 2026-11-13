#!/usr/bin/env bash
#
# cli.sh: Command-line interface
#
# Provides help text, status display, and user-facing reset logic.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This script should be sourced, not executed directly" >&2
    exit 1
}

#=============================================================================
# Help
#=============================================================================

# Print a short usage synopsis, for a usage error.
#
# Parameters: none.
#
# Returns: the synopsis on stdout; callers redirect it to stderr when
#   used for a usage error, per docs/CONTRACT.md.
show_usage() {
    cat << EOF
USAGE:
  drive-sync.sh [COMMAND] [OPTIONS]

COMMANDS:
  push, pull, sync, update, status, doctor, ratelimit

Run 'drive-sync.sh --help' for details.
EOF
}

# Print the full help text.
#
# Parameters: none.
#
# Returns: the help text on stdout.
show_help() {
    cat << EOF
drive_sync v${VERSION}: Simple Google Drive sync with PDF compression

USAGE:
  drive-sync.sh [COMMAND] [OPTIONS]

COMMANDS:
  push      Upload local changes (compresses PDFs)
  pull      Download remote changes
  sync      Full sync (pull then push)
  update    Mirror from Drive, deleting local files not on Drive
  status    Show sync status
  doctor    Check dependencies, remote, state and safety settings
  ratelimit Recover from rate limiting

OPTIONS:
  -n, --dry-run   Preview changes (no file is modified; -v lists PDFs to compress)
  -f, --force     Skip confirmations
  -v, --verbose   Show detailed progress
  -h, --help      Show this help
  -V, --version   Show version

EXAMPLES:
  drive-sync.sh status
  drive-sync.sh push
  drive-sync.sh sync -n
EOF
}

#=============================================================================
# Status Display
#=============================================================================

# Check the whole environment and report every result, instead of
# stopping at the first problem like validate_environment does.
#
# Parameters:
#   log_file: path to the active log file
#   state_file: path to state.json
#   remote_name: the configured rclone remote
#   local_path: local directory being synced
#
# Returns: 0 when every required check passes (warnings are allowed);
#   EX_UNAVAILABLE when any required check fails. Prints the report on
#   stdout, since the report is the command's result.
run_doctor() {
    local log_file="$1"
    local state_file="$2"
    local remote_name="$3"
    local local_path="$4"
    local failed=0 tool
    local _COLOR_ON
    use_color && _COLOR_ON=1 || _COLOR_ON=0

    echo ""
    style 36 "drive_sync doctor"; echo ""
    echo ""

    for tool in rclone gs jq flock; do
        if command -v "$tool" &> /dev/null; then
            echo "  $(style 32 "[ok]") $tool"
        else
            echo "  $(style 31 "[FAIL]") $tool is missing (install it, for example: sudo apt-get install $tool)"
            failed=1
        fi
    done

    if command -v bc &> /dev/null; then
        echo "  $(style 32 "[ok]") bc"
    else
        echo "  $(style 33 "[warn]") bc is missing (optional: integer arithmetic is used instead)"
    fi

    if command -v rclone &> /dev/null; then
        if ! rclone listremotes 2>/dev/null | grep -q "^${remote_name}$"; then
            echo "  $(style 31 "[FAIL]") remote ${remote_name} is not configured (run 'rclone config')"
            failed=1
        elif ! rclone about "$remote_name" &> /dev/null; then
            echo "  $(style 31 "[FAIL]") remote ${remote_name} is not reachable (check the network, or run 'rclone config reconnect ${remote_name}')"
            failed=1
        else
            echo "  $(style 32 "[ok]") remote ${remote_name} is configured and reachable"
        fi
    fi

    if [[ -d "$local_path" ]]; then
        echo "  $(style 32 "[ok]") local directory $local_path"
    else
        echo "  $(style 31 "[FAIL]") local directory $local_path does not exist"
        failed=1
    fi

    if [[ ! -w "$(dirname "$state_file")" ]]; then
        echo "  $(style 31 "[FAIL]") service directory $(dirname "$state_file") is not writable"
        failed=1
    elif command -v jq &> /dev/null; then
        local version
        if version=$(jq -er '.schema_version' "$state_file" 2>/dev/null); then
            echo "  $(style 32 "[ok]") state (schema $version)"
        else
            echo "  $(style 31 "[FAIL]") state file is not valid JSON or has no schema_version: $state_file"
            failed=1
        fi
    fi

    echo ""
    style 36 "Settings:"; echo ""
    echo "  tracking: ${TRACKING_MODE}"
    echo "  delete limit: ${MAX_DELETE_PERCENT}%"
    echo "  archive: ${ARCHIVE_DIR}"

    echo ""
    if [[ $failed -ne 0 ]]; then
        style 31 "Some required checks failed."; echo ""
        echo ""
        return "$EX_UNAVAILABLE"
    fi
    style 32 "All required checks passed."; echo ""
    echo ""
    return 0
}

# True when ANSI styling may be used: stdout is a terminal and NO_COLOR
# (https://no-color.org) is not set.
#
# Parameters: none.
#
# Returns: 0 when styling is allowed, 1 otherwise.
use_color() {
    [[ -t 1 && -z "${NO_COLOR:-}" ]]
}

# Print text wrapped in an ANSI SGR color code, or unchanged when
# use_color is false. No trailing newline. status and doctor share one
# palette: 36 cyan for titles, 32 green, 31 red, 33 yellow, 90 gray. They
# use colors only, never bold.
#
# Parameters:
#   code: the SGR code, for example 36 (cyan) or 31 (red)
#   text: what to print
#
# Returns: the text on stdout.
style() {
    # Callers decide once in _COLOR_ON (see show_status and run_doctor).
    # Asking use_color here would be wrong inside $(...), where stdout is a
    # pipe and never a terminal.
    local on="${_COLOR_ON:-}"
    if [[ -z "$on" ]]; then
        use_color && on=1 || on=0
    fi

    if [[ "$on" == 1 ]]; then
        printf '\033[%sm%s\033[0m' "$1" "$2"
    else
        printf '%s' "$2"
    fi
}

# Print the status report as plain text in sections (Paths, Sync, Files,
# Storage). Local and remote names, last sync and status from the state
# file, PDF counts (total/optimized/pending) with local size, and the
# remote's storage usage. In hash mode a PDF is optimized when state.json
# tracks it and the file still exists; *.optimized.pdf files always count.
# ponytail: a tracked file edited since its last push still counts as
# optimized until the next push re-checks it; compare mtime if that matters.
#
# Parameters:
#   log_file: path to the active log file
#   state_file: path to state.json
#   remote_name: the configured rclone remote
#   local_path: local directory being synced
#   optimized_marker: suffix marking already-compressed PDFs
#
# Returns: the report on stdout. Styling follows use_color.
show_status() {
    local log_file="$1"
    local state_file="$2"
    local remote_name="$3"
    local local_path="$4"
    local optimized_marker="$5"
    local _COLOR_ON
    use_color && _COLOR_ON=1 || _COLOR_ON=0

    echo ""
    style 36 "drive_sync v${VERSION}"; echo ""
    echo ""

    style 36 "Paths"; echo ""
    echo "  Local: $local_path"
    echo "  Remote: $remote_name"

    if [[ -f "$state_file" ]]; then
        local last_sync sync_status status_code
        last_sync=$(get_state_value "$state_file" "last_sync" | sed 's/null/Never/')
        sync_status=$(get_state_value "$state_file" "sync_status" | sed 's/null/idle/')

        case "$sync_status" in
            success) status_code=32 ;;
            failed)  status_code=31 ;;
            idle)    status_code=90 ;;
            *)       status_code=33 ;;
        esac

        echo ""
        style 36 "Sync"; echo ""
        echo "  Last sync: $last_sync"
        echo "  Status: $(style "$status_code" "$sync_status")"
    fi

    local pending=0
    if [[ -d "$local_path" ]]; then
        local total_pdfs marked_pdfs tracked_pdfs=0 optimized_pdfs total_bytes
        total_pdfs=$(find "$local_path" -type f -iname "*.pdf" 2>/dev/null | wc -l)
        marked_pdfs=$(find "$local_path" -type f -iname "*${optimized_marker}" 2>/dev/null | wc -l)

        if [[ "${TRACKING_MODE:-suffix}" == "hash" && -f "$state_file" ]]; then
            local rel
            while IFS=$'\t' read -r rel _; do
                if [[ -n "$rel" && -f "${local_path%/}/$rel" ]]; then
                    tracked_pdfs=$((tracked_pdfs + 1))
                fi
            done < <(list_tracked_files "$state_file")
        fi

        optimized_pdfs=$((marked_pdfs + tracked_pdfs))
        pending=$((total_pdfs - optimized_pdfs))
        [[ $pending -lt 0 ]] && pending=0

        total_bytes=$(du -sb "$local_path" 2>/dev/null | cut -f1 || echo 0)

        echo ""
        style 36 "Files"; echo ""
        echo "  PDFs: $total_pdfs total"
        echo "    Optimized: $optimized_pdfs"
        if [[ $pending -gt 0 ]]; then
            echo "    Pending: $(style 33 "$pending")"
        else
            echo "    Pending: $pending"
        fi
        echo "  Size: $(format_size "$total_bytes")"
    fi

    local storage
    storage=$(VERBOSE=false show_storage_usage "$log_file" "$remote_name" "  ")
    if [[ -n "$storage" ]]; then
        echo ""
        style 36 "Storage"; echo ""
        echo "$storage"
    fi

    if [[ $pending -gt 0 ]]; then
        echo ""
        style 90 "Next: drive-sync.sh push"; echo ""
    fi
    echo ""
}
