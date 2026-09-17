#!/usr/bin/env bash
#
# cli.sh — Command-line interface
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
  push, pull, sync, update, status, ratelimit

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
drive_sync v${VERSION} — Simple Google Drive sync with PDF compression

USAGE:
  drive-sync.sh [COMMAND] [OPTIONS]

COMMANDS:
  push      Upload local changes (compresses PDFs)
  pull      Download remote changes
  sync      Full sync (pull then push)
  update    Mirror from Drive, deleting local files not on Drive
  status    Show sync status
  ratelimit Recover from rate limiting

OPTIONS:
  -n, --dry-run   Preview changes
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

show_status() {
    local log_file="$1"
    local state_file="$2"
    local remote_name="$3"
    local local_path="$4"
    local optimized_marker="$5"

    echo ""
    echo "📁 drive_sync v${VERSION}"
    echo "─────────────────────────"

    echo "📂 Local: $local_path"
    echo "☁️  Remote: $remote_name"

    if [[ -f "$state_file" ]]; then
        local last_sync sync_status
        last_sync=$(get_state_value "$state_file" "last_sync" | sed 's/null/Never/')
        sync_status=$(get_state_value "$state_file" "sync_status" | sed 's/null/idle/')

        local status_icon="🟢"
        [[ "$sync_status" == "failed" ]] && status_icon="🔴"
        [[ "$sync_status" == "idle" ]] && status_icon="⏸️"

        echo "🔄 Last sync: $last_sync"
        echo "$status_icon Status: $sync_status"
    fi

    if [[ -d "$local_path" ]]; then
        local total_pdfs optimized_pdfs unoptimized_pdfs total_bytes
        total_pdfs=$(find "$local_path" -type f -iname "*.pdf" 2>/dev/null | wc -l)
        optimized_pdfs=$(find "$local_path" -type f -iname "*${optimized_marker}" 2>/dev/null | wc -l)
        unoptimized_pdfs=$((total_pdfs - optimized_pdfs))

        total_bytes=$(du -sb "$local_path" 2>/dev/null | cut -f1 || echo 0)
        local total_size_human
        total_size_human=$(format_size "$total_bytes")

        echo ""
        echo "📄 PDFs: $total_pdfs total"
        echo "   ✅ Optimized: $optimized_pdfs"
        echo "   ⏳ Pending: $unoptimized_pdfs"
        echo "   💾 Size: $total_size_human"

        if [[ $unoptimized_pdfs -gt 0 ]]; then
            echo ""
            echo "💡 Run: drive-sync.sh push"
        fi
    fi

    show_storage_usage "$log_file" "$remote_name"

    echo ""
    echo "─────────────────────────"
    echo ""
}
