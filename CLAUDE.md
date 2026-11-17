# Local agent: finish and verify AppShell

You own end-to-end native verification and release qualification of the existing source repository.
Do not rewrite it from scratch. Inspect AGENTS.md, README.md, contracts and docs before edits.

1. Verify the Python edition works on KDE Wayland with the matching installed NativeHTMLKit Core,
   Python SDK 0.1.2 and UI 0.1.1. Run all unit/integration tests.
2. Verify the PowerShell edition on Linux (`pwsh` 7.2+) and Windows Server 2022 (`pwsh` 7 and
   Windows PowerShell 5.1). Use the existing Windows test VM
   and Proxmox VM rollback as necessary; do not reset a production machine.
3. Validate correct NativeHTMLKit UI initialization, delegated document events, dialog focus,
   CSS, all control types and responsive startup. Fix actual API incompatibilities using SDK
   public APIs only. Never call Rust Core internals or wire protocol directly.
4. Perform end-to-end plugin install from local source and pinned package source,
   disable/enable/remove, manual drop, bad manifest, corrupt registry, crash and timeout,
   upgrade failure and recovery. Ensure no write action is silently retried.
5. Strengthen PowerShell modules with Pester-based tests, both PS7 and PS5.1. Review process
   invocation on Windows and make all external-command arguments safe for spaces/unicode.
6. Review for path traversal, symlink attacks, resource exhaustion, failed rollback, race
   conditions, invalid UTF-8, plugin log secrets, output contamination and worker hangs.
7. Complete native accessibility, keyboard and smoke gates on live systems; record verifiable
   evidence in docs/VERIFICATION.md. Do not claim tests passed without running them.
8. Preserve the simple scope. No cross-language dependency, no web server, Node/npm,
   marketplace backend, hot reload, global plugin bus, or new UI DSL.
9. Commit fixes in isolated chunks, ensure `main` is green, publish only when requested.
   Report final status, defects and gate evidence. Do not block for routine approvals.

Output: implemented fixes, test logs/evidence, documented remaining blockers, and a concise
final release report. Spend effort on making what is here reliable, not adding features.
