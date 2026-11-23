# Palisade

A small, hardened web browser for macOS. It is a native Swift app on the system
WebKit engine, with a strict policy layer and the App Sandbox around it.

Palisade does not implement its own rendering engine. Page rendering, JavaScript
and TLS are Apple's WebKit, so engine security is whatever your macOS version
ships. What this project adds is the browser around the engine.

## What it enforces

- **HTTPS only.** Plain HTTP is upgraded, or refused if the site has no HTTPS.
  Localhost is exempt, and you can allow one site per session from the shield menu.
- **No certificate click-through.** An invalid certificate stops the page.
- **Tracker blocking.** 81 well-known tracker and ad domains are blocked as
  third parties, and third-party cookies are refused.
- **Tracking parameters stripped.** `utm_*`, `gclid`, `fbclid` and similar are
  removed from addresses.
- **Memory-only storage.** Cookies, cache and site data never touch disk.
  "Burn session" closes every tab and replaces the data store.
- **Dangerous schemes refused.** `file:`, `javascript:`, top-level `data:` and
  links that launch other apps do nothing.
- **Permissions denied.** Camera, microphone and location are never granted.
  Script-opened pop-ups are blocked.
- **App Sandbox and hardened runtime.** The app can only read or write a file
  you pick in an open or save panel.
- **Per-site JavaScript switch** in the shield menu.

## Limits

- The blocklist is tiny next to lists like EasyList.
- No bookmarks, history, password manager, find-in-page or extensions. Logins
  end when you quit.
- The build is ad-hoc signed and not notarized, so it runs on the Mac that built it.
- This has not had a security audit.

## Build and run

Requires macOS 13 or later and the Xcode command line tools.

```bash
./build.sh
open build/Palisade.app
```

Run the self-test, which drives a headless tab through each protection (the
live checks need network access):

```bash
./build/Palisade.app/Contents/MacOS/Palisade --selftest
```

## Layout

- `Sources/NavigationPolicy.swift`: address parsing and the single function that
  decides every navigation.
- `Sources/Blocklist.swift`: the tracker domain list and content rules.
- `Sources/BrowserSession.swift`: the in-memory session and WebKit configuration.
- `Sources/BrowserWindowController.swift`: one tab's window, toolbar and delegates.
- `Sources/SelfTest.swift`: the `--selftest` checks.
- `Resources/Palisade.entitlements`: the sandbox entitlements.
