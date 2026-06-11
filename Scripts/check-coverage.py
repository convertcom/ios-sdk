#!/usr/bin/env python3
"""Coverage gate for the Convert iOS SDK.

Reads an .xcresult bundle via `xcrun xccov view --report --json` and enforces
two per-source-library line-coverage gates:

  * ConvertSDKCore source  >= --core-min      (default 85%)
  * ConvertSDK (platform)  >= --platform-min  (default 70%)

THE SUBSTRING TRAP (why this script exists)
-------------------------------------------
The story's reference impl matched targets with `"ConvertSDK" in target_name`.
That is WRONG: `"ConvertSDK" in "ConvertSDKCoreTests"` is True and
`"ConvertSDK" in "ConvertSDKTests"` is True, so a substring matcher returns a
*test-bundle* number (and the result depends on target iteration order).
This script matches target names with `==` ONLY, never `in`.

THE SPM TARGET-ATTRIBUTION QUIRK
--------------------------------
SPM does NOT emit a bare `ConvertSDKCore` source-target entry in xccov output.
The ConvertSDKCore *source* files (Segments.swift, TrackingEvent.swift, ...)
are attributed to the `ConvertSDKCoreTests` *test-bundle* target's files[] list,
intermixed with the actual test files (FooTests.swift, CodableTestHelpers.swift).
So the ConvertSDKCore source number is computed by aggregating that bundle's
files[] while EXCLUDING test files (any name ending in `Tests.swift`, plus the
`CodableTestHelpers.swift` helper). The remaining files are the real sources.

BLOCKING POSTURE (script vs YAML split)
---------------------------------------
This script is the reusable gate logic: it exits 1 when ANY gate is unmet and 0
when ALL gates pass — so it is honest and ready to be a hard gate later. The
NON-BLOCKING behavior for now lives entirely in the CI YAML
(`continue-on-error: true` + a `::warning::` annotation), NOT in this script.
Do not neuter the exit code here; flip the YAML when Story 5.5 hardens the gate.

Stdlib only (subprocess, json, sys, argparse). Python 3.9 compatible.
"""

import argparse
import json
import subprocess
import sys

# Files inside the ConvertSDKCoreTests bundle that are NOT ConvertSDKCore source.
# Rule: anything ending in "Tests.swift" is a test file; CodableTestHelpers.swift
# is a shared test helper. Everything else in that bundle is real source.
_TEST_HELPER_NAMES = {"CodableTestHelpers.swift"}


def _is_source_file(file_name):
    """True if a file in a test bundle is a real source file (not a test/helper)."""
    if file_name.endswith("Tests.swift"):
        return False
    if file_name in _TEST_HELPER_NAMES:
        return False
    return True


def _find_target(report, target_name):
    """Return the target dict whose name EXACTLY equals target_name, else None.

    EXACT match only. Using `==` (never `in`) is what stops "ConvertSDK" from
    matching "ConvertSDKCoreTests" / "ConvertSDKTests" (the substring trap).
    """
    for target in report.get("targets", []):
        if target.get("name") == target_name:
            return target
    return None


def _aggregate_source_coverage(target):
    """Sum coveredLines / executableLines over a target's source files[].

    Excludes test files and test helpers so a test-bundle target (which holds
    both source and test files) yields the SOURCE-only coverage.
    Returns (covered, executable).
    """
    covered = 0
    executable = 0
    for file_entry in target.get("files", []):
        if not _is_source_file(file_entry.get("name", "")):
            continue
        covered += file_entry.get("coveredLines", 0)
        executable += file_entry.get("executableLines", 0)
    return covered, executable


def _pct(covered, executable):
    """covered/executable*100, guarding divide-by-zero -> 0.0."""
    if executable == 0:
        return 0.0
    return covered / executable * 100.0


def _load_report(result_path):
    """Run xccov and parse its JSON report. Exits non-zero on failure."""
    try:
        completed = subprocess.run(
            ["xcrun", "xccov", "view", "--report", "--json", result_path],
            capture_output=True,
            text=True,
            check=True,
        )
    except FileNotFoundError:
        print("error: xcrun not found on PATH", file=sys.stderr)
        sys.exit(2)
    except subprocess.CalledProcessError as exc:
        print(
            "error: xccov failed for {0}\n{1}".format(result_path, exc.stderr),
            file=sys.stderr,
        )
        sys.exit(2)
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        print("error: could not parse xccov JSON: {0}".format(exc), file=sys.stderr)
        sys.exit(2)


def _gate_line(label, covered, executable, pct, minimum, met):
    """AC5-mandated wording: 'X coverage: N% (c/e lines) — below/meets M% gate'."""
    verdict = "meets" if met else "below"
    return "{0} coverage: {1:.1f}% ({2}/{3} lines) — {4} {5:.0f}% gate".format(
        label, pct, covered, executable, verdict, minimum
    )


def main():
    parser = argparse.ArgumentParser(
        description="Enforce per-source-library coverage gates on an .xcresult bundle."
    )
    parser.add_argument("--result", required=True, help="path to the .xcresult bundle")
    parser.add_argument(
        "--core-label",
        default="ConvertSDKCore",
        help=(
            "display label for the core gate line. Display-only: the xccov lookup is "
            "always the ConvertSDKCoreTests bundle (SPM attributes ConvertSDKCore source "
            "files there). Unlike --platform-target, this does NOT select the looked-up target."
        ),
    )
    parser.add_argument(
        "--core-min", type=float, default=85.0, help="core gate percentage"
    )
    parser.add_argument(
        "--platform-target",
        default="ConvertSDK",
        help="EXACT xccov target name for the platform library",
    )
    parser.add_argument(
        "--platform-min", type=float, default=70.0, help="platform gate percentage"
    )
    args = parser.parse_args()

    report = _load_report(args.result)

    # --- ConvertSDKCore source coverage -----------------------------------
    # SPM attributes ConvertSDKCore source files to the ConvertSDKCoreTests
    # test-bundle target. Aggregate that bundle's source files (excluding
    # *Tests.swift + helpers). EXACT-name match on the bundle target.
    core_bundle = _find_target(report, "ConvertSDKCoreTests")
    if core_bundle is None:
        core_covered, core_executable = 0, 0
    else:
        core_covered, core_executable = _aggregate_source_coverage(core_bundle)
    core_pct = _pct(core_covered, core_executable)
    core_met = core_pct >= args.core_min

    # --- ConvertSDK (platform) source coverage ----------------------------
    # EXACT-name target "ConvertSDK". Must NEVER match "ConvertSDKCoreTests"
    # or "ConvertSDKTests" -> _find_target uses == not in.
    platform_target = _find_target(report, args.platform_target)
    if platform_target is None:
        plat_covered, plat_executable = 0, 0
    else:
        # Aggregate the platform target's own source files the same way
        # (excluding any *Tests.swift). Today executableLines is 0 -> 0.0%.
        plat_covered, plat_executable = _aggregate_source_coverage(platform_target)
    plat_pct = _pct(plat_covered, plat_executable)
    plat_met = plat_pct >= args.platform_min

    print(
        _gate_line(
            args.core_label, core_covered, core_executable, core_pct, args.core_min, core_met
        )
    )
    print(
        _gate_line(
            args.platform_target,
            plat_covered,
            plat_executable,
            plat_pct,
            args.platform_min,
            plat_met,
        )
    )

    # Honest exit code: 1 if ANY gate unmet, 0 if ALL pass. The CI YAML makes
    # this non-blocking for now (continue-on-error + ::warning::); the script
    # stays a real gate so Story 5.5 can flip the YAML with no script change.
    if core_met and plat_met:
        sys.exit(0)
    sys.exit(1)


if __name__ == "__main__":
    main()
