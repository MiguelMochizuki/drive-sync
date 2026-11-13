# Savings in `status`: design

## Intent

`status` shows how many PDFs are optimized but not how much space that freed. The savings figure is the product's headline (see `docs/ROADMAP.md`), so `status` should show it.

## Goals and non-goals

Goal: one `Saved` line in the `Files` section, plus a note for legacy files whose savings were never recorded.

Non-goals: `status --json`, an estimate for pending files (that is `plan`), a cumulative counter in `state.json`, and rebuilding the savings of files renamed to `.optimized.pdf` before hash tracking (the originals are gone).

## Design

Source: `state.json` `files`, which already holds `original_size` and `size` per file (schema 2). No schema change and no migration.

Counting rule: only entries whose file still exists under `DRIVE_ROOT`, the same rule the `Optimized` count uses. `saved` is the sum of `original_size - size` over entries that shrank; the percentage is `saved` over the sum of `original_size` of those same entries, so files that did not shrink do not dilute it.

Output, hash mode only:

```
  Saved: 1.00 MiB (50.0% of the PDFs it shrank)
  Not counted: 140 legacy .optimized.pdf files (savings not recorded)
```

With nothing recorded the first line reads `Saved: nothing recorded yet`. The second line appears only when legacy files exist. In suffix mode neither line appears, because savings are not known there.

## Approaches

Derive from `files` (chosen): no new state, self-healing, same rule as `Optimized`. A cumulative counter in `state.json` survives deleted files but cannot be backfilled and can drift from the files, so it was not chosen.

## Tests

In `tests/unit/status.bats`: sum and percentage from tracked entries, an entry whose file is gone is ignored, entries that did not shrink do not dilute the percentage, nothing recorded, the legacy line, and suffix mode shows neither line.
