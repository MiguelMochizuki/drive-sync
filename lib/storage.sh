#!/usr/bin/env bash
#
# storage.sh — Google Drive storage quota display
#
# Displays current storage usage from Google Drive.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This script should be sourced, not executed directly" >&2
    exit 1
}

#=============================================================================
# Storage Quota Display
#=============================================================================

# Print Google Drive quota usage, in binary units, to the log and console.
#
# Parameters:
#   log_file: path to the active log file
#   remote_name: the configured rclone remote, for example "drive:"
#
# Returns: none. Prints nothing when the quota total is 0 or rclone
#   about fails; logs a warning in the failure case.
show_storage_usage() {
    local log_file="$1"
    local remote_name="$2"

    log_info "$log_file" "Checking Google Drive storage usage..."

    local quota_json
    if quota_json=$(rclone about "$remote_name" --json 2>/dev/null); then
        if command -v jq &> /dev/null; then
            local used total
            used=$(echo "$quota_json" | jq -r '.used // 0' 2>/dev/null)
            total=$(echo "$quota_json" | jq -r '.total // 0' 2>/dev/null)

            if [[ $total -gt 0 ]]; then
                local used_human total_human
                used_human=$(format_size "$used")
                total_human=$(format_size "$total")

                local percent
                if command -v bc &> /dev/null; then
                    percent=$(echo "scale=1; $used * 100 / $total" | bc)
                else
                    percent=$(( (used * 100) / total ))
                fi

                log_info "$log_file" "Storage: ${used_human} / ${total_human} (${percent}%)"
                echo "💾 Drive: ${used_human} / ${total_human} (${percent}%)"
            fi
        fi
    else
        log_warning "$log_file" "Could not retrieve storage information"
    fi
}
