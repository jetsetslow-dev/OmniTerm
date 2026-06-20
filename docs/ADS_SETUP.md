# Ads & monetization setup (AdMob)

Everything you need to make the banner actually show, and to keep AdMob happy.
Ads exist **only in the `playStore` flavor** — the `openSource` flavor bundles no
ads SDK at all (its `FlavorAdBanner` is an empty stub).

---

## 0. The #1 reason "ads don't work at all"

You're running the **`openSource`** build. It has no ad SDK, so the banner is
permanently blank by design.

**Build the Play Store flavor:**

```bash
./gradlew assemblePlayStoreDebug      # debug APK with ads
./gradlew bundlePlayStoreRelease      # AAB for Play (needs real IDs, see below)
```

Confirm in-app under **Tools → About → Distribution** — it must say `Play Store`.

---

## 1. AdMob IDs

IDs are injected at build time (env var **or** Gradle property). If unset, debug
builds fall back to Google's official **sample/test** IDs, which serve test ads.

| What | Env var | Gradle property | Where to get it |
|------|---------|-----------------|-----------------|
| App ID | `ADMOB_APP_ID` | `-PADMOB_APP_ID=` | AdMob → app → App settings (`ca-app-pub-…~…`) |
| Banner unit | `ADMOB_BANNER_UNIT_ID` | `-PADMOB_BANNER_UNIT_ID=` | AdMob → app → Ad units (`ca-app-pub-…/…`) |
| Test devices | `ADMOB_TEST_DEVICE_IDS` | `-PADMOB_TEST_DEVICE_IDS=` | logcat (see §3), comma-separated |

```bash
# Debug build with your real unit + your phone registered as a test device:
./gradlew assemblePlayStoreDebug \
  -PADMOB_APP_ID=ca-app-pub-XXXX~XXXX \
  -PADMOB_BANNER_UNIT_ID=ca-app-pub-XXXX/XXXX \
  -PADMOB_TEST_DEVICE_IDS=ABCDEF0123456789
```

A **`playStoreRelease`** build **fails the Gradle config** if the sample IDs are
still in place — you can't accidentally ship test IDs to production.

---

## 2. Consent (UMP) must resolve before any ad loads

The banner renders **nothing** until Google's User Messaging Platform resolves
consent (`AdsConsentManager.canRequestAds`). For EEA/UK users a consent form is
shown first; elsewhere consent is "not required" and ads load straight away.

If the banner is blank on first launch, watch for the consent flow completing —
it caches across launches, so it's usually a one-time step.

---

## 3. Test ads / "shake to test" — what it does and doesn't do

Registering a **test device** (in the AdMob console, or by setting
`ADMOB_TEST_DEVICE_IDS`) makes Google serve **test ads** to that device. This is
how you verify the placement **before a brand-new real ad unit has fill** — new
units commonly return **"no fill"** for hours to a couple of days.

- Test ads are **never billed** and generate **no revenue**.
- **Never click your own real (non-test) ads.** That's invalid traffic and can
  get your AdMob account suspended.

**Find your device's hashed test ID:** run the app once, then:

```bash
adb logcat | grep -i "OmniTermAds\|setTestDeviceIds"
```

Google logs a line like:
`Use RequestConfiguration.Builder().setTestDeviceIds(Arrays.asList("ABCDEF…"))`.
Copy that ID into `ADMOB_TEST_DEVICE_IDS` and rebuild.

**Diagnose a blank banner** by filtering logcat on tag **`OmniTermAds`**:

| `onAdFailedToLoad` code | Meaning | Fix |
|-------------------------|---------|-----|
| 0 | Internal error | Retry / check SDK version |
| 1 | Invalid request | Wrong ad unit ID, or app-ads.txt not set up |
| 2 | Network error | No connectivity / `INTERNET` permission |
| 3 | **No fill** | New unit, or no test device registered → register your device |

In **debug** Play Store builds, when ads can't render the app shows a small
on-screen placeholder (`[ads: …]`) so "no ad" is visibly distinct from "banner
not mounted." Release builds never show it.

---

## 4. app-ads.txt (required for full fill / no revenue throttling)

`app-ads.txt` authorizes Google to sell your ad inventory. Without it, demand is
filtered and you lose fill — another reason a live unit can look "broken."

It is **not part of the app**. It must be hosted at the **root** of the website
you list in the **Play Console → Store listing → Website** field. Google reads it
**only at the domain root** — a subpath (e.g. `…github.io/OmniTerm/app-ads.txt`)
will **not** work.

### Hosting it for free on GitHub Pages (custom domain)

This repo ships a ready `/docs` Pages site:

```
docs/
  app-ads.txt   ← edit the placeholder pub-ID
  CNAME         ← your custom domain
  index.html    ← minimal landing page
  .nojekyll
```

1. **Edit `docs/app-ads.txt`** — replace `pub-XXXXXXXXXXXXXXXX` with your AdMob
   publisher ID (AdMob → Account → Publisher ID). One line per ad network; add
   more lines if you onboard mediation partners.
2. **Edit `docs/CNAME`** — put your custom domain (e.g. `omniterm.app`). Delete
   this file if you are **not** using a custom domain.
3. **Point DNS** at GitHub Pages (in your domain registrar):
   - Apex domain → four `A` records: `185.199.108.153`, `185.199.109.153`,
     `185.199.110.153`, `185.199.111.153`
   - or `www`/subdomain → `CNAME` to `<user>.github.io`
4. **Enable Pages:** GitHub repo → Settings → Pages → Source = "Deploy from a
   branch", Branch = `main`, Folder = `/docs`. Then set your custom domain there
   and tick "Enforce HTTPS" once the cert provisions.
5. **Verify:** `https://YOUR-DOMAIN/app-ads.txt` returns the file. Put
   `https://YOUR-DOMAIN` in Play Console → Store listing → Website.
6. AdMob → Apps → app-ads.txt shows the crawl status (can take ~24h).

> Free GitHub accounts fully support Pages **and** custom domains. If you don't
> have a custom domain, a `<user>.github.io` **user/org** repo also serves
> `app-ads.txt` at its root — but a **project** page (this repo's
> `…/OmniTerm/`) does not, because Google ignores subpaths.

---

## 5. Who sees the banner

Only Play Store users who have **not** purchased ad removal or the full unlock.
Paying users never see it — the mount is gated on `licenseState.adsRemoved` in
`AppUi.kt`.
