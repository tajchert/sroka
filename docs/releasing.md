# Store uploads (Google Play, App Store, Chrome Web Store)

Three scripts build, preflight and upload from this Mac. Each has a `--check` mode that only tests the credentials.

| Store | Command | Where it lands | Still manual |
|---|---|---|---|
| Google Play | `scripts/release/android.sh` | the `internal` testing track (`--track alpha` for closed testing) | promoting to production |
| App Store | `scripts/release/ios.sh` | TestFlight | submitting for App Review |
| Chrome Web Store | `scripts/release/extension.sh` | a draft (`--submit` submits it for review as a staged publish) | pressing Publish after approval |

The scripts never publish to production. A leaked key can at most put a build on a test track or into a draft.

## Credentials: never in the repo

This repo is public. Every key lives in one folder **outside** the checkout:

```sh
mkdir -p ~/keystores/sroka-store && chmod 700 ~/keystores/sroka-store
```

(Set `SROKA_RELEASE_CREDS` to use another folder.) The scripts refuse to run if a file is missing, sits inside the repo, or has a mode other than 600/400.

```text
~/keystores/sroka-store/
  play-service-account.json     Google Play upload (service account key)
  apple.env                     ASC_KEY_ID=..., ASC_ISSUER_ID=...
  AuthKey_<KEY_ID>.p8           App Store Connect API key
  chrome.env                    CHROME_EXTENSION_ID=..., CHROME_PUBLISHER_ID=...
  chrome-service-account.json   Chrome Web Store upload (service account key)
```

Back this folder up somewhere private, such as a password manager. To revoke a key, delete it in the console it came from (the steps below say where), then delete the local file.

## Google Play (one-time setup)

1. Open [Google Cloud Console](https://console.cloud.google.com/) and select a project. The Firebase project `sroka-95489` works, or create a dedicated `sroka-release` project.
2. APIs & Services → Library → **Google Play Android Developer API** → Enable.
3. IAM & Admin → Service accounts → **Create service account**. Name it `sroka-play-upload`. Skip the optional "grant access" steps: it needs no Cloud roles.
4. Open the new account → Keys → Add key → Create new key → **JSON**. The browser downloads the key.
5. Copy the service account's email (`sroka-play-upload@<project>.iam.gserviceaccount.com`).
6. Open [Play Console](https://play.google.com/console) → **Users and permissions** → Invite new users → paste the email.
   - Account permissions: none.
   - App permissions → Add app → **Sroka** → tick only **Release apps to testing tracks** (it includes view access). Do *not* tick "Release to production".
   - Invite user. Linking a Cloud project under Setup → API access is no longer needed.
7. Move the key into place:
   ```sh
   mv ~/Downloads/<project>-<id>.json ~/keystores/sroka-store/play-service-account.json
   chmod 600 ~/keystores/sroka-store/play-service-account.json
   ```
8. `scripts/release/android.sh --check` should print `ok: access to app.sroka; tracks: ...`. A fresh invite can take a while to propagate, sometimes hours. Until then the check reports a 403 "The caller does not have permission".

**Every release:** bump `versionCode` and `versionName` in `apps/android/app/build.gradle.kts` and commit. Optionally add en-US release notes in `store/google-play/release-notes/<versionCode>.txt`, at most 500 characters. Then run `scripts/release/android.sh` (add `--github-release` for the GitHub APK, see below).
- The script refuses a dirty tree (override with `ALLOW_DIRTY=1`).
- It needs `apps/android/keystore.properties`.
- It runs `scripts/release-preflight.sh`.
- It uploads the AAB with its R8 mapping.
- It keeps a copy of both in `store/upload/`.

Then test the internal-track build and promote it in Play Console → Testing → Internal testing → Promote release.

## App Store (one-time setup)

1. In [App Store Connect](https://appstoreconnect.apple.com/), open **Users and Access** → **Integrations** → App Store Connect API → **Team Keys**. The first time, the Account Holder has to click "Request Access" once.
2. Click **Generate API Key** (the "+" button). Name it `sroka-upload`, Access: **Admin**. The export step signs with a cloud-managed distribution certificate through this key, and Apple gives that access only to Admin keys (a Developer key can upload but the export fails with "Cloud signing permission error").
3. Note the **Issuer ID** shown above the key list and the new key's **Key ID**. Click **Download** next to the key. Apple allows the `.p8` to be downloaded **only once**.
4. Move it into place and write `apple.env`:
   ```sh
   mv ~/Downloads/AuthKey_<KEY_ID>.p8 ~/keystores/sroka-store/
   printf 'ASC_KEY_ID=%s\nASC_ISSUER_ID=%s\n' '<KEY_ID>' '<ISSUER_ID>' > ~/keystores/sroka-store/apple.env
   chmod 600 ~/keystores/sroka-store/AuthKey_*.p8 ~/keystores/sroka-store/apple.env
   ```
5. The archive is signed by the Xcode account on this Mac; the export is signed through the API key (`xcodebuild` run outside Xcode reports "No Accounts" even when Xcode is signed in). Xcode → Settings → Accounts must list the team that `apps/ios/Config/Local.xcconfig` names in `DEVELOPMENT_TEAM`. `apps/ios/Config/GoogleService-Info.plist` must be the real file (see `apps/ios/docs/RELEASING.md`).
6. `scripts/release/ios.sh --check` should print `ok: App Store Connect key works; app Sroka (app.sroka, id ...)`.

**Every release:** bump `MARKETING_VERSION` and/or `CURRENT_PROJECT_VERSION` in `apps/ios/Config/Shared.xcconfig`, run `apps/ios/scripts/verify.sh all`, commit, then run `scripts/release/ios.sh`. The script:
1. archives Release-Prod;
2. preflights the archive;
3. exports an App Store `.ipa`;
4. preflights the `.ipa` (strict signing check);
5. uploads it with `xcrun altool`. altool reads the key from `API_PRIVATE_KEYS_DIR`, so the key path never appears in the command line.

When processing finishes, the build shows up in TestFlight. Then, in App Store Connect:

1. TestFlight → **External Testing** → the public beta group (the README's `testflight.apple.com/join/…` link) → Builds → **+** → pick the build, and fill in "What to Test". The first build of a new version goes through Beta App Review, usually under a day; later builds of the same version are often approved automatically. The upload key has the Developer role, so it cannot do this step.
2. For a store release: App Store tab → the version → Build → pick it → **Submit for Review**.

If Apple removes `altool --upload-app`, set `destination` to `upload` in the generated `exportOptions.plist` and pass `-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID` to `xcodebuild -exportArchive` instead.

## Chrome Web Store (one-time setup)

This uses the Chrome Web Store API v2 with a service account, so no OAuth refresh token is involved.

1. In [Google Cloud Console](https://console.cloud.google.com/), in the same project as above, open APIs & Services → Library → **Chrome Web Store API** → Enable.
2. IAM & Admin → Service accounts → **Create service account** `sroka-cws-upload` with no roles, then Keys → Add key → **JSON**. Use a separate account from Play, so each key can be revoked on its own.
3. Open the [Chrome Web Store Developer Dashboard](https://chrome.google.com/webstore/devconsole) → **Account** (the gear/settings page).
   - Find **Service accounts** and add the `sroka-cws-upload@...` email.
   - Copy the **Publisher ID** from the same page. It is also the id in the dashboard URL, `devconsole/<publisherId>/...`.
4. Move the key into place and write `chrome.env`:
   ```sh
   mv ~/Downloads/<project>-<id>.json ~/keystores/sroka-store/chrome-service-account.json
   printf 'CHROME_EXTENSION_ID=mgeodllnkiehnjbdogljfjgdbadjdblh\nCHROME_PUBLISHER_ID=%s\n' '<PUBLISHER_ID>' > ~/keystores/sroka-store/chrome.env
   chmod 600 ~/keystores/sroka-store/chrome-service-account.json ~/keystores/sroka-store/chrome.env
   ```
5. `npm run zip -w @sroka/extension`, then `scripts/release/extension.sh --check`. This is `wxt submit --dry-run`. It gets a token and reads the store item, so it proves both the key and the dashboard access. A wrong publisher id or a service account missing from the dashboard shows up as a 403 "Permission denied on resource 'publishers/…/items/…'".

**Every release:** bump `version` in `apps/extension/package.json` (WXT copies it into the manifest), make sure `apps/extension/analytics.config.json` exists, commit, then:
- `scripts/release/extension.sh` uploads a **draft**. Check it in the dashboard and submit it there.
- `scripts/release/extension.sh --submit` uploads and submits for review as a **staged publish**: after approval you press Publish in the dashboard.
- Add `--github-release --notes FILE` to either to publish the same zip on GitHub (see below).

Store listing text, privacy answers and screenshots stay manual for all three stores. The copy-paste kit is in `store/`.

## GitHub Releases (`--github-release`)

The README links to signed builds on [GitHub Releases](https://github.com/tajchert/sroka/releases). `android.sh` and `extension.sh` can publish them in the same run, with the same artifact that went to the store:

| Script | Tag / title | Asset | Notes |
|---|---|---|---|
| `scripts/release/android.sh --github-release [--github-notes FILE]` | `android-v<versionName>` / "Sroka Android <versionName>" | `sroka-<versionName>-release.apk` (play flavor, release-signed, preflighted) | `--github-notes` (markdown), else the Play notes file. An install line with the release-key SHA-256 is appended |
| `scripts/release/extension.sh --github-release --notes FILE` | `ext-v<version>` / "Sroka extension <version>" | `srokaextension-<version>-chrome.zip` | `--notes` (markdown, required) |

Before anything is built or uploaded, the scripts check three things: `gh` is signed in, the tag doesn't exist yet, and `HEAD` is already on `origin/main`. **Push the version-bump commit first.** The release is created only after the store upload succeeds, on a tag at `HEAD`. The generated body is kept in `store/upload/github-<tag>.md`. iOS has no GitHub release; testers use TestFlight.

Notes style (as in earlier releases): a `### New` / `### Changed` / `### Fixed` list in user language, then a line saying what was not tested.

## Public-repo rules

- Never commit a key, a `.env` with values, or a downloaded JSON key. `.gitignore` blocks the usual names (`*.p8`, `*.jks`, `*service-account*.json`, `.env.submit`) as a second line of defence. Turn on GitHub secret scanning and push protection in the repo settings.
- Store ids (package `app.sroka`, extension id, Apple app id, publisher id) are not secrets.
- The scripts pass keys through environment variables or files, never argv, and never print them. Don't add `set -x` to them.
- If you move this to CI later, follow these rules:
  - Trigger only on a protected tag or a manual dispatch.
  - Keep the secrets in a GitHub Environment that requires approval.
  - Never use `pull_request_target` with a checkout of PR code, and no self-hosted runners.
  - Remember that logs and artifacts on a public repo are public.
