# Dry run must not compress

Status: approved by the maintainer on 2026-11-13.

## Problem

`drive-sync push -n` and `sync -n` pass the dry-run flag to rclone but not to
the compression step. With the real Ghostscript, `push -n` shrank a 102950
byte PDF to 7802 bytes and recorded it in `state.json`. A preview that
changes local files is a bug in v2.2.0, and it blocks the planned `plan`
command, which needs a safe way to look at what would happen.

## Goals

- `-n` and `--dry-run` never modify local files, `state.json` or the
  archive, in both `hash` and `suffix` tracking modes.
- The dry run says what it would process, so the preview is useful.

## Non-goals

- Estimating the space saved. That belongs to `plan`, which can afford to
  run Ghostscript into a temporary file and say so.
- Changing the signatures of `compress_pdf` and `compress_drive_pdfs`.

## Approaches considered

1. Skip all work and list what would be processed. Fast and a small diff.
   It gives no size estimate. Chosen.
2. Run Ghostscript into a temporary file, measure the real saving and delete
   the file. Exact, but a dry run would take minutes on a large archive, and
   it is the `plan` command hidden behind a flag. Rejected for now.

## Design

- `main` exports `DRY_RUN=true` when `-n` or `--dry-run` is given, the same
  way it already exports `FORCE`. Signatures stay as they are, so the
  characterization tests keep passing unchanged.
- In `compress_drive_pdfs`, when `DRY_RUN` is `true`: find the files that
  would be processed (not already tracked, not carrying the optimized
  marker), log one `Would compress: <path> (<size>)` line each, log the
  count, and return 0. It does not run `gs`, rename or replace a file, write
  `last_compression`, or record a hash.
- `compress_pdf` also returns early without touching the file when
  `DRY_RUN` is `true`, so no caller can modify a file by accident.
- Release as 2.2.1 in its own PR, with the version bump and a tag.

## Tests

- `push -n` leaves the file size and bytes unchanged, adds no entry to
  `state.json`, and does not call `gs` (a failing `gs` would fail the test).
- The same for `TRACKING_MODE=suffix`: no rename.
- `sync -n` behaves the same on its push half.
- The `Would compress` lines and the count appear.
- Without `-n`, compression still runs as before.
