#!/usr/bin/env bash
#
# utils.sh — Utility functions
#
# Helpers for path validation, percentage calculation, and file size detection.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This script should be sourced, not executed directly" >&2
    exit 1
}

#=============================================================================
# Path Validation
#=============================================================================

# Resolve a path and confirm it falls under one of the allowed prefixes.
#
# Parameters:
#   path: the path to validate
#   allowed_paths: remaining arguments, one or more allowed prefixes
#
# Returns: the resolved absolute path on stdout and exit 0 when allowed;
#   an error message on stderr and exit 1 when the path cannot be
#   resolved or falls outside every allowed prefix.
validate_path() {
    local path="$1"
    shift
    local -a allowed_paths=("$@")
    local resolved_path
    local allowed=false

    if ! resolved_path=$(readlink -f "$path" 2>/dev/null); then
        echo "[ERROR] Failed to resolve path: $path" >&2
        return 1
    fi

    for allowed_path in "${allowed_paths[@]}"; do
        if [[ "$resolved_path" == "$allowed_path"* ]]; then
            allowed=true
            break
        fi
    done

    if [[ "$allowed" != "true" ]]; then
        echo "[ERROR] Path not allowed: $resolved_path" >&2
        return 1
    fi

    echo "$resolved_path"
    return 0
}

#=============================================================================
# Math Utilities
#=============================================================================

# Calculate the percentage reduction from an original value to a new value.
#
# Parameters:
#   original: the original (baseline) value
#   new: the new value to compare against the original
#
# Returns: the percentage reduction on stdout, for example "40" or
#   "40.00" depending on bc availability; "0" without dividing when
#   original is 0.
calculate_percentage() {
    local original="$1"
    local new="$2"

    [[ $original -eq 0 ]] && { echo "0"; return; }

    if command -v bc &> /dev/null; then
        echo "scale=2; 100 * ($original - $new) / $original" | bc
    else
        echo $(( (100 * (original - new)) / original ))
    fi
}

# Calculate what percentage of a total quota is currently used.
#
# Parameters:
#   used: the amount currently used
#   total: the total quota
#
# Returns: the used-over-total percentage on stdout, for example "25" or
#   "25.00" depending on bc availability; "0" without dividing when
#   total is 0.
calculate_quota_percentage() {
    local used="$1"
    local total="$2"

    [[ $total -eq 0 ]] && { echo "0"; return; }

    if command -v bc &> /dev/null; then
        echo "scale=2; $used * 100 / $total" | bc
    else
        echo $(( (used * 100) / total ))
    fi
}

#=============================================================================
# Size Formatting (binary units)
#=============================================================================

# Format a byte count as a human readable binary size.
#
# Parameters:
#   bytes: the size in bytes
#
# Returns: the formatted size on stdout, for example "512 MiB"; the
#   single source of truth for this formatting, used by storage.sh,
#   compression.sh, and cli.sh.
format_size() {
    local bytes="$1"
    local unit="B"
    local value="$bytes"

    if [[ $bytes -ge 1073741824 ]]; then
        if command -v bc &> /dev/null; then
            value=$(echo "scale=2; $bytes / 1073741824" | bc)
            unit="GiB"
        else
            value=$((bytes / 1073741824))
            unit="GiB"
        fi
    elif [[ $bytes -ge 1048576 ]]; then
        if command -v bc &> /dev/null; then
            value=$(echo "scale=2; $bytes / 1048576" | bc)
            unit="MiB"
        else
            value=$((bytes / 1048576))
            unit="MiB"
        fi
    elif [[ $bytes -ge 1024 ]]; then
        if command -v bc &> /dev/null; then
            value=$(echo "scale=2; $bytes / 1024" | bc)
            unit="KiB"
        else
            value=$((bytes / 1024))
            unit="KiB"
        fi
    fi

    if [[ "$value" =~ ^([0-9]+)\.([0-9]{1,2})?0*$ ]]; then
        value="${BASH_REMATCH[1]}"
        if [[ -n "${BASH_REMATCH[2]}" ]]; then
            value="${value}.${BASH_REMATCH[2]}"
        fi
    fi

    echo "${value} ${unit}"
}

#=============================================================================
# File Utilities
#=============================================================================

# Get the size in bytes of a file, using whichever stat flavor is available.
#
# Parameters:
#   file: the path to the file
#
# Returns: the size in bytes on stdout and exit 0 on success; "0" on
#   stdout and exit 1 when the size cannot be determined (GNU and BSD
#   stat both fail).
get_file_size() {
    local file="$1"
    local size

    if size=$(stat -c%s "$file" 2>/dev/null); then
        echo "$size"; return 0
    elif size=$(stat -f%z "$file" 2>/dev/null); then
        echo "$size"; return 0
    else
        echo "0"; return 1
    fi
}

#=============================================================================
# Size Formatting (decimal units)
#=============================================================================

format_bytes_decimal() {
    local bytes="$1"
    local unit="B"
    local value="$bytes"

    if [[ $bytes -ge 1000000000 ]]; then
        if command -v bc &> /dev/null; then
            value=$(echo "scale=2; $bytes / 1000000000" | bc)
            unit="GB"
        else
            value=$((bytes / 1000000000))
            unit="GB"
        fi
    elif [[ $bytes -ge 1000000 ]]; then
        if command -v bc &> /dev/null; then
            value=$(echo "scale=2; $bytes / 1000000" | bc)
            unit="MB"
        else
            value=$((bytes / 1000000))
            unit="MB"
        fi
    elif [[ $bytes -ge 1000 ]]; then
        if command -v bc &> /dev/null; then
            value=$(echo "scale=2; $bytes / 1000" | bc)
            unit="KB"
        else
            value=$((bytes / 1000))
            unit="KB"
        fi
    fi

    # Remove trailing zeros if present
    if [[ "$value" =~ ^([0-9]+)\.([0-9]{1,2})?0*$ ]]; then
        value="${BASH_REMATCH[1]}"
        if [[ -n "${BASH_REMATCH[2]}" ]]; then
            value="${value}.${BASH_REMATCH[2]}"
        fi
    fi

    echo "${value} ${unit}"
}
