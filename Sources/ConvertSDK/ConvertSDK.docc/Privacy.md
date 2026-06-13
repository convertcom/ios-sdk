# Privacy

Where the SDK stands on tracking, and where the full privacy guide lives.

## Overview

The SDK performs no cross-app tracking: there is no ATT prompt and the IDFA and IDFV are never read. Visitor identity is a persistent, app-scoped UUID. The SDK ships a `PrivacyInfo.xcprivacy` privacy manifest. Event delivery can be disabled entirely through the configuration's ``ConvertConfiguration/networkTracking`` flag while bucketing continues to work.

> Note: The complete Apple Privacy guide — what the `PrivacyInfo.xcprivacy` manifest declares, the required-reason API entries, and copy-ready answers for your App Store privacy questionnaire — is delivered in Story 6.4 and will be linked here once published.

### See also

To get started with the SDK, see <doc:GettingStarted>.
