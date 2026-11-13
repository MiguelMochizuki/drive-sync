# Changelog

## 3.0.0

drive-sync now previews what it will do, keeps what it replaces, and remembers the last sync.

Added

- `plan [push|pull|sync|update] [--json] [--measure]`: a read-only report of what a run would compress, transfer and delete, with an estimated or measured saving.
- A quarantine: the original of every PDF that compression replaces is kept under `~/.drive-sync/originals/` for 30 days, and `restore PATH` (or `restore --list`) puts one back.
- `sync` memory: a manifest of the paths both sides shared at the last successful `push`, `sync` or `update`. `sync` removes files you removed or renamed here from Drive (to its trash), and moves files removed or renamed on Drive into `~/.drive-sync/archive/`, so a rename no longer duplicates or reverts.
- `init`: a first-run setup that is safe to repeat.
- `status` shows the space saved by compression and the quarantine size.
- A run lock: a second push, pull, sync, update or restore exits 75 while another is running.

Changed

- Rate limit recovery no longer runs `rclone cleanup`, so Drive's trash is never emptied.
- A dry run says it finished without transferring, and ends with a line pointing to `plan`.
- Files under 10 KB are not listed as work in dry runs and `plan` in hash mode.
- PNG and JPEG compression was considered and dropped from the roadmap; PDF stays the only type.

Upgrading from 2.x

- The quarantine is on by default (`QUARANTINE_RETENTION_DAYS=30`). It keeps the original of every PDF compressed from now on, so expect disk use of roughly the size of what you compress, for 30 days. Set `QUARANTINE_RETENTION_DAYS=0` in `~/.drive-sync/drive-sync.conf` to turn it off.
- The same retention now prunes the timestamped folders `update` leaves in `~/.drive-sync/archive/`. Files you want to keep from there must be moved out within 30 days.
- The first `sync` after upgrading has no manifest, so it behaves as 2.x did (pull, then push) and records one. Files you deleted or renamed locally before upgrading are restored by that first pull; run `push` first to send those removals to Drive.
- `state.json` keeps schema 2 and needs no migration. The new files are `manifest` and `run.lock` in `~/.drive-sync/`.
- Exit codes are unchanged. Code 75 now also means another run holds the lock.

## 2.2.1

A dry run (`-n`) no longer compresses files or writes state.

## 2.2.0

A real deletion confirmation and limit, backups for `update`, hash-based state with migration, `doctor`, and a redesigned `status`.
