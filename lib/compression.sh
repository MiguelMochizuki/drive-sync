#!/usr/bin/env bash
#
# compression.sh: PDF compression with safety checks
#
# Core philosophy: Originals are NEVER deleted unless compression succeeds.
#
# BEHAVIOR:
#   1. Compression succeeds + reduces size: original deleted, file becomes .optimized.pdf
#   2. Compression succeeds but no reduction: original renamed to .optimized.pdf
#   3. Compression fails: original preserved, retry on next run
#
# The .optimized.pdf suffix means "this PDF is at its optimal size":
# either compressed or already small enough.
#
# TRACKING_MODE (default "suffix" here, "hash" from config.sh):
#   suffix: the behavior above; the file is renamed to *.optimized.pdf.
#   hash:   the file keeps its name. A compressed file replaces the original
#           in place (only when smaller and valid), and state.json remembers
#           the hash of content that is already optimized. Existing
#           *.optimized.pdf files are still recognized and left alone.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This script should be sourced, not executed directly" >&2
    exit 1
}

# Files below this size are never sent to Ghostscript: compress_pdf treats
# them as already optimal.
COMPRESS_MIN_BYTES=10240

# Tell whether a report should list a file of this size as work to do. In
# hash mode compress_pdf leaves files under COMPRESS_MIN_BYTES alone, so
# they are not work. In suffix mode it renames them, so they are.
#
# Parameters:
#   size: file size in bytes
#
# Returns: 0 when the file counts as work, 1 otherwise. Reads TRACKING_MODE.
compress_would_process() {
    local size="$1"
    [[ "${TRACKING_MODE:-suffix}" != "hash" || "$size" -ge "$COMPRESS_MIN_BYTES" ]]
}

#=============================================================================
# Single File Compression
#=============================================================================

# Run Ghostscript on one PDF with the compression settings drive-sync uses.
# compress_pdf and the plan command's measure mode both call it, so a
# measured figure is what a real run would produce.
#
# Parameters:
#   gs_device: the Ghostscript output device, for example "pdfwrite"
#   input: the PDF to compress
#   output: where to write the result
#
# Returns: the exit status of gs.
run_gs_compress() {
    local gs_device="$1"
    local input="$2"
    local output="$3"

    gs -sDEVICE="$gs_device" \
        -dPDFSETTINGS=/printer \
        -dCompatibilityLevel=1.7 \
        -dNOPAUSE -dQUIET -dBATCH \
        -dDetectDuplicateImages=true \
        -dOptimize=true \
        -dCompressFonts=true \
        -dSubsetFonts=true \
        -dEmbedAllFonts=false \
        -dMaxSubsetPct=100 \
        -dMonoImageDownsampleType=/Bicubic \
        -dMonoImageResolution=300 \
        -dGrayImageDownsampleType=/Bicubic \
        -dGrayImageResolution=200 \
        -dColorImageDownsampleType=/Bicubic \
        -dColorImageResolution=200 \
        -dJPEGQuality=80 \
        -sOutputFile="$output" \
          "$input" 2>/dev/null
}

# Compress one PDF with Ghostscript, or mark it optimized without
# compressing, per the module's core invariant: the original is never
# deleted unless compression both succeeds and produces a smaller file.
#
# Parameters:
#   log_file: path to the active log file
#   optimized_marker: filename suffix marking a file as done, for
#     example ".optimized.pdf"
#   gs_device: the Ghostscript output device, for example "pdfwrite"
#   min_valid_size: minimum acceptable compressed size in bytes
#   input_file: the PDF to process
#   allowed_paths: remaining arguments, prefixes validate_path checks against
#
# Does nothing when the DRY_RUN environment variable is "true": it returns
# 0 without running gs or touching the file.
#
# Returns: 0 if the file ends up marked optimized, whether by
#   compression or because it was already small or already optimal;
#   1 if compression failed or the input path was invalid, leaving the
#   original file untouched for a retry on the next run.
compress_pdf() {
    local log_file="$1"
    local optimized_marker="$2"
    local gs_device="$3"
    local min_valid_size="$4"
    local input_file="$5"
    shift 5
    local -a allowed_paths=("$@")
    local validated_path
    local mode="${TRACKING_MODE:-suffix}"

    if ! validated_path=$(validate_path "$input_file" "${allowed_paths[@]}"); then
        log_error "$log_file" "Invalid path for compression: $input_file"
        return 1
    fi

    [[ "${DRY_RUN:-false}" == "true" ]] && return 0

    if [[ "$validated_path" == *"$optimized_marker" ]]; then
        return 0
    fi

    local original_size
    original_size=$(get_file_size "$validated_path") || {
        log_error "$log_file" "Cannot determine size of: $(basename "$validated_path")"
        return 1
    }

    if [[ $original_size -lt $COMPRESS_MIN_BYTES ]]; then
        local size_human
        size_human=$(format_size "$original_size")
        log_info "$log_file" "File already optimal: $(basename "$validated_path") ($size_human)"

        if [[ "$mode" == "hash" ]]; then
            log_success "$log_file" "  Already small, left as is"
            return 0
        fi

        local optimized_file="${validated_path%.pdf}${optimized_marker}"
        if mv "$validated_path" "$optimized_file" 2>/dev/null; then
            log_success "$log_file" "  Marked as optimized (already small)"
            return 0
        else
            log_error "$log_file" "  Failed to rename small file"
            return 1
        fi
    fi

    local size_human
    size_human=$(format_size "$original_size")
    log_info "$log_file" "Compressing: $(basename "$validated_path") ($size_human)"

    local optimized_file="${validated_path%.pdf}${optimized_marker}"
    [[ "$mode" == "hash" ]] && optimized_file="$validated_path"
    local temp_output="${optimized_file}.tmp.$$.pdf"

    if run_gs_compress "$gs_device" "$validated_path" "$temp_output"; then

        local new_size
        new_size=$(get_file_size "$temp_output") || new_size=0

        if [[ $new_size -lt $min_valid_size ]]; then
            local new_size_human
            new_size_human=$(format_size "$new_size")
            log_error "$log_file" "  Compressed file too small ($new_size_human)"
            rm -f "$temp_output"
            log_error "$log_file" "  Keeping original file"
            return 1
        fi

        if [[ $new_size -gt 0 ]] && [[ $new_size -lt $original_size ]]; then
            local percent
            percent=$(calculate_percentage "$original_size" "$new_size")

            local reduction=$((original_size - new_size))
            local reduction_human
            reduction_human=$(format_size "$reduction")

            if mv "$temp_output" "$optimized_file" 2>/dev/null; then
                [[ "$optimized_file" != "$validated_path" ]] && rm -f "$validated_path" 2>/dev/null
                log_success "$log_file" "  Optimized: ${percent}% reduction (saved ${reduction_human})"
                return 0
            else
                log_error "$log_file" "  Failed to move compressed file"
                rm -f "$temp_output"
                return 1
            fi
        else
            rm -f "$temp_output"
            local orig_human new_human
            orig_human=$(format_size "$original_size")
            new_human=$(format_size "$new_size")
            log_info "$log_file" "  No size reduction achieved ($new_human vs $orig_human)"
            if [[ "$mode" == "hash" ]]; then
                log_success "$log_file" "  Left as is (already at optimal size)"
                return 0
            fi
            if mv "$validated_path" "$optimized_file" 2>/dev/null; then
                log_success "$log_file" "  Marked as optimized (already at optimal size)"
                return 0
            else
                log_error "$log_file" "  Failed to rename file"
                return 1
            fi
        fi
    else
        log_warning "$log_file" "  Compression failed for: $(basename "$validated_path")"
        rm -f "$temp_output"
        log_info "$log_file" "  Keeping original file intact (will retry next run)"
        return 1
    fi
}

#=============================================================================
# Batch Compression
#=============================================================================

# Decide whether a file's current content is already tracked as optimized
# (hash mode). Compares size and mtime first, so unchanged files are never
# re-read; when those differ it compares the SHA-256, and a match (for
# example after a touch or a copy) refreshes the recorded mtime, except
# when DRY_RUN is "true", which never writes state.
#
# Parameters:
#   log_file: path to the active log file
#   state_file: path to state.json
#   lock_file: path to the lock file
#   local_path: the synced directory the recorded paths are relative to
#   file: the PDF to check
#   tracked_hash: name of an associative array, relative path to hash
#   tracked_sig: name of an associative array, relative path to "size:mtime"
#
# Returns: 0 if the content is already optimized; 1 if it must be processed.
is_tracked_current() {
    local log_file="$1"
    local state_file="$2"
    local lock_file="$3"
    local local_path="$4"
    local file="$5"
    local -n _hash_map="$6"
    local -n _sig_map="$7"

    local rel="${file#"${local_path%/}"/}"
    [[ -n "${_hash_map[$rel]:-}" ]] || return 1

    local size mtime
    size=$(get_file_size "$file") || return 1
    mtime=$(get_file_mtime "$file") || return 1
    [[ "${_sig_map[$rel]}" == "${size}:${mtime}" ]] && return 0

    local hash
    hash=$(get_file_hash "$file") || return 1
    [[ "$hash" == "${_hash_map[$rel]}" ]] || return 1

    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    record_file_state "$log_file" "$state_file" "$lock_file" "$rel" \
        "$hash" "$size" "$size" "$mtime" || true
    return 0
}

# Print the PDFs a real run would process, NUL terminated so any file name
# is safe. Skips files carrying the optimized marker and, in hash mode,
# files already tracked as optimized (see is_tracked_current). Both the
# batch run and the plan command read this list, so they cannot disagree.
#
# Parameters:
#   log_file: path to the active log file
#   local_path: the synced directory to search
#   optimized_marker: suffix marking already-compressed PDFs
#   state_file: path to state.json
#   lock_file: path to the lock file
#
# Returns: 0. Honors DRY_RUN through is_tracked_current (no state writes).
list_compress_candidates() {
    local log_file="$1"
    local local_path="$2"
    local optimized_marker="$3"
    local state_file="$4"
    local lock_file="$5"

    local mode="${TRACKING_MODE:-suffix}"
    local -A tracked_hash=() tracked_sig=()
    if [[ "$mode" == "hash" ]]; then
        local t_path t_hash t_size t_mtime
        while IFS=$'\t' read -r t_path t_hash t_size t_mtime; do
            tracked_hash["$t_path"]="$t_hash"
            tracked_sig["$t_path"]="${t_size}:${t_mtime}"
        done < <(list_tracked_files "$state_file")
    fi

    local file
    while IFS= read -r -d '' file; do
        if [[ "$file" == *"$optimized_marker" ]]; then
            continue
        fi
        if [[ "$mode" == "hash" ]] && is_tracked_current "$log_file" "$state_file" \
               "$lock_file" "$local_path" "$file" tracked_hash tracked_sig; then
            continue
        fi
        printf '%s\0' "$file"
    done < <(find "$local_path" -type f -iname "*.pdf" -print0 2>/dev/null)
}

# Compress every PDF under a directory that is not already marked
# optimized, and report a summary.
#
# Parameters:
#   log_file: path to the active log file
#   local_path: directory to scan for PDFs
#   optimized_marker: filename suffix marking a file as done
#   state_file: path to state.json
#   lock_file: path to the lock file
#   gs_device: the Ghostscript output device
#   min_valid_size: minimum acceptable compressed size in bytes
#   allowed_paths: remaining arguments, prefixes validate_path checks against
#
# When the DRY_RUN environment variable is "true", it only logs a
# "Would compress" line per pending file (leaving out files under
# COMPRESS_MIN_BYTES in hash mode, see compress_would_process) and returns
# 0: no gs call, no file change, no state write.
#
# Returns: 0 if every PDF ended up optimized; 1 if one or more files
#   failed compression, in which case those originals are preserved
#   for the next run.
compress_drive_pdfs() {
    local log_file="$1"
    local local_path="$2"
    local optimized_marker="$3"
    local state_file="$4"
    local lock_file="$5"
    local gs_device="$6"
    local min_valid_size="$7"
    shift 7
    local -a allowed_paths=("$@")

    if [[ -z "$log_file" ]]; then
        echo "[ERROR] log_file is empty in compress_drive_pdfs" >&2
        return 1
    fi

    log_info "$log_file" "Starting PDF optimization..."

    local start_time
    start_time=$(date +%s)
    local compressed=0
    local marked_optimal=0
    local failed=0
    local total_size_saved=0

    local mode="${TRACKING_MODE:-suffix}"
    local -a pdf_files=()
    mapfile -d '' -t pdf_files < <(list_compress_candidates "$log_file" \
        "$local_path" "$optimized_marker" "$state_file" "$lock_file")

    local total_files=${#pdf_files[@]}

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        local -a would=()
        local size
        for file in "${pdf_files[@]}"; do
            size=$(get_file_size "$file") || size=0
            compress_would_process "$size" && would+=("$file")
        done
        if [[ ${#would[@]} -eq 0 ]]; then
            log_info "$log_file" "All PDFs are already optimized"
        else
            for file in "${would[@]}"; do
                log_info "$log_file" "Would compress: $file ($(format_size "$(get_file_size "$file")"))"
            done
            log_info "$log_file" "Would compress ${#would[@]} files"
        fi
        return 0
    fi

    if [[ $total_files -eq 0 ]]; then
        log_info "$log_file" "All PDFs are already optimized"
        update_state "$log_file" "$state_file" "$lock_file" "last_compression" "$(date -Iseconds)"
        return 0
    fi

    log_info "$log_file" "Found $total_files PDFs to process"

    for file in "${pdf_files[@]}"; do
        local orig_size
        orig_size=$(get_file_size "$file") || orig_size=0

        if compress_pdf "$log_file" "$optimized_marker" "$gs_device" \
                        "$min_valid_size" "$file" "${allowed_paths[@]}"; then
            local optimized_file="${file%.pdf}${optimized_marker}"
            if [[ "$mode" == "hash" ]]; then
                local new_size
                new_size=$(get_file_size "$file" 2>/dev/null) || new_size=0
                record_file_state "$log_file" "$state_file" "$lock_file" \
                    "${file#"${local_path%/}"/}" "$(get_file_hash "$file")" \
                    "$orig_size" "$new_size" "$(get_file_mtime "$file")" || true
                if [[ $new_size -lt $orig_size ]]; then
                    ((compressed++)) || true
                    total_size_saved=$((total_size_saved + orig_size - new_size))
                else
                    ((marked_optimal++)) || true
                fi
            elif [[ -f "$optimized_file" ]]; then
                if [[ ! -f "$file" ]]; then
                    ((compressed++)) || true
                    local new_size
                    new_size=$(get_file_size "$optimized_file" 2>/dev/null) || new_size=0
                    if [[ $new_size -lt $orig_size ]]; then
                        total_size_saved=$((total_size_saved + orig_size - new_size))
                    fi
                else
                    ((marked_optimal++)) || true
                fi
            fi
        else
            ((failed++)) || true
        fi
    done

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_info "$log_file" "Optimization completed:"
    log_info "$log_file" "  Compressed: $compressed files"
    log_info "$log_file" "  Marked as optimal (no compression needed): $marked_optimal files"
    log_info "$log_file" "  Failed (originals preserved): $failed files"

    if [[ $total_size_saved -gt 0 ]]; then
        local saved_human
        saved_human=$(format_size "$total_size_saved")
        log_info "$log_file" "  Total space saved: $saved_human"
    fi

    log_info "$log_file" "  Time: ${duration}s"

    update_state "$log_file" "$state_file" "$lock_file" "last_compression" "$(date -Iseconds)"

    if [[ $failed -gt 0 ]]; then
        log_warning "$log_file" "$failed files failed compression (originals preserved)"
        log_info "$log_file" "These files will be retried on next run"
        return 1
    fi

    return 0
}
