# Quarantine and `restore`: design

## Intent

Compression replaces a PDF with a smaller one and the original is gone. That is the one step in drive-sync that cannot be undone, and it is lossy in practice (images are downsampled). Keeping every replaced original locally for a while, and a command to put one back, makes the savings safe to accept. It is the second half of the v3.0 safety story after the deletion guard.

## Goals

- Before compression replaces a file, the original is kept under `~/.drive-sync/originals/` for `QUARANTINE_RETENTION_DAYS` (default 30).
- `drive-sync restore <path>` puts the newest quarantined original back at that path, and `restore --list` shows what is available.
- A restored file is not compressed again.
- If the original cannot be kept, compression of that file fails and the original stays in place. The existing invariant (never replace without success) gains this condition.

## Non-goals

Restoring from Drive revisions, quarantine in the legacy suffix mode, restoring a whole run at once, encryption, and a separate `prune` command.

## Anti-goals

Silently doubling local disk use with no way to see or turn it off. A restore that gets undone by the next run.

## Constraints

- No `state.json` schema change. The quarantine directory is its own index.
- Hash mode only. Suffix mode keeps its current behavior.
- `plan`, `-n` and `status` never modify the quarantine.

## Approaches

Keep the original with a hard link (chosen): `ln original quarantine/..` then `mv temp original`. Free when `~/drive` and `~/.drive-sync` share a disk (they do on the author's machine), atomic, and crash safe; falls back to `cp -p` across disks. Alternatives were a copy always (doubles I/O on a 1 GiB archive) and an index map in `state.json` (a schema change for information the directory already holds).

## Design

**Layout.** `originals/<relpath>/<UTC timestamp>`, for example `originals/books/analysis.pdf/20261113T140512`. A path may hold several timestamps when a file is compressed, edited and compressed again.

**Keeping.** In `compress_pdf`, in the branch where the compressed output is smaller and about to replace the original, hash mode first links (or copies) the original into the quarantine, and only then moves the compressed file over it. A file that did not shrink is never quarantined. Retention 0 turns the quarantine off and restores today's behavior.

**Pruning.** At the start of a real compression run, entries older than the retention are removed. The `update` archive under `ARCHIVE_DIR` (timestamp-named directories) is pruned by the same rule, which is what the roadmap promised for it. A dry run, `plan` and `status` never prune.

**restore.** `restore <path>` takes a path relative to `DRIVE_ROOT` (or absolute under it), moves the newest entry back over the file, and records the file in `state.json` with its own hash and `size == original_size`, so it counts as optimized and is skipped by the next run. It prints that `push` is needed to send the original to Drive. `restore --list` prints path, date, original size per entry. An unknown path exits 1; bad usage exits 2.

**Visibility.** `status` gets a line `Quarantine: 12 originals, 340.0 MiB (kept 30 days)`. `doctor` checks the quarantine directory is writable and reports the retention.

**Config.** `QUARANTINE_DIR` (default `${DRIVE_SYNC_HOME}/originals`) and `QUARANTINE_RETENTION_DAYS` (default 30, 0 disables).

## Left to the builder

How `compress_pdf` learns the path relative to `DRIVE_ROOT` without changing existing test call signatures, the exact `--list` columns, and the wording of messages.

## Tests

Original kept and file replaced; a file that did not shrink is not quarantined; a quarantine failure keeps the original and fails that file; retention 0 keeps today's behavior; two versions of one path; pruning by age including the `update` archive and never under dry run; restore round trip with the file skipped by the next run; restore of an unknown path; `--list`; status and doctor lines; path traversal in `restore` rejected.
