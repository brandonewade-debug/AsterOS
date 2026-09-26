# AsterOS

A native iPhone and iPad companion for Unraid, by Asterline Labs. Development foundation 0.1.0; not a released app or replacement operating system.

## Open and run

1. On a Mac with Xcode 16.1+ and Go installed, run `bash scripts/bootstrap_tailnet.sh` (first build downloads pinned sources and Go 1.25.5).
2. Run `python3 scripts/generate_project.py`, then open `AsterOS.xcodeproj`.
3. Select AsterOS and an iPhone simulator, or your development signing team and physical iPhone.
4. Choose **Connect with Tailscale**, sign in and approve this AsterOS device in your existing tailnet, select the server and its HTTPS port, then return to **Sign in to Unraid**. No manual API key is required. Direct HTTPS/Unraid Connect addresses remain available.

Requires iOS/iPadOS 18.1+ (the embedded framework's minimum), Xcode, and Go. The bootstrap script pins libtailscale/TailscaleKit to `59d4bb82744915815178e0f0776d60026a397ee7` and SMBClient to `66eafaa6d17e034e8036dee4b3ebc1b52cb53919`. A small documented SMB patch injects per-client Network parameters without changing its server hostname or authentication. Frameworks/dependency worktrees are generated under ignored `.build/`; they are not committed.

On September 26, 2026, the embedded approach passed 13 simulator regression tests, an opt-in real-network check obtaining an official Tailscale login URL and HTTP 200 through the local SOCKS proxy, and a development-signed iPhone build. Live user-approved tailnet access, Unraid sign-in, SMB transfers and suspend/recovery remain to be validated. This is an experimental development build, not a TestFlight/App Store release.

### Simulator signing

Keep signing enabled when building for the simulator. Disabling it produces an app without the application-identifier entitlement and Keychain writes fail with error `-34018`. Ad-hoc simulator signing does not require a distribution certificate:

```sh
xcodebuild test -project AsterOS.xcodeproj -scheme AsterOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

Choose an installed simulator name. The hosted Keychain regression test saves, reads, updates, and removes only a randomly identified test credential. All 13 current XCTest checks passed locally with signing enabled.

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
- Files tab defaults to direct SMB shares, browsing, folder creation, foreground uploads and download sharing; the companion is optional.

## Important boundaries

Files connects directly to Unraid SMB shares using a separate share account stored in Keychain. Use the full Tailscale DNS name/IP through AsterOS Private connection, or a LAN address; HTTPS reverse proxies and Unraid Connect are not SMB tunnels. Root cannot access SMB shares. Direct uploads use a unique staging name and refuse to overwrite an existing destination; interrupted transfers must be restarted. The companion remains available as an optional Files connection with resumable uploads. Photos now offers user-started original-resource backup to a selected SMB share, with a latest-five-item test, persistent completion receipts, and foreground pause/retry. Automatic background backup, gallery/album management and Photos-library restoration remain future work. No app catalog, installs, updates, VM management, SSH, push notifications, biometric lock, relay, or automatic LAN/remote fallback is implemented. Companion storage is independent of the selected Unraid dashboard profile and clearly displays its own hostname. Only one companion connection is stored in this preview.

This initial browser uses ephemeral sessions: website logins are cleared when its WebKit session is released. Persistent isolated app sessions, downloads/uploads and external OAuth need implementation and device validation before release. Some providers disallow embedded login; use Open in Safari in this preview. Browser sessions never receive the Unraid API key.

HTTPS with valid certificates is required. No certificate bypass or broad cleartext transport exception is included. A VPN supplies reachability, not automatic certificate trust. API redirects are rejected to prevent key leakage. Cloudflare Access or another gateway may return HTML or block requests; this starter reports the problem and does not bypass it. Interactive gateway authentication is future work.

The Connect option accepts the **server's remote URL**, not `connect.myunraid.net` as an API server. It does not authenticate to the Unraid cloud account, discover servers, or tunnel Docker traffic. Custom app URLs must be reachable independently.

The current API schema was inspected as a reference, but features differ by installed API version. Compatibility must be verified against real server schemas; no broad version-support claim is made. For initial setup, create a scoped key on the server with read access to Info/Array/Docker and Metrics where supported. Add Docker update rights only if start/stop is desired. UI permission labels vary with API versions.

## Repository

The project belongs in the private `brandonewade-debug/AsterOS` repository. Open `AsterOS.xcodeproj` from the development branch to work on the foundation. Do not add server keys, certificates or signing keys. No code license is granted in this starter; choose the commercial licensing policy before making the repository public.

See `docs/PRODUCT.md` for the implementation roadmap and `docs/VALIDATION.md` for the validation status and release gates.


## Embedded private connection

Settings → Private connection joins the existing tailnet as an AsterOS-owned node. The separate Tailscale iOS application's configuration is not imported. This build links only the embedded Tailscale Go runtime; the previous WireGuard extension and sources are excluded from the generated project, retained only as historical source.

Only full `.ts.net` names and Tailscale IPv4/IPv6 ranges use the authenticated in-process SOCKS proxy. API requests, Unraid sign-in, Docker browser pages/icons and SMB connections use that route; public sites stay direct. TLS verification and API redirect blocking remain enabled. No companion, system VPN entitlement, Shortcuts automation, public tunnel or router forward is required. The Unraid server must already be on the tailnet, with access rules permitting this device and the required ports.

The app starts its saved node on launch. It deliberately does not stop on background/inactive transitions. iOS may suspend networking; foreground entry verifies the loopback listener and recreates the node using its existing identity if that listener has been reclaimed. API mutations are never automatically replayed. Active transfers may need restarting. Force-quitting ends the app-owned process; tailnet presence may take time to update. This is not a system-wide VPN.

State is kept in app-private Application Support, excluded from backup, with iOS file protection. API/share credentials remain in device-only Keychain. Explicit Tailscale sign-out calls the local logout API. See [embedded networking](docs/EMBEDDED_TAILSCALE.md) for routing, build and validation details.

## Photo backup preview

Connect a share account in Files, then open Photos → Load my Unraid shares → choose a writable share and backup folder → Allow Photos → Back up now. Start with Test latest 5 items before a full run. Nothing uploads until the user confirms a run. Keep the Photos screen open. Original photos/videos, Live Photo components and available edit resources are exported individually with PhotoKit and streamed to SMB. iCloud originals may require downloading and mobile data. Existing files are never overwritten or deleted; source photos are untouched. Completed asset folders carry a receipt written only after all resources have been acknowledged and size-checked on the server. Resume checks receipts/file sizes; incomplete existing resource files are byte-compared to the original before reuse. This is file backup, not an album-preserving one-tap restore or continuous background service.
