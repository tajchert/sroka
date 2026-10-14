# New product checklist

## Identity and distribution

- Use [the adoption script](ADOPTING.md) for package, labels, schema paths, and profile invalidation; replace launcher icons.
- Set application ID, versioning policy, Play App Signing, and CI release credentials using [the release workflow](RELEASING.md).
- Confirm min/target SDK and device-support policy; the baseline targets Android 17 (API 37).
- Test API 26 and API 37, predictive back, edge-to-edge/IME insets, rotation, large fonts, and resizable tablet/foldable windows.
- Keep `android:windowSoftInputMode="adjustResize"` on every Activity that shows a soft keyboard; without it the IME covers focused text fields.
- Extend `@FormFactorPreviews` coverage to each new screen, and choose a multi-pane layout per screen relationship rather than copying list-detail everywhere. See [Adaptive layouts](ADAPTIVE_LAYOUTS.md).
- Review Android 17 target behavior changes before adding reflection, local-network access, background work, or platform-specific SDKs.

## Environments and data

- Separate demo/development and production endpoints and bindings.
- Remove the in-memory task network source from production variants.
- Define authentication, secret handling, timeouts, logging redaction, and certificate policy.
- Choose local-only, cache-first, or durable offline-sync semantics explicitly.
- Add and test every Room migration; retain all exported schema files.

## Product platform work

- Review [the actual backup/data-extraction and network security defaults](SECURITY_DEFAULTS.md); define and test your product's restore/transfer policy.
- Replace the deep link host, publish `/.well-known/assetlinks.json` with the release signing fingerprint, and verify with `adb shell pm get-app-links`.
- Decide what a deep link to a signed-out or unauthorized resource does; resolve the destination after establishing identity and do not leak whether a resource exists.
- Re-check the deep link rules in [Deep links](DEEP_LINKS.md) whenever a URI is added.
- Configure any other exported Android components deliberately.
- Select crash reporting, analytics, push, billing, and consent only as required.
- Follow [localization and RTL checks](LOCALIZATION.md), extend accessibility coverage, and add privacy disclosures and data-deletion flows.
- Request dangerous permissions only for an actual user action; prefer permission-free pickers, explain rationale, handle denial, and recheck grants at use time.

## Quality and operations

- Keep `testDebugUnitTest lintDebug assembleDebug :app:lintRelease :app:assembleRelease` green locally and in CI.
- Run `./gradlew :app:analyzeReleaseR8Config` to review keep rules; AGP 9.3+ provides this as a standalone task.
- Raise the pinned Robolectric SDK in `src/test/resources/robolectric.properties` as Robolectric catches up with `targetSdk`.
- Treat `koverHtmlReport` output as a signal about untested logic, not as a release gate. Add `koverVerify` thresholds only if the team agrees what they mean.
- Extend the existing CI emulator journeys and database migration tests for your product.
- Retain release mapping files with shipped versions; CI already compiles the minified release.
- Extend the startup/create-task profile examples with representative product journeys and run release smoke tests on a physical device.
- Test draft restoration, background/resume completion, failed writes, and rapid repeated submissions.
- Establish dependency update, vulnerability response, monitoring, and rollback ownership.

## Performance and database refresh

- [ ] Keep historical Room schemas and verify stored data survives library upgrades.
- [ ] Run schema 1-to-2 and existing schema-2 compatibility tests after modifying Room.
- [ ] Update the benchmark target package when renaming the application ID.
- [ ] Regenerate Baseline Profiles after changing startup or common navigation paths.
- [ ] Measure startup on a physical device; emulator timings are not product measurements.
- [ ] Review long-text, large-font, dark-theme screenshot references when changing UI.
