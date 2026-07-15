#!/usr/bin/env bash
#
# compression.sh — PDF compression with safety checks
#
# Core philosophy: Originals are NEVER deleted unless compression succeeds.
#
# BEHAVIOR:
#   1. Compression succeeds + reduces size → original deleted, file becomes .optimized.pdf
#   2. Compression succeeds but no reduction → original renamed to .optimized.pdf
#   3. Compression fails → original preserved, retry on next run
#
# The .optimized.pdf suffix means "this PDF is at its optimal size" —
# either compressed or already small enough.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This script should be sourced, not executed directly" >&2
    exit 1
}

#=============================================================================
# Formatting Helpers
#=============================================================================

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
# Single File Compression
#=============================================================================

compress_pdf() {
    local log_file="$1"
    local optimized_marker="$2"
    local gs_device="$3"
    local min_valid_size="$4"
    local input_file="$5"
    shift 5
    local -a allowed_paths=("$@")
    local validated_path

    if ! validated_path=$(validate_path "$input_file" "${allowed_paths[@]}"); then
        log_error "$log_file" "Invalid path for compression: $input_file"
        return 1
    fi

    if [[ "$validated_path" == *"$optimized_marker" ]]; then
        return 0
    fi

    local original_size
    original_size=$(get_file_size "$validated_path") || {
        log_error "$log_file" "Cannot determine size of: $(basename "$validated_path")"
        return 1
    }

    if [[ $original_size -lt 10240 ]]; then
        local size_human
        size_human=$(format_size "$original_size")
        log_info "$log_file" "File already optimal: $(basename "$validated_path") ($size_human)"

        local optimized_file="${validated_path%.pdf}${optimized_marker}"
        if mv "$validated_path" "$optimized_file" 2>/dev/null; then
            log_success "$log_file" "  ✓ Marked as optimized (already small)"
            return 0
        else
            log_error "$log_file" "  ✗ Failed to rename small file"
            return 1
        fi
    fi

    local size_human
    size_human=$(format_size "$original_size")
    log_info "$log_file" "Compressing: $(basename "$validated_path") ($size_human)"

    local optimized_file="${validated_path%.pdf}${optimized_marker}"
    local temp_output="${optimized_file}.tmp.$$.pdf"

    if gs -sDEVICE="$gs_device" \
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
          -sOutputFile="$temp_output" \
          "$validated_path" 2>/dev/null; then

        local new_size
        new_size=$(get_file_size "$temp_output") || new_size=0

        if [[ $new_size -lt $min_valid_size ]]; then
            local new_size_human
            new_size_human=$(format_size "$new_size")
            log_error "$log_file" "  ✗ Compressed file too small ($new_size_human)"
            rm -f "$temp_output"
            log_error "$log_file" "  → Keeping original file"
            return 1
        fi

        if [[ $new_size -gt 0 ]] && [[ $new_size -lt $original_size ]]; then
            local percent
            percent=$(calculate_percentage "$original_size" "$new_size")

            local reduction=$((original_size - new_size))
            local reduction_human
            reduction_human=$(format_size "$reduction")

            if mv "$temp_output" "$optimized_file" 2>/dev/null; then
                rm -f "$validated_path" 2>/dev/null || true
                log_success "$log_file" "  ✓ Optimized: ${percent}% reduction (saved ${reduction_human})"
                return 0
            else
                log_error "$log_file" "  ✗ Failed to move compressed file"
                rm -f "$temp_output"
                return 1
            fi
        else
            rm -f "$temp_output"
            local orig_human new_human
            orig_human=$(format_size "$original_size")
            new_human=$(format_size "$new_size")
            log_info "$log_file" "  → No size reduction achieved ($new_human vs $orig_human)"
            if mv "$validated_path" "$optimized_file" 2>/dev/null; then
                log_success "$log_file" "  ✓ Marked as optimized (already at optimal size)"
                return 0
            else
                log_error "$log_file" "  ✗ Failed to rename file"
                return 1
            fi
        fi
    else
        log_warning "$log_file" "  ✗ Compression failed for: $(basename "$validated_path")"
        rm -f "$temp_output"
        log_info "$log_file" "  → Keeping original file intact (will retry next run)"
        return 1
    fi
}

#=============================================================================
# Batch Compression
#=============================================================================

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

    local -a pdf_files=()
    while IFS= read -r -d '' file; do
        if [[ "$file" == *"$optimized_marker" ]]; then
            continue
        fi
        pdf_files+=("$file")
    done < <(find "$local_path" -type f -iname "*.pdf" -print0 2>/dev/null)

    local total_files=${#pdf_files[@]}

    if [[ $total_files -eq 0 ]]; then
        log_info "$log_file" "All PDFs are already optimized"
        update_state "$state_file" "$lock_file" "last_compression" "$(date -Iseconds)"
        return 0
    fi

    log_info "$log_file" "Found $total_files PDFs to process"

    for file in "${pdf_files[@]}"; do
        local orig_size
        orig_size=$(get_file_size "$file") || orig_size=0

        if compress_pdf "$log_file" "$optimized_marker" "$gs_device" \
                        "$min_valid_size" "$file" "${allowed_paths[@]}"; then
            local optimized_file="${file%.pdf}${optimized_marker}"
            if [[ -f "$optimized_file" ]]; then
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
    log_info "$log_file" "  ✓ Compressed: $compressed files"
    log_info "$log_file" "  ✓ Marked as optimal (no compression needed): $marked_optimal files"
    log_info "$log_file" "  ✗ Failed (originals preserved): $failed files"

    if [[ $total_size_saved -gt 0 ]]; then
        local saved_human
        saved_human=$(format_size "$total_size_saved")
        log_info "$log_file" "  Total space saved: $saved_human"
    fi

    log_info "$log_file" "  Time: ${duration}s"

    update_state "$state_file" "$lock_file" "last_compression" "$(date -Iseconds)"

    if [[ $failed -gt 0 ]]; then
        log_warning "$log_file" "$failed files failed compression (originals preserved)"
        log_info "$log_file" "These files will be retried on next run"
        return 1
    fi

    return 0
}
