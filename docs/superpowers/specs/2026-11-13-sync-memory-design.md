# Sync memory: design

## Intent

`sync` pulls and then pushes, and it has no memory of the last sync. A file present only on Drive could be new there (pull it) or deleted here (delete it there), and `sync` always assumes the first. So a file you delete or rename locally comes back from Drive, and a rename ends up as two files. `push` and `update` handle each side correctly but you cannot always pick the right one.

## Goals

- After a successful `push`, `sync` or `update`, drive-sync records the list of paths both sides share (the manifest, `~/.drive-sync/manifest`).
- `sync` then honors changes since that point on both sides: a file removed or renamed away locally is removed from Drive (to the trash), and a file removed or renamed away on Drive is moved from the local directory to the archive (`ARCHIVE_DIR`, same retention as the quarantine). A rename is a removal plus a new file, so nothing is duplicated.
- Without a manifest (first run after upgrading) `sync` behaves as before and creates the manifest on success.
- `plan sync` shows what would be honored.

## Non-goals

Conflict resolution (a file edited on one side and removed on the other follows the removal rule), server side moves to avoid re-uploading a renamed file, using the manifest for `push`, `pull` and `update` (a plain `pull` never updates it because it does not make both sides equal), and tracking by hash.

## Anti-goals

A first run that deletes things because the manifest is missing or stale. A removal honored without the deletion limit and confirmation.

## Design

**Manifest.** Sorted relative paths, one per line, written atomically from a local `find` after a successful `push`, `sync` or `update` (after those the two sides match). Never written in a dry run.

**Sets.** With `M` the manifest, `L` the local files and `R` the remote files (`rclone lsf -R --files-only`, with the sync flags so Google Docs are skipped like they are elsewhere):
- removed locally: files in `R` and not `L`, that are in `M`.
- removed on Drive: files in `L` and not `R`, that are in `M`.
Files in neither list follow the normal rules (new on Drive is pulled, new locally is pushed).

**Applying.** Before the pull, `sync` removes the first set from Drive with `rclone delete --files-from-raw ... --drive-use-trash` and moves the second set into `ARCHIVE_DIR/<UTC timestamp>/`. Both sets go through the existing limit: the abort threshold is `MAX_DELETE_PERCENT` of the files on that side, even with `-f`, and a terminal run asks for confirmation unless `FORCE` is set. After applying, the usual pull and push find nothing to resurrect.

**Plan.** In `plan sync`, the pull's restore list leaves out the files that would be honored, and a "Since last sync" section lists both counts. Without a manifest the section says there is none yet.

## Tests

Sets from a manifest; manifest written after success and not in a dry run, nor after `pull`; delete call and archive move; limit abort; no action without a manifest; `plan` section; a rename (old removed, new added) produces no duplicate.
