# Drive Sync

A robust command-line tool for synchronizing and optimizing PDF files with Google Drive.

## Features

- **Two-way sync** between local and Google Drive
- **Automatic PDF compression** using Ghostscript
- **Rate limit handling** with automatic recovery
- **File locking** for concurrent run safety
- **Structured logging** with rotation
- **Storage usage display** in binary units (GiB, MiB, KiB)
- **9 modular components** for maintainability
- **User-configurable** via `~/.drive-sync/drive-sync.conf`

## Installation

### Prerequisites

- [rclone](https://rclone.org/) configured with Google Drive
- [Ghostscript](https://ghostscript.com/) for PDF compression
- Bash 4.0+ or Zsh
- Optional: `bc` for precise calculations, `jq` for JSON parsing
- `make` (for installation)

### Quick Install

```bash
git clone https://github.com/yourusername/drive-sync.git
cd drive-sync
sudo make install
```

This copies the project to `/usr/local/lib/drive-sync/` and installs a
wrapper at `/usr/local/bin/drive-sync`.

To install without sudo (links to your clone location):

```bash
make install-user
```

**Important:** Make sure `~/.local/bin` is in your PATH. Add this to your `~/.bashrc` or `~/.zshrc` if not already:

```bash
export PATH="$PATH:$HOME/.local/bin"
```

### Uninstall

```bash
sudo make uninstall
```

This removes the wrapper from `/usr/local/bin/` and the sources from
`/usr/local/lib/drive-sync/`.

### Manual Setup

If you prefer not to use make:

1. Clone the repository
2. Make scripts executable: `chmod +x drive-sync.sh lib/*.sh`
3. Configure rclone: `rclone config`
4. Configure defaults: `cp lib/config.sh ~/.drive-sync/drive-sync.conf`
5. Run directly: `./drive-sync.sh sync`

## Usage

### Basic Commands

```bash
drive-sync push         # Upload to Drive (compresses PDFs first)
drive-sync pull         # Download from Drive
drive-sync sync         # Full bidirectional sync (pull then push)
drive-sync status       # Show sync status and storage usage
drive-sync ratelimit    # Manual rate limit recovery
```

### Options

| Flag | Description |
|---|---|
| `-n`, `--dry-run` | Preview changes without syncing |
| `-f`, `--force` | Skip confirmations |
| `-h`, `--help` | Show help text |
| `-v`, `--version` | Show version |

### Sync Process

1. **Scan**: Finds all PDFs in the local directory
2. **Compress**: Uses Ghostscript to optimize PDFs
   - Files under 10KB are marked as optimized
   - Files that compress successfully are renamed with `.optimized.pdf`
   - Failed compressions are preserved for retry
3. **Sync**: Uploads compressed files to Google Drive
4. **Monitor**: Handles rate limits automatically

### Status Display

The `status` command shows:
- Total PDF count and breakdown (optimized/pending)
- Storage usage in binary units (GiB/MiB/KiB)
- Last sync and compression timestamps
- Sync status and rate limit recovery count

## Configuration

All defaults live in `lib/config.sh`. You can override any variable by creating:

`~/.drive-sync/drive-sync.conf`

### Example

```bash
# ~/.drive-sync/drive-sync.conf — User overrides

# Sync target
REMOTE_NAME="drive:"
DRIVE_ROOT="${HOME}/drive"

# Performance (increase for fast connections)
RCLONE_TRANSFERS="4"
RCLONE_CHECKERS="4"

# Rate limiting
RATE_LIMIT_BACKOFF_SECONDS=300
MAX_RETRIES=3
RETRY_DELAY=60
```

### Available Variables

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
| `OPTIMIZED_MARKER` | `.optimized.pdf` | PDF compression suffix (⚠️) |
| `GHOSTSCRIPT_DEVICE` | `pdfwrite` | GS output device (⚠️) |
| `MIN_VALID_COMPRESSED_SIZE` | `1024` | Min valid compressed bytes (⚠️) |
| `RATE_LIMIT_BACKOFF_SECONDS` | `300` | Rate limit wait period |
| `MAX_RETRIES` | `3` | Sync attempt retries |
| `RETRY_DELAY` | `60` | Delay between retries |

⚠️ Changing variables marked with ⚠️ mid-flight can corrupt your workflow.
   See `lib/config.sh` warnings for details.

### Service Data

State, logs, and lock files live in **`~/.drive-sync/`** — not in the synced directory.
Your `~/drive` stays clean with only your files.

## Architecture

The tool consists of 9 modular components:

1. **`drive-sync.sh`** - Main entry point and sync orchestrator
2. **`lib/cli.sh`** - Command-line interface, help text, and status display
3. **`lib/sync_ops.sh`** - Core sync logic via rclone wrappers
4. **`lib/compression.sh`** - PDF compression with safety guarantees and binary size formatting
5. **`lib/storage.sh`** - Storage quota display in binary units (GiB, MiB, KiB)
6. **`lib/limit.sh`** - Rate limit detection and recovery
7. **`lib/logging.sh`** - Structured logging with automatic 10 MB rotation
8. **`lib/state.sh`** - JSON state persistence with file locking (flock)
9. **`lib/utils.sh`** - Path validation, file utilities, and decimal formatting

## Size Formatting

The tool displays storage sizes in **binary units** (GiB, MiB, KiB) to match common file
system conventions, while maintaining compatibility with Google Drive's decimal display
where needed.

## Logging

Logs are stored in `~/.drive-sync/` with:
- Automatic rotation at 10 MB (keeps 5 generations)
- Timestamped entries in ISO 8601 format
- Success/error/warning/info levels
- Compression metrics (percentage reduction, space saved)

## Rate Limit Handling

When Google Drive API rate limits are encountered:
1. Tool pauses execution
2. Waits for recovery period (default 300 seconds)
3. Resumes automatically
4. Tracks recovery attempts in state and logs

Distinguishes temporary errors (rclone exit 5/6) from fatal errors (exit 7)
that retries won't fix.

## Troubleshooting

### Common Issues

**"drive-sync: command not found"**
- Make sure `~/.local/bin` or `/usr/local/bin` is in your PATH
- Run: `export PATH="$PATH:$HOME/.local/bin"` or add to shell config

**"rclone not found"**
- Install rclone: `curl https://rclone.org/install.sh | sudo bash`

**"gs not found"**
- Install Ghostscript:
  - Ubuntu/Debian: `sudo apt install ghostscript`
  - macOS: `brew install ghostscript`

**"Permission denied"**
- Make scripts executable: `chmod +x drive-sync.sh lib/*.sh`

**"bc not found"**
- Install bc for precise calculations:
  - Ubuntu/Debian: `sudo apt install bc`
  - macOS: `brew install bc`

### Manual Rate Limit Recovery

```bash
drive-sync ratelimit
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes following existing style
4. Test thoroughly
5. Submit a pull request

## License

Drive Sync is distributed freely under the [MIT License](https://opensource.org/licenses/MIT).
See `LICENSE` for details.

## Acknowledgments

- [rclone](https://rclone.org/) for Google Drive integration
- [Ghostscript](https://ghostscript.com/) for PDF compression
- All contributors and users
