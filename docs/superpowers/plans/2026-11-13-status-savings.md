# Savings in `status`: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `status` prints the space freed by compression and the count of legacy files that cannot be measured.

**Architecture:** A new `list_tracked_savings` in `lib/state.sh` emits `path, original_size, size` per tracked file. `show_status` in `lib/cli.sh` sums it for files that still exist and prints the lines.

**Tech Stack:** Bash, jq, bats-core.

**Spec:** `docs/superpowers/specs/2026-11-13-status-savings-design.md`

## Global Constraints

- Plain text, no emoji, arrows or dashes. Status uses colors only, never bold, and stays ASCII.
- Every new function has the `CONTRIBUTING.md` comment block. No existing test is edited. Baseline is 249 passing; command is `bats -r tests`.
- Hash mode only; no state change.

## Review Focus

- A tracked entry whose file is gone must not add to the total.
- Entries with `size` equal to `original_size` (small files) must not dilute the percentage.
- No tracked entries and no legacy files: the `Not counted` line is absent and the first line says nothing is recorded.
- `original_size` of zero must not divide by zero.

---

### Task 1: The Saved lines

**Files:**
- Modify: `lib/state.sh` (add `list_tracked_savings`), `lib/cli.sh` (`show_status`), `README.md` (status example)
- Test: `tests/unit/status.bats` (append)

**Interfaces:**
- Produces: `list_tracked_savings state_file` prints `path<TAB>original_size<TAB>size` per `files` entry, returns 0.
- Consumes: `list_tracked_files`-style `jq` over `state.json`, `format_size`.

- [ ] **Step 1: Write the failing tests** appended to `tests/unit/status.bats`, using `record_file_state` and fixtures as the existing hash tests do:
  - `Saved sums original minus size for tracked files that exist`: two entries (4000 to 2000, 6000 to 3000), both files present: output contains `Saved: 4.88 KiB (50.0% of the PDFs it shrank)`.
  - `a tracked entry whose file is gone does not add to Saved`.
  - `files that did not shrink do not dilute the percentage`: add an entry with equal sizes, percentage unchanged.
  - `Saved says nothing recorded yet without entries`.
  - `Not counted names the legacy files`: one `old.optimized.pdf` gives `Not counted: 1 legacy .optimized.pdf file (savings not recorded)`; none gives no such line.
  - `suffix mode shows neither line` (`TRACKING_MODE=suffix` exported before sourcing config, per CLAUDE.md, in a separate `@test` that re-sources, or by calling in a subshell with the variable set).
- [ ] **Step 2: Run to verify they fail:** `bats tests/unit/status.bats`.
- [ ] **Step 3: Implement** `list_tracked_savings` and the lines in the `Files` section, after `Size`. Zero original sizes give `nothing recorded yet`.
- [ ] **Step 4: Verify:** `bats tests/unit/status.bats`, then `bats -r tests` (all green), then `./drive-sync.sh status` against the real state: expect `Saved: nothing recorded yet` and `Not counted: 140 legacy ...`.
- [ ] **Step 5: Update the README status example, and commit and open the PR:**

```bash
git add lib/state.sh lib/cli.sh README.md tests/unit/status.bats docs/superpowers
git commit -m "feat: show the space saved in status"
```
