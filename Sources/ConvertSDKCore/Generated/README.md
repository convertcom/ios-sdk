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
Trigger it manually with `gh workflow run generate-config-types.yml`.

The generator is **swift-openapi-generator**, pinned **exact `1.12.2`**, **types-only**
(`generate: [types]`), invoked from the **isolated** manifest at
`Scripts/generate-config-types/Package.swift`. That manifest is never referenced by the
root `Package.swift`, so `swift package resolve` at the repo root resolves zero extra
packages (NFR16 / NFR18 / AC1).

## Files in this directory

- `ConfigSchemas.swift` — generated `Components.Schemas` config `Codable` types
  (`// auto-generated — do not edit`, `// swiftlint:disable all`). Produced by `run.sh`:
  the raw generator output has its `@_spi(Generated) import OpenAPIRuntime` line removed and
  every `OpenAPIRuntime.` qualifier stripped, so the freeform-container references resolve to
  the in-repo vendored shim in the **same module** (see `OpenAPIRuntimeShim.swift`).
- `OpenAPIRuntimeShim.swift` — a **vendored**, bounded, Foundation-only subset of
  `swift-openapi-runtime` (tag 1.8.2, Apache-2.0): only the surface the generated config code
  uses (`OpenAPIValueContainer`, `OpenAPIObjectContainer`, and the `DecodingError`
  `oneOf`-decoding extension methods). Vendoring honors NFR16 (**zero** third-party runtime
  dependencies) and mirrors the project's vendored-MurmurHash3 pattern. Root
  `swift package resolve` stays zero-packages.
- `PolymorphicSentinels.swift` — hand-authored, lint-clean wrapper-enum + `JSONValue`
  sentinel layer making discriminator-absent / unknown-discriminator payloads decode to
  a forward-compatible sentinel that **never throws** and **re-serializes byte-identical**
  (R5 / FR60 / AR16). Its schema list is derived from `discriminator-manifest.json`.
- `discriminator-manifest.json` — the config-reachable `oneOf+discriminator` schemas
  **derived from the serving spec** by `run.sh` (transitive `$ref` closure of the config root
  schemas; AR16 — never hand-listed). Consumed by `PolymorphicSentinels.swift`.

## Architecture note — vendored OpenAPIRuntime shim (maintainer ruling 2026-06-11, Option D)

`swift-openapi-generator` 1.12.2 types-only output emits `@_spi(Generated) import OpenAPIRuntime`
and uses OpenAPIRuntime symbols, which would force a third-party runtime dependency on
`ConvertSDKCore` and violate the SDK's zero-runtime-dependency guarantee (NFR16 / AC10 / AC7).
The resolution: a `filter:` narrows generation to config-reachable schemas (dropping the
Operations types and `AcceptHeaderContentType`), `run.sh` deterministically rewrites the
remaining `OpenAPIRuntime.` references to the vendored `OpenAPIRuntimeShim.swift`, and the
regenerate-and-diff CI gate (AC2) compares `run.sh`-output to `run.sh`-output. See
`ai-driven-product-dev/work/2026-06-11-story-1-4-openapi-typegen-sentinel/blocking-architecture-decision.md`.
