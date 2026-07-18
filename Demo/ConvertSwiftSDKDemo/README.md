# ConvertSwiftSDKDemo

A SwiftUI demo app for the Convert FullStack iOS SDK (Epic 7). It runs OFFLINE by default,
bucketing against the bundled `demo-config.json` (a real FS-Test-Proj staging config with
audience/location gates cleared so the run screens bucket deterministically with no network).

## Testing experiment-preview deep links

The demo registers the custom URL scheme `convertdemo://` (see `Info.plist`'s
`CFBundleURLTypes`) so it can receive experiment-preview deep links exactly like a host app
would wire the SDK's qs-02/qs-03 preview surface (`PreviewParam.parse` +
`ConvertContext.setPreview(experienceId:variationId:)`). Link registration and this deep-link
route are a **host-app concern** — the SDK itself does not register any link (explicit
non-goal) — so this wiring lives entirely in the demo:

- `ConvertSwiftSDKDemoApp.swift` — `.onOpenURL { url in Task { await viewModel.applyPreviewLink(url) } }`
- `Model/DemoViewModel+Preview.swift` — `applyPreviewLink(_:)` parses the link and calls into the SDK

### Canonical link format

```
convertdemo://preview?convert_preview={experienceId}.{variationId}
```

`convert_preview` is the same dot-separated `{experienceId}.{variationId}` param the SDK's
`PreviewParam.parse` helper expects — two non-empty, all-digit components separated by a
single `.`. Any other shape (missing param, non-numeric ids, wrong separator) is ignored: the
demo logs the reason and leaves the current context/results untouched.

### Concrete example (bundled demo-config IDs)

The bundled `demo-config.json` carries experience `test-experience-ab-fullstack-4`
(id `100349071`) with two variations: `original` (id `1003180877`) and `variation-1`
(id `1003180878`). To force the second variation:

```
xcrun simctl openurl booted "convertdemo://preview?convert_preview=100349071.1003180878"
```

**Expected result:** the app forces `test-experience-ab-fullstack-4` to `variation-1` and the
Experiences screen's result cards refresh — the top card reads
`test-experience-ab-fullstack-4` / `Variation variation-1`, regardless of whatever the
bucketing hash would otherwise have picked for the current visitor.

### Confirming zero-trace via the Event Inspector

Preview is a full decision bypass with **zero trace**: no bucketing enqueue, no sticky-decision
write, no conversion tracking to the source. Open the demo's Event Inspector (the toolbar
button present on every tab) and check the **Events** segment: applying the preview link above
must NOT add a new `.bucketing` row for `test-experience-ab-fullstack-4`. (The Inspector's
**Logs** segment is a placeholder — Story 7.2b, not yet wired to a live log stream — so use
`log stream`, below, for the preview-link diagnostic lines themselves.)

To see the demo's own `[preview-link] applied …` / `[preview-link] ignored: …` diagnostic line
(emitted via unified logging, not the Event Inspector), stream the simulator log in a separate
terminal before running the `simctl openurl` command:

```
xcrun simctl spawn booted log stream --predicate 'subsystem == "com.convert.ConvertSwiftSDKDemo" AND category == "preview-link"'
```

### Offline vs. live

- **In-config experiences preview fully offline.** Any experience already present in
  `demo-config.json` (like `test-experience-ab-fullstack-4` above) previews with no network,
  since the SDK already holds its `ConfigExperience` and can force the named variation directly.
- **A draft / not-yet-loaded experience needs a live serving host.** If the previewed
  `experienceId` is absent from the currently-held config snapshot, the SDK falls back to the
  `?exp=`-scoped `ConfigFetchService.fetchExperienceConfig(experienceId:)` fetch, which requires
  network access to a real Convert serving host. Point the demo at a live environment via
  `ConvertConfiguration`'s `apiConfigEndpoint` (rather than the bundled offline `demo-config.json`
  path) before previewing an experience that isn't already in the bundled config.
