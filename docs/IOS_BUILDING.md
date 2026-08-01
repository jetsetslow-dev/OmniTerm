# Building OmniTerm for iOS

## Host requirements

iOS application, Simulator, device, signing, and XCTest work requires a Mac. Apple does not ship
Xcode or the iOS SDK for Linux. Linux remains a supported host for Android and platform-neutral
shared tests, but it cannot provide iOS validation evidence.

It is not necessary to **own** a Mac for day-to-day shared-code development. A Linux-first workflow
can use GitHub-hosted macOS runners, a rented remote Mac, or Xcode Cloud for the Apple build stage.
It is still necessary for the release pipeline to execute macOS/Xcode somewhere. Theos plus Darling
is not an OmniTerm build path: it does not provide the supported Gradle/Kotlin-Native/Compose,
Simulator, XCTest, Instruments, signing, and App Store validation chain.

| Tool | Supported baseline | Purpose |
|---|---|---|
| macOS | A release supported by Xcode 26.4 | Xcode host |
| Xcode | 26.4 | iOS SDK, Simulator, signing, XCTest |
| JDK | Temurin 17 | Gradle and Kotlin builds |
| Kotlin | 2.4.0 | Shared Kotlin compiler; held for repository CodeQL compatibility |
| Compose Multiplatform | 1.11.1 (Material3 1.11.2) | Shared Android/iOS UI |
| Android Gradle Plugin | 9.3.1 | Android app and Android-KMP target |
| Gradle | Repository wrapper, currently 9.6.1 | Reproducible build entry point |

The Kotlin compatibility table currently lists AGP through 9.1 for Kotlin 2.4.x, while Google's
dedicated Android-KMP plugin documents AGP 9.3 support. OmniTerm uses that dedicated plugin rather
than applying `com.android.library` to the shared module. The exact combination must remain covered
by Android CI and the macOS shared-framework gate.

## One-time setup

1. Install Xcode 26.4 from Apple and launch it once so it can install platform components.
2. Select it with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` if it is not
   already the active developer directory.
3. Install Homebrew from its official site.
4. Run `./scripts/setup-ios-dev.sh`. It installs the repository's command-line tools from
   `iosApp/Brewfile`, runs shared tests, and compiles an iOS Simulator framework.
5. Install the Kotlin Multiplatform plugin in Android Studio or IntelliJ IDEA if using either IDE.

Generate and open the shell project:

```bash
xcodegen generate --spec iosApp/project.yml
open iosApp/OmniTerm.xcodeproj
```

`project.yml` is the source of truth. The Xcode pre-build phase invokes
`:shared:embedAndSignAppleFrameworkForXcode` for the selected SDK and architecture.

The setup script deliberately does not accept the Xcode license with `sudo`, create certificates,
download arbitrary Simulator runtimes, or modify a login keychain. Those actions require an
interactive administrator or Apple-account decision.

### No personally owned Mac

Use the committed GitHub Actions macOS workflow for ordinary pull-request compilation and tests.
For signing or interactive Simulator/device diagnosis, use a temporary or rented Mac with the setup
script above. Xcode Cloud is also suitable after initial onboarding, but Apple currently requires
the first workflow to be configured in Xcode, Apple Developer Program membership, an App Store
Connect app record for application builds, and repository access. Membership includes 25—not
100—Xcode Cloud compute hours per month as of this document's date.

The Xcode project specification must remain committed and reproducible. Apple warns that dynamically
generating or editing projects during Xcode Cloud onboarding can fail, so an Xcode Cloud migration
must generate and review a project snapshot before onboarding rather than generating it only
in cloud CI.

## Apple identifiers and signing

Reserve these identifiers in the Apple Developer account:

- Application: `com.jetsetslow.omniterm.app`
- Widget extension: `com.jetsetslow.omniterm.app.widget`
- App Group: `group.com.jetsetslow.omniterm.app`

Simulator CI must use automatic, unsigned simulator builds. Device and archive jobs use an Apple
team, distribution certificate, and provisioning profiles supplied through the protected CI
environment. Never commit `.p12`, `.mobileprovision`, Apple API keys, keychains, or their passwords.

Expected protected CI secret names, once device/archive automation is enabled:

- `APPLE_TEAM_ID`
- `APPLE_SIGNING_CERTIFICATE_BASE64`
- `APPLE_SIGNING_CERTIFICATE_PASSWORD`
- `APPLE_PROVISIONING_PROFILE_BASE64`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY_BASE64`

No current pull-request job requires these secrets.

## Command-line validation

On Linux or macOS:

```bash
./gradlew :shared:allTests --no-daemon --no-configuration-cache
```

On macOS only:

```bash
./gradlew :shared:linkDebugFrameworkIosSimulatorArm64 --no-daemon --no-configuration-cache
./gradlew :shared:linkDebugFrameworkIosArm64 --no-daemon --no-configuration-cache
```

Build-affecting final heads must also pass `./scripts/local-pr-check.sh --full` and every required
hosted check described in `AGENTS.md`. A Linux result must never be reported as an iOS build result.

## Dependency policy

Prefer Maven-hosted Kotlin Multiplatform dependencies in `shared`, covered by Gradle's strict
SHA-256/SHA-512 verification metadata. Use direct framework integration for the shared module.
Introduce CocoaPods or Swift Package Manager dependencies only with a task-specific design review,
locked resolution, license review, security review, and SBOM/notices update. CocoaPods is installed
for evaluated native dependencies but is not currently part of the application linkage path.
