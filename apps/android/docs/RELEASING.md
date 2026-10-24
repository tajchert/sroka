# Release workflow

> Inherited from the ai-android-template. The template's Tasks sample was removed; where this guide names `feature:tasks`, use the Sroka modules (`feature:library:impl`, `feature:reader:impl`, …). Sroka rulings in [DECISIONS](DECISIONS.md) override this guide.

Release builds are minified and signed with the Sroka release key. `benchmarkRelease` and `nonMinifiedRelease` use the debug key for local tests; they are not distribution variants. There is no publishing automation yet.

## Signing setup

Release signing is wired in `app/build.gradle.kts`. Local builds read the gitignored file `apps/android/keystore.properties`:

```properties
storeFile=/Users/<user>/keystores/sroka-release.jks
storePassword=<password>
keyAlias=sroka
keyPassword=<password>
```

CI can supply the same values through `SROKA_KEYSTORE_PATH`, `SROKA_KEYSTORE_PASSWORD`, `SROKA_KEY_ALIAS` and `SROKA_KEY_PASSWORD` (for GitHub Actions, decode a `RELEASE_KEYSTORE_BASE64` secret, made with `base64 -i sroka-release.jks`, into the runner's temp dir).

`keystore.properties`, `*.jks` and `*.keystore` must stay uncommitted. Keep a backup of the keystore and its password outside this machine. Without Play App Signing, a lost key means users cannot upgrade in place; with it, this key is the upload key and Google can reset it. Without a release keystore, Gradle falls back to the debug key so contributor and CI release builds stay installable; a public release must always be verified as release-signed.

Expected release certificate (PKCS12, RSA 4096, valid until 2054-03-11):

```text
CN=Sroka Release, O=Tajchert, C=PL
SHA-256: 74ee30adc67a9c03be7d329d6d68154f1ca75ecba6ef13914c6923536863f74a
```

Verify a build with:

```bash
./gradlew :app:assembleRelease
APKSIGNER=$(find "$ANDROID_HOME/build-tools" -name apksigner -type f | sort -V | tail -n1)
"$APKSIGNER" verify --print-certs app/build/outputs/apk/release/app-release.apk
```

## Prepare a product release

1. Replace the template launcher icon with Sroka branding and review [security defaults](SECURITY_DEFAULTS.md). Configure CI on the forge you use; the included workflow targets GitHub Actions, not GitLab.
2. Set `versionCode` and `versionName` in `app/build.gradle.kts`. Use an increasing code for successive product releases and define a user-visible naming policy.
3. For Google Play, enroll in Play App Signing and upload with the Sroka release key (it becomes the upload key). For direct APK distribution it is the app signing key.
4. Run [verification](TESTING.md#commands), relevant device tests, and screenshot checks. Regenerate reviewed Baseline Profiles when startup/common paths change.

See the official [app-signing guide](https://developer.android.com/studio/publish/app-signing) for key management and signed builds.

## Produce and retain artifacts

```bash
./gradlew :app:bundleRelease
```

The bundle is under `app/build/outputs/bundle/release/`. An AAB is not directly installable with `adb install`; use your channel's test delivery or generate device APKs with the official [bundletool](https://developer.android.com/tools/bundletool).

Retain the exact distributed artifact, version, source commit, and signing-certificate identity. Archive the release R8 mapping from `app/build/outputs/mapping/release/mapping.txt` with that version for crash retracing. The included CI verifies assembly; it does not publish or archive release mappings.

## Check the distributed build

Test the signed, optimized build rather than relying on debug behavior. Check startup, create/open/delete, persisted preferences, process restart, saved drafts, and deep links. Verify upgrades from the previous shipped version and database restore where supported. Check the minimum/target API, large fonts, RTL, accessibility, and adaptive windows for your product.

Publish App Link associations with the certificate that signs the installed distribution. Keep physical-device performance checks separate from emulator functional journeys. Use the distribution channel's internal test track before broader rollout, and record what was tested with the release.
