# The `plan` command: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `drive-sync plan [push|pull|sync|update] [--json] [--measure]` prints, without changing anything, what a run would compress, transfer and delete.

**Architecture:** One new module, `lib/plan.sh`, builds a single JSON document from three sections (compress, transfers, deletions) and renders the text report from that same document, so the two formats cannot disagree. The compression candidate list is extracted from `compress_drive_pdfs` into a function both the real run and `plan` call. rclone is only ever called with `--dry-run`.

**Tech Stack:** Bash, jq, bats-core. rclone and `gs` are mocked in the suite.

**Spec:** `docs/superpowers/specs/2026-11-13-plan-command-design.md`

## Global Constraints

- Plain text everywhere: no emoji, arrows or dashes in code, logs, comments, tests or docs.
- Every new `.sh` file has a header comment after the shebang (`name.sh: description`) and the sourced-not-executed guard. Every new or changed function keeps the `CONTRIBUTING.md` comment block (description, `Parameters:` if any, `Returns:`).
- No existing test is edited, only added to. Baseline is 205 passing tests; command is `bats -r tests`.
- `plan` writes nothing: no file under `DRIVE_ROOT`, no `state.json` change, no rclone `cleanup`, no Drive change. `main` exports `DRY_RUN=true` for it.
- Stream contract (`docs/CONTRACT.md`): the report is the command's result and goes to stdout like `status`; logs follow the severity table; JSON mode writes only the JSON document to stdout.
- Exit codes do not change: 0 success, 1 when rclone cannot produce a plan, 2 usage, 69 missing dependency.
- Build JSON with `jq`, never with `printf`, so paths with spaces, quotes or newlines stay valid.

## Review Focus

- A path with spaces, a quote or a newline in its name: the JSON stays valid and the text report prints the path whole.
- Empty `state.json` (no `files` entries, or `original_size` sum of zero): `estimate` is `null` and nothing divides by zero.
- `--measure` with a failing `gs`, or interrupted: the temp directory is gone, no output file is left next to the originals, and the run still exits 0 with that file marked as not measured.
- rclone dry run fails: exit 1, an error on stderr, and nothing on stdout in `--json` mode (no half document).
- A tracked file whose mtime changed but whose content did not: `plan` must not refresh the mtime in `state.json`.

---

### Task 1: Shared candidate list

**Files:**
- Modify: `lib/compression.sh` (extract from `compress_drive_pdfs`; add `COMPRESS_MIN_BYTES`, `compress_would_process`; use the constant in `compress_pdf`)
- Test: `tests/unit/compression_candidates.bats` (create)

**Interfaces:**
- Produces: `list_compress_candidates log_file local_path optimized_marker state_file lock_file` prints the PDFs a real run would process as NUL-terminated paths on stdout, returns 0. It skips files carrying `optimized_marker` and, in hash mode, files `is_tracked_current` accepts; it builds the `tracked_hash` and `tracked_sig` arrays itself. `COMPRESS_MIN_BYTES=10240`. `compress_would_process size` returns 0 when a report should list a file of that size as work: always in suffix mode, only when `size >= COMPRESS_MIN_BYTES` in hash mode.
- Consumes: `list_tracked_files`, `is_tracked_current`, `get_file_size`, `format_size` (existing).

- [ ] **Step 1: Write the failing tests** in `tests/unit/compression_candidates.bats`, setup mirroring `tests/unit/compression_dry_run.bats`. Tests:
  - `lists an untracked pdf`: one 50000 byte `a.pdf`; `mapfile -d '' -t out < <(list_compress_candidates ...)` gives one entry equal to the path.
  - `skips a file with the optimized marker`.
  - `skips a tracked unchanged file in hash mode`: run a normal batch with `MOCK_GS_BEHAVIOR=smaller` first, then the list is empty.
  - `keeps a path with spaces and a newline whole`.
  - `compress_would_process is false for 5000 bytes in hash mode and true in suffix mode`, true for 50000 in both.
  - `the real run still processes a small file in hash mode` (run_batch on a 5000 byte file records it in `state.json`; this pins that the extraction changed nothing).

- [ ] **Step 2: Run to verify they fail:** `bats tests/unit/compression_candidates.bats`. Expect failures for the missing functions; the last test passes already.

- [ ] **Step 3: Implement.** Move the tracked-array setup and the `find` loop out of `compress_drive_pdfs` into `list_compress_candidates`, and have `compress_drive_pdfs` read it with `mapfile -d '' -t pdf_files`. Add `COMPRESS_MIN_BYTES` near the top and replace the literal `10240` in `compress_pdf`. In the `DRY_RUN` branch of `compress_drive_pdfs`, list only files where `compress_would_process` is true and say `All PDFs are already optimized` when none remain. Update the comment blocks.

- [ ] **Step 4: Verify:** `bats tests/unit/compression_candidates.bats`, then `bats -r tests`. Expect all green (205 plus the new ones); the existing dry run and characterization tests must not change.

- [ ] **Step 5: Commit** on a new branch `feat/plan-command` from `main`:

```bash
git add lib/compression.sh tests/unit/compression_candidates.bats
git commit -m "refactor: share the compression candidate list"
```

### Task 2: The compress section, with estimate and measure

**Files:**
- Create: `lib/plan.sh`
- Modify: `lib/compression.sh` (extract `run_gs_compress` from `compress_pdf`), `drive-sync.sh` (source `plan.sh` after `safety.sh`, before `cli.sh`)
- Test: `tests/unit/plan_compress.bats` (create)

**Interfaces:**
- Produces:
  - `run_gs_compress gs_device input output` runs the exact `gs` command line `compress_pdf` runs today and returns its status. `compress_pdf` calls it; no behavior change.
  - `plan_estimate_ratio state_file` prints `1 - sum(size)/sum(original_size)` over all `files` entries with 4 decimals, or `null` when there are no entries or the sum is zero.
  - `plan_compress_json log_file local_path optimized_marker state_file lock_file gs_device min_valid_size measure` prints one JSON object: `{"candidates":[{"path":"rel/path.pdf","size":N,"measured_saved":N|null}],"total_bytes":N,"estimate":{"method":"history"|"measured"|null,"saved_bytes":N|null,"ratio":R|null}}`. Candidates are those of `list_compress_candidates` for which `compress_would_process` is true. `path` is relative to `local_path`. With `measure` false, `method` is `history` when a ratio exists (`saved_bytes = round(ratio * total_bytes)`) and `null` otherwise. With `measure` true, each candidate is compressed by `run_gs_compress` into a file under one `mktemp -d` directory, accepted only when the output is at least `min_valid_size` and smaller than the input (`measured_saved` is the difference, else `0`; `null` when `gs` fails), `method` is `measured` and `saved_bytes` is the sum. The directory is removed by a trap on EXIT, INT and TERM.
- Consumes: Task 1 functions, `list_tracked_files`-style `jq` over `state.json`, `get_file_size`.

- [ ] **Step 1: Write the failing tests** in `tests/unit/plan_compress.bats` (same setup; `jq` checks on the printed JSON). Tests:
  - `ratio from state`: state with entries (original 1000, size 500) and (2000, 2000) gives `0.3333`.
  - `ratio is null on an empty state and when original sizes sum to zero`.
  - `history estimate applies the ratio to pending bytes`: with that state and one pending 30000 byte file, `saved_bytes` is `10000` and `method` is `history`.
  - `no estimate without history`: `estimate.method` is `null`.
  - `small files are not candidates in hash mode`.
  - `measure with the smaller mock reports measured_saved 25000 for a 50000 byte file`, `method` measured, the original untouched, and no `.pdf` or temp leftovers under the fixture directory or the temp dir (compare `ls` before and after).
  - `measure with a failing gs gives measured_saved null, exit 0, no leftovers`.
  - `measure with the too-small mock gives measured_saved 0`.
  - `a path with a quote and spaces survives as valid JSON` (`jq -e .`).
  - `plan_compress_json leaves state.json byte-identical` (`cmp` against a copy), including after touching a tracked file's mtime.

- [ ] **Step 2: Run to verify they fail:** `bats tests/unit/plan_compress.bats`. Expect failures for the missing functions.

- [ ] **Step 3: Implement** the three functions in `lib/plan.sh` and the extraction in `compress_pdf`. Use `jq -n --arg`/`--argjson` and `jq -s` to assemble the object. Export `DRY_RUN=true` inside `plan_compress_json` for the duration of the call (a `local` assignment is enough) so `is_tracked_current` never writes. The new file gets the header and the sourced-only guard.

- [ ] **Step 4: Verify:** `bats tests/unit/plan_compress.bats`, then `bats -r tests` (all existing compression tests still green, which proves the `run_gs_compress` extraction).

- [ ] **Step 5: Commit**

```bash
git add lib/plan.sh lib/compression.sh drive-sync.sh tests/unit/plan_compress.bats
git commit -m "feat: add the plan compress section"
```

### Task 3: The transfers and deletions section

**Files:**
- Modify: `lib/plan.sh`, `tests/mocks/rclone`
- Test: `tests/unit/plan_transfers.bats` (create)

**Interfaces:**
- Produces: `plan_transfer_json log_file direction local_path remote_name` prints `{"copy_files":N,"delete":{"count":N,"total":N,"percent":P,"limit":L,"would_abort":true|false}}` and returns 0; it returns 1 with a logged error and prints nothing when the dry run fails. `direction` selects what rclone runs, as the real commands do: `pull` runs `copy remote local`, `push` runs `sync local remote`, `update` runs `sync remote local`. `delete` is `null` for `pull` (pull never deletes). `limit` is `MAX_DELETE_PERCENT`; `would_abort` follows the same rule as `guard_deletions` (`deletions * 100 > limit * total`, total at least the deletion count). Counts come from `Skipped delete` lines and `Skipped copy` lines of `rclone ... --dry-run --log-level NOTICE`; destination total comes from `count_dest_files`.
- Mock change: the `rclone` mock treats `copy ... --dry-run --log-level` like the existing `sync` plan call (logs to `rclone_plan.log`, does not consume the exit sequence) and prints `MOCK_RCLONE_PLAN_COPIES` (default 0) lines `<5>NOTICE: fileN.txt: Skipped copy as --dry-run is set (size 1)` for both `copy` and `sync` plan calls. Document the variable in the mock header and add it to the `unset` list in `tests/test_helper.bash`.
- Consumes: `build_rclone_flags`, `count_dest_files` (existing, `lib/safety.sh`).

- [ ] **Step 1: Write the failing tests** in `tests/unit/plan_transfers.bats` (source utils, logging, config values as `tests/unit/safety.bats` does). Tests:
  - `push counts copies and deletions from the dry run`: `MOCK_RCLONE_PLAN_COPIES=3`, `MOCK_RCLONE_PLAN_DELETES=2`, `MOCK_RCLONE_LSF_COUNT=10` gives `copy_files` 3, `delete.count` 2, `total` 10, `percent` 20.
  - `would_abort is true above the limit and false at it`: 6 of 10 with limit 50 is true; 5 of 10 is false.
  - `pull uses copy and reports no deletions` (`rclone_plan.log` holds a `copy` line; `delete` is `null`).
  - `update runs sync with remote first`.
  - `the real call is never made`: `rclone_calls.log` has no `sync` or `copy` entry.
  - `a failing dry run returns 1, logs an error and prints nothing` (`MOCK_RCLONE_PLAN_EXIT=1`).

- [ ] **Step 2: Run to verify they fail:** `bats tests/unit/plan_transfers.bats`.

- [ ] **Step 3: Implement** `plan_transfer_json` and the mock change. Reuse the flag handling of `count_planned_deletions` (strip `--progress`). Verify the two NOTICE line formats once against real rclone with a throwaway directory and `rclone copy --dry-run --log-level NOTICE`, and adjust the grep patterns if the wording differs (the mock only fakes it).

- [ ] **Step 4: Verify:** `bats tests/unit/plan_transfers.bats`, then `bats -r tests`.

- [ ] **Step 5: Commit**

```bash
git add lib/plan.sh tests/mocks/rclone tests/test_helper.bash tests/unit/plan_transfers.bats
git commit -m "feat: add the plan transfers and deletions section"
```

### Task 4: The report and the `plan` command

**Files:**
- Modify: `lib/plan.sh` (`show_plan`), `drive-sync.sh` (`main`), `lib/cli.sh` (usage and help text)
- Test: `tests/unit/plan_command.bats` (create)

**Interfaces:**
- Produces: `show_plan log_file state_file lock_file local_path remote_name optimized_marker gs_device min_valid_size direction json measure` assembles `{"schema_version":1,"direction":D,"compress":{...},"transfers":{...}}` from Tasks 2 and 3, prints it with `jq` when `json` is `true`, otherwise prints the sectioned text report, and returns 0, or 1 when `plan_transfer_json` fails (printing nothing on stdout). `sync` calls `plan_transfer_json` twice (pull half then push half) and the document carries `transfers.pull` and `transfers.push`; the other directions carry a single `transfers` object. The compress section is omitted for `pull` and `update`, matching which real directions compress (push and sync).
- CLI: `drive-sync.sh [-v] plan [push|pull|sync|update] [--json] [--measure]`. The direction defaults to `sync`; `--json` and `--measure` are accepted only by `plan`. Any other argument is a usage error (exit 2), as today. `main` exports `DRY_RUN=true` for `plan`.
- Text report: titles in cyan through `style`, `NO_COLOR` respected, sections Compress, Download, Upload, Delete, each with counts and `format_size` figures, the estimate labelled `estimated from history` or `measured`, and a line saying no estimate exists yet when `method` is `null`. The Delete section ends with a line saying whether the real run would abort at the limit.

- [ ] **Step 1: Write the failing tests** in `tests/unit/plan_command.bats`, using the setup of `tests/unit/drive_sync.bats` (mocked rclone and gs, temp `HOME`, `$HOME/drive/big.pdf` 50000 bytes). Tests:
  - `plan --json prints one valid JSON document` (`jq -e .schema_version`), with `MOCK_RCLONE_PLAN_COPIES=2`.
  - `plan changes nothing`: file bytes, `state.json` and the directory listing of `$HOME/drive` identical before and after, with a failing `gs`, in text and JSON modes.
  - `plan never calls the real rclone sync or copy`.
  - `plan text mentions the candidate, the estimate source and the deletion verdict`.
  - `plan pull has no compress section`; `plan` with no direction equals `plan sync`.
  - `plan --measure prints measured savings and leaves no temp files`.
  - `plan with a failing rclone dry run exits 1 and --json prints nothing on stdout`.
  - `plan bogus` and `plan --nope` exit 2.
  - `--json and --measure are rejected by push` (exit 2).

- [ ] **Step 2: Run to verify they fail:** `bats tests/unit/plan_command.bats`.

- [ ] **Step 3: Implement** `show_plan`, the `plan` case and flag handling in `main` (the existing flag loop rejects unknown words, so parse the direction and the two flags only when `command == plan`), and the usage and help lines. Build the text report from the JSON document with `jq`, not from separate variables.

- [ ] **Step 4: Verify:** `bats tests/unit/plan_command.bats`, `bats -r tests`, then a manual run against the real remote: `./drive-sync.sh plan` and `./drive-sync.sh plan --json | jq .`. Compare the Delete numbers with `./drive-sync.sh push -n -v`. Expect `plan` to leave `~/drive` and `~/.drive-sync/state.json` byte-identical (checksum both before and after).

- [ ] **Step 5: Commit**

```bash
git add lib/plan.sh drive-sync.sh lib/cli.sh tests/unit/plan_command.bats
git commit -m "feat: add the plan command"
```

### Task 5: Documentation

**Files:**
- Modify: `README.md` (commands list and a `plan` section with real output from Task 4's manual run), `docs/CONTRACT.md` (`plan` writes its result to stdout like `status`; exit 1 on a failed dry run), `CLAUDE.md` (architecture: `lib/plan.sh`, source order, `plan` in the dispatch list), `docs/ROADMAP.md` (status: `plan` done)

**Interfaces:**
- Consumes: the finished command.

- [ ] **Step 1:** Update the four files. Paste real `plan` and `plan --json` output (trim paths if private) into the README. Run /humanizer:humanizer over the prose written.
- [ ] **Step 2:** `bats -r tests` is green; `grep -rnP '\x{2014}|\x{2013}' README.md docs CLAUDE.md lib` shows nothing new.
- [ ] **Step 3: Commit and open the PR** against `main`, plain-prose body, no AI attribution (the repo is AI driven in tracked files but commit and PR text carry no attribution, per the ai-commit-policy):

```bash
git add README.md docs/CONTRACT.md CLAUDE.md docs/ROADMAP.md
git commit -m "docs: document the plan command"
git push -u origin feat/plan-command
```

The design and plan files under `docs/superpowers/` and the roadmap change ride in the first PR of this branch if the docs branch has not merged yet.
