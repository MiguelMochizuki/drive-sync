# Contributing

Run the test suite with `make test` (requires `bats-core` >= 1.5.0, `jq` and `flock`).

## Documentation Conventions

### Bash

Every `.sh` file starts with a header, right after the shebang. Every function gets a
comment block directly above it: a short description, then `Parameters:` and `Returns:`.
Omit `Parameters:` for functions without arguments. Trivial one-line helpers may use a
single-line comment.

File header:

```bash
#!/usr/bin/env bash
#
# state.sh: persistent state with file locking.
#
# Manages drive_sync state stored as JSON. Uses flock for concurrent run
# safety.
```

Function:

```bash
# Download remote_name to local_path with rclone copy: adds and updates
# files locally, but never deletes local files absent from the remote.
#
# Parameters:
#   log_file: path to the active log file
#   local_path: directory to download into
#   remote_name: the configured rclone remote
#   dry_run: "true" to preview without transferring, default "false"
#
# Returns: 0 on success; 2 on a temporary/rate-limit error; 3 on a
#   fatal error; 1 on any other nonzero exit.
sync_from_drive() {
```
