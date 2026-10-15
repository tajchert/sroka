# Security and backup defaults

> Inherited from the ai-android-template. The template's Tasks sample was removed; where this guide names `feature:tasks`, use the Sroka modules (`feature:library:impl`, `feature:reader:impl`, …). Sroka rulings in [DECISIONS](DECISIONS.md) override this guide.

This describes the sample's configuration, not a complete product security policy. Review it when replacing the feature, adding networking, or storing sensitive data.

## Current choices

| Configuration | Current behavior |
|---|---|
| App manifest | `allowBackup="true"`, RTL support, and one exported launcher/deep-link activity |
| Permissions | The app declares no INTERNET or ACCESS_NETWORK_STATE permission; its backend is an in-memory fake |
| Network security XML | Cleartext denied by default; exceptions for `10.0.2.2`, `localhost`, and `127.0.0.1`, including subdomains |
| Legacy backup XML | Excludes the entire SharedPreferences domain |
| Android 12+ extraction XML | Excludes SharedPreferences from cloud backup; no explicit device-transfer section |
| Local storage | Room database `sroka-database` and DataStore file `files/datastore/user_preferences.preferences_pb` |

The cleartext exceptions are in the main configuration, so they also apply to release variants. The fake makes no HTTP requests. When adding a backend, add INTERNET only when required and move development exceptions to an appropriate debug configuration or remove them.

## Backup implications

Sroka (DECISIONS A6): `backup_rules.xml` and `data_extraction_rules.xml` exclude SharedPreferences and the session DataStore (`datastore/session.preferences_pb`, AES-GCM token under an AndroidKeyStore key) from cloud backup and device transfer. The library database and preferences may be restored; a restored device without the session signs in again. Cleartext is allowed only in the debug `network_security_config` for localhost, 127.0.0.1 and 10.0.2.2.

Android backs up databases and internal files by default, subject to its transport and device conditions. Use separate cloud and device-transfer rules where required. See the official [Auto Backup guide](https://developer.android.com/identity/data/autobackup), including the platform caveat that disabling cloud backup does not universally disable device transfers.

For a product, decide which user data should restore, which settings are portable, and which credentials/device identifiers must be excluded. Update both `app/src/main/res/xml/backup_rules.xml` and `data_extraction_rules.xml`, then test backup/restore, database migration after restore, and transfer behavior on supported Android versions. Do not treat uninstall/reinstall as proof of an empty database because restoration may occur.

## Other product decisions

- Validate incoming links and authorize the destination against the signed-in user when authentication exists. Sroka has no deep links; the only external entry is the `ShareActivity` text/plain share target, which only saves an http(s) URL.
- Choose credential storage and retention deliberately. Room and Preferences DataStore in this starter are not configured as encrypted credential stores.
- Keep server credentials out of the APK. Review logging, exported components, permission requests, and any new SDK's data collection.
- Configure real signing and artifact retention through [Release](RELEASING.md); keys do not belong in the repository.

Document product policies in [DECISIONS](DECISIONS.md).
