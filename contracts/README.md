# Machine-readable contracts

- `manifest.schema.json`: extension's native-language `manifest` result.
- `view.schema.json`: extension's native-language `page` result.
- Schemas use JSON Schema 2020-12 for structural shape only. Both implementations must ALSO enforce global node/depth counts, duplicate page/command/field IDs, cross-reference `button.command`, select default membership, native package/manifest identity, max UTF-8 frame size and JSON-only transport.
- `fixtures/valid/` must pass schema and semantic validation.
- `fixtures/invalid/*.semantic.json` pass structural schema but MUST fail the **semantic** validation layer (duplicate ID, unknown command). Other invalid fixtures must fail structural schema.
- Both implementations must provide separate test runners (Python native unit tests and PowerShell Pester). This repo's schema JSON is **data**, not a runtime dependency on any particular programming language.
