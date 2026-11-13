# Roadmap

Decisions from planning the v2.2 and v3 redesign. Check this file before adding a feature that is not listed here.

## Positioning

drive-sync is for people with large archives of PDFs, scans and photos who want their Google Drive storage under control without learning `rclone`. The headline is space saved. Safety (no lost files) is the guarantee behind it, and a quick setup is the way in.

Google Drive is the only documented backend.

The name stays "drive-sync" until phase 1 works. Before the first public announcement, check for name collisions on GitHub, brew and apt, and pick the final name then.

## Product decisions

| Area | Decision |
|---|---|
| File types | PDF only. PNG and JPEG were considered and dropped: lossless gains are small (a few percent for JPEG, little for PNG outside unoptimized screenshots) and nearly all the compressible volume in the author's archive is PDF. A per-type pipeline waits until a second type has real demand. Lossy compression is opt-in and never the default. |
| Tracking optimized files | A content hash per file in `state.json`, with no renaming. The `.optimized.pdf` suffix stays as a legacy mode, and the state migrates automatically. |
| Replaced originals | Every original that compression replaces, PDFs included, is moved to a local quarantine (`~/.drive-sync/originals/`) with configurable retention (for example 30 days). `drive-sync restore` undoes it. |
| Tool dependencies | `gs` is optional. A missing `gs` disables compression with a warning. Exit 69 applies only to `rclone`, `jq` and `flock`. This changes `docs/CONTRACT.md`. |
| Destructive operations | A real confirmation (terminal only, `-f` skips it), a recoverable place for whatever `push` or `update` deletes, and a percentage limit that aborts a plan deleting more than X% of the files. |
| New commands | `plan` (with `--json`), `init`, `doctor`, `restore` and `schedule` (systemd timer or launchd). `status` shows the cumulative space saved. |
| TUI | Not in phase 1. `plan` gives a text and JSON report first, and a TUI would sit on top of it if there is demand. |

## Engineering decisions

Bash stays through phase 1. The `bats` characterization suite is the specification a later Go port has to pass.

Exit codes and the console I/O contract stay. `state.json` and `drive-sync.conf` migrate automatically, keeping a backup of the old file. Breaking changes wait for a major version and come with a migration note.

## Status

v2.2 is released as 2.2.0 (PR #9): real confirmation, the deletion limit, backups, hash-based state with migration, and `doctor`. Version 2.2.1 (PR #12) fixed `-n`, which modified files and state before. The release differs from the plan in a few places.

- A Drive-side `--backup-dir` is impossible when the remote is the Drive root, because rclone refuses a backup directory inside the destination. `push` pins `--drive-use-trash` instead, and `REMOTE_BACKUP_DIR` is optional for remotes that point at a subfolder. `update` archives locally.
- The deletion limit applies even with `-f`. Only the confirmation can be skipped. A dry run that fails aborts the sync.
- Nothing prunes `~/.drive-sync/archive/` yet. Retention arrives with the v3.0 quarantine.

Before v2.2, `-f` was parsed in `main()` but never read, so no confirmation existed, and `push` and `update` deleted files without asking and without a `--backup-dir`.

`plan` (with `--json` and `--measure`) is built in v3.0; design in `docs/superpowers/specs/2026-11-13-plan-command-design.md`. Next in v3.0: the savings report in `status`, then quarantine and `restore`, then `init` and the README rewrite.

## Phases

1. v2.2 (safe base): real confirmation, backups, deletion limit, hash-based state with migration, `doctor`.
2. v3.0 (the differentiator): `plan` with `--json`, savings report in `status`, quarantine and `restore`, `init`, and a README rewrite that shows real `plan` output.
3. v3.x (convenience): `schedule`, and PNG, JPEG, lossy images, a TUI and video only if people ask for them.

Safety goes first. A savings report on top of a tool that still deletes without asking would cost the first user their files.

## Success signal

Five people outside the author's circle run `init` to the end and open an issue or a pull request.

## Non-goals

Until at least v3.x:

- Real bidirectional sync with conflict resolution (that is `rclone bisync`).
- Backends other than Google Drive.
- A `watch` daemon.
- A web interface.
- Built-in encryption.
