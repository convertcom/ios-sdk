#!/usr/bin/env python3
"""Documentation-coverage gate for the Convert iOS SDK (Story 6.1 / AC2).

Reads the Swift symbol-graph JSON emitted by
`swift build --target ConvertSDK -Xswiftc -emit-symbol-graph ...` and enforces:

  * EVERY in-scope `public` symbol carries a source `///` doc comment.

Exits 1 (build FAILURE) listing every undocumented public symbol; exits 0 with a
one-line PASS summary when the whole public surface is documented. This is the
gate logic; the CI YAML invokes it after the DocC catalog build (Part A proves
the catalog compiles; this script — Part B — enforces coverage).

WHY THE SYMBOL GRAPH AND NOT docc's hasAbstract (the trap that drives this design)
----------------------------------------------------------------------------------
`docc convert --experimental-documentation-coverage` reports `hasAbstract:false`
for ~12 PROTOCOL-REQUIREMENT WITNESSES even when they carry a source `///`:

  * Codable witnesses — `init(from:)` / `encode(to:)`
  * Identifiable — `Variation.id`
  * LocalizedError — `ConvertError.errorDescription`

Proven against this repo: `Variation.id` has `/// Stable identifier of the
variation.` in source, yet docc reports hasAbstract=false — while its sibling
`Variation.key` (also documented) reports true. A naive `hasAbstract == false`
gate would FALSELY FAIL the build on these witnesses.

The SYMBOL GRAPH's `docComment` field does NOT have this blind spot: it records
the `///` for ALL of these witnesses (verified: `Variation.id`'s symbol-graph
entry contains its docComment). So the symbol-graph `docComment` is the source of
truth for "does this symbol carry a doc comment", and this gate reads that.

Story 6.1 enforces doc COVERAGE (a public symbol must have an abstract / doc
comment), NOT link resolution. The Part-A catalog build in CI deliberately omits
`--warnings-as-errors` because there are ~41 PRE-EXISTING broken backtick-symbol
links in INTERNAL-type source `///` comments (DecisionStore / ExperienceManager /
EventQueue / ConfigStore / ...) that are out of this story's scope; promoting
them to errors would falsely redden CI. This gate is concerned only with
PRESENCE of a doc comment, never with link validity.

THE IN-SCOPE FILTER (conductor-verified to return EXACTLY 0 on the current surface)
----------------------------------------------------------------------------------
A symbol is IN SCOPE iff ALL of:

  1. `accessLevel == "public"`              — only the public surface is gated.
  2. `location.uri` contains `/Sources/`    — excludes compiler-synthesized
                                              stdlib witnesses (assertIsolated /
                                              assumeIsolated / synthesized
                                              Hashable members) whose `location`
                                              is null — they are not OUR source.
  3. `location.uri` does NOT contain `/Generated/`
                                            — excludes the generated OpenAPI
                                              codegen under
                                              Sources/ConvertSDKCore/Generated/,
                                              which is not hand-authored API and
                                              is out of the documented surface.

DEDUPLICATION
-------------
The same public symbol appears in BOTH the `ConvertSDK` and `ConvertSDKCore`
symbol graphs because `@_exported import ConvertSDKCore` re-homes core types into
the product module. We deduplicate by `identifier.precise` (the USR) so each
symbol is judged once. (The gate reads ALL `*.symbols.json` files in the dir.)

UNDOCUMENTED DEFINITION
-----------------------
A symbol is UNDOCUMENTED iff its symbol-graph `docComment` is null or absent
(the key is simply omitted when there is no `///`). A present `docComment` is a
dict with a `lines` array; its mere presence is sufficient for this gate.

Stdlib only (argparse, glob, json, os, sys). Python 3.9 compatible (matches the
sibling check-coverage.py; runs on the macos-26 runner's python3 with no pip
deps, since those runners carry no third-party Python packages).
"""

import argparse
import glob
import json
import os
import sys


def _is_in_scope(symbol):
    """True iff this symbol is a hand-authored public API symbol we gate.

    public + lives under /Sources/ + not under /Generated/. The /Sources/ test
    also drops symbols with a null location (synthesized stdlib witnesses),
    because those have no uri to match.
    """
    if symbol.get("accessLevel") != "public":
        return False
    location = symbol.get("location") or {}
    uri = location.get("uri", "")
    if "/Sources/" not in uri:
        return False
    if "/Generated/" in uri:
        return False
    return True


def _is_documented(symbol):
    """True iff the symbol carries a source doc comment.

    The symbol-graph omits `docComment` entirely (or sets it null) when there is
    no `///`. A documented symbol has a `docComment` dict. This reads PRESENCE
    from the symbol graph — NOT docc's hasAbstract, which is blind to protocol-
    requirement witnesses (see module docstring).
    """
    return symbol.get("docComment") is not None


def _symbol_path(symbol):
    """Slash-joined declaration path, e.g. 'Variation/id'."""
    return "/".join(symbol.get("pathComponents", [])) or symbol.get(
        "identifier", {}
    ).get("precise", "<unknown>")


def _symbol_kind(symbol):
    """Human-readable kind, e.g. 'Instance Property', falling back to identifier."""
    kind = symbol.get("kind", {})
    return kind.get("displayName") or kind.get("identifier", "symbol")


def _symbol_source(symbol):
    """Basename of the source file the symbol is declared in."""
    location = symbol.get("location") or {}
    return os.path.basename(location.get("uri", "")) or "<unknown source>"


def _collect_symbols(symbol_graph_dir):
    """Load every *.symbols.json in the dir; return deduped in-scope symbols.

    Deduplicated by identifier.precise (USR) so @_exported re-homed symbols that
    appear in both the ConvertSDK and ConvertSDKCore graphs are judged once.
    Returns a list of symbol dicts in stable (sorted-by-path) order.
    """
    pattern = os.path.join(symbol_graph_dir, "*.symbols.json")
    graph_files = sorted(glob.glob(pattern))
    if not graph_files:
        print(
            "error: no *.symbols.json files found in {0}".format(symbol_graph_dir),
            file=sys.stderr,
        )
        sys.exit(2)

    by_usr = {}
    for path in graph_files:
        try:
            with open(path, "r") as handle:
                graph = json.load(handle)
        except (OSError, json.JSONDecodeError) as exc:
            print(
                "error: could not read symbol graph {0}: {1}".format(path, exc),
                file=sys.stderr,
            )
            sys.exit(2)
        for symbol in graph.get("symbols", []):
            if not _is_in_scope(symbol):
                continue
            usr = symbol.get("identifier", {}).get("precise")
            if usr is None or usr in by_usr:
                continue
            by_usr[usr] = symbol

    return [by_usr[usr] for usr in sorted(by_usr, key=lambda u: _symbol_path(by_usr[u]))]


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Fail the build if any in-scope public symbol lacks a doc comment. "
            "Reads doc-comment PRESENCE from the Swift symbol graph (not docc's "
            "hasAbstract, which is blind to protocol-requirement witnesses)."
        )
    )
    parser.add_argument(
        "--symbol-graph-dir",
        required=True,
        help=(
            "directory of *.symbols.json files from "
            "`swift build --target ConvertSDK -Xswiftc -emit-symbol-graph ...`"
        ),
    )
    args = parser.parse_args()

    symbols = _collect_symbols(args.symbol_graph_dir)
    undocumented = [s for s in symbols if not _is_documented(s)]

    if undocumented:
        # GitHub Actions surfaces ::error:: lines in the job log + annotations.
        for symbol in undocumented:
            print(
                "::error::Undocumented public symbol: {0} [{1}] in {2} "
                "— add a /// doc comment (Story 6.1 AC2).".format(
                    _symbol_path(symbol),
                    _symbol_kind(symbol),
                    _symbol_source(symbol),
                )
            )
        # stdout (not stderr): GitHub Actions renders ::error:: annotations from the
        # step's stdout. Keeping the aggregate summary on stdout — alongside the
        # per-symbol annotations above — makes it a PR annotation too, not just a log line.
        print(
            "::error::Doc-coverage gate FAILED: {0} of {1} in-scope public "
            "symbol(s) undocumented.".format(len(undocumented), len(symbols))
        )
        sys.exit(1)

    print(
        "Doc-coverage gate PASSED: all {0} in-scope public symbol(s) "
        "documented.".format(len(symbols))
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
