#!/usr/bin/env bash
# Regenerate config types from the committed serving spec (types-only).
#
# ─────────────────────────────────────────────────────────────────────────────
# ⚠️  STORY 1.4 IS BLOCKED ON A VERIFIED ARCHITECTURE DECISION.
#     The generator (swift-openapi-generator 1.12.2) emits output that
#     `@_spi(Generated) import OpenAPIRuntime` and uses OpenAPIRuntime symbols
#     (OpenAPIValueContainer/OpenAPIObjectContainer/AcceptHeaderContentType +
#     three @_spi DecodingError extensions). Committing that file into
#     ConvertSDKCore would force a runtime dependency, violating NFR16/AC10/AC7
#     (ZERO runtime deps; clean root resolve; compiles clean).
#
#     Resolution is pending a maintainer ruling — see
#     ai-driven-product-dev/work/2026-06-11-story-1-4-openapi-typegen-sentinel/
#       blocking-architecture-decision.md  (recommended: Option D — vendor a
#       bounded Foundation-only shim + deterministic import rewrite here).
#
#     Until that ruling lands, this script ONLY produces the RAW generator
#     output into a scratch dir and does NOT copy it into Sources/.../Generated/.
#     The OUTPUT-FINALIZATION block below is the placeholder for the chosen
#     resolution (import rewrite + relocation to ConfigSchemas.swift + filter +
#     accessModifier).
# ─────────────────────────────────────────────────────────────────────────────
#
# Determinism (AC8): the generator is deterministic for a fixed spec + config +
# pinned version (exact 1.12.2). The output-finalization step, once defined, MUST
# also be deterministic (no timestamps, stable ordering) so the regenerate-and-
# diff CI gate (AC2) is byte-stable.
#
# Isolation (NFR16/NFR18/AC1): this script runs the generator via the ISOLATED
# manifest in this directory. swift-openapi-generator is NEVER referenced by the
# root Package.swift; root `swift package resolve` resolves zero extra packages
# (verified: root has no Package.resolved).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SPEC="${SCRIPT_DIR}/openapi.yaml"
CONFIG="${SCRIPT_DIR}/openapi-generator-config.yaml"
RAW_OUT="${SCRIPT_DIR}/_genout"          # scratch — git-ignored, NOT committed
# FINAL_OUT="${REPO_ROOT}/Sources/ConvertSDKCore/Generated"  # enabled after the decision

if [[ ! -f "${SPEC}" ]]; then
  echo "error: serving spec not found at ${SPEC}" >&2
  exit 1
fi

echo "Running swift-openapi-generator (types-only) over ${SPEC} ..."
rm -rf "${RAW_OUT}"
mkdir -p "${RAW_OUT}"

# Build + run the generator's CLI from the isolated manifest. Non-zero exit on
# generation failure propagates (set -e) so CI fails loudly, not silently.
swift run --package-path "${SCRIPT_DIR}" swift-openapi-generator generate \
  "${SPEC}" \
  --config "${CONFIG}" \
  --output-directory "${RAW_OUT}"

echo "Raw generator output written to ${RAW_OUT}/Types.swift"

# ── OUTPUT-FINALIZATION (BLOCKED — pending architecture decision) ────────────
# Once the maintainer rules (see blocking-architecture-decision.md), this block
# implements the chosen resolution. For the recommended Option D it will:
#   1. rewrite `@_spi(Generated) import OpenAPIRuntime` -> `import ConvertOpenAPIShim`
#      and `OpenAPIRuntime.` -> `` (or `ConvertOpenAPIShim.`) deterministically;
#   2. prepend the `// auto-generated — do not edit` + `// swiftlint:disable all` header;
#   3. relocate to ${FINAL_OUT}/ConfigSchemas.swift;
#   4. (optionally) narrow generation via `filter:` to config-reachable schemas and
#      set `accessModifier: public` in ${CONFIG}.
# It is intentionally NOT implemented yet so we never commit a file that violates
# NFR16/AC10 or that the regenerate-and-diff gate (AC2) would thrash on.
echo "OUTPUT-FINALIZATION skipped: Story 1.4 blocked on architecture decision (see blocking-architecture-decision.md)." >&2
echo "Raw types were generated successfully; not copied into Sources/ until the runtime-dependency resolution is ratified." >&2
