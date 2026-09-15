#!/usr/bin/env bash
#
# logging.sh: structured logging with automatic rotation and severity
# based console routing.
#
# ERROR and WARNING always reach stderr. INFO and SUCCESS reach the
# console only when VERBOSE is "true". Every level always reaches the
# log file regardless of VERBOSE. See docs/CONTRACT.md.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This script should be sourced, not executed directly" >&2
    exit 1
}

VERBOSE="${VERBOSE:-false}"

# Roll the log file over to .1 through .5 once it exceeds 10 MB.
#
# Parameters:
#   log_file: path to the active log file
#
# Returns: none. Creates the log directory and an empty log file if one
#   does not already exist.
init_logging() {
    local log_file="$1"
    local log_dir
    log_dir=$(dirname "$log_file")

    mkdir -p "$log_dir"

    if [[ -f "$log_file" ]]; then
        local size
        size=$(wc -c < "$log_file" 2>/dev/null || echo 0)

        if [[ $size -gt 10485760 ]]; then
            for i in 4 3 2 1; do
                [[ -f "${log_file}.${i}" ]] && mv "${log_file}.${i}" "${log_file}.$((i + 1))"
            done
            mv "$log_file" "${log_file}.1"
            touch "$log_file"
        fi
    fi
}

# Write one timestamped line to the log file, and to the console when
# the level warrants it.
#
# Parameters:
#   log_file: path to the active log file
#   level: one of ERROR, WARNING, INFO, SUCCESS
#   message: remaining arguments, joined with spaces
#
# Returns: none. ERROR and WARNING always print to stderr. INFO and
#   SUCCESS print to stdout only when VERBOSE is "true".
_log_write() {
    local log_file="$1"
    local level="$2"
    shift 2
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[${timestamp}] [${level}] ${message}"

    echo "$line" >> "$log_file"

    case "$level" in
        ERROR|WARNING)
            echo "$line" >&2
            ;;
        INFO|SUCCESS)
            if [[ "$VERBOSE" == "true" ]]; then
                echo "$line"
            fi
            ;;
    esac

    return 0
}

# Log an ERROR line. Always reaches stderr and the log file.
#
# Parameters:
#   f: path to the active log file
#   message: remaining arguments, joined with spaces
#
# Returns: none.
log_error() {
    local f="$1"
    shift
    _log_write "$f" "ERROR" "$@"
}

# Log a WARNING line. Always reaches stderr and the log file.
#
# Parameters:
#   f: path to the active log file
#   message: remaining arguments, joined with spaces
#
# Returns: none.
log_warning() {
    local f="$1"
    shift
    _log_write "$f" "WARNING" "$@"
}

# Log an INFO line. Always reaches the log file; reaches stdout only
# when VERBOSE is "true".
#
# Parameters:
#   f: path to the active log file
#   message: remaining arguments, joined with spaces
#
# Returns: none.
log_info() {
    local f="$1"
    shift
    _log_write "$f" "INFO" "$@"
}

# Log a SUCCESS line. Always reaches the log file; reaches stdout only
# when VERBOSE is "true".
#
# Parameters:
#   f: path to the active log file
#   message: remaining arguments, joined with spaces
#
# Returns: none.
log_success() {
    local f="$1"
    shift
    _log_write "$f" "SUCCESS" "$@"
}
