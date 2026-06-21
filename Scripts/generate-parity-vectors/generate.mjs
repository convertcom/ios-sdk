/*!
 * generate-parity-vectors / generate.mjs
 *
 * Generates Tests/ConvertSwiftSDKCoreTests/Fixtures/hash-parity-vectors.json for the
 * iOS SDK's cross-SDK MurmurHash3 bucketing parity suite (Epic 3 / Story 2, AC9).
 *
 * HARD PROVENANCE RULE (NFR18):
 *   Every expectedValue / expectedVariationId in the emitted fixture is computed
 *   ONLY from the PUBLISHED `@convertcom/js-sdk-bucketing` npm package, installed
 *   from the registry into this isolated tool's node_modules. No local sibling
 *   checkout (e.g. ../../../javascript-sdk) is ever imported or referenced. This
 *   tool is NOT part of the Swift package graph and must never be referenced from
 *   Package.swift.
 *
 * Published API driven (verified against the installed lib/index.d.ts +
 * lib/index.mjs of @convertcom/js-sdk-bucketing@3.1.3):
 *   - new BucketingManager()                 // default config => _max_traffic = 10000
 *   - getValueVisitorBased(visitorId, { seed, experienceId }) -> number (0..9999)
 *       internally: parseInt(String((murmurhash.v3(experienceId + String(visitorId), seed) / 4294967296) * 10000), 10)
 *   - selectBucket(buckets, value, redistribute=0) -> string | null
 *
 * Vector set (AC9):
 *   (a) The 69 Android cross-SDK vectors, taken as VERBATIM INPUTS
 *       (experienceId, visitorId, seed, buckets) and RECOMPUTED here with the
 *       published package. Each recomputed (expectedValue, expectedVariationId)
 *       is cross-checked against the Android file's claimed values; ANY mismatch
 *       is a real cross-SDK parity defect and aborts generation (no silent
 *       overwrite).
 *   (b) >= 5 iOS-specific vectors generated fresh from the published package.
 *
 * Output: the merged, pretty-printed JSON array is written to the fixture path
 * (and also echoed to stdout).
 */

import { BucketingManager } from '@convertcom/js-sdk-bucketing';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));

// --- Paths -----------------------------------------------------------------
// Android cross-SDK vectors: verbatim INPUTS (provenance source is the
// published package, not this file — this file only supplies the input cases
// and the values to cross-check against).
const ANDROID_VECTORS_PATH = resolve(
  __dirname,
  '../../../android-sdk/packages/core/src/test/resources/hash-parity-vectors.json',
);
// Committed fixture consumed by the iOS parity tests.
const OUTPUT_PATH = resolve(
  __dirname,
  '../../Tests/ConvertSwiftSDKCoreTests/Fixtures/hash-parity-vectors.json',
);

// --- Published-package driver ----------------------------------------------
// Default config => _max_traffic = 10000 (verified: Android values are 0..9999).
const manager = new BucketingManager();

/**
 * Compute the 0..9999 bucket value for (experienceId, visitorId, seed) using
 * the PUBLISHED BucketingManager. Each vector carries its own seed (the Android
 * set includes seed 0, 12345 and 2147483647 alongside the default 9999), so the
 * seed is always passed explicitly.
 */
function computeValue(visitorId, experienceId, seed) {
  return manager.getValueVisitorBased(visitorId, { seed, experienceId });
}

/**
 * Select the variation key for a bucket value using the PUBLISHED selectBucket.
 */
function computeVariation(buckets, value) {
  return manager.selectBucket(buckets, value);
}

/** Build a fully-recomputed vector record in the canonical cross-SDK schema. */
function buildVector(description, visitorId, experienceId, seed, buckets) {
  const expectedValue = computeValue(visitorId, experienceId, seed);
  const expectedVariationId = computeVariation(buckets, expectedValue);
  return {
    description,
    visitorId,
    experienceId,
    seed,
    expectedValue,
    expectedVariationId,
    buckets,
  };
}

// --- (a) Recompute + cross-check the 69 Android vectors --------------------
const androidVectors = JSON.parse(readFileSync(ANDROID_VECTORS_PATH, 'utf8'));
if (!Array.isArray(androidVectors)) {
  throw new Error(`Android vectors file is not a JSON array: ${ANDROID_VECTORS_PATH}`);
}

const recomputedAndroid = [];
const mismatches = [];

for (const v of androidVectors) {
  const out = buildVector(v.description, v.visitorId, v.experienceId, v.seed, v.buckets);
  // Cross-SDK agreement proof: recomputed MUST equal the Android-claimed values.
  if (out.expectedValue !== v.expectedValue || out.expectedVariationId !== v.expectedVariationId) {
    mismatches.push({
      description: v.description,
      visitorId: v.visitorId,
      experienceId: v.experienceId,
      seed: v.seed,
      claimedValue: v.expectedValue,
      recomputedValue: out.expectedValue,
      claimedVariationId: v.expectedVariationId,
      recomputedVariationId: out.expectedVariationId,
    });
  }
  recomputedAndroid.push(out);
}

if (mismatches.length > 0) {
  // PROVENANCE-CRITICAL: a divergence is a real cross-SDK parity defect.
  // Do NOT silently overwrite the Android values — abort and report.
  console.error(
    `\nCROSS-SDK PARITY DEFECT: ${mismatches.length} of ${androidVectors.length} Android vector(s) ` +
      `diverge between the published @convertcom/js-sdk-bucketing package and the Android file:\n`,
  );
  console.error(JSON.stringify(mismatches, null, 2));
  process.exit(1);
}

// --- (b) >= 5 iOS-specific vectors (fresh from the published package) -------
// seed 9999, 2-way 50/50 buckets; values/variations come straight from the
// published package (no Android cross-check — these are iOS-specific).
const IOS_SEED = 9999;
const IOS_BUCKETS = { varA: 50, varB: 50 };

const longVisitorId = 'x'.repeat(256); // >= 200 chars (AC9 case 2)

const iosSpecific = [
  buildVector(
    'iOS-specific: Unicode visitorId with CJK characters (Japanese)',
    'こんにちは世界_東京',
    'ios_exp_unicode',
    IOS_SEED,
    IOS_BUCKETS,
  ),
  buildVector(
    `iOS-specific: long visitorId (${longVisitorId.length} chars, >= 200)`,
    longVisitorId,
    'ios_exp_long',
    IOS_SEED,
    IOS_BUCKETS,
  ),
  buildVector(
    'iOS-specific: empty visitorId with non-empty experienceId',
    '',
    'ios_exp_empty_visitor',
    IOS_SEED,
    IOS_BUCKETS,
  ),
  buildVector(
    'iOS-specific: standard hyphenated UUID visitorId',
    '0b0e64d5-adf0-4c43-9c1f-4f6a81e4e87e',
    'ios_exp_uuid',
    IOS_SEED,
    IOS_BUCKETS,
  ),
  buildVector(
    'iOS-specific: visitorId containing spaces',
    'visitor with internal spaces',
    'ios_exp_spaces',
    IOS_SEED,
    IOS_BUCKETS,
  ),
];

// --- Merge + write ----------------------------------------------------------
const allVectors = [...recomputedAndroid, ...iosSpecific];
const json = JSON.stringify(allVectors, null, 2) + '\n';

writeFileSync(OUTPUT_PATH, json, 'utf8');

// --- Provenance / cross-check summary to stderr (stdout stays pure JSON) ----
const seedCounts = allVectors.reduce((acc, v) => {
  acc[v.seed] = (acc[v.seed] || 0) + 1;
  return acc;
}, {});

console.error(
  `\n[generate-parity-vectors] wrote ${allVectors.length} vectors to ${OUTPUT_PATH}\n` +
    `  source: PUBLISHED @convertcom/js-sdk-bucketing (BucketingManager.getValueVisitorBased + selectBucket)\n` +
    `  breakdown: ${recomputedAndroid.length} Android (recomputed + cross-checked) + ${iosSpecific.length} iOS-specific\n` +
    `  Android cross-check: ${androidVectors.length}/${androidVectors.length} matched expectedValue AND expectedVariationId (0 mismatches)\n` +
    `  seed distribution: ${JSON.stringify(seedCounts)}\n`,
);

// Pure JSON to stdout for piping/inspection.
process.stdout.write(json);
