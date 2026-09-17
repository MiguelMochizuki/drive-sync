# Drive Sync

A command-line tool for synchronizing PDF files with Google Drive, with
optional compression before upload.

## Requirements

- [rclone](https://rclone.org/), configured with a Google Drive remote
- [Ghostscript](https://ghostscript.com/) (`gs`), for PDF compression
- `jq`, `flock`
- Bash 4.0+ or Zsh
- Optional: `bc` for precise size calculations
- `make`, for installation

## Install

```bash
git clone https://github.com/yourusername/drive-sync.git
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

### Manual setup

```bash
chmod +x drive-sync.sh lib/*.sh
rclone config
cp lib/config.sh ~/.drive-sync/drive-sync.conf   # optional, for overrides
./drive-sync.sh sync
```

## Usage

```bash
drive-sync push         # upload to Drive (compresses PDFs first)
drive-sync pull         # download from Drive, never deletes locally
drive-sync sync         # pull, then push
drive-sync update       # mirror from Drive, deleting local files not on Drive
drive-sync status       # show sync status and storage usage
drive-sync ratelimit    # manual rate limit recovery
```

`push` mirrors local to Drive, including deletions. `pull` only adds and
updates local files. `update` is the reverse of `push`: it mirrors Drive
to local, so any local file no longer on Drive is deleted. Use it to
discard local changes and match Drive exactly.

### Options

| Flag | Description |
|---|---|
| `-n`, `--dry-run` | Preview changes without syncing |
| `-f`, `--force` | Skip confirmations |
| `-v`, `--verbose` | Show detailed progress (INFO/SUCCESS lines) |
| `-h`, `--help` | Show help text |
| `-V`, `--version` | Show version |

### Sync process

1. **Scan** — find all PDFs in the local directory
2. **Compress** — optimize with Ghostscript
   - files under 10 KB are marked optimized without compressing
   - successfully compressed files are renamed with `.optimized.pdf`
   - failed compressions leave the original in place for retry
3. **Sync** — transfer files to or from Drive
4. **Monitor** — detect and recover from rate limits

## Configuration

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
| `OPTIMIZED_MARKER` | `.optimized.pdf` | PDF compression suffix |
| `GHOSTSCRIPT_DEVICE` | `pdfwrite` | Ghostscript output device |
| `MIN_VALID_COMPRESSED_SIZE` | `1024` | Minimum valid compressed size, in bytes |
| `RATE_LIMIT_BACKOFF_SECONDS` | `300` | Rate limit wait period |
| `MAX_RETRIES` | `3` | Sync attempt retries |
| `RETRY_DELAY` | `60` | Delay between retries |

Changing `OPTIMIZED_MARKER`, `GHOSTSCRIPT_DEVICE`, or
`MIN_VALID_COMPRESSED_SIZE` mid-workflow can leave already-processed
files in an inconsistent state; see the warnings in `lib/config.sh`.

Service data — state, logs, and the lock file — lives in
`~/.drive-sync/`, separate from the synced directory.

## Architecture

Nine modules under `lib/`, sourced by `drive-sync.sh`:

| Module | Responsibility |
|---|---|
| `cli.sh` | Command-line parsing, help text, status display |
| `sync_ops.sh` | rclone wrappers for push/pull/sync/update |
| `compression.sh` | PDF compression with safety guarantees |
| `storage.sh` | Storage usage in binary units (GiB, MiB, KiB) |
| `limit.sh` | Rate limit detection and recovery |
| `logging.sh` | Structured logging with rotation |
| `state.sh` | JSON state persistence with file locking |
| `utils.sh` | Path validation and formatting helpers |
| `config.sh` | Defaults and user overrides |

## Rate limiting

On a Google Drive API rate limit, the tool pauses, waits for the
configured backoff period, and resumes automatically, tracking recovery
attempts in state and logs. Temporary errors (rclone exit 5/6) are
distinguished from fatal ones (exit 7), which are not retried.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | General failure |
| `2` | Usage error — unknown command, unknown flag, or no arguments |
| `69` | Resource unavailable — fatal rclone error, or a missing dependency/remote |
| `75` | Temporary failure — retries exhausted after transient or rate-limit errors |

See [`docs/CONTRACT.md`](docs/CONTRACT.md) for the full exit-code and
console I/O contract, including stream and verbosity behavior.

## Testing

```bash
make test
```

Requires [bats-core](https://github.com/bats-core/bats-core) >= 1.5.0.
`rclone` and `gs` are mocked (`tests/mocks/`); `jq` and `flock` run for
real. Tests live under:

- `tests/characterization/` — pins existing, contracted behavior
- `tests/unit/` — covers individual functions and edge cases

## Troubleshooting

**`drive-sync: command not found`** — ensure `~/.local/bin` or
`/usr/local/bin` is on your `PATH`.

**`rclone not found`** — `curl https://rclone.org/install.sh | sudo bash`

**`gs not found`** — `sudo apt install ghostscript` (Ubuntu/Debian) or
`brew install ghostscript` (macOS)

**Permission denied** — `chmod +x drive-sync.sh lib/*.sh`

**`bc not found`** — `sudo apt install bc` (Ubuntu/Debian) or
`brew install bc` (macOS)

## Contributing

Fork the repository, create a feature branch, and submit a pull request.

## License

MIT. See [`LICENSE`](LICENSE).
