# Dry run must not compress: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `drive-sync push -n` and `sync -n` never modify local files or `state.json`, and list what they would compress instead.

**Architecture:** `main` exports `DRY_RUN=true` for `-n`/`--dry-run`, the way it already exports `FORCE`. `compress_drive_pdfs` and `compress_pdf` read it and return early without side effects. No signature changes.

**Tech Stack:** Bash, bats-core, jq. Real `gs` is only for a manual check.

**Spec:** `docs/superpowers/specs/2026-11-13-dry-run-compression-design.md`

## Global Constraints

- Signatures of `compress_pdf` and `compress_drive_pdfs` do not change, and no existing test is edited (only added to).
- Only the exact value `DRY_RUN=true` means dry run. Anything else, including unset, is a normal run.
- Plain text everywhere: no emoji, arrows or dashes in code, logs, comments or docs.
- Every new or changed function keeps the `CONTRIBUTING.md` comment block (description, `Parameters:`, `Returns:`).
- Test command: `bats -r tests`. Baseline is 180 passing tests.

## Review Focus

- A tracked file whose mtime changed but whose content did not: in a dry run `is_tracked_current` must not refresh the recorded mtime in `state.json` (it writes today).
- `DRY_RUN` set to something other than `true` (for example `false` or empty) in the environment: compression runs normally.
- Every PDF already tracked, or an empty directory: the dry run says "All PDFs are already optimized" and not "Would compress 0".
- A PDF whose path has spaces: it is listed whole in the `Would compress` line.
- A failing `gs` during a dry run: exit status stays 0, because `gs` is never called.

---

### Task 1: Dry run in `compress_drive_pdfs` and `compress_pdf`

**Files:**
- Modify: `lib/compression.sh` (`compress_pdf`, `compress_drive_pdfs`, `is_tracked_current`)
- Modify: `tests/test_helper.bash` (add `DRY_RUN` to the `unset` list in `common_setup`)
- Test: `tests/unit/compression_dry_run.bats` (create)

**Interfaces:**
- Consumes: `list_tracked_files`, `get_file_size`, `format_size`, `log_info`, `record_file_state` (existing).
- Produces: behavior only. With `DRY_RUN=true`, `compress_drive_pdfs "$log" "$dir" ".optimized.pdf" "$state" "$lock" pdfwrite 1024 "$dir"` returns 0 and writes `Would compress: <path> (<size>)` lines to the log; `compress_pdf` returns 0 and leaves the file alone.

- [ ] **Step 1: Write the failing tests** in `tests/unit/compression_dry_run.bats`. Setup mirrors `tests/unit/compression_hash.bats` (source utils, logging, state, compression; `TRACKING_MODE="hash"`; temp `LOG_FILE`, `STATE_FILE`, `LOCK_FILE`, `LOCAL_PATH`; `init_state`). A helper `run_batch` calls `compress_drive_pdfs` as in that file. Tests, each with `DRY_RUN=true` and `MOCK_GS_BEHAVIOR=fail` unless noted:
  - `dry run leaves the file bytes unchanged`: `cmp` against a copy, status 0.
  - `dry run adds no entry to state.json`: `jq '.files | length'` is `0`, and `last_compression` is `null`.
  - `dry run logs a Would compress line with the path and size`: `grep -q "Would compress: .*big.pdf" "$LOG_FILE"`.
  - `dry run lists a path with spaces whole`: file `my doc.pdf`.
  - `dry run in suffix mode does not rename`: `TRACKING_MODE="suffix"`, no `.optimized.pdf` appears.
  - `dry run skips tracked files and says everything is optimized`: run a normal batch first (`DRY_RUN` unset, `MOCK_GS_BEHAVIOR=smaller`), then a dry run; log contains `All PDFs are already optimized` and no `Would compress`.
  - `dry run does not refresh the mtime of a tracked file`: after the normal batch, `touch -d 2001-01-01` the file, run the dry batch, and assert `.files["big.pdf"].mtime` in state is unchanged.
  - `DRY_RUN=false compresses as usual`: the file shrinks to half.
  - `compress_pdf under dry run returns 0 and leaves the file untouched` (calls `compress_pdf` directly, as `compression_hash.bats` does).

- [ ] **Step 2: Run to verify they fail:** `bats tests/unit/compression_dry_run.bats`. Expect failures on the unchanged-bytes, state and log tests (compression runs today); the `DRY_RUN=false` test already passes.

- [ ] **Step 3: Implement.** In `compress_pdf`, return 0 right after path validation when `"${DRY_RUN:-false}" == "true"`. In `is_tracked_current`, skip the `record_file_state` refresh when `DRY_RUN` is `true`. In `compress_drive_pdfs`, after building `pdf_files`, when `DRY_RUN` is `true`: if the list is empty log `All PDFs are already optimized`, else log one `Would compress: <path> (<format_size>)` line per file and `Would compress <N> files`; then return 0 before the loop, without touching `last_compression`. Both log through `log_info`. Update the comment blocks of the three functions to mention `DRY_RUN`.

- [ ] **Step 4: Run to verify they pass:** `bats tests/unit/compression_dry_run.bats`, then `bats -r tests`. Expect all green (180 plus the new ones).

- [ ] **Step 5: Commit**

```bash
git add lib/compression.sh tests/test_helper.bash tests/unit/compression_dry_run.bats
git commit -m "fix: make compression a no-op in dry run mode"
```

### Task 2: `main` exports `DRY_RUN` and the CLI behaves

**Files:**
- Modify: `drive-sync.sh` (`-n|--dry-run` case in `main`'s flag loop)
- Modify: `README.md` (the `-n`, `--dry-run` row of the options table), `lib/cli.sh` (the `-n, --dry-run` help line)
- Test: `tests/unit/drive_sync.bats` (append)

**Interfaces:**
- Consumes: Task 1's `DRY_RUN` behavior.
- Produces: `drive-sync.sh push -n` and `sync -n` exit 0 without modifying `$HOME/drive` or `state.json`.

- [ ] **Step 1: Write the failing tests** appended to `tests/unit/drive_sync.bats`, using its existing `setup` (mocked rclone, temp `HOME`), creating `$HOME/drive/big.pdf` with `make_pdf_fixture ... 50000`:
  - `push -n does not compress`: `MOCK_GS_BEHAVIOR=fail`, run `push -n`; status 0, file size still `50000`, `jq '.files | length'` of `$HOME/.drive-sync/state.json` is `0`.
  - `sync -n does not compress`: same with `sync -n`.
  - `push without -n still compresses`: `MOCK_GS_BEHAVIOR=smaller`; file size becomes `25000`.
  - `push -n -v prints the Would compress line on stdout`.

- [ ] **Step 2: Run to verify they fail:** `bats tests/unit/drive_sync.bats`. Expect the first, second and fourth to fail.

- [ ] **Step 3: Implement.** In `main`, set `export DRY_RUN="true"` alongside `dry_run="true"` in the `-n|--dry-run` case. Reword the help line and the README row to say that no files are changed, and that PDFs that would be compressed are listed with `-v`.

- [ ] **Step 4: Run the full suite:** `bats -r tests`. Expect all green.

- [ ] **Step 5: Manual check with the real Ghostscript** (not part of the suite): repeat the experiment from the design (a real PDF in a temp `HOME`, a `PATH` holding only the rclone mock and `/usr/bin`). `push -n` leaves the size at 102950 bytes and `state.json` has no files. Then run `push` without `-n` and confirm it shrinks.

- [ ] **Step 6: Commit and open the PR**

```bash
git add drive-sync.sh lib/cli.sh README.md tests/unit/drive_sync.bats
git commit -m "fix: pass dry run through to compression"
git push -u origin fix/dry-run-compression
```

Open the PR against `main` with a plain-prose body (what was wrong, the real-gs reproduction, the fix). The design and plan files under `docs/superpowers/` go in the same PR.

### Task 3: Release 2.2.1

**Files:**
- Modify: `lib/config.sh` (`VERSION`), `drive-sync.sh` (header comment), `README.md` (status example), `tests/characterization/drive_sync.bats`, `tests/characterization/config.bats`, `tests/unit/drive_sync.bats` (every `2.2.0` string)

**Interfaces:**
- Consumes: the fix PR merged into `main`.
- Produces: tag `v2.2.1`.

- [ ] **Step 1:** After the fix PR is merged, branch `chore/v2.2.1-release` from `main`. Replace `2.2.0` with `2.2.1` in the files above, then check `grep -rn "2\.2\.0" --exclude-dir=.git .` shows only history in docs, if anything.
- [ ] **Step 2:** `bats -r tests` is green and `./drive-sync.sh --version` prints `drive_sync version 2.2.1`.
- [ ] **Step 3:** Commit `chore: bump version to 2.2.1`, open the PR, merge it after CI is green, then create the annotated tag on the merge commit and push it: `git tag -a v2.2.1 <merge-sha> -m "v2.2.1 ..."` and `git push origin v2.2.1`. Confirm the Release workflow succeeds and lists `drive-sync.tar.gz`.
