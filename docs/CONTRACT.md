# drive-sync contract

This document is the target for exit codes and console I/O. It is the
reference other documentation (README.md, the man page) points to.

## Exit codes

| Code | Meaning | When |
|---|---|---|
| 0 | success | |
| 1 | general or unspecified failure | defensive fallback, should rarely fire; also the deletion guard aborting a push or update (limit exceeded, plan unavailable, or the user declined), see lib/safety.sh; also plan when rclone cannot produce a plan |
| 2 | usage error | unknown command, unknown flag, or no arguments given |
| 69 (EX_UNAVAILABLE) | resource unavailable | fatal rclone error (exit 7: auth revoked or account suspended), or environment validation failure (missing dependency, remote not configured), or a required check failing in doctor |
| 75 (EX_TEMPFAIL) | temporary failure | retries exhausted after only transient or rate limit errors (rclone exit 5 or 6) |

Internal return codes passed between functions in the same process (for
example sync_to_drive returning 2 or 3 to handle_sync_result) are a
private contract and are not covered by this table. Only what main()
returns to the shell is covered above.

Bare invocation (drive-sync.sh with no arguments) is a usage error: exit
2, usage text to stderr. This differs from explicit -h/--help, which is
a successful, requested action: exit 0, full help text to stdout.

## Console I/O

Severity, not verbosity, decides which stream a line goes to. The
-v/--verbose flag only decides whether INFO and SUCCESS lines reach the
console at all. No line is duplicated across streams.

| Level | Log file | Console (default) | Console (-v) |
|---|---|---|---|
| ERROR | always | stderr | stderr |
| WARNING | always | stderr | stderr |
| INFO | always | silent | stdout |
| SUCCESS | always | silent | stdout |

status, doctor, plan, --help, and --version keep writing their intentional
output to stdout regardless of -v, since that output is the command's actual
result, not a log line. rclone's --progress bar is only enabled with -v.
The log file always receives every level, unaffected by -v.

The deletion confirmation prompt ("Continue? [y/N]") is written to stderr
and only appears when both stdin and stdout are a terminal. The guard's
error and warning lines follow the table above.

## plan

plan prints its report on stdout (text, or one JSON document with
--json) and changes nothing. With --json, -v is ignored so log lines
cannot end up inside the document. When rclone cannot produce a plan,
plan exits 1 and prints nothing on stdout.
