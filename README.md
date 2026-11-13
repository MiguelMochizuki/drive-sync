# Drive Sync

![CI](https://github.com/MiguelMochizuki/drive-sync/actions/workflows/ci.yml/badge.svg)

Drive Sync keeps a local folder and Google Drive in step and shrinks your
PDFs on the way, so a large archive of papers, books and scans takes less of
your Drive quota. Anything that changes or removes files can be previewed
first and undone afterwards.

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Project Organization](#project-organization)
- [Main Tools & Stack](#main-tools--stack)
- [Usage](#usage)
- [Documentation Conventions](#documentation-conventions)
- [Contributing](#contributing)
- [License](#license)

## Overview

Drive Sync wraps `rclone`. Before uploading it compresses PDFs with
Ghostscript, and the rest is about doing that without losing anything.

- `plan` shows what a run would compress, transfer and delete, with the
  space it expects to save, and changes nothing.
- A compressed PDF replaces the original only when it is smaller and valid.
  The original is kept for 30 days, and `restore` puts it back.
- Deletions are limited (50% of the files by default, even with `-f`) and
  go to Drive's trash or to a local archive, never straight to nothing.
- `sync` remembers the last sync, so a file you rename or delete is not
  brought back or duplicated.
- `status` shows how much space compression has freed.

### How a sync works

Before a push or sync, the local PDFs are compressed with Ghostscript. Files
under 10 KB are left alone. A compressed file replaces the original in place
(same name) only when it is smaller and valid, and its content hash is
recorded in `state.json` so it is not processed again. A failed compression
leaves the original in place for the next run. Then rclone transfers the
files, and a rate limit is detected and waited out.

### Direction of each command

`push` mirrors local to Drive, including deletions. `pull` only adds and
updates local files. `update` is the reverse of `push`: it mirrors Drive
to local, so any local file no longer on Drive is deleted. Use it to
discard local changes and match Drive exactly.

Because `push` and `update` delete files, both are guarded; see
[Safety](#safety).

### Renames and removals in a sync

`sync` remembers what both sides shared at the last successful `push`,
`sync` or `update` (the manifest, `~/.drive-sync/manifest`) and honors what
changed on each side since then:

- a file you removed or renamed here is removed from Drive, into its trash;
- a file removed or renamed on Drive is moved from your directory into
  `~/.drive-sync/archive/`, under the same retention as the quarantine;
- a file that is new on one side is copied to the other.

A rename is a removal plus a new file, so nothing is duplicated and you do
not have to pick `push` or `update` by hand. The deletion limit and the
confirmation apply to these removals too (see [Safety](#safety)), and
`plan` lists both counts under "Since last sync". There is no conflict
resolution: a file edited on one side and removed on the other follows the
removal. The first `sync` after upgrading has no manifest, so it pulls and
pushes as before and records one. Run `push` first if you want removals you
made before upgrading to reach Drive. A rename still uploads the whole file
again, because rclone's rename tracking is not used.

## Quick Start

Prerequisites are listed under [Main Tools & Stack](#main-tools--stack).

```bash
git clone https://github.com/MiguelMochizuki/drive-sync.git
cd drive-sync
sudo make install       # installs to /usr/local
# or
make install-user       # installs to ~/.local/bin, no sudo
```

`make install-user` requires `~/.local/bin` on your `PATH`:

```bash
export PATH="$PATH:$HOME/.local/bin"
```

To remove: `sudo make uninstall`.

### First run

```bash
rclone config           # once: create a remote of type drive
drive-sync init         # writes the config, creates ~/drive, checks the setup
drive-sync plan         # see what a first sync would do, changing nothing
drive-sync sync
```

`init` is safe to repeat. It never overwrites a config and never touches the
files in your synced directory. If the doctor checks it runs fail, it tells
you what is missing and exits `69`.

### Manual setup

```bash
chmod +x drive-sync.sh lib/*.sh
rclone config
./drive-sync.sh init
./drive-sync.sh sync
```

## Project Organization

```
drive-sync/
├── .github/               # GitHub config
│   └── workflows/
├── docs/                  # exit-code and console I/O contract
│   └── CONTRACT.md
├── lib/                   # sourced shell modules
│   ├── cli.sh
│   ├── compression.sh
│   ├── config.sh
│   ├── limit.sh
│   ├── logging.sh
│   ├── memory.sh
│   ├── plan.sh
│   ├── quarantine.sh
│   ├── safety.sh
│   ├── state.sh
│   ├── storage.sh
│   ├── sync_ops.sh
│   └── utils.sh
├── tests/                 # test suite
│   ├── characterization/  # pins contracted behavior
│   ├── fixtures/
│   ├── mocks/             # rclone and gs stubs
│   ├── unit/
│   └── test_helper.bash
├── .gitignore
├── CLAUDE.md
├── CONTRIBUTING.md
├── drive-sync.sh
├── LICENSE
├── Makefile
└── README.md
```

### Key modules

`drive-sync.sh` is the entry point and sources the thirteen modules under
`lib/`:

| Module | Responsibility |
|---|---|
| `cli.sh` | Help text and status display |
| `sync_ops.sh` | rclone wrappers for push/pull/sync/update |
| `compression.sh` | PDF compression with safety guarantees |
| `storage.sh` | Storage usage in binary units (GiB, MiB, KiB) |
| `limit.sh` | Rate limit detection and recovery |
| `safety.sh` | Deletion guard: plan, percentage limit, confirmation |
| `plan.sh` | The read-only `plan` report: compression, transfers, deletions |
| `quarantine.sh` | Keeps replaced originals for a while, prunes them, restores them |
| `memory.sh` | The sync manifest: honors removals and renames made on either side |
| `logging.sh` | Structured logging with rotation |
| `state.sh` | JSON state persistence with file locking |
| `utils.sh` | Path validation and formatting helpers |
| `config.sh` | Defaults and user overrides |

Service data (state, logs, and the lock file) lives in `~/.drive-sync/`,
separate from the synced directory.

## Main Tools & Stack

- **Language**: Bash 4.0+ or Zsh
- **Sync**: [rclone](https://rclone.org/), configured with a Google Drive remote
- **Compression**: [Ghostscript](https://ghostscript.com/) (`gs`)
- **State and locking**: `jq`, `flock`
- **Optional**: `bc` for precise size calculations
- **Build/install**: `make`
- **Tests**: [bats-core](https://github.com/bats-core/bats-core) >= 1.5.0
- **CI**: GitHub Actions runs `make test` on push and pull requests to
  `main`; a release workflow packages `drive-sync.sh` and `lib/` on
  `v*` tags

## Usage

```bash
drive-sync push         # upload to Drive (compresses PDFs first)
drive-sync pull         # download from Drive, never deletes locally
drive-sync sync         # pull, then push
drive-sync update       # mirror from Drive, deleting local files not on Drive
drive-sync init         # first-run setup: config, local directory, checks
drive-sync plan         # show what a run would compress, transfer and delete
drive-sync restore PATH # put a compressed PDF's original back (restore --list shows what is kept)
drive-sync status       # show sync status and storage usage
drive-sync doctor       # check dependencies, remote, state and settings
drive-sync ratelimit    # manual rate limit recovery
```

### Status output

`status` prints plain text in sections, and `doctor` follows the same
style. On a terminal titles are cyan, `[ok]` is green, `[FAIL]` is red and
`[warn]` is yellow; there is no bold. Set `NO_COLOR` to turn color off.
Redirected output never contains escape codes.

```
drive-sync 3.0.0

Paths
  Local: /home/you/drive
  Remote: drive:

Sync
  Last sync: 2026-11-13T12:19:54+00:00
  Status: success

Files
  PDFs: 148 total
    Optimized: 141
    Pending: 7
  Size: 2.86 GiB
  Saved: 412.30 MiB (31.2% of the PDFs it shrank)

Storage
  Drive: 4.19 GiB / 15.00 GiB (27.9%)

Next: drive-sync.sh push
```

In `hash` mode, "Optimized" counts the PDFs `state.json` tracks plus any
legacy `*.optimized.pdf` files.

`Saved` adds up what compression freed, from the sizes `state.json`
recorded before and after for each tracked file that still exists. Files
renamed to `*.optimized.pdf` by older versions cannot be measured, because
their originals are gone, so a `Not counted` line reports how many there
are. Both lines appear only in `hash` mode.

### Plan

`plan` shows what a run would do and changes nothing: no file, no
`state.json` entry, no Drive change. It takes the same direction as the
other commands (`push`, `pull`, `sync` or `update`) and defaults to `sync`.

```
drive-sync plan (sync)

Compress
  3 PDFs, 11.34 MiB to process
  Saving: no estimate yet (nothing optimized before); try --measure
    books/analysis.pdf (7.62 MiB)
    books/scan-2024.pdf (2.86 MiB)
    notes.pdf (878.90 KiB)

Download
  2 files would be copied

Upload
  2 files would be copied

Delete
  1 of 200 files (limit 50%)
  would continue
```

The saving is an estimate: the ratio recorded in `state.json` applied to
the pending PDFs. With no history there is no estimate. `plan --measure`
compresses every candidate into a temporary directory and reports what the
real run would save; it takes as long as compressing, and leaves your files
alone. `plan --json` prints the same report as one JSON document, for
scripts, and nothing else on stdout.

In a `sync` the pull runs first, so the delete count leaves out files the
pull would restore. To push a local deletion to Drive, use `push`: `sync`
downloads the file again.

### Quarantine and restore

Before compression replaces a PDF, the original is kept under
`~/.drive-sync/originals/<path>/<UTC timestamp>` for 30 days. On the same
disk it is a hard link, so nothing is copied, but the original's disk space
stays in use until it ages out: expect roughly the size of what you
compressed, for 30 days. `restore --list` shows what is kept, and
`restore books/analysis.pdf` puts the newest original back and marks the
file as already optimized, so the next run leaves it alone. Run `push`
afterwards to send the original to Drive.

A file that did not shrink is never kept, and if the original cannot be
kept (for example the directory is not writable) that file is not
compressed. Set `QUARANTINE_RETENTION_DAYS=0` in
`~/.drive-sync/drive-sync.conf` to turn the quarantine off, and
`QUARANTINE_DIR` to move it. It applies in `hash` mode only.

The same retention prunes the timestamped folders `update` leaves under
`~/.drive-sync/archive/`. Pruning runs at the start of a real `push`,
`pull`, `sync` or `update`, never in a dry run, in `plan` or in `status`.

### Options

| Flag | Description |
|---|---|
| `-n`, `--dry-run` | Preview changes without modifying anything: no transfer, no compression, no state change. With `-v`, lists the PDFs it would compress |
| `-f`, `--force` | Skip the deletion confirmation (the deletion limit still applies) |
| `-v`, `--verbose` | Show detailed progress (INFO/SUCCESS lines) |
| `-q`, `--quiet` | Hide warnings on the console; errors are still shown and the log file keeps everything |
| `--json` | With `plan`: print the report as JSON |
| `--measure` | With `plan`: measure PDF savings with `gs` instead of estimating |
| `-h`, `--help` | Show help text |
| `-V`, `--version` | Show version |

### Configuration

Defaults live in `lib/config.sh`. Override any variable in
`~/.drive-sync/drive-sync.conf`:

```bash
# ~/.drive-sync/drive-sync.conf

REMOTE_NAME="drive:"
DRIVE_ROOT="${HOME}/drive"

RCLONE_TRANSFERS="4"
RCLONE_CHECKERS="4"

RATE_LIMIT_BACKOFF_SECONDS=300
MAX_RETRIES=3
RETRY_DELAY=60
```

| Variable | Default | Description |
|---|---|---|
| `REMOTE_NAME` | `drive:` | rclone remote name |
| `DRIVE_ROOT` | `~/drive` | Local sync directory |
| `RCLONE_TRANSFERS` | `2` | Parallel file transfers |
| `RCLONE_CHECKERS` | `2` | Parallel file checkers |
| `RCLONE_TPSLIMIT` | `8` | API transactions/sec limit |
| `RCLONE_TPSLIMIT_BURST` | `5` | Transaction burst allowance |
| `RCLONE_TIMEOUT` | `5m` | Operation timeout |
| `RCLONE_RETRIES` | `3` | rclone internal retries |
| `RCLONE_DRIVE_CHUNK_SIZE` | `128M` | Upload chunk size |
| `TRACKING_MODE` | `hash` | `hash` keeps file names and tracks content in `state.json`; `suffix` is the legacy `*.optimized.pdf` renaming |
| `MAX_DELETE_PERCENT` | `50` | Abort a push/update that would delete more than this percentage of the destination |
| `ARCHIVE_DIR` | `~/.drive-sync/archive` | Where `update` and `sync` move local files they remove |
| `QUARANTINE_DIR` | `~/.drive-sync/originals` | Where replaced originals are kept |
| `QUARANTINE_RETENTION_DAYS` | `30` | Days to keep originals and the archive; `0` turns the quarantine off |
| `REMOTE_BACKUP_DIR` | empty | Optional rclone `--backup-dir` for `push`; must be outside the destination |
| `OPTIMIZED_MARKER` | `.optimized.pdf` | Legacy suffix: files carrying it are recognized as optimized |
| `GHOSTSCRIPT_DEVICE` | `pdfwrite` | Ghostscript output device |
| `MIN_VALID_COMPRESSED_SIZE` | `1024` | Minimum valid compressed size, in bytes |
| `RATE_LIMIT_BACKOFF_SECONDS` | `300` | Rate limit wait period |
| `MAX_RETRIES` | `3` | Sync attempt retries |
| `RETRY_DELAY` | `60` | Delay between retries |

Changing `OPTIMIZED_MARKER`, `GHOSTSCRIPT_DEVICE`, or
`MIN_VALID_COMPRESSED_SIZE` mid-workflow can leave already-processed
files in an inconsistent state; see the warnings in `lib/config.sh`.

### Safety

`push` and `update` run `rclone sync`, which deletes. Before either runs,
drive-sync does a dry run and counts what would be deleted:

- If that is more than `MAX_DELETE_PERCENT` of the destination's files
  (default 50%), it aborts with exit 1, even with `-f` and even without a
  terminal. This catches an unmounted disk or an emptied folder before a
  `push` wipes Drive. Set `MAX_DELETE_PERCENT=100` to disable the limit.
- On a terminal it asks `Continue? [y/N]`; `-f` skips the question. Under
  cron or a pipe there is no prompt, only the limit.
- If the dry run itself fails, it aborts rather than proceed blind.
- `--dry-run` skips all of this, and `pull` and the pull half of `sync`
  never delete, so they are never guarded.

What is deleted stays recoverable:

- `push` sends remote deletions to Google Drive's trash
  (`--drive-use-trash`). rclone refuses a `--backup-dir` inside the
  destination, so a Drive-side archive only works when `REMOTE_NAME`
  points at a subfolder (`REMOTE_NAME="drive:Sync"`,
  `REMOTE_BACKUP_DIR="drive:Sync-archive"`).
- `update` moves local files it would delete into
  `~/.drive-sync/archive/<timestamp>/`. Nothing prunes that directory yet.

### One run at a time

`push`, `pull`, `sync`, `update` and `restore PATH` take a lock on
`~/.drive-sync/run.lock` and hold it until they exit. A second one started
meanwhile (a cron job overlapping a manual run, for example) prints
"another drive-sync run is in progress" on stderr, does nothing and exits
`75`. Dry runs, `plan`, `status`, `doctor` and `restore --list` only read,
so they are never blocked.

### State and migration

`state.json` is schema 2: besides the sync fields it keeps a `files` map of
relative path to `{hash, original_size, size, mtime}`. A v1 file is migrated
on the first run, and the old one is kept as `state.json.bak-v1`. Files
already renamed to `*.optimized.pdf` are left alone and still recognized.

### Rate limiting

On a Google Drive API rate limit, the tool pauses, waits for the
configured backoff period, and resumes automatically, tracking recovery
attempts in state and logs. Temporary errors (rclone exit 5/6) are
distinguished from fatal ones (exit 7), which are not retried.

### Upgrading

See [`CHANGELOG.md`](CHANGELOG.md) for what changed and what to check when
moving from 2.x: the quarantine is on by default, the first `sync` has no
manifest yet, and the `update` archive is now pruned.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | General failure, or the deletion guard aborted (limit exceeded, plan unavailable, or you answered no) |
| `2` | Usage error: unknown command, unknown flag, or no arguments |
| `69` | Resource unavailable: fatal rclone error, a missing dependency/remote, or a failed `doctor` or `init` check |
| `75` | Temporary failure: retries exhausted after transient or rate-limit errors, or another run is already in progress |

See [`docs/CONTRACT.md`](docs/CONTRACT.md) for the full exit-code and
console I/O contract, including stream and verbosity behavior.

### Tests

```bash
make test
```

`rclone` and `gs` are mocked (`tests/mocks/`); `jq` and `flock` run for
real. Tests live under:

- `tests/characterization/`: pins existing, contracted behavior
- `tests/unit/`: covers individual functions and edge cases

### Troubleshooting

**`drive-sync: command not found`**: ensure `~/.local/bin` or
`/usr/local/bin` is on your `PATH`.

**`rclone not found`**: `curl https://rclone.org/install.sh | sudo bash`

**`gs not found`**: `sudo apt install ghostscript` (Ubuntu/Debian) or
`brew install ghostscript` (macOS)

**Permission denied**: `chmod +x drive-sync.sh lib/*.sh`

**`bc not found`**: `sudo apt install bc` (Ubuntu/Debian) or
`brew install bc` (macOS)

## Documentation Conventions

Bash files use a file header and a `Parameters:` / `Returns:` block above
each function. The rules and examples are in
[`CONTRIBUTING.md`](CONTRIBUTING.md#documentation-conventions).

## Contributing

Fork the repository, create a feature branch, and submit a pull request.
Run `make test` first and follow [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

MIT. See [`LICENSE`](LICENSE).
