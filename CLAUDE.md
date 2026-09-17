# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make test                 # run full bats suite (requires bats-core >= 1.5.0)
bats tests/unit/cli.bats  # run a single test file
bats -f "some test name" tests/unit/cli.bats  # run a single test by name
./drive-sync.sh sync -n -v   # dry-run + verbose, exercises real code paths locally
```

Only `rclone` and `gs` are mocked (`tests/mocks/`); `jq` and `flock` run for real, so those two must be installed to run tests. Tests are split into:
- `tests/characterization/` — pins existing, contracted behavior (do not casually "fix" what these pin without checking `docs/CONTRACT.md` first)
- `tests/unit/` — individual functions and edge cases

CI (`.github/workflows/`) runs `make test` on push/PR to main; a separate `Release` workflow tars `drive-sync.sh` + `lib/` on `v*` tags.

## Architecture

Bash CLI, `set -euo pipefail`, no dependency manager — everything is sourced shell. `drive-sync.sh` is the entry point: it sources every `lib/*.sh` module in a fixed order (config → utils → logging → state → storage → limit → compression → sync_ops → cli), then `main()` validates the environment and dispatches to `push`/`pull`/`sync`/`status`/`ratelimit`.

Every `lib/*.sh` file guards against direct execution (`[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1`) — they're libraries, not scripts, and must be sourced.

- **`lib/config.sh`** — single source of truth for defaults, exit codes (`EX_*`), and `get_*` accessor functions. User overrides live at `~/.drive-sync/drive-sync.conf` and are sourced after the defaults, then everything is made `readonly`. Changing `OPTIMIZED_MARKER`, `GHOSTSCRIPT_DEVICE`, or `MIN_VALID_COMPRESSED_SIZE` mid-flight can corrupt an in-progress workflow (see warnings in the file).
- **`lib/sync_ops.sh`** — thin rclone wrappers (`sync_to_drive`, `sync_from_drive`). `push` mirrors deletions to Drive; `pull` only adds/updates locally and never deletes. Both translate rclone exit codes into a private 0/1/2/3 contract (0 success, 2 temporary/rate-limit, 3 fatal, 1 other) consumed by `handle_sync_result` in `drive-sync.sh` — this internal code is distinct from the process's final `EX_*` exit code.
- **`lib/limit.sh`** — classifies rclone exit codes 5/6 as retryable rate limits and 7 as fatal (auth revoked/account suspended); `recover_from_rate_limit` sleeps, clears rclone's cache, and probes the remote.
- **`lib/compression.sh`** — PDF compression via Ghostscript. Core invariant: an original is never deleted unless compression both succeeds and produces a smaller file; a failed compression always leaves the original in place for retry next run. Files already under 10 KB, or files already carrying the `OPTIMIZED_MARKER` suffix, are skipped/marked without invoking `gs`.
- **`lib/state.sh`** — `state.json` under `~/.drive-sync/`, guarded by `flock` on fd 200 (`acquire_lock`/`release_lock`) so concurrent runs don't corrupt it. All state mutation goes through `update_state`, which writes to a `.tmp.$$` file and `mv`s it into place.
- **`lib/utils.sh`** — path validation (`validate_path` restricts operations to `ALLOWED_PATHS`, i.e. under `DRIVE_ROOT`) and size/decimal formatting helpers shared by compression and storage display.
- **`lib/storage.sh`**, **`lib/logging.sh`**, **`lib/cli.sh`** — storage-usage display in binary units (GiB/MiB/KiB), rotating structured logging (10 MB rotation, 5 generations kept, ISO 8601 timestamps), and the `status`/`--help`/usage text.

Service data (state, logs, lock file) lives entirely in `~/.drive-sync/`, never inside the synced directory (`DRIVE_ROOT`, default `~/drive`).

### Exit codes and console I/O contract

`docs/CONTRACT.md` is the authoritative reference for process exit codes (`0`, `1`, `2`, `69`, `75`) and for which stream (stdout/stderr) each log severity writes to under default vs. `-v/--verbose`. Read it before changing anything in `lib/logging.sh`, `main()`'s argument parsing, or `handle_sync_result` — those three are what the contract constrains. Key points not to relearn by trial and error:
- Stream choice is decided by severity, not by `-v`; `-v` only toggles whether INFO/SUCCESS reach the console at all (they always go to the log file regardless).
- Bare invocation (no args) is a usage error (exit 2); explicit `-h`/`--help` is a successful, requested action (exit 0).
