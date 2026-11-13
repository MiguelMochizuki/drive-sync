# Quarantine and `restore`: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compression keeps a local copy of every original it replaces, and `drive-sync restore` puts one back.

**Architecture:** A new `lib/quarantine.sh` owns the directory layout (`originals/<relpath>/<UTC timestamp>`), keeping, pruning, listing and restoring. `compress_pdf` calls it just before the compressed file replaces the original. The directory is its own index, so `state.json` keeps its schema.

**Tech Stack:** Bash, jq, bats-core.

**Spec:** `docs/superpowers/specs/2026-11-13-quarantine-restore-design.md`

## Global Constraints

- Plain text, no emoji, arrows or dashes. Every new `.sh` file has a header and the sourced-only guard; every function has the `CONTRIBUTING.md` comment block. No existing test is edited. Baseline is 255 passing; command is `bats -r tests`.
- `QUARANTINE_RETENTION_DAYS` (default 30, 0 disables) and `QUARANTINE_DIR` (default `${DRIVE_SYNC_HOME}/originals`) are exported-with-default in `config.sh` and made readonly with the other settings. Without `config.sh` (characterization tests) retention reads as 0, which keeps those tests valid.
- Hash mode only. A dry run, `plan` and `status` never modify the quarantine.
- Exit codes: `restore` of a path with no quarantined original exits 1; bad usage exits 2.

## Review Focus

- The original must survive a crash between linking and replacing: link first, move second.
- A quarantine failure (unwritable directory) leaves the original in place and counts as a failed file.
- A `..` component in a path given to `restore` or in a computed relative path is rejected.
- Pruning never removes a directory that is not a timestamp-named archive entry.
- The hard-linked quarantine copy keeps the original mtime, so age must come from the timestamp in the name, never from `mtime`.

---

### Task 1: Keep, prune, list and restore

**Files:**
- Create: `lib/quarantine.sh`, `tests/unit/quarantine.bats`
- Modify: `lib/config.sh`, `drive-sync.sh` (source after `limit.sh`; prune call in `do_sync`), `lib/compression.sh` (`compress_pdf`)

**Interfaces:**
- `quarantine_enabled`: 0 when `QUARANTINE_RETENTION_DAYS` (default 0 if unset) is greater than 0 and `TRACKING_MODE` is `hash`.
- `quarantine_keep log_file input relpath`: links `input` (copy with `cp -p` when linking fails) to `$QUARANTINE_DIR/<relpath>/<UTC YYYYmmddTHHMMSS>`, adding `.1`, `.2` on a name clash; returns 1 on a `..` component or any failure, 0 otherwise.
- `quarantine_prune log_file`: removes entries older than the retention (by the timestamp in the name) and empty directories; also removes `ARCHIVE_DIR` subdirectories named `YYYYmmddTHHMMSS` older than the retention. No-op at retention 0.
- `quarantine_list`: prints `relpath<TAB>timestamp<TAB>size` per entry, oldest first.
- `quarantine_summary`: prints `count<TAB>bytes`.
- `quarantine_restore log_file state_file lock_file local_path path`: moves the newest entry for `path` (relative or absolute under `local_path`) over the file, records it in `state.json` with `record_file_state` (`original_size == size`), returns 1 when nothing is quarantined for it or the path escapes `local_path`.
- `compress_pdf` computes the relpath against its first allowed path and calls `quarantine_keep` (guarded by `declare -F quarantine_enabled`) just before moving the compressed file in; on failure it removes the temp file, logs an error and returns 1.

- [ ] **Step 1: Write the failing tests** in `tests/unit/quarantine.bats` (source config, utils, logging, state, quarantine, compression; temp `HOME`; fixtures with `make_pdf_fixture`; `MOCK_GS_BEHAVIOR=smaller`): keep and replace (original bytes preserved at `originals/a.pdf/<ts>`, live file halved), not quarantined when no shrink, retention 0 leaves no quarantine, unwritable `QUARANTINE_DIR` keeps the original and returns 1, two versions of one path, a name clash adds a suffix, prune by timestamp (a fixture entry named for 40 days ago is removed, one for 5 days ago stays, even when its mtime is ancient), prune of the archive removes only matching names, prune never runs under `DRY_RUN`, `..` rejected, list output, restore round trip (bytes back, state entry present, `compress_drive_pdfs` skips it afterwards), restore of an unknown path returns 1, and restore outside `local_path` returns 1.
- [ ] **Step 2: Run to verify they fail:** `bats tests/unit/quarantine.bats`.
- [ ] **Step 3: Implement** the module, the config variables (comment block like the others) and the `compress_pdf` hook; call `quarantine_prune` from `do_sync` when `dry_run` is not `true`.
- [ ] **Step 4: Verify:** `bats tests/unit/quarantine.bats`, then `bats -r tests`.
- [ ] **Step 5: Commit** `feat: keep replaced originals in a quarantine`.

### Task 2: The `restore` command, status and doctor

**Files:**
- Modify: `drive-sync.sh` (`main`), `lib/cli.sh` (help, `show_status`, `run_doctor`)
- Test: `tests/unit/restore_command.bats` (create), `tests/unit/status.bats` (append)

**Interfaces:**
- CLI: `drive-sync.sh restore <path>` and `restore --list`; one path only. No path and no `--list` is a usage error. `--list` prints `quarantine_list`; a path prints what was restored and that `push` is needed to send it to Drive.
- `status` prints `Quarantine: N originals, SIZE (kept D days)` under `Files` when the count is above zero in hash mode with retention above zero. `doctor` prints `[ok] quarantine directory` (or `[warn]` when unwritable) and the retention.

- [ ] **Step 1: Write the failing tests:** restore round trip through the CLI with mocked rclone and gs, `restore --list` output, no argument exits 2, two paths exit 2, unknown path exits 1, `--list` with a path exits 2, status shows the Quarantine line and omits it when empty or disabled, doctor reports the directory.
- [ ] **Step 2: Run to verify they fail:** `bats tests/unit/restore_command.bats tests/unit/status.bats`.
- [ ] **Step 3: Implement** the dispatch and the two display additions. Accept a positional path and `--list` only when `command == restore`.
- [ ] **Step 4: Verify:** the two files, then `bats -r tests`. Then a manual check with a throwaway `HOME` and the mocks: compress, `restore --list`, `restore <path>`, run again and confirm no recompression.
- [ ] **Step 5: Commit** `feat: add the restore command`.

### Task 3: Documentation

**Files:**
- Modify: `README.md`, `docs/CONTRACT.md`, `CLAUDE.md`, `docs/ROADMAP.md`

- [ ] **Step 1:** README: a Quarantine and restore section (layout, retention, `QUARANTINE_RETENTION_DAYS=0`, that `restore` needs a `push` to reach Drive, that retention also prunes the `update` archive), the commands list and module table. CONTRACT: `restore` exit codes and that its output goes to stdout. CLAUDE.md: the module and the new invariant. ROADMAP: mark quarantine done and the archive retention promise kept. Run /humanizer:humanizer over the prose.
- [ ] **Step 2:** `bats -r tests` green; `grep -rnP '\x{2014}|\x{2013}' README.md docs CLAUDE.md lib` shows nothing.
- [ ] **Step 3:** Commit `docs: document the quarantine and restore`, push, open the PR, merge after CI.
