# The `plan` command: design

## Intent

Before a run changes anything, the user should be able to see what it would do: what gets compressed and roughly how much space that frees, what gets uploaded or downloaded, and what gets deleted. Today those facts live in three places (`push -n -v`, the `guard_deletions` dry run, and nothing at all for savings). `plan` puts them in one read-only report, in text and in JSON.

It also feeds the v3.0 README, which is meant to show real `plan` output.

## Goals

- `drive-sync plan [push|pull|sync|update]` (default `sync`) prints a report and changes nothing: no file, no `state.json` write, no rclone cleanup, no Drive change.
- `--json` prints the same report as one JSON document on stdout. Logs and progress go to stderr, so the JSON can be piped to `jq`.
- The compression candidate list is exactly what a real `push` or `sync` would process. Plan and run must not drift apart.
- A deletion section that reuses the `guard_deletions` numbers and says whether the real run would abort at `MAX_DELETE_PERCENT`.

## Non-goals

- Executing a saved plan (`plan` then `apply`). Out of scope.
- Estimating anything other than PDF compression. Transfer sizes are reported as rclone reports them.
- Changing exit codes or the console contract in `docs/CONTRACT.md`, other than documenting `plan`.

## Anti-goals

A plan that disagrees with the run that follows it. A plan that writes state or touches files "just to measure". A savings number presented as exact when it is an estimate.

## Constraints

- Bash, `jq` already required, no new dependency.
- Read-only on `DRIVE_ROOT`, `state.json` and the Drive remote. Temporary files only under a `mktemp` directory removed on exit and on interrupt.
- Dry-run safety already in place stays in place: `DRY_RUN=true` makes `compress_pdf`, `compress_drive_pdfs` and `is_tracked_current` side-effect free.

## Approaches

For the savings figure:

1. Measure: run `gs` on every candidate into a temp directory. Exact, but minutes for 140 PDFs and 1.16 GiB.
2. Estimate from history: apply the ratio recorded in `state.json` to the pending bytes. Instant, approximate, absent on a fresh install.
3. List sizes only. No estimate.

Decision: 2 by default, 1 behind `plan --measure`. Option 3 is what `push -n -v` already does.

## Design

**Shared candidate list.** Extract the file-selection loop of `compress_drive_pdfs` into `list_compress_candidates` (tracked files and the optimized marker skipped, as today). Both the real run and `plan` call it. The function lists everything the run walks. Reports (`plan` and the dry run listing) then skip files under 10 KB in hash mode, where `compress_pdf` leaves them alone; in suffix mode `compress_pdf` renames them, so they stay listed. This also fixes the "Would compress" noise listed as a deferred minor.

**Estimate.** `ratio = 1 - sum(size) / sum(original_size)` over all entries in `state.json` `files`, counting entries that did not shrink so the figure is not optimistic. Estimated saving is `ratio * pending bytes`. With no entries the report says there is no estimate yet instead of showing zero. In `--measure`, each candidate is compressed to a temp file and accepted under the same rule as the real run (smaller, and at least `MIN_VALID_COMPRESSED_SIZE`); the report labels the figure as measured.

**Transfers and deletions.** One rclone dry run per direction (`copy` for pull, `sync` otherwise, as the real commands use) gives the number of files to copy and the "Skipped delete" count. Only counts are reported: rclone prints sizes in human units in those lines, so bytes would be guesses. `sync` runs the pull half, then the push half, the same order as the real command. The deletion block carries the count, the destination total, the percentage, the limit, and `would_abort`.

**Text report.** Sections in the style of `status` (cyan titles, plain tags, `NO_COLOR` respected): Compress, Download, Upload, Delete.

**JSON.** `schema_version: 1`, `direction`, and one object per section. Compress holds the candidate list (path, size), total bytes, and `estimate` with `method` (`history`, `measured` or `null`), `saved_bytes` and `ratio`. Delete holds `count`, `total`, `percent`, `limit`, `would_abort`.

**Failure.** If rclone cannot produce a plan, `plan` reports the error and exits 1, as `guard_deletions` does when its dry run fails. Missing `rclone`, `jq` or `flock` still exits 69 through `validate_environment`.

## Left to the builder

Exact rclone log lines used to count copies (verify against real rclone, not only the mock), the wording of the text sections, how `--measure` shows progress on stderr, and the dispatch wiring in `main` and `lib/cli.sh` help text.

## Tests

Bats, with the existing rclone and `gs` mocks: plan leaves files and `state.json` byte-identical; candidate list equals what a real run processes; estimate math from a fixture state; empty state gives no estimate; `--measure` leaves no temp files, including after a failing `gs`; JSON validates with `jq`; `would_abort` flips above the limit; a failing rclone dry run exits 1.
