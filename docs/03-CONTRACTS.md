# AppShell extension contracts — v1 (NORMATIVE)

This file defines the **public, language-neutral extension API**. Its JSON data is identical for Python and PowerShell, but the entry point implementation is native to each language. Schema companions: `contracts/manifest.schema.json`, `contracts/view.schema.json`. The schemas capture structural requirements; the additional semantic constraints in this document are also normative.

## 1. Identity and compatibility

- Each extension has a stable, globally unique lowercase reverse-domain `id` such as `org.example.hello`. Regex: `^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9-]*)+$`; max 140 chars; case-fold identifiers on Windows and reject duplicates.
- `version`: nonempty native package version string (Python PEP 440 metadata or PowerShell module manifest `ModuleVersion`, rendered as a string). The worker's manifest version MUST equal the version installed in the active release record.
- `api_version`: integer **1**, interpreted as the *AppShell extension contract*, unrelated to Core's wire protocol v1.
- The `manifest.id` MUST equal the registry package identity (`entry point name` in Python or `PrivateData.AppShell.Id` in PowerShell). Extension files are not accepted under an arbitrary traversal path.
- No extension needs an SDK import. AppShell passes JSON-compatible data and basic context. Extensions do not access the NativeHTMLKit host directly.

## 2. Minimum manifest

```json
{
  "api_version": 1,
  "id": "org.example.hello",
  "title": "Hello",
  "version": "0.1.0",
  "pages": [
    {"id": "overview", "title": "Overview", "order": 10}
  ],
  "commands": [
    {"id": "refresh", "title": "Refresh", "risk": "read"}
  ]
}
```

`pages[]` and `commands[]` are the **only v1 contribution types**. At least one page required. Page IDs and command IDs are extension-local slugs (`^[a-z][a-z0-9_-]*$`, up to 64 chars) and unique within their collections. `order` integer 0..9999; ties sorted by page id. Host derives the global key from extension id + local id. `risk` enum `read|write|destructive`; `write` or `destructive` commands MUST have a nonempty `confirmation` string. `description` for extension/pages and `platforms` (`linux`, `windows`) are optional informational fields, with the worker/platform runtime still determining actual compatibility.

`api_version` is the compatibility gate. Unknown **required fields**, unsupported new `api_version`, duplicate IDs, dangerous commands with no confirmation, and unknown top-level fields (strict schema) cause the extension to fail validation **without killing the shell**.

No themes, workspaces, permissions, event bus, secrets API, workflow API, background timers, service providers or UI adapter names are part of v1.

## 3. Public extension operations

All editions provide these conceptual operations; only their local-language entrypoint syntax differs:

| Operation | Input | Output | Required behavior |
|---|---|---|---|
| `manifest` | context | Manifest JSON object | Fast/local; no network, no installation, no side effects |
| `page` | local `page_id`, context | View JSON object | Read-only by convention; no blocking startup or remote work until selected |
| `action` | local `command_id`, form `values`, static `params`, context | Action result object | Only declared commands accepted; throws/returns error on failure |
| `shutdown` | context | No result / success | Best-effort cleanup, bounded by host timeout |

`ping` is an internal host operation handled by the worker wrapper, **not** an extension hook.

`context` contains only `data_dir` (absolute path to extension-owned persistent directory), `extension_id`, `app_version`. Values are strings. The host does not supply credentials, global services, native UI objects, or secrets. A future context field requires a backward-compatible contract revision.

**Python**: an entry point in group `nativehtmlkit.appshell.extensions` named after extension ID resolves to a class or factory. The resulting object exposes methods `manifest(context)`, `page(page_id, context)`, `action(command_id, values, params, context)`, optional `shutdown(context)`. Plain dicts in/out, no special base class or required imports. The internal Python worker wrapper is owned by AppShell and uses only standard library + installed plugin packages.

**PowerShell**: the native module manifest has `PrivateData.AppShell.Id = 'org.example.hello'`, and exports a single `Invoke-AppShellExtension` function with `-Operation`, `-Payload`, `-Context`. `-Payload` is a native hashtable/PSCustomObject with `page_id`, `command_id`, `values`, `params` as appropriate; `-Context` holds the same three context properties. The function returns plain dictionaries/PSCustomObjects for `manifest` and `page`, and optionally `action`. Handler MAY throw; wrapper catches and produces a bounded structured error. `shutdown` is optional. Nothing in the PowerShell module calls Python or uv.

PowerShell output rules (implemented in 0.1.0 and covered by `powershell/tests/Lifecycle.Tests.ps1`):

- The handler's result is the **one** dictionary or PSCustomObject it outputs. Other pipeline output
  (strings, numbers), `Write-Host`/`Write-Information`, warnings, verbose/debug records,
  `Write-Error` (non-terminating), `[Console]::Write*` and native command output are appended to the
  extension log, never to the result. Two dictionaries/PSCustomObjects fail the request.
- `action` and `shutdown` may output nothing; that is an empty result `{}`.
- The handler runs with PowerShell's default `$ErrorActionPreference` (`Continue`): use `throw` or
  `-ErrorAction Stop` to fail a request. `-Payload` and `-Context` arrive as PSCustomObjects
  (`$Payload.values.message`), with JSON types preserved (booleans, numbers, `$null`, arrays).
- Each request is a fresh PowerShell process of the same edition; module-scope state does not
  survive between requests. Persist state under `$Context.data_dir`.

### Action result

```json
{"message":"Refreshed successfully","refresh":true}
```

`message`: optional short user-visible string (max 500 chars); `refresh`: optional boolean, default false. AppShell re-renders the currently visible page after completion only if `refresh=true`. The host never silently retries a `write` or `destructive` action after a timeout.

A handler exception produces a host-owned structured `error` with e.g. `EXTENSION_ERROR`, `BAD_RESULT`, `TIMEOUT`, `OUTCOME_UNKNOWN`; the extension author doesn't write a transport frame directly. For read-only actions, failures are definite only if the wrapper reports a clean exception. For writes, worker death/IPC timeout after send means `OUTCOME_UNKNOWN` unless the host proves the request was not delivered.

## 4. Page/view contract

A selected page returns a UTF-8 JSON object:

```json
{
  "title": "System Overview",
  "blocks": [
    {"kind":"heading","text":"System Overview","level":2},
    {"kind":"text","text":"Read-only status"},
    {"kind":"input","name":"filter","label":"Filter","value":""},
    {"kind":"button","text":"Refresh","command":"refresh"}
  ]
}
```

Only these bounded, semantic kinds exist in v1 (all strings treated as plain text and escaped by the host):

| Kind | Properties | Meaning |
|---|---|---|
| `heading` | `text`, optional `level` 1..4 | Title/subtitle |
| `text`, `caption`, `code`, `badge` | `text` | Plain visible text; `code` is **not** executable |
| `notice` | `text`, optional `tone`: `info|success|warning|danger` | Status message |
| `divider` | none | Separator |
| `input` | `name`, `label`, optional `value`, `placeholder`, `password` boolean | String field |
| `textarea` | `name`, `label`, optional `value` | Multi-line string |
| `checkbox` | `name`, `label`, optional `checked` bool | Boolean form value |
| `select` | `name`, `label`, `options` array of `{value,label}`, optional `value` | Fixed option selection |
| `button` | `text`, `command`, optional `params` JSON object | Invoke a declared command using all current page form values |
| `table` | `columns` of `{key,title}`, `rows` of objects | Read-only bounded data table |
| `card`, `row`, `column` | `children` block array | Simple layout grouping |

No arbitrary `html`, `css`, `style`, `src`, URL-driven script, handler expression, native object, file attachment or JS. No raw image/chart block in v1. Plugins that need domain-specific advanced rendering can propose a future **trusted UI adapter**, separately reviewed; this is not part of v1.

### Validation and quotas

- Maximum serialized manifest: 128 KiB; maximum page view: 1 MiB UTF-8, maximum depth 10, maximum 300 block nodes; tables max 24 columns x 200 rows. One internal protocol frame max 1 MiB + 64 KiB envelope; larger payloads fail, not truncate.
- Table cells may be JSON null/string/number/boolean only, rendered as text; never object recursion or raw HTML. Form field names unique on a page (otherwise validation fails). Select `value` must match one option or be blank. Total form fields max 80.
- `button.command` must match a command defined in the manifest. On click AppShell looks up command risk, prompts for `write` or `destructive`, then gathers current page's native form data via public SDK; `input`/`textarea`/`select` values are strings, while `checkbox` values are normalized to explicit JSON booleans (`false` for unchecked, even though native form-data omits unchecked inputs); the extension cannot downgrade risk in the page spec.
- Host-generated unique element IDs, a page generation token and the selected extension ID prevent a stale click response from executing an action on the wrong page.
- `rows` and `children` bounded by schema; validation also checks global node count, uniqueness and references.
- `page` and `action` requests that return invalid JSON are rejected and recorded in that extension's log. The last valid page is not silently trusted as an updated result.

## 5. Confirmation policy

Risk `read`: run immediately. Risk `write`: native confirmation dialog describing the action. Risk `destructive`: explicitly labeled danger dialog showing the command title and declared confirmation, requiring a second action. A shell confirmation is an accidental-click prevention mechanism, **not a sandbox**; extension code can still modify resources during import/page/manifest if malicious or buggy.

## 6. Versioning strategy

- Freeze the JSON manifest/view v1 contract for both editions.
- Additive optional fields within v1 must be ignored only where explicitly documented; unknown fields in currently frozen v1 objects fail validation, so new surface requires an updated schema/capability profile.
- Breaking changes require `api_version: 2`. Implementations can support 1 and 2 concurrently in a future release; v0.1 only needs 1.
- The worker transport protocol is private and may evolve between AppShell releases; third-party plugin authors must depend on the public operation contract, not worker frame shapes.

## 7. Extension author acceptance

A plugin is conforming if it can be installed into a fresh edition without importing its counterpart language, yields a valid manifest/view, handles read/write commands, preserves its data directory across restarts, and fails predictably on unknown command, malformed view or unavailable remote resource. The same JSON fixtures must validate in both implementations.
