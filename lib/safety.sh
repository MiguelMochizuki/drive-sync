#!/usr/bin/env bash
#
# safety.sh: guard against destructive syncs.
#
# Before a push or update deletes anything, count what rclone would delete
# (a dry run), abort when it exceeds MAX_DELETE_PERCENT of the destination,
# and ask for confirmation when running on a terminal. The percentage limit
# applies even with -f/--force and without a terminal, so an unattended run
# against a missing mount or an emptied folder cannot wipe the destination.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This script should be sourced, not executed directly" >&2
    exit 1
}

# True when both stdin and stdout are a terminal, so a prompt can be
# answered. Cron, systemd timers and pipes are not interactive.
#
# Parameters: none.
#
# Returns: 0 on a terminal, 1 otherwise.
is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# Count the files rclone would delete when syncing src onto dst, using a
# dry run and the "Skipped delete" notices it prints.
#
# Parameters:
#   log_file: path to the active log file
#   src: sync source (local directory or remote)
#   dst: sync destination (local directory or remote)
#
# Returns: the count on stdout and 0; 1 and a logged error when the dry
#   run itself fails, so the caller never proceeds on an unknown plan.
count_planned_deletions() {
    local log_file="$1"
    local src="$2"
    local dst="$3"
    local flags plan

    flags=$(build_rclone_flags "false")
    flags="${flags//--progress/}"

    if ! plan=$(rclone sync "$src" "$dst" $flags --dry-run --log-level NOTICE 2>&1); then
        log_error "$log_file" "Could not compute the deletion plan (rclone dry run failed)"
        return 1
    fi

    grep -c "Skipped delete" <<< "$plan" || true
}

# Count the files currently at a destination.
#
# Parameters:
#   log_file: path to the active log file
#   dest: a local directory or a remote
#
# Returns: the count on stdout and 0; 1 and a logged error when rclone
#   cannot list a remote.
count_dest_files() {
    local log_file="$1"
    local dest="$2"

    if [[ -d "$dest" ]]; then
        find "$dest" -type f 2>/dev/null | wc -l
        return 0
    fi

    local listing
    if ! listing=$(rclone lsf -R --files-only "$dest" 2>/dev/null); then
        log_error "$log_file" "Could not list files at $dest"
        return 1
    fi
    [[ -z "$listing" ]] && { echo 0; return 0; }
    wc -l <<< "$listing"
}

# Decide whether a destructive sync may proceed.
#
# Skips everything on a dry run. Otherwise counts the planned deletions
# and, when there are any: aborts if they exceed the percentage limit
# (always, even with FORCE), then asks "Continue?" on a terminal unless
# FORCE is "true". Without a terminal it logs a warning and proceeds.
#
# Parameters:
#   log_file: path to the active log file
#   src: sync source
#   dst: sync destination (where files would be deleted)
#   dry_run: "true" to skip all checks
#   max_percent: abort above this percentage of dst, default MAX_DELETE_PERCENT
#
# Returns: 0 to proceed; 1 to abort (limit exceeded, plan unavailable or
#   the user answered no). Reads the FORCE environment variable.
guard_deletions() {
    local log_file="$1"
    local src="$2"
    local dst="$3"
    local dry_run="${4:-false}"
    local max_percent="${5:-${MAX_DELETE_PERCENT:-50}}"

    [[ "$dry_run" == "true" ]] && return 0

    local deletions total
    deletions=$(count_planned_deletions "$log_file" "$src" "$dst") || return 1
    [[ "$deletions" -eq 0 ]] && return 0

    total=$(count_dest_files "$log_file" "$dst") || return 1
    [[ "$total" -lt "$deletions" ]] && total="$deletions"

    if [[ $((deletions * 100)) -gt $((max_percent * total)) ]]; then
        log_error "$log_file" "Aborting: this would delete $deletions of $total files at $dst (limit ${max_percent}%)"
        log_error "$log_file" "Check that the source is mounted and not empty; raise MAX_DELETE_PERCENT if intended"
        return 1
    fi

    if [[ "${FORCE:-false}" != "true" ]] && is_interactive; then
        local answer
        printf 'This will delete %s of %s files at %s. Continue? [y/N] ' \
            "$deletions" "$total" "$dst" >&2
        read -r answer || answer=""
        if [[ "$answer" != "y" && "$answer" != "Y" && "$answer" != "yes" ]]; then
            log_warning "$log_file" "Cancelled by the user; nothing was deleted"
            return 1
        fi
        return 0
    fi

    log_warning "$log_file" "Deleting $deletions of $total files at $dst"
    return 0
}
