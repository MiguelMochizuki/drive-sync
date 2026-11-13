# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make test                 # run full bats suite (requires bats-core >= 1.5.0)
bats tests/unit/cli.bats  # run a single test file
bats -f "some test name" tests/unit/cli.bats  # run a single test by name
./drive-sync.sh sync -n -v   # dry-run + verbose, exercises real code paths locally
```

Only `rclone` and `gs` are mocked (`tests/mocks/`); `jq` and `flock` run for real, so those two must be installed to run tests. Config variables are `readonly` once `config.sh` is sourced, so a test cannot reassign them: export the variable before sourcing (as `TRACKING_MODE`, `MAX_DELETE_PERCENT` and `FORCE` are, with a `${VAR:-default}` fallback) or pass it as a parameter. The `rclone` mock treats `sync --dry-run --log-level ...` as a deletion-plan call: it does not consume `MOCK_RCLONE_EXIT_SEQUENCE`, logs to `rclone_plan.log` instead of `rclone_calls.log`, and prints `MOCK_RCLONE_PLAN_DELETES` "Skipped delete" lines and `MOCK_RCLONE_PLAN_COPIES` "Skipped copy" lines (`copy --dry-run --log-level ...` is treated the same way; `MOCK_RCLONE_PLAN_COPY_NAMES` and `MOCK_RCLONE_PLAN_DELETE_NAMES` add named lines); `MOCK_RCLONE_LSF_COUNT` sets the `lsf` file count.

Tests are split into:
- `tests/characterization/`: pins existing, contracted behavior (do not casually "fix" what these pin without checking `docs/CONTRACT.md` first)
- `tests/unit/`: individual functions and edge cases

`make install-user` symlink-style installs to `~/.local/bin` (sets `DRIVE_SYNC_HOME` to the checkout, so edits apply immediately); `make install` copies to `/usr/local/lib/drive-sync` and needs sudo. The version lives in `lib/config.sh` (`VERSION`).

Documentation convention (`CONTRIBUTING.md`): every `.sh` file has a header comment after the shebang, and every function has a comment block above it with a description, `Parameters:` (omit if none) and `Returns:`. Follow it for new code.

CI (`.github/workflows/`) runs `make test` on push/PR to main; a separate `Release` workflow tars `drive-sync.sh` + `lib/` on `v*` tags.

## Architecture

Bash CLI, `set -euo pipefail`, no dependency manager, everything is sourced shell. `drive-sync.sh` is the entry point: it sources every `lib/*.sh` module in a fixed order (config, utils, logging, state, storage, limit, quarantine, compression, sync_ops, safety, memory, plan, cli), then `main()` validates the environment and dispatches to `init`/`push`/`pull`/`sync`/`update`/`plan`/`restore`/`status`/`doctor`/`ratelimit`. `doctor` and `init` skip `validate_environment` on purpose: they report every problem instead of exiting at the first. `init` (`run_init` in `cli.sh`) writes `~/.drive-sync/drive-sync.conf` only when absent, naming the single Google Drive remote that `rclone listremotes --long` shows, creates the local directory, then runs `run_doctor` against that remote (exit 69 on a failed check).

Every `lib/*.sh` file guards against direct execution (`[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1`). They're libraries, not scripts, and must be sourced.

- **`lib/config.sh`**: single source of truth for defaults, exit codes (`EX_*`), and `get_*` accessor functions. User overrides live at `~/.drive-sync/drive-sync.conf` and are sourced after the defaults, then everything is made `readonly`. Changing `OPTIMIZED_MARKER`, `GHOSTSCRIPT_DEVICE`, or `MIN_VALID_COMPRESSED_SIZE` mid-flight can corrupt an in-progress workflow (see warnings in the file).
- **`lib/sync_ops.sh`**: thin rclone wrappers (`sync_to_drive`, `sync_from_drive`, `update_from_drive`). `push` mirrors deletions to Drive; `pull` only adds/updates locally and never deletes; `update` mirrors Drive onto local (rclone `sync`), deleting local files absent from Drive. All translate rclone exit codes into a private 0/1/2/3 contract (0 success, 2 temporary/rate-limit, 3 fatal, 1 other) consumed by `handle_sync_result` in `drive-sync.sh`. This internal code is distinct from the process's final `EX_*` exit code.
- **`lib/safety.sh`**: `guard_deletions` runs from `do_sync` before every `push`, `update` and the push half of `sync` (for `sync`, between the pull and the push). It counts the "Skipped delete" lines of an `rclone sync --dry-run --log-level NOTICE`, aborts with exit 1 above `MAX_DELETE_PERCENT` (also with `-f` and without a TTY), and prompts only on a TTY unless `FORCE` is set. `-f` exports `FORCE`; it is not a parameter. `update` also passes `--backup-dir` under `ARCHIVE_DIR`. rclone rejects a `--backup-dir` inside the destination, so `push` relies on Drive's trash.
- **`lib/quarantine.sh`**: keeps the original of every PDF compression replaces (hash mode), under `QUARANTINE_DIR/<relpath>/<UTC timestamp>`, for `QUARANTINE_RETENTION_DAYS` (default 30, 0 disables). The directory is its own index, so `state.json` has no extra field. `compress_pdf` links the original into the quarantine before the compressed file replaces it, and a failure there fails that file with the original untouched, which extends the compression invariant. Age is read from the name, never from mtime, because a hard-linked entry keeps the original's mtime. `quarantine_prune` also removes old timestamped dirs under `ARCHIVE_DIR` and runs from `do_sync` only outside dry runs. `restore` moves the newest entry back and records it in `state.json` with `size == original_size` so it is not recompressed. Without `config.sh` the retention reads as 0, which keeps the characterization tests valid.
- **`lib/memory.sh`**: the `sync` memory. After a successful `push`/`sync`/`update` (never a dry run or `pull`) `do_sync` writes `~/.drive-sync/manifest`, the sorted local paths both sides then share. Before the pull, `sync_memory_prepass` diffs it against the local and remote listings (`memory_diff`) and `memory_apply` removes files removed locally from Drive (`rclone delete --files-from-raw --drive-use-trash`) and moves files removed on Drive into a timestamped dir under `ARCHIVE_DIR`, through `memory_guard` (same `MAX_DELETE_PERCENT`, confirmation and `FORCE` rules as `guard_deletions`). No manifest means the old pull-then-push behavior, so a stale or missing manifest never deletes anything. `plan sync` mirrors it ("Since last sync"). The `rclone` mock's `lsf` takes `MOCK_RCLONE_LSF_NAMES` and `delete` records its list in `deleted_files.txt`.
- **`lib/plan.sh`**: the read-only `plan` command. It builds one JSON document (compress, transfers, deletions) and renders the text report from it. The compress section reads `list_compress_candidates` from `compression.sh`, the same list a real run processes, so a plan cannot drift from the run. rclone is only called with `--dry-run`, `gs` only writes under a `mktemp` directory (`--measure`), and `DRY_RUN` is forced on. For `sync`, deletions the pull half would restore are left out of the count. `plan --json` suppresses `-v` so stdout stays pure JSON.
- **`lib/limit.sh`**: classifies rclone exit codes 5/6 as retryable rate limits and 7 as fatal (auth revoked/account suspended); `recover_from_rate_limit` sleeps, clears rclone's cache, and probes the remote.
- **`lib/compression.sh`**: PDF compression via Ghostscript. Core invariant: an original is never deleted or replaced unless compression both succeeds and produces a smaller file; a failed compression always leaves the original in place for retry next run. Files under 10 KB, or carrying the `OPTIMIZED_MARKER` suffix, never invoke `gs`. `TRACKING_MODE` selects how "already optimized" is remembered: `hash` (default from `config.sh`) keeps the file name and records the content hash in `state.json`, skipping unchanged files by size+mtime without re-reading them; `suffix` is the legacy rename to `*.optimized.pdf`. When the module is sourced without `config.sh` (as the characterization tests do) it defaults to `suffix`, which is what keeps those tests valid.
- **`lib/state.sh`**: `state.json` under `~/.drive-sync/`, guarded by `flock` on fd 200 (`acquire_lock`/`release_lock`) so concurrent runs don't corrupt it. `acquire_run_lock` (fd 201, `run.lock`, non-blocking, held until exit) serializes whole mutating runs: `main` takes it for `push`/`pull`/`sync`/`update`/`restore PATH` outside dry runs and exits 75 when it is taken. Schema 2 adds `schema_version` and a `files` map (path relative to `DRIVE_ROOT`, mapped to `{hash, original_size, size, mtime}`); `init_state` migrates a v1 file and keeps `state.json.bak-v1`. All state mutation (`update_state`, `record_file_state`, `migrate_state`) writes to a `.tmp.$$` file and `mv`s it into place.
- **`lib/utils.sh`**: path validation (`validate_path` restricts operations to `ALLOWED_PATHS`, i.e. under `DRIVE_ROOT`) and size/decimal formatting helpers shared by compression and storage display.
- **`lib/storage.sh`**, **`lib/logging.sh`**, **`lib/cli.sh`**: storage-usage display in binary units (GiB/MiB/KiB), rotating structured logging (10 MB rotation, 5 generations kept, ISO 8601 timestamps), and the `status`/`--help`/usage text.

Service data (state, logs, lock file) lives entirely in `~/.drive-sync/`, never inside the synced directory (`DRIVE_ROOT`, default `~/drive`).

### Exit codes and console I/O contract

`docs/CONTRACT.md` is the authoritative reference for process exit codes (`0`, `1`, `2`, `69`, `75`) and for which stream (stdout/stderr) each log severity writes to under default vs. `-v/--verbose`. Read it before changing anything in `lib/logging.sh`, `main()`'s argument parsing, or `handle_sync_result`. Those three are what the contract constrains. Key points not to relearn by trial and error:
- Stream choice is decided by severity, not by `-v`; `-v` only toggles whether INFO/SUCCESS reach the console at all (they always go to the log file regardless).
- Bare invocation (no args) is a usage error (exit 2); explicit `-h`/`--help` is a successful, requested action (exit 0).
