# OmniTerm Privacy

OmniTerm is designed as an on-device SSH/SFTP administration tool.

## Data The App Handles

OmniTerm stores the following data locally on the user's device when the user enters it:

- SSH host names, addresses, ports, usernames, groups, notes, and connection settings.
- SSH passwords, sudo passwords, proxy passwords, credential profiles, and imported private keys.
- Quick scripts, alert rules, Wake-on-LAN targets, app settings, and recent metric history.

## Network Use

The app connects directly from the user's device to servers and proxies configured by the user. OmniTerm does not operate a backend service for telemetry, analytics, advertising, crash reporting, or credential sync.

## Advertising (Play Store Build Only)

The free Play Store build shows a single banner ad served by Google AdMob. AdMob may collect device identifiers and ad-interaction data as described in [Google's privacy policy](https://policies.google.com/privacy). In the EEA/UK, ads are only requested after consent is collected through Google's User Messaging Platform. Purchasing ad removal or the full unlock removes the banner and stops all ad requests. The source-available build contains no ad SDK and makes no ad requests.

## Sharing And Sale

OmniTerm does not sell user data. It does not share credentials, private keys, host inventory, metrics, or files with the project maintainers or third-party services.

User-initiated SSH/SFTP operations send data directly to the host or proxy selected by the user. User-initiated exports, CSV files, and encrypted backups are written only to destinations selected through Android's system document picker.

## Backups

Android platform auto-backup is disabled because local app data can include SSH credentials and private keys.

The in-app backup feature is user initiated. It encrypts exported app data with AES-256-GCM using a passphrase-derived key. The passphrase is not stored by OmniTerm and is required to restore the backup.

## Permissions

OmniTerm requests only permissions needed for its visible features:

- `INTERNET` for SSH and SFTP connections to user-configured hosts.
- `USE_BIOMETRIC` for optional app lock and privileged-action confirmation.
- `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, and `FOREGROUND_SERVICE_CONNECTED_DEVICE` for the optional background SSH keep-alive notification and monitoring alerts.
- `WAKE_LOCK` to keep an explicitly backgrounded live terminal from being suspended mid-session.

The app does not request Android storage permissions or All Files Access. File import and export use Android's Storage Access Framework.

## Data Deletion

Users can delete hosts, credentials, keys, scripts, alerts, and Wake-on-LAN targets inside the app. Uninstalling the app removes its local database and settings from the device.
