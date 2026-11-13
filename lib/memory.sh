#!/usr/bin/env bash
#
# memory.sh: remember what both sides shared at the last successful sync.
#
# Without it, sync cannot tell a file that is new on Drive from one deleted
# or renamed locally, and restores it (or duplicates a renamed file). The
# manifest is the sorted list of paths the local directory held right after
# a push, sync or update succeeded, when both sides matched. sync compares
# it with the current local and remote listings and honors what changed on
# each side: removals go to Drive's trash or to the local archive, behind
# the same deletion limit and confirmation as every other deletion.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This script should be sourced, not executed directly" >&2
    exit 1
}

# Print the files under a directory as sorted relative paths.
#
# Parameters:
#   local_path: the synced directory
#
# Returns: 0, one path per line in C locale order.
list_local_files() {
    local local_path="$1"

    find "$local_path" -type f -printf '%P\n' 2>/dev/null | LC_ALL=C sort
}

# Print the files at the remote as sorted relative paths.
#
# Parameters:
#   log_file: path to the active log file
#   remote_name: the configured rclone remote
#
# Returns: 0 with one path per line; 1 and a logged error when rclone
#   cannot list the remote.
list_remote_files() {
    local log_file="$1"
    local remote_name="$2"
    local listing

    # Not build_rclone_flags: its sync-only flags (--create-empty-src-dirs,
    # --size-only) are unknown flags to lsf.
    if ! listing=$(rclone lsf -R --files-only --fast-list --drive-skip-gdocs \
            --drive-skip-shortcuts --tpslimit "$RCLONE_TPSLIMIT" \
            --tpslimit-burst "$RCLONE_TPSLIMIT_BURST" --timeout "$RCLONE_TIMEOUT" \
            --retries "$RCLONE_RETRIES" "$remote_name" 2>/dev/null); then
        log_error "$log_file" "Could not list the remote to compare with the last sync"
        return 1
    fi
    [[ -z "$listing" ]] || LC_ALL=C sort <<< "$listing"
}

# Record the current local files as what both sides share. Call it only
# after a push, sync or update succeeded. The file is replaced atomically.
#
# Parameters:
#   log_file: path to the active log file
#   local_path: the synced directory
#   manifest: path of the manifest file
#
# Returns: 0, also when nothing is written (DRY_RUN is "true"); 1 and a
#   logged warning when the file cannot be written.
memory_write_manifest() {
    local log_file="$1"
    local local_path="$2"
    local manifest="$3"

    [[ "${DRY_RUN:-false}" == "true" ]] && return 0

    local tmp="${manifest}.tmp.$$"
    if list_local_files "$local_path" > "$tmp" && mv -f "$tmp" "$manifest"; then
        return 0
    fi
    rm -f "$tmp"
    log_warning "$log_file" "Could not write the sync manifest: $manifest"
    return 1
}

# Work out what changed on each side since the last successful sync.
#
# Parameters:
#   log_file: path to the active log file
#   local_path: the synced directory
#   remote_name: the configured rclone remote
#   manifest: path of the manifest file
#   out_removed_local: file to receive the paths removed or renamed away
#     locally (on Drive, in the manifest, not local)
#   out_removed_remote: file to receive the paths removed or renamed away
#     on Drive (local, in the manifest, not on Drive)
#
# Returns: 0 with both files written; 2 when there is no manifest (nothing
#   is known, so callers keep the old behavior); 1 when the remote cannot
#   be listed.
memory_diff() {
    local log_file="$1"
    local local_path="$2"
    local remote_name="$3"
    local manifest="$4"
    local out_removed_local="$5"
    local out_removed_remote="$6"

    [[ -f "$manifest" ]] || return 2

    local tmp
    tmp=$(mktemp -d)
    list_local_files "$local_path" > "$tmp/local"
    if ! list_remote_files "$log_file" "$remote_name" > "$tmp/remote"; then
        rm -rf "$tmp"
        return 1
    fi
    LC_ALL=C sort "$manifest" > "$tmp/manifest"

    LC_ALL=C comm -12 <(LC_ALL=C comm -13 "$tmp/local" "$tmp/remote") "$tmp/manifest" > "$out_removed_local"
    LC_ALL=C comm -12 <(LC_ALL=C comm -23 "$tmp/local" "$tmp/remote") "$tmp/manifest" > "$out_removed_remote"
    rm -rf "$tmp"
    return 0
}

# Check one set of removals against the deletion limit and, on a terminal,
# ask for confirmation. Same rules as guard_deletions.
#
# Parameters:
#   log_file: path to the active log file
#   count: how many files would be removed
#   total: how many files that side holds
#   where: a label for messages
#
# Returns: 0 to proceed; 1 to abort. Reads MAX_DELETE_PERCENT and FORCE.
memory_guard() {
    local log_file="$1"
    local count="$2"
    local total="$3"
    local where="$4"
    local max_percent="${MAX_DELETE_PERCENT:-50}"

    [[ "$count" -eq 0 ]] && return 0
    [[ "$total" -lt "$count" ]] && total="$count"

    if [[ $((count * 100)) -gt $((max_percent * total)) ]]; then
        log_error "$log_file" "Aborting: sync would remove $count of $total files $where since the last sync (limit ${max_percent}%)"
        log_error "$log_file" "Check that the source is mounted and not empty; raise MAX_DELETE_PERCENT if intended"
        return 1
    fi

    if [[ "${FORCE:-false}" != "true" ]] && is_interactive; then
        local answer
        printf 'sync will remove %s of %s files %s, as they were removed on the other side. Continue? [y/N] ' \
            "$count" "$total" "$where" >&2
        read -r answer || answer=""
        if [[ "$answer" != "y" && "$answer" != "Y" && "$answer" != "yes" ]]; then
            log_warning "$log_file" "Cancelled by the user; nothing was removed"
            return 1
        fi
        return 0
    fi

    log_warning "$log_file" "Removing $count files $where, as they were removed on the other side"
    return 0
}

# The pre-pull step of a sync: compare the manifest with both sides and
# honor what was removed on each. With no manifest it does nothing and the
# sync keeps its plain pull-then-push behavior. A dry run does nothing.
#
# Parameters:
#   log_file: path to the active log file
#   local_path: the synced directory
#   remote_name: the configured rclone remote
#   dry_run: "true" to do nothing
#
# Returns: 0 to go on with the pull and push; 1 to abort the sync (a limit,
#   the user, or an unreadable remote).
sync_memory_prepass() {
    local log_file="$1"
    local local_path="$2"
    local remote_name="$3"
    local dry_run="${4:-false}"

    [[ "$dry_run" == "true" ]] && return 0

    local tmp rc=0
    tmp=$(mktemp -d)
    memory_diff "$log_file" "$local_path" "$remote_name" "$(get_manifest_file)" \
        "$tmp/removed_local" "$tmp/removed_remote" || rc=$?
    case "$rc" in
        0) memory_apply "$log_file" "$local_path" "$remote_name" \
               "$tmp/removed_local" "$tmp/removed_remote" "$dry_run" || rc=$? ;;
        2) log_info "$log_file" "No sync manifest yet: plain pull then push, and one will be recorded"
           rc=0 ;;
    esac
    rm -rf "$tmp"
    return "$rc"
}

# Apply the changes found by memory_diff before the pull: remove the first
# set from Drive (to its trash) and move the second set from the local
# directory to a timestamped folder under ARCHIVE_DIR.
#
# Parameters:
#   log_file: path to the active log file
#   local_path: the synced directory
#   remote_name: the configured rclone remote
#   removed_local: file listing paths to remove from Drive
#   removed_remote: file listing paths to archive locally
#   dry_run: "true" to do nothing
#
# Returns: 0 on success or nothing to do; 1 when a limit or the user
#   stops it, or rclone fails to delete.
memory_apply() {
    local log_file="$1"
    local local_path="$2"
    local remote_name="$3"
    local removed_local="$4"
    local removed_remote="$5"
    local dry_run="${6:-false}"

    [[ "$dry_run" == "true" ]] && return 0

    local n_remote n_local total
    n_remote=$(wc -l < "$removed_local")
    n_local=$(wc -l < "$removed_remote")
    [[ "$n_remote" -eq 0 && "$n_local" -eq 0 ]] && return 0

    if [[ "$n_remote" -gt 0 ]]; then
        total=$(count_dest_files "$log_file" "$remote_name") || return 1
        memory_guard "$log_file" "$n_remote" "$total" "from Drive" || return 1
    fi
    if [[ "$n_local" -gt 0 ]]; then
        total=$(find "$local_path" -type f 2>/dev/null | wc -l)
        memory_guard "$log_file" "$n_local" "$total" "from the local directory" || return 1
    fi

    if [[ "$n_remote" -gt 0 ]]; then
        log_info "$log_file" "Removing $n_remote files from Drive (removed here since the last sync)"
        if ! rclone delete "$remote_name" --files-from-raw "$removed_local" --drive-use-trash \
                --tpslimit "$RCLONE_TPSLIMIT" --tpslimit-burst "$RCLONE_TPSLIMIT_BURST" \
                --timeout "$RCLONE_TIMEOUT" --retries "$RCLONE_RETRIES"; then
            log_error "$log_file" "Could not remove the files from Drive"
            return 1
        fi
    fi

    if [[ "$n_local" -gt 0 ]]; then
        local archive rel
        archive="${ARCHIVE_DIR}/$(date -u +%Y%m%dT%H%M%S)"
        log_info "$log_file" "Archiving $n_local local files to $archive (removed on Drive since the last sync)"
        while IFS= read -r rel; do
            [[ -n "$rel" && -f "${local_path%/}/$rel" ]] || continue
            mkdir -p "$archive/$(dirname "$rel")" \
                && mv "${local_path%/}/$rel" "$archive/$rel" \
                || { log_error "$log_file" "Could not archive: $rel"; return 1; }
        done < "$removed_remote"
    fi
    return 0
}
