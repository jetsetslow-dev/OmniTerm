# OmniTerm Privacy

OmniTerm is designed as an on-device SSH/SFTP administration tool.

## Data The App Handles

OmniTerm stores the following data locally on the user's device when the user enters it:

- SSH host names, addresses, ports, usernames, groups, notes, and connection settings.
- SSH passwords, sudo passwords, proxy passwords, credential profiles, and imported private keys.
- Quick scripts, alert rules, Wake-on-LAN targets, app settings, and recent metric history.
- Alert forwarding settings, if the user sets them up: the service, its address and topic, and an optional access token (stored encrypted).

## Network Use

The app connects directly from the user's device to servers and proxies configured by the user. OmniTerm does not operate a backend service for telemetry, analytics, advertising, crash reporting, or credential sync.

## Alert Forwarding (Opt-In)

Alert forwarding is off unless the user sets it up under Alerts. When it is on, each alert that opens (and, if the user keeps that option, each one that resolves) is sent from the device to the one address the user entered: an ntfy server and topic, a Gotify server, or a webhook. The message carries the alert's title and text (the host's name, the rule, the reading and its threshold), its severity and the time. Nothing else is sent: no credentials, files, terminal output or other metrics. Muted alerts are not forwarded. An access token the user enters is stored encrypted on the device with the Android Keystore and sent only to that address; redirects are not followed, so it never goes anywhere else. A plain `http://` address sends the alert and token unencrypted, and the form says so. On a public ntfy server, anyone who knows the topic can read its messages. The service receiving the alerts is the user's choice and is governed by its own terms.

## Advertising (Play Store Build Only)

The free Play Store build shows a single banner ad served by Google AdMob. AdMob may collect device identifiers and ad-interaction data as described in [Google's privacy policy](https://policies.google.com/privacy). In the EEA/UK, ads are only requested after consent is collected through Google's User Messaging Platform. Purchasing ad removal or the full unlock removes the banner and stops all ad requests. The source-available build contains no ad SDK and makes no ad requests.

## Sharing And Sale

OmniTerm does not sell user data. It does not share credentials, private keys, host inventory, metrics, or files with the project maintainers or third-party services. The only exception is alert forwarding, when the user turns it on: alerts then go to the service the user chose, as described above.

User-initiated SSH/SFTP operations send data directly to the host or proxy selected by the user. User-initiated exports, CSV files, and encrypted backups are written only to destinations selected through Android's system document picker.

## Backups

Android platform auto-backup is disabled because local app data can include SSH credentials and private keys.

The in-app backup feature is user initiated. It encrypts exported app data with AES-256-GCM using a passphrase-derived key. The passphrase is not stored by OmniTerm and is required to restore the backup.

## Permissions

OmniTerm requests only permissions needed for its visible features:

- `INTERNET` for SSH and SFTP connections to user-configured hosts.
- `ACCESS_LOCAL_NETWORK` (Android 17 and later) to reach hosts, shares and devices on your local network: SSH, SFTP, LAN discovery, tunnels, shares and Wake-on-LAN.
- `USE_BIOMETRIC` for optional app lock and privileged-action confirmation.
- `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, and `CHANGE_NETWORK_STATE` for the optional background SSH keep-alive notification and monitoring alerts.
- `ACCESS_NETWORK_STATE` to tell whether the phone has a network at all, so the Host Offline alert and the checks the phone runs itself record nothing while it is offline instead of reporting every host as down. Only whether a network is active is read.
- `FOREGROUND_SERVICE_DATA_SYNC` for the progress notification that keeps a long file copy or other long operation running while the app is in the background.
- `WAKE_LOCK` to keep an explicitly backgrounded live terminal from being suspended mid-session.
- `NFC` to talk to a FIDO2 security key you hold to the phone when you sign in with it or make a key on it. USB security keys and USB serial consoles use Android's per-device USB permission prompt instead.

The app does not request Android storage permissions or All Files Access. File import and export use Android's Storage Access Framework.

## Data Deletion

Users can delete hosts, credentials, keys, scripts, alerts, and Wake-on-LAN targets inside the app. Uninstalling the app removes its local database and settings from the device.
