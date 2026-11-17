# Architecture decision records — baseline 2026-11-17

These are the default implementation decisions. Change them only after a reproducible defect or a real extension demonstrates the need.

| ADR | Decision | Rejected alternative / rationale |
|---|---|---|
| A001 | Two standalone language-native AppShell editions | A Python server behind a PowerShell UI, or a PowerShell subprocess behind a Python-only extension host |
| A002 | One source repository; two independent build/publish pipelines | Maintaining completely duplicated docs and schemas in separate repos |
| A003 | Keep Core, SDKs, UI and CLI untouched | Generic plugin APIs inside NativeHTMLKit UI or Core |
| A004 | Fixed shell + SDK-controlled dynamic view outlet | Rebuild entire UI/window on navigation; new reactive vDOM |
| A005 | JSON manifest and view; semantic nodes only | Arbitrary plugin HTML/JS/CSS, UI objects serialized across worker boundary |
| A006 | Native wheels/pyproject entry points and PSD1/PSM1 modules | New `.appshell` custom archive/package format |
| A007 | One worker process per same-language plugin | Untrusted third-party imports in UI process; cross-language worker mediation |
| A008 | Restart-only extension activation | Hot reload or live installation/upgrading into running process |
| A009 | App-owned immutable release snapshots | Overwriting loaded modules and losing previous working package |
| A010 | Per-extension code rollback, persistent data unchanged | Promising to undo remote operations, migrations and credential changes |
| A011 | Keep v0.1 API to page/action | Built-in event bus and general capability broker before first real case |
| A012 | Human-selected native sources; optional static catalog later | Central marketplace accounts, servers, auto-updates |
| A013 | No extension SDK package dependency | Recreating Octopus SDK name-conflict and user package burden |
| A014 | UI shell does not require network connections at boot | Mandatory remote system scan or background server |
| A015 | Risk confirmation for write/destructive; no automatic retry | Security theater claiming a full plugin sandbox or safe automatic destructive retries |
| A016 | Explicit absolute PS module file path; no global module install | Modifying user machine-wide PSModulePath and silently selecting latest module |
| A017 | Same public contract/fixtures, not identical internal code | Sharing executable Python parser, installer or runtime with PowerShell edition |
| A018 | Test Linux + Windows versions actually shipped | General claims of macOS parity or of full accessibility without evidence |

## Decision deferred deliberately

- **Services:** should extensions call each other via an AppShell broker? A tested future contract may add provider IDs, caller identity and bounded request/deadlock handling **only for same-language host**.
- **Live charts:** first real dashboard may demonstrate whether the JSON block contract needs an image/data chart contribution or a trusted view adapter. Do not invent it now.
- **Read-only periodic refresh:** first real monitoring extension may need visible-page polling. Add only measured rate-limited feature if explicit Refresh is insufficient.
- **Package verification/signing:** v0.1 uses explicit operator source trust and hashes; optional source signing/provenance is future security engineering.
- **Huge plugin count / lazy activation:** measure startup and memory after real multi-plugin packs; don't pre-design a scheduler.
