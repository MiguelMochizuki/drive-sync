# Roadmap

Decisions reached while planning the v2.2 / v3 redesign. This is the
reference for scope and ordering; revisit it before adding features that
are not listed here.

## Positioning

- **Audience:** people with large archives (PDFs, scans, photos) who want
  their Drive storage under control without learning `rclone`.
- **Promise:** space savings is the headline, safety ("never loses a
  file") is the guarantee, and easy setup ("configured in two minutes")
  is the way in.
- **Backend:** Google Drive is the primary and only documented path.
- **Name:** keep "drive-sync" until phase 1 works. Decide the final name,
  after checking for collisions on GitHub, brew and apt, before the first
  public announcement.

## Product decisions

| Area | Decision |
|---|---|
| File types | PDF, PNG and JPEG first. Lossy compression is opt-in, never the default. Configurable lossy images and video come later, and only on demand. |
| Optimized-file tracking | Per-file hash in `state.json`, with no renaming. The `.optimized.pdf` suffix remains as a legacy mode, migrated automatically. |
| Originals under lossy compression | Moved to a local quarantine (`~/.drive-sync/originals/`) with configurable retention; `drive-sync restore` undoes it. PDF and other lossless types keep today's behavior. |
| Tool dependencies | Each per-type tool (`gs`, `oxipng`, `jpegoptim`, ...) is optional: a missing tool disables that type with a warning. Exit 69 applies only to `rclone`, `jq` and `flock`. **This changes `docs/CONTRACT.md`.** |
| Destructive operations | Real confirmation (TTY only, `-f` skips), rclone `--backup-dir` for anything `push`/`update` would delete, and a percentage limit that aborts a plan deleting more than X% of files. |
| New commands | `plan` (with `--json`), `init`, `doctor`, `restore`, `schedule` (systemd timer / launchd). `status` shows cumulative space saved. |
| TUI | Not in phase 1. `plan` gives the text and JSON report first; a TUI is a layer on top, only if there is demand. |

## Engineering decisions

- **Language:** Bash through phase 1. The `bats` characterization suite is
  the specification a later Go port must pass.
- **Compatibility:** exit codes and the console I/O contract stay.
  `state.json` and `drive-sync.conf` migrate automatically with a backup
  of the old file. Breaking changes only in a major version with a
  migration note.

## Known issue to fix first

`-f` / `--force` is parsed in `main()` but the `force` variable is never
used, so no confirmation exists today: `push` and `update` run
`rclone sync` and delete files without asking, and neither passes
`--backup-dir`.

## Phases

1. **v2.2, safe base:** real confirmation, `--backup-dir`, deletion
   limit, hash-based state with migration, `doctor`.
2. **v3.0, the differentiator:** multi-type pipeline (PDF, PNG, JPEG),
   `plan` with `--json`, savings report in `status`, quarantine and
   `restore`, `init`, and a README rewrite showing real `plan` output.
3. **v3.x, convenience:** `schedule`, opt-in lossy images and, only on
   demand, a TUI and video.

Safety comes first: a savings report on top of a tool that still deletes
without asking would lose the first user's files.

## Success signal

The first five people outside the author's circle who run `init` to the
end and open an issue or a pull request.

## Non-goals

Until at least v3.x:

- Real bidirectional sync with conflict resolution (that is
  `rclone bisync`).
- Backends other than Google Drive.
- A `watch` daemon.
- A web interface.
- Built-in encryption.
