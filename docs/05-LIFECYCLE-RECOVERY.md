# Lifecycle, failure handling and rollback contract

## States

Registry records: `discovered`, `pending`, `enabled`, `disabled`, `failed`, `active_version`, `candidate_version`, `source`, and `last_error`. These may be represented as separate fields rather than a single complicated state machine. UI status is derived from these fields. Managed versions are immutable and identified by `version + content hash`, not just human-readable version.

| Event | Result | Restart? |
|---|---|---|
| Empty shell first launch | Extensions page and Settings work without plugin | No |
| Add/drop package | Stage candidate; active release unchanged | **Yes** |
| Enable/disable | Save changed flag; current worker remains as-is | **Yes** |
| Update extension | Prepare candidate beside old | **Yes** |
| Startup healthy | Activate selected candidate in registry, maintain previous working bits | No further restart |
| Candidate worker import or manifest fails | Start previous working release if present; otherwise disable that extension, show error | No (fallback can occur during same startup) |
| Worker crashes during active session | Mark extension failed, remove/disable its actions, show logs | Recovery on **next** restart |
| Uninstall | Mark for removal, leave persistent data | **Yes** |
| Delete data | Separate explicit destructive confirmation; do not delete executable data during crash recovery | After stopping extension |

## Startup algorithm

1. SDK host/backend handshake first. Initialize owned AppShell state only inside real backend, never SDK launcher pre-reexec phase.
2. Acquire per-edition single-instance lock; load state with bounded decode and schema validation. A broken registry triggers shell recovery view and safe mode; do not overwrite or silently reset it.
3. If a previous `startup.json` marker says a candidate activation was interrupted, mark candidate suspicious and boot the last-known-good set. Do not assume a kill/reboot necessarily identifies a guilty plugin; display an explanation and logs.
4. If `--safe-mode` is set, load NO extensions; show shell recovery page. Without safe mode, prepare newly discovered drop-ins and pending versions, validating package shape and dependency requirements; never mutate active release in place.
5. For enabled entries, select candidate if present, else pinned active version. Launch each same-language worker and request manifest under deadline. Invalid import, duplicate id, incompatible API or other failure → mark candidate failed, attempt previously working worker **once**, else mark extension disabled/failed.
6. Assemble deterministic sidebar from valid manifests. UI/registry is available even when every extension fails. Candidate status is accepted only after successful wrapper start/handshake + contract-valid manifest + shell rendered successfully. This is a **boot-level** health check, not an external service health guarantee.
7. Atomically write new active version map to registry and refresh `last-good.json`, only for fully accepted candidates. Preserve the old executable release for at least one successful subsequent start. Clear startup marker after the shell is usable.
8. If the outer backend crashes before clearing startup marker, next invocation starts in last-good mode and offers safe-mode diagnostics; no automatic endless restart attempts.

All registry/state writes use a temporary file, flush/fsync where available, and atomic same-volume replace. A scoped file/process lock stops two running AppShell instances from modifying the same edition state. Never claim atomicity for arbitrary multi-file extension data.

## Error behavior

- `INVALID_MANIFEST`, `UNSUPPORTED_API`, `BAD_VIEW`, `UNKNOWN_COMMAND`, `INSTALL_FAILED`, `STARTUP_FAILED`, `WORKER_EXITED`, `TIMEOUT`, `OUTCOME_UNKNOWN`, `REGISTRY_CORRUPT`, `DUPLICATE_ID`, `MISSING_RUNTIME` are stable user-facing error categories.
- Logs record timestamp, extension ID, version, operation and a redacted exception summary; UI can show `Open log` and `Retry at next restart`.
- Unexpected Python/PS exception should be per-extension error, not blank shell.
- On `page` failure, display retryable error page; keep sidebar and other extensions working.
- On `action` failure, show a persistent status message; do not assume remote resource was unchanged on timeout.
- If a write/destructive request was actually sent but its worker dies/times out, return **outcome unknown**; user must verify real target state manually before retry.
- Worker shutdown is bounded; a task that cannot stop is terminated. This may interrupt external work, so extensions must design their own safe remote-operation semantics.

## What last-known-good DOES / DOES NOT mean

**Does:** restores the previously selected executable package release, last working activation flags and app's own registry; preserves enough logs to diagnose fault; prevents one bad updated plugin from killing the whole shell.

**Does not:** rollback database schema migrations, files written under the extension data directory, changes to Docker/Proxmox/Windows/other remote systems, secrets, third-party installation scripts, or a plugin that appears healthy at startup but later misbehaves. Domain data migrations must be backward compatible or handled by the extension, never silently reverted by AppShell.

## Recovery UX

When a candidate fails, show e.g. `Proxmox Manager 0.3 failed: previous 0.2 active` and actions `View log`, `Keep previous`, `Disable on restart`, `Retry update on restart`. If no previous exists, `Failed / Disabled`. If the registry itself is broken, offer **Safe mode**, `Export diagnostic bundle`, and explicit **Backup and reset registry** without deleting extension source/data.

## Single-language and platform health

- PowerShell host uses its native module worker, with its existing 5.1 or 7 process. No fallback to Python.
- Python host uses the venv Python interpreter, no fallback to PowerShell.
- Tests must inject a native worker crash and prove the shell remains responsive. A Python `SystemExit` or PowerShell `exit` inside extension must terminate only the worker, not the AppShell backend.
