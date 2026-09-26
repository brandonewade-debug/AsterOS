# AsterOS

A native iPhone and iPad companion for Unraid, by Asterline Labs. Development foundation 0.1.0; not a released app or replacement operating system.

## Open and run

1. Open `AsterOS.xcodeproj` on a Mac with Xcode 16 or newer.
2. Select the AsterOS scheme and an iPhone simulator, then Run.
3. Choose **Explore demo**, or enter your server's HTTPS address and choose **Sign in to Unraid**. Approve AsterOS to return the app credential automatically. Manual key entry is an optional fallback.
4. For a physical device, set your signing team and a unique bundle identifier in the app target. The current identifier `com.asterlinelabs.asteros` is provisional; it is not registered by this project.

Requires iOS/iPadOS 17+. No third-party runtime dependencies. No credentials are included. The initial iOS foundation built successfully on the development Mac with Xcode 26.6, and four XCTest checks passed on the iPhone 17 Pro simulator. The companion Files integration also compiled successfully and passed the same four checks. No physical-device or TestFlight release is claimed. The included macOS CI workflow builds and runs the unit tests once pushed to GitHub with Actions enabled.

### Simulator signing

Keep signing enabled when building for the simulator. Disabling it produces an app without the application-identifier entitlement and Keychain writes fail with error `-34018`. Ad-hoc simulator signing does not require a distribution certificate:

```sh
xcodebuild test -project AsterOS.xcodeproj -scheme AsterOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

Choose an installed simulator name. The hosted Keychain regression test saves, reads, updates, and removes only a randomly identified test credential. All nine XCTest checks passed locally with signing enabled.

## Implemented source

- Dark SwiftUI layout inspired by the supplied reference screenshots, with native tabs, adaptive cards, and app launcher.
- Multiple saved server profiles; direct HTTPS URL and manually supplied Unraid Connect remote URL.
- Unraid login and permission approval with automatic API-key capture, validated callback, and optional manual Safari fallback.
- Approved AsterOS logo and iOS app icon.
- Connection validation before saving. API keys in device-only Keychain; credentials are not stored in preferences.
- GraphQL overview: hostname, OS release, processor, array capacity and data disk temperatures/status.
- Optional CPU/memory utilization; errors isolated from the overview.
- Docker container list and confirmed start/stop actions. The key must have appropriate permissions.
- User-added HTTPS app shortcuts, including custom reverse proxy domains.
- In-app WebKit browser with bottom controls, back/forward, reload, Safari fallback, and close.
- Clearly labeled demo data; controls cannot mutate a server in demo mode.
- Refresh while foregrounded, pull-to-refresh, last successful timestamp, and visible errors.
- Unit tests for address validation, capacity units and GraphQL error decoding.
- Companion container and 17 Python tests covering pairing, scoped files, resumable uploads and security boundaries.
- Files tab with companion pairing, browsing, folder creation, foreground uploads and download sharing.

## Important boundaries

Files now connects to the separately deployed companion for pairing, browsing, folder creation, foreground resumable uploads and file downloads. Photos remains a clearly labeled future feature. No app catalog, installs, updates, VM management, SSH, push notifications, biometric lock, relay, or automatic LAN/remote fallback is implemented. Companion storage is independent of the selected Unraid dashboard profile and clearly displays its own hostname. Only one companion connection is stored in this preview.

This initial browser uses ephemeral sessions: website logins are cleared when its WebKit session is released. Persistent isolated app sessions, downloads/uploads and external OAuth need implementation and device validation before release. Some providers disallow embedded login; use Open in Safari in this preview. Browser sessions never receive the Unraid API key.

HTTPS with valid certificates is required. No certificate bypass or broad cleartext transport exception is included. A VPN supplies reachability, not automatic certificate trust. API redirects are rejected to prevent key leakage. Cloudflare Access or another gateway may return HTML or block requests; this starter reports the problem and does not bypass it. Interactive gateway authentication is future work.

The Connect option accepts the **server's remote URL**, not `connect.myunraid.net` as an API server. It does not authenticate to the Unraid cloud account, discover servers, or tunnel Docker traffic. Custom app URLs must be reachable independently.

The current API schema was inspected as a reference, but features differ by installed API version. Compatibility must be verified against real server schemas; no broad version-support claim is made. For initial setup, create a scoped key on the server with read access to Info/Array/Docker and Metrics where supported. Add Docker update rights only if start/stop is desired. UI permission labels vary with API versions.

## Repository

The project belongs in the private `brandonewade-debug/AsterOS` repository. Open `AsterOS.xcodeproj` from the development branch to work on the foundation. Do not add server keys, certificates or signing keys. No code license is granted in this starter; choose the commercial licensing policy before making the repository public.

See `docs/PRODUCT.md` for the implementation roadmap and `docs/VALIDATION.md` for the validation status and release gates.
