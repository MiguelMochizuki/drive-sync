#!/usr/bin/env bash
#
# plan.sh: a read-only report of what a run would compress, transfer and delete.
#
# Each section is built as a JSON document with jq, so file names with
# spaces, quotes or newlines stay valid. The text report is rendered from
# the same document, so the two formats cannot disagree. Nothing here
# writes to the synced directory, state.json or the remote: rclone is only
# called with --dry-run and gs only writes under a temporary directory.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This script should be sourced, not executed directly" >&2
    exit 1
}

# Print the history ratio at full precision: 1 minus the sum of current
# sizes over the sum of original sizes, across every entry in state.json
# (entries that did not shrink count, so the figure is not optimistic).
#
# Parameters:
#   state_file: path to state.json
#
# Returns: 0, printing the ratio, or "null" when there are no entries or
#   the original sizes sum to zero.
plan_history_ratio() {
    local state_file="$1"

    jq -r '[(.files // {}) | to_entries[] | .value] as $v
           | ($v | map(.original_size // 0) | add // 0) as $o
           | ($v | map(.size // 0) | add // 0) as $s
           | if $o == 0 then "null" else ([1 - $s / $o, 0] | max) end' \
        "$state_file" 2>/dev/null || echo "null"
}

# Print the history ratio rounded to 4 decimals, for display.
#
# Parameters:
#   state_file: path to state.json
#
# Returns: 0, printing the ratio or "null" (see plan_history_ratio).
plan_estimate_ratio() {
    local ratio
    ratio=$(plan_history_ratio "$1")
    [[ "$ratio" == "null" ]] && { echo "null"; return 0; }
    jq -n --argjson r "$ratio" '($r * 10000 | round) / 10000'
}

# Build the compress section of the plan as one JSON object: the files a
# real run would process, their total size, and a savings estimate. The
# estimate applies the history ratio to the pending bytes, or with measure
# set compresses each candidate into a temporary directory and sums what
# a real run would save. Nothing outside that directory is written, and
# state.json is never touched (DRY_RUN is forced on for the call).
#
# Parameters:
#   log_file: path to the active log file
#   local_path: the synced directory
#   optimized_marker: suffix marking already-compressed PDFs
#   state_file: path to state.json
#   lock_file: path to the lock file
#   gs_device: the Ghostscript output device
#   min_valid_size: minimum acceptable compressed size in bytes
#   measure: "true" to run gs on every candidate, anything else to estimate
#
# Returns: 0, printing the JSON object.
plan_compress_json() {
    local log_file="$1"
    local local_path="$2"
    local optimized_marker="$3"
    local state_file="$4"
    local lock_file="$5"
    local gs_device="$6"
    local min_valid_size="$7"
    local measure="${8:-false}"

    local DRY_RUN="true"
    local -a files=()
    mapfile -d '' -t files < <(list_compress_candidates "$log_file" "$local_path" \
        "$optimized_marker" "$state_file" "$lock_file")

    local tmp=""
    if [[ "$measure" == "true" ]]; then
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"; exit 130' INT TERM
    fi

    # ponytail: one jq call per candidate, quadratic but fine for thousands
    # of files; batch the calls if a plan over a huge archive gets slow.
    local cands="[]" total=0 saved=0 size measured out file
    for file in "${files[@]}"; do
        size=$(get_file_size "$file") || size=0
        compress_would_process "$size" || continue
        total=$((total + size))
        measured="null"
        if [[ -n "$tmp" ]]; then
            out="$tmp/out.pdf"
            rm -f "$out"
            if run_gs_compress "$gs_device" "$file" "$out"; then
                local new_size
                new_size=$(get_file_size "$out") || new_size=0
                if [[ $new_size -ge $min_valid_size && $new_size -lt $size ]]; then
                    measured=$((size - new_size))
                else
                    measured=0
                fi
                saved=$((saved + measured))
            fi
            rm -f "$out"
        fi
        cands=$(jq -c --arg p "${file#"${local_path%/}"/}" --argjson s "$size" \
                    --argjson m "$measured" \
                    '. + [{path: $p, size: $s, measured_saved: $m}]' <<< "$cands")
    done

    if [[ -n "$tmp" ]]; then
        rm -rf "$tmp"
        trap - INT TERM
    fi

    local method="null" ratio="null"
    if [[ "$measure" == "true" ]]; then
        method='"measured"'
    else
        ratio=$(plan_history_ratio "$state_file")
        [[ "$ratio" != "null" ]] && method='"history"'
    fi

    jq -n --argjson c "$cands" --argjson t "$total" --argjson m "$method" \
          --argjson r "$ratio" --argjson sv "$saved" '
        {candidates: $c, total_bytes: $t,
         estimate: (
           if $m == "measured" then
             {method: $m, saved_bytes: $sv,
              ratio: (if $t > 0 then ($sv / $t * 10000 | round) / 10000 else null end)}
           elif $m == "history" then
             {method: $m, saved_bytes: ($r * $t | round), ratio: (($r * 10000 | round) / 10000)}
           else {method: null, saved_bytes: null, ratio: null} end)}'
}

# Build the transfers and deletions section of the plan as one JSON object,
# from an rclone dry run shaped like the real command: copy for pull, sync
# for push (local to remote) and update (remote to local). Only counts are
# reported, because rclone prints sizes in human units. The deletion block
# follows guard_deletions: it would abort when deletions exceed
# MAX_DELETE_PERCENT of the destination.
#
# Parameters:
#   log_file: path to the active log file
#   direction: "push", "pull" or "update"
#   local_path: the synced directory
#   remote_name: the configured rclone remote
#   names_out: optional file to receive the names rclone would copy, one
#     per line (a name with a newline in it is not supported)
#   skip_file: optional file of names to leave out of the deletion count;
#     the sync plan passes what its pull half would restore, since the real
#     push then finds those files locally and does not delete them
#
# Returns: 0, printing {"copy_files":N,"delete":{count,total,percent,limit,
#   would_abort}} with "delete" null for pull; 1 and a logged error, printing
#   nothing, when the dry run or the destination listing fails.
plan_transfer_json() {
    local log_file="$1"
    local direction="$2"
    local local_path="$3"
    local remote_name="$4"
    local names_out="${5:-}"
    local skip_file="${6:-}"

    local cmd src dst
    case "$direction" in
        pull)   cmd=copy; src="$remote_name"; dst="$local_path" ;;
        push)   cmd=sync; src="$local_path";  dst="$remote_name" ;;
        update) cmd=sync; src="$remote_name"; dst="$local_path" ;;
        *) log_error "$log_file" "Unknown plan direction: $direction"; return 1 ;;
    esac

    local flags out
    flags=$(build_rclone_flags "false")
    flags="${flags//--progress/}"
    if ! out=$(rclone "$cmd" "$src" "$dst" $flags --dry-run --log-level NOTICE 2>&1); then
        log_error "$log_file" "Could not compute the plan (rclone dry run failed)"
        return 1
    fi

    local copies deletions=0 total=0 limit="${MAX_DELETE_PERCENT:-50}"
    copies=$(grep -c "Skipped copy" <<< "$out" || true)
    if [[ -n "$names_out" ]]; then
        sed -n 's/^<5>NOTICE: \(.*\): Skipped copy as --dry-run is set.*/\1/p' <<< "$out" > "$names_out"
    fi

    if [[ "$direction" == "pull" ]]; then
        jq -n --argjson c "$copies" '{copy_files: $c, delete: null}'
        return 0
    fi

    if [[ -n "$skip_file" ]]; then
        deletions=$(sed -n 's/^<5>NOTICE: \(.*\): Skipped delete as --dry-run is set.*/\1/p' <<< "$out" \
                    | { grep -vxFf "$skip_file" || true; } | wc -l)
    else
        deletions=$(grep -c "Skipped delete" <<< "$out" || true)
    fi
    total=$(count_dest_files "$log_file" "$dst") || return 1
    [[ "$total" -lt "$deletions" ]] && total="$deletions"

    jq -n --argjson c "$copies" --argjson d "$deletions" --argjson t "$total" \
          --argjson l "$limit" '
        {copy_files: $c,
         delete: {count: $d, total: $t,
                  percent: (if $t > 0 then ($d * 1000 / $t | round) / 10 else 0 end),
                  limit: $l,
                  would_abort: ($d * 100 > $l * $t)}}'
}

# Print the text report for a plan document. Every figure is read back from
# the JSON, so the text and --json output cannot disagree. Sections that do
# not apply to the direction are left out. Colors follow status and doctor
# (cyan titles, green and red verdicts) and respect NO_COLOR.
#
# Parameters:
#   doc: the plan JSON document
#
# Returns: 0, printing the report on stdout.
render_plan_text() {
    local doc="$1"
    local _COLOR_ON=0
    use_color && _COLOR_ON=1

    local direction
    direction=$(jq -r '.direction' <<< "$doc")
    style 36 "drive_sync plan ($direction)"; echo ""

    if [[ "$(jq -r '.compress' <<< "$doc")" != "null" ]]; then
        local count total method saved ratio
        count=$(jq -r '.compress.candidates | length' <<< "$doc")
        total=$(jq -r '.compress.total_bytes' <<< "$doc")
        method=$(jq -r '.compress.estimate.method' <<< "$doc")
        saved=$(jq -r '.compress.estimate.saved_bytes' <<< "$doc")
        ratio=$(jq -r '(.compress.estimate.ratio // 0) * 1000 | round / 10' <<< "$doc")
        echo ""
        style 36 "Compress"; echo ""
        if [[ "$count" -eq 0 ]]; then
            echo "  Nothing to compress"
        else
            echo "  $count PDF$([[ "$count" -eq 1 ]] || echo s), $(format_size "$total") to process"
            case "$method" in
                measured) echo "  Saving: $(format_size "$saved") (${ratio}%), measured with gs" ;;
                history)  echo "  Saving: about $(format_size "$saved") (${ratio}%), estimated from history" ;;
                *)        echo "  Saving: no estimate yet (nothing optimized before); try --measure" ;;
            esac
            local csize cpath
            while IFS=$'\t' read -r csize cpath; do
                echo "    $cpath ($(format_size "$csize"))"
            done < <(jq -r '.compress.candidates | sort_by(-.size) | .[0:10][]
                            | [.size, .path] | @tsv' <<< "$doc")
            [[ "$count" -gt 10 ]] && echo "    ... and $((count - 10)) more"
        fi
    fi

    if [[ "$(jq -r '.transfers.pull // empty' <<< "$doc")" != "" ]]; then
        echo ""
        style 36 "Download"; echo ""
        echo "  $(jq -r '.transfers.pull.copy_files' <<< "$doc") files would be copied"
    fi
    if [[ "$(jq -r '.transfers.update // empty' <<< "$doc")" != "" ]]; then
        echo ""
        style 36 "Download"; echo ""
        echo "  $(jq -r '.transfers.update.copy_files' <<< "$doc") files would be copied"
    fi
    if [[ "$(jq -r '.transfers.push // empty' <<< "$doc")" != "" ]]; then
        echo ""
        style 36 "Upload"; echo ""
        echo "  $(jq -r '.transfers.push.copy_files' <<< "$doc") files would be copied"
    fi

    local del
    del=$(jq -c '(.transfers.push // .transfers.update // null) | .delete' <<< "$doc")
    if [[ "$del" != "null" ]]; then
        echo ""
        style 36 "Delete"; echo ""
        echo "  $(jq -r '.count' <<< "$del") of $(jq -r '.total' <<< "$del") files (limit $(jq -r '.limit' <<< "$del")%)"
        if [[ "$(jq -r '.would_abort' <<< "$del")" == "true" ]]; then
            echo "  The run would abort: raise MAX_DELETE_PERCENT if this is intended"
            style 31 "  would abort"; echo ""
        else
            style 32 "  would continue"; echo ""
        fi
    fi
}

# Build the plan for a direction and print it as text or JSON. Transfers
# are planned first so a failing rclone stops the command before the slow
# measure pass. Compression is planned only for push and sync, the
# directions that compress. Nothing is written anywhere.
#
# Parameters:
#   log_file: path to the active log file
#   state_file: path to state.json
#   lock_file: path to the lock file
#   local_path: the synced directory
#   remote_name: the configured rclone remote
#   optimized_marker: suffix marking already-compressed PDFs
#   gs_device: the Ghostscript output device
#   min_valid_size: minimum acceptable compressed size in bytes
#   direction: "push", "pull", "sync" or "update"
#   json: "true" to print the JSON document instead of the text report
#   measure: "true" to measure savings with gs instead of estimating
#
# Returns: 0 with the report on stdout; 1 with nothing on stdout when
#   rclone cannot produce a plan. Forces DRY_RUN on.
show_plan() {
    local log_file="$1"
    local state_file="$2"
    local lock_file="$3"
    local local_path="$4"
    local remote_name="$5"
    local optimized_marker="$6"
    local gs_device="$7"
    local min_valid_size="$8"
    local direction="$9"
    local json="${10}"
    local measure="${11}"

    local DRY_RUN="true"
    local transfers="{}" part compress="null"

    # In a sync the pull runs first, so what it restores is local again by
    # the time the push looks for deletions.
    local restored dir
    restored=$(mktemp)
    for dir in $(case "$direction" in sync) echo "pull push" ;; *) echo "$direction" ;; esac); do
        local names_out="" skip_file=""
        [[ "$direction" == "sync" && "$dir" == "pull" ]] && names_out="$restored"
        [[ "$direction" == "sync" && "$dir" == "push" ]] && skip_file="$restored"
        part=$(plan_transfer_json "$log_file" "$dir" "$local_path" "$remote_name" \
                   "$names_out" "$skip_file") || { rm -f "$restored"; return 1; }
        transfers=$(jq -c --arg d "$dir" --argjson p "$part" '. + {($d): $p}' <<< "$transfers")
    done
    rm -f "$restored"

    if [[ "$direction" == "push" || "$direction" == "sync" ]]; then
        [[ "$measure" == "true" ]] && echo "Measuring PDFs with gs, this can take a while..." >&2
        compress=$(plan_compress_json "$log_file" "$local_path" "$optimized_marker" \
                       "$state_file" "$lock_file" "$gs_device" "$min_valid_size" "$measure")
    fi

    local doc
    doc=$(jq -n --arg d "$direction" --argjson c "$compress" --argjson t "$transfers" \
               '{schema_version: 1, direction: $d, compress: $c, transfers: $t}')

    if [[ "$json" == "true" ]]; then
        jq . <<< "$doc"
    else
        render_plan_text "$doc"
    fi
}
