# AsterOS

A native iPhone and iPad companion for Unraid, by Asterline Labs. Development foundation 0.1.0; not a released app or replacement operating system.

## Open and run

1. Open `AsterOS.xcodeproj` on a Mac with Xcode 16 or newer.
2. Select the AsterOS scheme and an iPhone simulator, then Run.
3. Choose **Explore demo**, or supply your server's HTTPS address and Unraid API key.
4. For a physical device, set your signing team and a unique bundle identifier in the app target. The current identifier `com.asterlinelabs.asteros` is provisional; it is not registered by this project.

Requires iOS/iPadOS 17+. No third-party runtime dependencies. No credentials are included. This starter was authored on Linux without Swift/Xcode; it has not been compiled, simulator-tested, or device-tested. The included macOS CI workflow builds and runs the unit tests once pushed to GitHub with Actions enabled.

## Implemented source

- Dark SwiftUI layout inspired by the supplied reference screenshots, with native tabs, adaptive cards, and app launcher.
- Multiple saved server profiles; direct HTTPS URL and manually supplied Unraid Connect remote URL.
- Connection validation before saving. API keys in device-only Keychain; credentials are not stored in preferences.
- GraphQL overview: hostname, OS release, processor, array capacity and data disk temperatures/status.
- Optional CPU/memory utilization; errors isolated from the overview.
- Docker container list and confirmed start/stop actions. The key must have appropriate permissions.
- User-added HTTPS app shortcuts, including custom reverse proxy domains.
- In-app WebKit browser with bottom controls, back/forward, reload, Safari fallback, and close.
- Clearly labeled demo data; controls cannot mutate a server in demo mode.
- Refresh while foregrounded, pull-to-refresh, last successful timestamp, and visible errors.
- Unit-test source for address validation, capacity units and GraphQL error decoding.

## Important boundaries

Files and Photos are explicitly labeled future features, not functioning file/backup screens. No app catalog, installs, updates, VM management, SSH, push notifications, biometric lock, relay, or automatic LAN/remote fallback is implemented.

This initial browser uses ephemeral sessions: website logins are cleared when its WebKit session is released. Persistent isolated app sessions, downloads/uploads and external OAuth need implementation and device validation before release. Some providers disallow embedded login; use Open in Safari in this preview. Browser sessions never receive the Unraid API key.

HTTPS with valid certificates is required. No certificate bypass or broad cleartext transport exception is included. A VPN supplies reachability, not automatic certificate trust. API redirects are rejected to prevent key leakage. Cloudflare Access or another gateway may return HTML or block requests; this starter reports the problem and does not bypass it. Interactive gateway authentication is future work.

The Connect option accepts the **server's remote URL**, not `connect.myunraid.net` as an API server. It does not authenticate to the Unraid cloud account, discover servers, or tunnel Docker traffic. Custom app URLs must be reachable independently.

The current API schema was inspected as a reference, but features differ by installed API version. Compatibility must be verified against real server schemas; no broad version-support claim is made. For initial setup, create a scoped key on the server with read access to Info/Array/Docker and Metrics where supported. Add Docker update rights only if start/stop is desired. UI permission labels vary with API versions.

## Repository

The project belongs in the private `brandonewade-debug/AsterOS` repository. Open `AsterOS.xcodeproj` from the development branch to work on the foundation. Do not add server keys, certificates or signing keys. No code license is granted in this starter; choose the commercial licensing policy before making the repository public.

See `docs/PRODUCT.md` for the implementation roadmap and `docs/VALIDATION.md` for the validation status and release gates.
