# Ferret

Ferret (formerly Flameferret) is a personal fork of Firefox for iOS that adds browser extension support. It installs real
Firefox (`.xpi`) and Chrome (`.crx`) extension packages and runs them on top of WebKit.

It is not affiliated with or endorsed by Mozilla. "Firefox" is a trademark of the Mozilla Foundation;
this build is renamed so it can't be confused with the real app and can be installed next to it.

## What works and what doesn't

iOS requires every browser to use WebKit, so extensions run through WebKit's APIs rather than Firefox's
Gecko engine. That covers most everyday extensions, but not all of them.

| Works | Partly works | Doesn't work |
| --- | --- | --- |
| Content scripts and CSS (all frames, `run_at`, match patterns, globs) | `declarativeNetRequest` (block, allow, upgrade; no redirect or header edits) | `webRequest` blocking or observing |
| `storage.local` / `sync` / `session` with `onChanged` | `tabs` (no pinning, moving or muting) | `nativeMessaging`, `proxy`, `devtools` |
| `runtime` messaging and ports, `onInstalled`, `getURL` | `windows` (one window per scene) | Sidebars, themes, toolbar icon badges |
| Background pages and MV3 service workers (run as a page) | `cookies` (default store) | `history` and `bookmarks` (empty results) |
| Popups and options pages | `notifications` (shown as iOS notifications) | Context menu items |
| `scripting.executeScript`, `insertCSS`, `registerContentScripts` | `webNavigation` (main-frame events) | |
| `i18n`, `alarms`, `permissions`, `action` badge text | | |
| Cross-origin `fetch` from extension pages (host permissions) | | |

Good candidates: uBlock Origin Lite, Dark Reader, SponsorBlock, Return YouTube Dislike, userscript
managers, translation and dictionary popups, simple page tweakers. Full uBlock Origin (not Lite)
depends on `webRequest`, so use uBlock Origin Lite instead.

## Built-in ad blocking (AdGuard)

Ferret has AdGuard's filtering engine built in — the same open-source pieces AdGuard uses in its own
Safari and iOS apps — so ad blocking doesn't depend on an extension. Open **Menu → Extensions →
AdGuard Ad Blocking** to:

- turn blocking on or off, and update filter lists (they also update automatically once a day);
- choose filter lists: AdGuard Base, Mobile Ads, Tracking Protection, Social Media, Cookie Notices,
  Popups, Mobile App Banners, Other Annoyances and Widgets, or add any list by URL;
- turn blocking off for the site you're on, or manage the list of sites that aren't blocked;
- write your own rules in AdGuard syntax.

How it works: network and simple element-hiding rules are compiled into WebKit content blockers.
Scriptlets, script rules and Extended CSS (`#?#`, `#%#`, `#$#`) are looked up per page with AdGuard's
`FilterEngine`. For the main page they're installed before the page starts loading, so scriptlets run
ahead of the site's own code and aren't affected by its Content Security Policy; frames get theirs as
soon as they start. A few rule types have no WebKit equivalent and are skipped — mainly `$redirect`,
`$removeparam`, `$csp`, `$replace`, header changes and HTML filtering — which is the same limit every
Safari ad blocker has.

AdGuard's libraries are licensed under GPL-3.0 (`SafariConverterLib`, `@adguard/safari-extension`,
`@adguard/scriptlets`, `@adguard/extended-css`). The JavaScript bundles are built from
`firefox-ios/AdGuardJS` with `./scripts/flameferret-build-adguard-js.sh`.

## PIN lock and encryption

**Settings → Privacy → Passcode & Data Protection**

- **Require PIN:** a 6-digit PIN to open Ferret, with optional Face ID or Touch ID. You choose
  whether it locks immediately or after 1, 5, 15 or 60 minutes away, and there's a *Lock Now* button.
  The lock screen covers every window and also hides your tabs in the app switcher.
- **Wrong PINs:** after 5 wrong tries you wait 30 seconds, then 1, 5, 15 and 60 minutes for each
  further miss. The wait survives restarting the app. Data is never erased.
- **Forgotten PIN:** there's no recovery; delete and reinstall the app (this erases its data).
- **Protect Data While Locked** (on by default): moves everything Ferret stores — history, tabs,
  cookies and website data, saved passwords, extensions and ad-blocking data — to iOS's strongest
  practical encryption class. Files are encrypted with a key that's discarded shortly after your iPhone
  locks, so they can't be read without your device passcode. Files already open, such as active
  downloads, keep working in the background.

The PIN is never stored. Ferret keeps a salted PBKDF2-SHA256 hash (200,000 rounds) in the
Keychain, readable only on this device while it's unlocked.

- **Hide Content in App Switcher** (on by default): covers your tabs whenever Ferret leaves the
  foreground, even without a PIN, so the app switcher and iOS's saved snapshot show nothing.
- **Always Use HTTPS** (on by default): every `http://` page load is upgraded to `https://`. If a site
  can't do a secure connection, or redirects back to `http://`, Ferret uses `http://` for that site
  until you quit. Local addresses (routers, printers, `localhost`) are left alone.

**Private by default.** On a fresh install Ferret turns off everything that sends data off the device
on its own: usage data, daily usage pings, crash reports and studies (to Mozilla), search suggestions
(each keystroke to the search engine) and sponsored suggestions. Tracking protection starts on
**Strict**. These are set once, so you can turn any of them back on in Settings.

What can't be done on iOS: Safari's engine handles DNS itself, so there's no per-app DNS-over-HTTPS
(turn on the NordVPN proxy to keep lookups away from your network), and screenshots can't be blocked.

## NordVPN proxy (Ferret only, no system VPN)

Settings → Privacy → **NordVPN Proxy** sends Ferret's tabs (normal and private) and extension pages
through NordVPN's encrypted HTTPS proxy servers, the same ones the NordVPN browser extension uses on desktop.
The rest of your iPhone keeps its normal connection. Requires iOS 17 or later and a NordVPN subscription.

1. Get your **service credentials** at my.nordaccount.com → NordVPN → Set up NordVPN manually →
   Service credentials. They are not your NordVPN email and password.
2. Paste them into Ferret, turn the proxy on, and pick a country (or leave it on Fastest Available).
   After choosing a country you can narrow it to a region (state or province) and a city. Only places
   where NordVPN has proxy servers are listed, and Ferret uses the least busy server there.
3. Tap **Check Connection** to confirm NordVPN sees the traffic as protected.

When the proxy is on but can't be used (missing credentials, no server yet), pages don't load rather than
going out directly. Credentials are kept in the Keychain on this device only. Ferret's own background
requests (search suggestions, ad-block filter updates, favicons, Sync) still use the normal connection.

## Icons and color themes

Settings → General → **Color Theme** restyles the whole app (light and dark mode, private browsing,
Ferret's own screens) in one of six themes: **Classic**, **Sunflower** (inspired by Ukraine: flag blue
with sunflower yellow), **Midnight Gold**, **Oxblood**, **Field Green** and **Monochrome**. Picking a theme
also switches the home screen icon to match, unless you turn that off. Settings → General → **App Icon**
lets you choose any of the six icons on its own.

The icons are drawn by `branding/tools/icons/` (`python3 variants.py` writes light, dark and tinted
versions) and the theme colors come from `branding/tools/make_theme_palettes.py`, which builds each
theme's color scales from the Classic theme's lightness steps so contrast stays the same.

## Using extensions

- **Menu → Extensions** opens the extensions screen. Tap an extension to open its popup or settings,
  use the switch to turn it off, or swipe to remove it.
- **Install from addons.mozilla.org:** choose *Browse Firefox Add-ons*, open an add-on, and tap
  *Download file*. Ferret catches the `.xpi` and asks before installing.
- **Install from a link:** choose *Install from Link…* and paste an addons.mozilla.org page, a Chrome
  Web Store page, or a direct `.xpi`/`.crx` link.
- **Install from Files:** choose *Install from File…* and pick an `.xpi`, `.crx` or `.zip`.

Content scripts apply to pages loaded after installing, so reload open tabs.

### Compatibility labels on addons.mozilla.org

When you browse addons.mozilla.org in Ferret, every add-on gets a label: **Works in Ferret**, **Partly works
in Ferret**, **Won't work in Ferret**, or **Not available in Ferret** (themes, dictionaries, language packs).
Each add-on's page also shows the reasons, such as "Its right-click menu items won't appear". The verdict comes
from the permissions the store lists for the add-on, compared with what Ferret's extension engine supports,
so treat it as a strong hint rather than a guarantee.

## Getting the app onto your iPhone

### 1. Build the IPA (no Mac needed)

1. On GitHub, open this repository's **Actions** tab. Forks have Actions turned off by default, so click
   **I understand my workflows, go ahead and enable them**.
2. Choose **Build Ferret** → **Run workflow**. The build takes roughly 40–90 minutes.
3. When it finishes, open the run and download the **Ferret-ipa** artifact. Unzip it to get
   `Ferret.ipa`.

If the build fails, download the **xcodebuild-log** artifact and look for lines containing `error:`.

### 2. Sideload it

Use [SideStore](https://sidestore.io), [AltStore](https://altstore.io) or Sideloadly with your Apple ID:

- **SideStore / AltStore:** open the app, tap **+** under My Apps, and pick `Ferret.ipa`.
- **Sideloadly (Windows or Mac):** drag in `Ferret.ipa`, enter your Apple ID and click Start.

With a free Apple ID the app expires after 7 days; SideStore and AltStore can refresh it
automatically. The widget, share sheet and notification extensions are left out of the IPA because
free accounts can only register a few App IDs. Push notifications and Firefox's credential-provider
autofill don't work in a sideloaded build either, since they need paid-account entitlements.

### Default browser

iOS only offers an app as the default browser if it's signed with Apple's
`com.apple.developer.web-browser` entitlement, which Apple grants on request to paid developer
accounts. A sideloaded build can't carry it, so Ferret won't appear under
Settings → Apps → Default Browser App. If you have a paid account and Apple approves the
entitlement, sign the app with your own provisioning profile and it will appear there; the app
already handles http/https links.

Until then, open links in Ferret with its URL scheme, for example from a Shortcut's
*Open URLs* action: `ferret://open-url?url=https://example.com`.

### Building on a Mac instead

```shell
./scripts/flameferret-build-ipa.sh       # writes build/flameferret/Ferret.ipa
```

Or open `firefox-ios/Client.xcodeproj`, choose the **Fennec** scheme, set your own team under
*Signing & Capabilities* for the Client target, and run on your device. The bundle ID is
`com.mykthical.flameferret`; change `MOZ_BUNDLE_ID` in `firefox-ios/Client/Configuration/Fennec.xcconfig`
if Xcode says it's taken.

## For developers

- Extension engine: `firefox-ios/Client/Frontend/Browser/WebExtensions/`
  - `WebExtensionManager.swift` — loads extensions, injects scripts and rule lists into tabs
  - `WebExtensionManager+API.swift` — native side of every `browser.*` call
  - `WebExtensionDNRConverter.swift` — `declarativeNetRequest` → WebKit content-blocker rules
  - `WebExtensionArchive.swift` — `.xpi`/`.crx`/`.zip` reader
- The JavaScript `browser`/`chrome` runtime lives in `firefox-ios/WebExtensionsJS/webextension-api.js`.
  After editing it, run `python3 scripts/flameferret-embed-js.py` to regenerate
  `WebExtensionAPISource.swift`.
- AdGuard integration: `firefox-ios/Client/Frontend/Browser/AdGuard/` (`AdGuardManager.swift` applies
  rules to tabs, `AdGuardCompiler.swift` converts filter lists).
- PIN lock and data protection: `firefox-ios/Client/Frontend/Browser/AppLock/`.
- Unit tests: `firefox-ios/firefox-ios-tests/Tests/ClientTests/WebExtensions/`.
- Debug extension pages and content scripts with Safari's Web Inspector (Settings → Safari → Advanced →
  Web Inspector on the phone, then Develop menu on a Mac); background pages show up as separate pages.

Brand artwork lives in `branding/`: the app icon in light and dark (`ferret-icon.svg`,
`ferret-icon-dark.svg`), the globe logo (`ferret-logo.png`, `ferret-logo-dark.png`), and
`tools/make_brand_assets.py`, which regenerates the in-app logos, wordmark and illustrations with
dark-mode variants. Interface text says "Ferret" wherever translations say "Firefox"
(see `flameferretBranded` in `firefox-ios/Shared/Strings.swift`).
