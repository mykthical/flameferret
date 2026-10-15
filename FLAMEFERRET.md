# Flameferret

Flameferret is a personal fork of Firefox for iOS that adds browser extension support. It installs real
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

Flameferret has AdGuard's filtering engine built in — the same open-source pieces AdGuard uses in its own
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

## Using extensions

- **Menu → Extensions** opens the extensions screen. Tap an extension to open its popup or settings,
  use the switch to turn it off, or swipe to remove it.
- **Install from addons.mozilla.org:** choose *Browse Firefox Add-ons*, open an add-on, and tap
  *Download file*. Flameferret catches the `.xpi` and asks before installing.
- **Install from a link:** choose *Install from Link…* and paste an addons.mozilla.org page, a Chrome
  Web Store page, or a direct `.xpi`/`.crx` link.
- **Install from Files:** choose *Install from File…* and pick an `.xpi`, `.crx` or `.zip`.

Content scripts apply to pages loaded after installing, so reload open tabs.

## Getting the app onto your iPhone

### 1. Build the IPA (no Mac needed)

1. On GitHub, open this repository's **Actions** tab. Forks have Actions turned off by default, so click
   **I understand my workflows, go ahead and enable them**.
2. Choose **Build Flameferret** → **Run workflow**. The build takes roughly 40–90 minutes.
3. When it finishes, open the run and download the **Flameferret-ipa** artifact. Unzip it to get
   `Flameferret.ipa`.

If the build fails, download the **xcodebuild-log** artifact and look for lines containing `error:`.

### 2. Sideload it

Use [SideStore](https://sidestore.io), [AltStore](https://altstore.io) or Sideloadly with your Apple ID:

- **SideStore / AltStore:** open the app, tap **+** under My Apps, and pick `Flameferret.ipa`.
- **Sideloadly (Windows or Mac):** drag in `Flameferret.ipa`, enter your Apple ID and click Start.

With a free Apple ID the app expires after 7 days; SideStore and AltStore can refresh it
automatically. The widget, share sheet and notification extensions are left out of the IPA because
free accounts can only register a few App IDs. Push notifications and Firefox's credential-provider
autofill don't work in a sideloaded build either, since they need paid-account entitlements.

### Default browser

iOS only offers an app as the default browser if it's signed with Apple's
`com.apple.developer.web-browser` entitlement, which Apple grants on request to paid developer
accounts. A sideloaded build can't carry it, so Flameferret won't appear under
Settings → Apps → Default Browser App. If you have a paid account and Apple approves the
entitlement, sign the app with your own provisioning profile and it will appear there; the app
already handles http/https links.

Until then, open links in Flameferret with its URL scheme, for example from a Shortcut's
*Open URLs* action: `flameferret://open-url?url=https://example.com`.

### Building on a Mac instead

```shell
./scripts/flameferret-build-ipa.sh       # writes build/flameferret/Flameferret.ipa
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
- Unit tests: `firefox-ios/firefox-ios-tests/Tests/ClientTests/WebExtensions/`.
- Debug extension pages and content scripts with Safari's Web Inspector (Settings → Safari → Advanced →
  Web Inspector on the phone, then Develop menu on a Mac); background pages show up as separate pages.

Brand artwork lives in `branding/`: the app icon (`flameferret-icon.svg`), its iOS 26 Liquid Glass
layers (`glass-layers/`), and `tools/make_brand_assets.py`, which regenerates the in-app logos,
wordmark and illustrations. Interface text says "Flameferret" wherever translations say "Firefox"
(see `flameferretBranded` in `firefox-ios/Shared/Strings.swift`).
