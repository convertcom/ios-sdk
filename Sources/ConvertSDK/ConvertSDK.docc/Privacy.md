# Privacy

What the SDK collects, what its privacy manifest declares, and copy-ready answers for your App Store App Privacy questionnaire.

## Overview

Convert is an A/B-testing and feature-flag SDK, and Apple designates A/B-testing SDKs as requiring a privacy manifest. The SDK ships one — `PrivacyInfo.xcprivacy` — and this guide explains every entry in it so you can fill out your app's **App Privacy** answers correctly and defend them.

The headline is the boundary: the SDK does **no cross-app tracking**. It reads neither the IDFA nor the IDFV, shows **no App Tracking Transparency (ATT) prompt**, and declares `Tracking = false` for every data type. Your app does not need to request tracking authorization on Convert's behalf.

> Important: Your App Privacy answers are your responsibility, not Convert's — getting them wrong rejects **your** app at review. The blocks below are written so you can paste them verbatim. They describe only what *this SDK* does; combine them with the answers for the rest of your app.

## No advertising identifiers, no ATT

The visitor identifier is a randomly generated `UUID` minted on the device the first time you create a context without supplying your own `visitorId`. It is **never** the IDFA or the IDFV, and it is never derived from a device fingerprint. Because it is not an advertising identifier and is never shared across apps, the SDK has no reason to call `ATTrackingManager` and shows no ATT prompt.

The identifier is stored on-device, scoped to your app: the Keychain is the system of record and a UserDefaults entry mirrors it for fast reads. It carries no personal information and is not linked to a real-world identity.

## What the manifest declares

The shipped `PrivacyInfo.xcprivacy` declares exactly two collected data types and one required-reason API. Nothing else is collected.

### Collected data types

| Data type | What it is in Convert | Linked to the user | Used for tracking | Purposes |
|-----------|-----------------------|--------------------|-------------------|----------|
| **Device ID** | The generated visitor `UUID` (not the IDFA/IDFV). | No | No | App Functionality, Analytics |
| **Product Interaction** | Experiment exposures and goal conversions the SDK records — which variation a visitor saw and which goals they converted. | No | No | App Functionality, Analytics |

Both are reported **not linked** to the user's identity and **not used for tracking**. The two purposes mean the same data does two jobs: **App Functionality** (running the experiment — deciding which variation to serve) and **Analytics** (the conversion reports you read in Convert).

### Required-reason API

The SDK declares a single required-reason API: access to **UserDefaults**, with reason code **`CA92.1`** — "accessing user defaults to read and write information that is only accessible to the app itself." The SDK uses UserDefaults solely to mirror the visitor identifier and a small set of fast-read flags for its own use; it never reads values written by other apps or the system, and never writes values other apps can read.

## Copy-ready App Privacy answers

Paste the following into your App Store **App Privacy** questionnaire for the portion contributed by this SDK. There are no placeholders to fill in.

**Data used for tracking:** None. The Convert SDK performs no cross-app or cross-site tracking. It reads no advertising identifier (no IDFA, no IDFV) and shows no App Tracking Transparency prompt.

**Data collected — Device ID.** The Convert SDK assigns each visitor a randomly generated identifier (a UUID) to keep A/B-test assignments consistent across launches. It is not an advertising identifier and is not linked to the user's identity. Used for App Functionality and Analytics. Not used to track the user.

**Data collected — Product Interaction.** The Convert SDK records which experiment variation a visitor was shown and which in-app goals they completed, so the experiment can run and its results can be reported. This data is not linked to the user's identity. Used for App Functionality and Analytics. Not used to track the user.

> Tip: In Apple's questionnaire these map to the **Identifiers → Device ID** and **Usage Data → Product Interaction** categories, each with **"Used to Track You" = No** and **"Linked to the User" = No**.

## No consent management — you own the decision

The SDK ships **no consent-management UI**. It does not store a consent flag, present a consent dialog, or gate itself on one. Consent is your decision to make, and you enforce it with four controls you hold:

- **Don't initialize.** If a user has not consented, simply do not construct the SDK. With no ``ConvertSDK/init(configuration:)`` call there is no identifier, no bucketing, and no event.
- **Disable delivery for the whole SDK (static).** Construct the SDK with ``ConvertConfiguration/networkTracking`` set to `false`. Bucketing still resolves so your UI can decide, but no exposure or conversion event is ever sent. This is the reliable kill-switch for *all* tracking, including feature evaluation.
- **Disable delivery for a single decision (per-call).** Pass `enableTracking: false` to ``ConvertContext/runExperience(_:enableTracking:)`` to bucket a visitor without emitting that exposure event. Note this per-call flag governs the **experience** path only; the **feature** path (``ConvertContext/runFeature(_:)``) takes no `enableTracking` parameter (Android parity), so use the static `networkTracking` flag when you need to suppress feature tracking.
- **Disable delivery at runtime (whole SDK, mid-session).** Call ``ConvertSDK/setTrackingEnabled(_:)`` at any point after initialization. `await sdk.setTrackingEnabled(false)` suppresses all outbound bucketing and conversion events immediately; `await sdk.setTrackingEnabled(true)` re-opens delivery (suppressed events are not replayed). ``ConvertSDK/isTrackingEnabled()`` reads the current state. This is the supported consent-withdrawal path for GDPR mid-session opt-out — the SDK ships the control; you own the decision.

Whichever you choose, bucketing and tracking are independent of any advertising framework — there is no IDFA, IDFV, or ATT in the loop. For the full mechanics of how delivery is suppressed and how events behave offline, see <doc:OfflineAndBackgroundDelivery>.

## See also

- <doc:GettingStarted> — the full integration path, including where the visitor `UUID` comes from.
- <doc:OfflineAndBackgroundDelivery> — the two delivery-control flags in depth, and the offline/background event behavior.
