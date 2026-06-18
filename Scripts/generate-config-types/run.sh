#!/usr/bin/env bash
# Regenerate the config Codable types from the committed serving spec (types-only)
# and produce the FINAL, committed Sources/ConvertSDKCore/Generated/ConfigSchemas.swift
# via the ratified Option-D rewrite.
#
# CROSS-REPO CONSUMER (keep this interface stable): besides local + in-repo CI use,
# the backend serving pipeline (convertcom/backend, the `create-iOS-serving-PR` job
# in .github/workflows/update-ts-api-serving.yml) invokes this script on macos-26 to
# regenerate these types from the CANONICAL serving spec. That job depends on (1) the
# `PYTHON` env-var seam below and (2) the output paths
# Sources/ConvertSDKCore/Generated/{ConfigSchemas.swift,discriminator-manifest.json}.
# Changing either requires updating that backend job in lockstep.
#
# ─────────────────────────────────────────────────────────────────────────────
# OPTION D (maintainer-ratified): zero third-party runtime dependency (NFR16).
#
#   swift-openapi-generator 1.12.2 types-only output `@_spi(Generated) import
#   OpenAPIRuntime` and references a small bounded set of its symbols
#   (after filtering to the config schemas: OpenAPIValueContainer ×47,
#   OpenAPIObjectContainer ×4, and the DecodingError extension methods
#   unknownOneOfDiscriminator/verifyAtLeastOneSchemaIsNotNil). The Convert iOS
#   SDK forbids linking OpenAPIRuntime, so this script:
#     1. narrows generation via `filter:` (config schemas only) and
#        `accessModifier: public` in openapi-generator-config.yaml; and
#     2. deterministically rewrites the generated Types.swift so every
#        OpenAPIRuntime symbol resolves to the in-repo, Foundation-only vendored
#        shim Sources/ConvertSDKCore/Generated/OpenAPIRuntimeShim.swift, which
#        declares those symbols at MODULE scope (same module: ConvertSDKCore).
#        The rewrite deletes the `@_spi(Generated) import OpenAPIRuntime` line
#        and strips every `OpenAPIRuntime.` qualifier; the now-unqualified
#        symbols bind to the same-module shim. The result is written to
#        ConfigSchemas.swift, prefixed with an `// auto-generated — do not edit`
#        + `// swiftlint:disable all` header.
#
#   Discriminator manifest (AR16): the script also derives, FROM THE SPEC's
#   `discriminator:` blocks (never hand-listed), the set of config-reachable
#   oneOf+discriminator schemas — their discriminator property name (both the
#   JSON wire name and the swift-openapi-generator-escaped Swift name) and the
#   mapping values — into discriminator-manifest.json. The hand-authored
#   LCD-sentinel decode layer (PolymorphicSentinels.swift) consults it.
# ─────────────────────────────────────────────────────────────────────────────
#
# Determinism (AC2/AC8): the generator is deterministic for a fixed spec +
# config + pinned version (exact 1.12.2). The finalization step below is ALSO
# deterministic — pure stdlib transforms, stable sort ordering, no timestamps,
# no `date`, no random temp names in any output content — so the
# regenerate-and-diff CI gate is byte-stable across runs.
#
# Isolation (NFR16/NFR18/AC1): this script runs the generator via the ISOLATED
# manifest in this directory. swift-openapi-generator is NEVER referenced by the
# root Package.swift; root `swift package resolve` resolves zero extra packages.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SPEC="${SCRIPT_DIR}/openapi.yaml"
CONFIG="${SCRIPT_DIR}/openapi-generator-config.yaml"
RAW_OUT="${SCRIPT_DIR}/_genout"          # scratch — git-ignored, NOT committed
FINAL_DIR="${REPO_ROOT}/Sources/ConvertSDKCore/Generated"
FINAL_SWIFT="${FINAL_DIR}/ConfigSchemas.swift"
MANIFEST="${FINAL_DIR}/discriminator-manifest.json"

if [[ ! -f "${SPEC}" ]]; then
  echo "error: serving spec not found at ${SPEC}" >&2
  exit 1
fi
if [[ ! -d "${FINAL_DIR}" ]]; then
  echo "error: target directory not found: ${FINAL_DIR}" >&2
  exit 1
fi

# Pick a python3 interpreter (PyYAML required for the spec-derived manifest).
PYTHON="${PYTHON:-python3}"
if ! command -v "${PYTHON}" >/dev/null 2>&1; then
  echo "error: python3 not found on PATH (set PYTHON=/path/to/python3)" >&2
  exit 1
fi

echo "Running swift-openapi-generator (filtered, types-only, public) over ${SPEC} ..."
rm -rf "${RAW_OUT}"
mkdir -p "${RAW_OUT}"

# Build + run the generator's CLI from the isolated manifest. Non-zero exit on
# generation failure propagates (set -e) so CI fails loudly, not silently.
swift run --package-path "${SCRIPT_DIR}" swift-openapi-generator generate \
  "${SPEC}" \
  --config "${CONFIG}" \
  --output-directory "${RAW_OUT}"

RAW_SWIFT="${RAW_OUT}/Types.swift"
if [[ ! -f "${RAW_SWIFT}" ]]; then
  echo "error: generator did not produce ${RAW_SWIFT}" >&2
  exit 1
fi
echo "Raw generator output written to ${RAW_SWIFT}"

# ── 1. Discriminator manifest (AR16) — DERIVED from the spec, never hand-listed ──
# Computes the transitive $ref closure from the three config root schemas, then
# emits every oneOf+discriminator schema whose owning schema falls inside that
# closure: its JSON wire property name, the swift-openapi-generator-escaped Swift
# property name (Swift keywords are prefixed with `_`, e.g. `type` -> `_type`),
# and the sorted discriminator mapping values. Output is stable-sorted JSON so
# the regenerate-and-diff gate is byte-identical across runs.
echo "Deriving discriminator manifest from ${SPEC} ..."
SPEC_PATH="${SPEC}" MANIFEST_PATH="${MANIFEST}" RAW_SWIFT_PATH="${RAW_SWIFT}" "${PYTHON}" - <<'PYEOF'
import json
import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("error: PyYAML is required to derive the discriminator manifest "
                     "(pip install pyyaml, or set PYTHON to an interpreter that has it)\n")
    sys.exit(1)

spec_path = os.environ["SPEC_PATH"]
manifest_path = os.environ["MANIFEST_PATH"]

with open(spec_path, "r", encoding="utf-8") as fh:
    spec = yaml.safe_load(fh)

schemas = (spec.get("components") or {}).get("schemas") or {}
roots = ["ConfigResponseData", "ConfigMinimalResponseData", "ConfigOptionalResponseData"]
for root in roots:
    if root not in schemas:
        sys.stderr.write("error: expected config root schema '%s' not found in spec\n" % root)
        sys.exit(1)

ref_re = re.compile(r"#/components/schemas/(.+)$")


def refs_in(node):
    """All component-schema names referenced anywhere under node."""
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$ref" and isinstance(value, str):
                match = ref_re.match(value.strip())
                if match:
                    found.append(match.group(1))
            else:
                found.extend(refs_in(value))
    elif isinstance(node, list):
        for item in node:
            found.extend(refs_in(item))
    return found


# Transitive $ref closure from the config roots.
reachable = set()
stack = list(roots)
while stack:
    name = stack.pop()
    if name in reachable:
        continue
    reachable.add(name)
    node = schemas.get(name)
    if node is None:
        sys.stderr.write("warning: referenced schema not found: %s\n" % name)
        continue
    for ref in refs_in(node):
        if ref not in reachable:
            stack.append(ref)


def discriminators_in(node):
    """Every `discriminator` block (with a propertyName) under node."""
    found = []

    def walk(inner):
        if isinstance(inner, dict):
            disc = inner.get("discriminator")
            if isinstance(disc, dict) and "propertyName" in disc:
                found.append(disc)
            for value in inner.values():
                walk(value)
        elif isinstance(inner, list):
            for item in inner:
                walk(item)

    walk(node)
    return found


# Map each JSON wire property name to the Swift identifier the generator actually
# emits, derived from the GENERATED CodingKeys (ground truth — never a hand-kept
# keyword list, which drifts from the generator's own escaping rules). The
# generator escapes identifiers that collide with Swift keywords or reserved
# member names by prefixing `_` (e.g. `type` -> `_type`); identifiers it does not
# escape appear verbatim (`rule_type`, `detection_type`). CodingKey declarations
# take exactly two forms:
#   case _type = "type"   (escaped/renamed: swift name, then `= "<wire>"`)
#   case rule_type        (identity: swift name == wire name)
raw_swift_path = os.environ["RAW_SWIFT_PATH"]
with open(raw_swift_path, "r", encoding="utf-8") as fh:
    generated_swift = fh.read()

renamed_re = re.compile(r"^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\"([^\"]+)\"\s*$",
                        re.MULTILINE)
identity_re = re.compile(r"^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\s*$", re.MULTILINE)

wire_to_swift = {}
for swift_id, wire in renamed_re.findall(generated_swift):
    wire_to_swift.setdefault(wire, swift_id)
for swift_id in identity_re.findall(generated_swift):
    # Identity CodingKey: wire name == swift identifier. Do not let it clobber an
    # already-recorded renamed mapping for the same wire name.
    wire_to_swift.setdefault(swift_id, swift_id)


def swift_property_name(wire_name):
    swift_id = wire_to_swift.get(wire_name)
    if swift_id is None:
        sys.stderr.write("error: wire discriminator property '%s' has no CodingKey in the "
                         "generated output; cannot determine its Swift identifier\n" % wire_name)
        sys.exit(1)
    return swift_id


entries = []
for name in sorted(reachable):
    node = schemas.get(name)
    if node is None:
        continue
    for disc in discriminators_in(node):
        wire = disc["propertyName"]
        mapping = disc.get("mapping") or {}
        bad = []
        for key, target in mapping.items():
            match = ref_re.match(str(target).strip())
            if match is None or match.group(1) not in schemas:
                bad.append({"value": key, "target": target})
        if bad:
            sys.stderr.write("error: schema '%s' has discriminator mapping targets that do not "
                             "resolve: %s\n" % (name, bad))
            sys.exit(1)
        entries.append({
            "schema": name,
            "wire_property_name": wire,
            "swift_property_name": swift_property_name(wire),
            "discriminator_values": sorted(mapping.keys()),
        })

# Stable ordering: by schema name, then wire property name.
entries.sort(key=lambda item: (item["schema"], item["wire_property_name"]))

manifest = {
    "_comment": ("Config-reachable oneOf+discriminator schemas, DERIVED from the serving "
                 "spec's discriminator blocks via the transitive $ref closure of the config "
                 "root schemas. Do not hand-edit; regenerate via "
                 "Scripts/generate-config-types/run.sh. Consumed by the LCD-sentinel decode "
                 "layer (PolymorphicSentinels.swift)."),
    "config_root_schemas": sorted(roots),
    "distinct_wire_property_names": sorted({e["wire_property_name"] for e in entries}),
    "distinct_swift_property_names": sorted({e["swift_property_name"] for e in entries}),
    "schemas": entries,
}

with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=True, ensure_ascii=False)
    fh.write("\n")

sys.stderr.write("Discriminator manifest written: %d config-reachable discriminator "
                 "schema(s); property names %s\n"
                 % (len(entries), sorted({e["swift_property_name"] for e in entries})))
PYEOF

# ── 2. Deterministic Swift rewrite: _genout/Types.swift -> ConfigSchemas.swift ──
# Pure stdlib, single pass, no timestamps / no temp-name leakage into content:
#   - prepend the 2-line `// auto-generated — do not edit` + `// swiftlint:disable all`
#     header BEFORE the generator's first line;
#   - delete the single line `@_spi(Generated) import OpenAPIRuntime` (the shim is
#     same-module, so no import is needed);
#   - strip every `OpenAPIRuntime.` qualifier so each reference binds to the
#     module-scope vendored shim symbol (the `// Generated by swift-openapi-generator`
#     comment is untouched — it contains no `OpenAPIRuntime.` substring);
#   - remove every standalone `@available(*, deprecated)` annotation line (see below).
#
# WHY strip `@available(*, deprecated)` (AC7 zero-warnings):
#   swift-openapi-generator emits `@available(*, deprecated)` on 5 config WIRE
#   properties whose backend spec marks `deprecated: true` (ConfigExperience
#   `environments`; ConfigExperience/settings `min_order_value` + `max_order_value`;
#   ConfigProject/settings/value1 `min_order_value` + `max_order_value`). The
#   generator's OWN synthesized memberwise `init`s then assign each of those
#   properties (`self.min_order_value = min_order_value`), producing an in-module
#   self-reference to a deprecated declaration → 5 `[#DeprecatedDeclaration]`
#   warnings. This is upstream swift-openapi-generator issue #715, which is OPEN
#   and WONTFIX (the generator does not suppress its own deprecation warnings in
#   its generated initializers).
#
#   The upstream-recommended remedy is SE-0443 per-diagnostic-group suppression
#   (`-Wno DeprecatedDeclaration` at the target level). That flag does NOT exist
#   in the local toolchain (Apple Swift 6.2.3): `swiftc` rejects `-Wno` and offers
#   only `-suppress-warnings` (ALL warnings — too broad; it would also mask any
#   real warnings in OpenAPIRuntimeShim.swift / PolymorphicSentinels.swift and
#   defeat AC7's intent) plus escalation-only flags (`-warn-*`, `-no-warnings-as-
#   errors`). No per-group suppress is available, so the target-level path is out.
#
#   These are CDN-decoded wire types: the `deprecated: true` reflects a BACKEND
#   field deprecation the SDK consumer cannot act on — consumers receive decoded
#   config, they never CONSTRUCT `ConfigExperience.settingsPayload`. Stripping the
#   annotation removes no consumer-actionable signal. The strip is surgical: it
#   removes ONLY lines whose trimmed content is exactly `@available(*, deprecated)`
#   (there are no other `@available(...)` variants in this output, and the match
#   is exact so e.g. `@available(macOS ...)` would be left untouched if one ever
#   appeared). The adjacent `/// - Remark: Generated from #/...` provenance
#   doc-comments and the property declarations are preserved verbatim.
echo "Rewriting ${RAW_SWIFT} -> ${FINAL_SWIFT} (Option-D import rewrite) ..."
RAW_SWIFT_PATH="${RAW_SWIFT}" FINAL_SWIFT_PATH="${FINAL_SWIFT}" "${PYTHON}" - <<'PYEOF'
import os
import sys

raw_path = os.environ["RAW_SWIFT_PATH"]
final_path = os.environ["FINAL_SWIFT_PATH"]

HEADER = "// auto-generated — do not edit\n// swiftlint:disable all\n"
IMPORT_LINE = "@_spi(Generated) import OpenAPIRuntime"
QUALIFIER = "OpenAPIRuntime."
# Standalone deprecation annotation the generator emits on 5 config WIRE
# properties (upstream issue #715; see the WHY block above run.sh's section 2).
# Matched on EXACT trimmed content so only this annotation is removed — any other
# `@available(...)` variant (e.g. `@available(macOS ...)`) would NOT match.
AVAILABLE_DEPRECATED = "@available(*, deprecated)"

with open(raw_path, "r", encoding="utf-8") as fh:
    lines = fh.readlines()

out = []
removed_import = 0
removed_deprecated = 0
for line in lines:
    stripped = line.strip()
    # Delete exactly the generated OpenAPIRuntime import line (match on the
    # stripped content so a stray trailing newline/whitespace difference can't
    # smuggle the import through).
    if stripped == IMPORT_LINE:
        removed_import += 1
        continue
    # Drop standalone `@available(*, deprecated)` lines (exact trimmed match):
    # the generator's own synthesized memberwise inits assign these WIRE
    # properties, an in-module self-reference that would emit
    # `[#DeprecatedDeclaration]` warnings (AC7). The adjacent provenance
    # doc-comment and the property declaration on the following line are kept.
    if stripped == AVAILABLE_DEPRECATED:
        removed_deprecated += 1
        continue
    # Strip the module qualifier; same-module shim resolves the bare symbol.
    out.append(line.replace(QUALIFIER, ""))

if removed_import != 1:
    sys.stderr.write("error: expected exactly 1 `%s` line in generated output, found %d\n"
                     % (IMPORT_LINE, removed_import))
    sys.exit(1)

text = HEADER + "".join(out)

if QUALIFIER in text:
    sys.stderr.write("error: residual `%s` qualifier(s) remain after rewrite\n" % QUALIFIER)
    sys.exit(1)
if "OpenAPIRuntime" in text:
    sys.stderr.write("error: residual `OpenAPIRuntime` token(s) remain after rewrite\n")
    sys.exit(1)
# AC7 guard: no standalone deprecation annotations may survive the rewrite, else
# the cold build re-emits the upstream-#715 `[#DeprecatedDeclaration]` warnings.
for out_line in text.splitlines():
    if out_line.strip() == AVAILABLE_DEPRECATED:
        sys.stderr.write("error: residual `%s` line(s) remain after rewrite\n"
                         % AVAILABLE_DEPRECATED)
        sys.exit(1)

sys.stderr.write("Rewrite: removed %d OpenAPIRuntime import line, %d standalone "
                 "`%s` annotation(s)\n"
                 % (removed_import, removed_deprecated, AVAILABLE_DEPRECATED))

with open(final_path, "w", encoding="utf-8") as fh:
    fh.write(text)
PYEOF

# ── 3. Post-rewrite verification (AC: zero OpenAPIRuntime references) ──
RUNTIME_REFS="$(grep -c "OpenAPIRuntime" "${FINAL_SWIFT}" || true)"
if [[ "${RUNTIME_REFS}" -ne 0 ]]; then
  echo "error: ${FINAL_SWIFT} still contains ${RUNTIME_REFS} OpenAPIRuntime reference(s)" >&2
  exit 1
fi

echo ""
echo "OK: wrote ${FINAL_SWIFT}"
echo "    lines: $(wc -l < "${FINAL_SWIFT}" | tr -d ' ')   OpenAPIRuntime refs: ${RUNTIME_REFS}"
echo "OK: wrote ${MANIFEST}"
echo "    config discriminator schemas: $("${PYTHON}" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["schemas"]))' "${MANIFEST}")"
