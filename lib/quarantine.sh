#!/usr/bin/env bash
#
# quarantine.sh: keep replaced originals for a while, and restore them.
#
# Before compression replaces a PDF, the original is kept under
# QUARANTINE_DIR/<relpath>/<UTC timestamp>. The directory is its own
# index, so state.json needs no schema change. The original is linked
# (same disk) or copied, and only then replaced, so a crash in between
# never loses it. Age comes from the timestamp in the name, never from
# mtime, because a linked entry keeps the original file's mtime.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This script should be sourced, not executed directly" >&2
    exit 1
}

# The retention in whole days, 0 when the setting is unset or not a number.
#
# Parameters: none.
#
# Returns: the number of days on stdout. Reads QUARANTINE_RETENTION_DAYS.
quarantine_days() {
    local days="${QUARANTINE_RETENTION_DAYS:-0}"
    [[ "$days" =~ ^[0-9]+$ ]] && echo "$days" || echo 0
}

# Tell whether replaced originals are being kept: retention above zero and
# hash mode. When the module is sourced without config.sh the retention is
# unset and this is false, which keeps the characterization tests valid.
#
# Parameters: none.
#
# Returns: 0 when the quarantine is on, 1 otherwise.
quarantine_enabled() {
    [[ "$(quarantine_days)" -gt 0 && "${TRACKING_MODE:-suffix}" == "hash" ]]
}

# Keep a file under QUARANTINE_DIR/<relpath>/<UTC timestamp>. The file is
# hard linked, or copied when linking fails (another disk), so no data is
# copied on the common path. A name clash within one second gets a .1, .2
# suffix.
#
# Parameters:
#   log_file: path to the active log file
#   input: the file to keep
#   relpath: its path relative to the synced directory
#
# Returns: 0 when the copy exists; 1 and a logged error for a path with a
#   dot dot component or when the directory or the copy cannot be created.
quarantine_keep() {
    local log_file="$1"
    local input="$2"
    local relpath="$3"

    case "/$relpath/" in
        */../*|//) log_error "$log_file" "Refusing to quarantine an unsafe path: $relpath"; return 1 ;;
    esac

    local dir="${QUARANTINE_DIR}/${relpath}"
    if ! mkdir -p "$dir" 2>/dev/null; then
        log_error "$log_file" "Cannot create the quarantine directory: $dir"
        return 1
    fi

    local ts dest n=0
    ts=$(date -u +%Y%m%dT%H%M%S)
    dest="$dir/$ts"
    while [[ -e "$dest" ]]; do
        n=$((n + 1))
        dest="$dir/$ts.$n"
    done

    if ! ln "$input" "$dest" 2>/dev/null && ! cp -p "$input" "$dest" 2>/dev/null; then
        log_error "$log_file" "Cannot keep a copy of the original: $input"
        return 1
    fi
    [[ -f "$dest" ]]
}

# Remove quarantined originals, and old archive directories of the update
# command, that are older than the retention. Age comes from the timestamp
# in the name. Does nothing at retention 0 or under DRY_RUN.
#
# Parameters:
#   log_file: path to the active log file
#
# Returns: 0. Reads QUARANTINE_DIR, ARCHIVE_DIR and DRY_RUN.
quarantine_prune() {
    local log_file="$1"
    local days
    days=$(quarantine_days)

    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    [[ "$days" -gt 0 ]] || return 0

    local cutoff f base removed=0
    cutoff=$(date -u -d "$days days ago" +%Y%m%dT%H%M%S)

    if [[ -d "${QUARANTINE_DIR:-}" ]]; then
        while IFS= read -r -d '' f; do
            base="${f##*/}"
            [[ "$base" =~ ^[0-9]{8}T[0-9]{6}(\.[0-9]+)?$ ]] || continue
            if [[ "${base:0:15}" < "$cutoff" ]]; then
                rm -f "$f" && removed=$((removed + 1))
            fi
        done < <(find "$QUARANTINE_DIR" -type f -print0)
        find "$QUARANTINE_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    fi

    if [[ -d "${ARCHIVE_DIR:-}" ]]; then
        while IFS= read -r -d '' f; do
            base="${f##*/}"
            [[ "$base" =~ ^[0-9]{8}T[0-9]{6}$ ]] || continue
            if [[ "$base" < "$cutoff" ]]; then
                rm -rf "$f" && removed=$((removed + 1))
            fi
        done < <(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
    fi

    [[ $removed -gt 0 ]] && log_info "$log_file" "Pruned $removed expired quarantine and archive entries"
    return 0
}

# List the quarantined originals, oldest first.
#
# Parameters: none.
#
# Returns: 0, printing "relpath<TAB>timestamp<TAB>size" per entry. A path
#   containing a newline is not supported.
quarantine_list() {
    [[ -d "${QUARANTINE_DIR:-}" ]] || return 0

    local f rel
    while IFS= read -r -d '' f; do
        rel="${f#"$QUARANTINE_DIR"/}"
        printf '%s\t%s\t%s\n' "${rel##*/}" "${rel%/*}" "$(stat -c%s "$f")"
    done < <(find "$QUARANTINE_DIR" -type f -print0) \
        | sort -t$'\t' -k1,1 | awk -F'\t' '{print $2 "\t" $1 "\t" $3}'
}

# Count the quarantined originals and add up their sizes.
#
# Parameters: none.
#
# Returns: 0, printing "count<TAB>bytes".
quarantine_summary() {
    if [[ ! -d "${QUARANTINE_DIR:-}" ]]; then
        printf '0\t0\n'
        return 0
    fi
    find "$QUARANTINE_DIR" -type f -printf '%s\n' \
        | awk '{n++; s += $1} END {printf "%d\t%d\n", n, s}'
}

# Put the newest quarantined original back at its path and record it in
# state.json as already optimized (size equals original_size), so the next
# run does not compress it again.
#
# Parameters:
#   log_file: path to the active log file
#   state_file: path to state.json
#   lock_file: path to the lock file
#   local_path: the synced directory
#   path: the file, relative to local_path or absolute under it
#
# Returns: 0 on success; 1 and a logged error when the path is outside
#   local_path, has a dot dot component, or has nothing quarantined.
quarantine_restore() {
    local log_file="$1"
    local state_file="$2"
    local lock_file="$3"
    local local_path="$4"
    local path="$5"

    local rel="$path"
    if [[ "$path" == /* ]]; then
        if [[ "$path" != "${local_path%/}/"* ]]; then
            log_error "$log_file" "Not inside the synced directory: $path"
            return 1
        fi
        rel="${path#"${local_path%/}"/}"
    fi
    case "/$rel/" in
        */../*|//) log_error "$log_file" "Not a valid path to restore: $path"; return 1 ;;
    esac

    local dir="${QUARANTINE_DIR}/${rel}" newest
    newest=$(find "$dir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort | tail -n 1)
    if [[ -z "$newest" ]]; then
        log_error "$log_file" "No quarantined original for: $rel"
        return 1
    fi

    local target="${local_path%/}/$rel"
    mkdir -p "$(dirname "$target")" 2>/dev/null
    if ! mv -f "$dir/$newest" "$target"; then
        log_error "$log_file" "Could not restore $rel"
        return 1
    fi
    find "$QUARANTINE_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true

    local size
    size=$(get_file_size "$target") || size=0
    record_file_state "$log_file" "$state_file" "$lock_file" "$rel" \
        "$(get_file_hash "$target")" "$size" "$size" "$(get_file_mtime "$target")" || true
    log_info "$log_file" "Restored $rel from the quarantine ($newest)"
}
