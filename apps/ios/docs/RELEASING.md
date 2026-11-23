# Releasing Sroka for iOS

App Store builds are always **Release-Prod** (bundle `app.sroka`, share extension `app.sroka.share`, server
`https://api.sroka.app`). Dev builds are for simulators and test devices only.

## Owner-only prerequisites (one time)

1. **Apple Developer**: team id in `apps/ios/Config/Local.xcconfig` (gitignored; copy `Local.xcconfig.example`):
   `DEVELOPMENT_TEAM = <TEAMID>`.
2. **App IDs**: `app.sroka` and `app.sroka.share` (plus `app.sroka.dev`, `app.sroka.dev.share` for device testing), each with
   the App Groups capability.
3. **App Group**: `group.app.sroka` (and `group.app.sroka.dev`), enabled on both App IDs of the environment.
4. **Keychain sharing**: the access group `app.sroka.shared` (Dev: `app.sroka.dev.shared`), declared in
   `App/Sroka.entitlements` through `KEYCHAIN_GROUP`; the team prefix is added by Xcode.
5. **Firebase iOS app**: in project `sroka-95489` (console → Project settings → Add app → iOS) with bundle id `app.sroka`.
   Download `GoogleService-Info.plist` and save it as `apps/ios/Config/GoogleService-Info.plist` (gitignored; never
   commit it). `Config/GoogleService-Info.example.plist` is the placeholder format. In Firebase Analytics settings leave
   Google signals / ad personalization off. Crashlytics needs no extra setup beyond the first crash or a dSYM upload.
6. **API secrets for App Review**: set the Worker secrets `REVIEW_EMAIL` and `REVIEW_OTP` (`wrangler secret put` in
   `workers/api`) and paste the same values into App Store Connect → App Review Information → Sign-in. Never commit them
   (`store/README.md`).
7. **App Store Connect**: the app record for `app.sroka`, privacy policy URL `https://sroka.app/privacy`, and the App
   Privacy answers below.

## Checklist before every release

- `MARKETING_VERSION` (`Config/Shared.xcconfig`) bumped to the release version (x.y or x.y.z); `CURRENT_PROJECT_VERSION`
  bumped (build numbers must increase for each upload).
- `apps/ios/Config/GoogleService-Info.plist` exists and is the real file (project id `sroka-95489`, bundle `app.sroka`).
  Without it, or with the example placeholder, the build still succeeds but ships with **no telemetry**; the preflight
  below exists to stop that from reaching the Store (Android 1.4.0 and 1.5.0 shipped with a placeholder config).
- `scripts/verify.sh all` is green.

## Archive, preflight, upload

All commands run in `apps/ios`.

```sh
# 1. Archive (Release-Prod). Release builds turn user-script sandboxing off for the Sroka target so the Crashlytics
#    dSYM upload phase can reach the network; the phase only runs with a real plist present.
xcodebuild archive -project Sroka.xcodeproj -scheme "Sroka Prod" -configuration Release-Prod \
  -destination 'generic/platform=iOS' -archivePath build/Sroka.xcarchive -allowProvisioningUpdates

# 2. Preflight the archive: placeholder/missing Firebase config, simulator or ad-hoc signing, unexpected ids and versions.
scripts/release-preflight.sh build/Sroka.xcarchive

# 3. Export the App Store .ipa (exportOptions.plist: method app-store-connect, your teamID), then preflight it again;
#    this is the strict check (Apple Distribution certificate, get-task-allow false, App Store profile).
xcodebuild -exportArchive -archivePath build/Sroka.xcarchive -exportOptionsPlist build/exportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates
scripts/release-preflight.sh build/export/Sroka.ipa

# 4. Upload (Xcode Organizer → Distribute App, or the altool line below).
#    scripts/release/ios.sh (repo root) runs steps 1-4 in one go; see docs/releasing.md.
xcrun altool --upload-app -f build/export/Sroka.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

Do not upload if the preflight prints `preflight FAIL`. `scripts/release-preflight.sh --self-test [path/to/Sroka.app]`
proves the preflight still rejects a missing or placeholder config, bad ids and unsigned apps (optionally also a built
Debug simulator app). Overrides: `EXPECTED_BUNDLE_ID`, `EXPECTED_FIREBASE_PROJECT`, `EXPECTED_API_BASE_URL`,
`EXPECTED_VERSION`.

The dSYM upload phase locates Firebase's script at
`<DerivedData>/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run`; archiving with a custom
`-clonedSourcePackagesDirPath` makes the phase fail loudly (by design: crash reports without symbols are useless).
If it ever fails, upload the dSYMs from the archive with `Crashlytics/upload-symbols` instead.

## Telemetry behaviour (D15)

- Telemetry is on only when **all** hold: Release build, `GoogleService-Info.plist` bundled, not the placeholder, its
  `BUNDLE_ID` equals the app's own (so a Dev build never reports into the production stream). Otherwise `NoTelemetry`
  and no Firebase code runs at launch.
- Firebase collection is off in `Info.plist`; the stored consent turns it on at launch (`ConsentApplier`). Usage
  analytics are opt-in (first-run prompt), crash reports on by default with a Settings switch.
- No advertising identifier (the `FirebaseAnalytics` product is linked, `FirebaseAnalyticsIdentitySupport` is not), no
  IDFV collection, no ad signals, no App Tracking Transparency prompt, no user id. Events carry enum-only parameters.
- `App/PrivacyInfo.xcprivacy` (and `Share/PrivacyInfo.xcprivacy`) declare the data below and the required-reason APIs
  (UserDefaults `1C8F.1`/`CA92.1`, file timestamps `C617.1`, disk space `E174.1`).

### App Privacy answers (App Store Connect), same list as the manifest

| Data type | Linked to user | Tracking | Purpose | Notes |
|---|---|---|---|---|
| Email address | yes | no | App functionality | sign-in code is sent to it |
| User ID | yes | no | App functionality | server account id |
| Other user content | yes | no | App functionality | saved links, articles, PDFs, tags (synced) |
| Product interaction | no | no | Analytics | only after the user allows analytics |
| Device ID | no | no | Analytics, App functionality | Firebase installation id (no IDFA, no IDFV) |
| Crash data | no | no | App functionality | Crashlytics; user can switch off |

Search text, URLs, titles and tag names are never sent to Firebase.
