# Generated config types

This directory holds Swift config types generated from the **backend serving spec**
(`Convert API for Experiences Serving`, OpenAPI 3.0.3) plus the hand-authored
`oneOf+discriminator` LCD-sentinel decode layer.

## Regeneration command

```bash
Scripts/generate-config-types/run.sh
```

or, in CI, the `generate-config-types.yml` workflow (manual `workflow_dispatch` or on a
change to `Scripts/generate-config-types/openapi.yaml`), which regenerates and opens a PR.

The generator is **swift-openapi-generator**, pinned **exact `1.12.2`**, **types-only**
(`generate: [types]`), invoked from the **isolated** manifest at
`Scripts/generate-config-types/Package.swift`. That manifest is never referenced by the
root `Package.swift`, so `swift package resolve` at the repo root resolves zero extra
packages (NFR16 / NFR18 / AC1).

## Expected files (once unblocked)

- `ConfigSchemas.swift` — generated `Components.Schemas` config `Codable` types
  (`// auto-generated — do not edit`).
- `PolymorphicSentinels.swift` — hand-authored, lint-clean wrapper-enum + `JSONValue`
  sentinel layer making discriminator-absent / unknown-discriminator payloads decode to
  a forward-compatible sentinel that **never throws** and **re-serializes byte-identical**
  (R5 / FR60 / AR16).

## ⚠️ STATUS: BLOCKED — pending architecture decision

`swift-openapi-generator` 1.12.2 types-only output `@_spi(Generated) import OpenAPIRuntime`
and uses OpenAPIRuntime symbols, which would force a runtime dependency on `ConvertSDKCore`
and violate the SDK's zero-runtime-dependency guarantee (NFR16 / AC10 / AC7). The generated
`ConfigSchemas.swift` is therefore **not yet committed**. See
`ai-driven-product-dev/work/2026-06-11-story-1-4-openapi-typegen-sentinel/blocking-architecture-decision.md`
for the verified evidence and the ranked resolution options (recommended: vendor a bounded
Foundation-only shim + deterministic import rewrite in `run.sh`).
