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

HTTPS with valid certificates is the default. Local-only users can explicitly approve HTTP for one private IPv4 address and port in connection setup. This consent is remembered on the device; HTTP sends credentials and data without transport encryption. Public HTTP and certificate bypass remain blocked. A VPN supplies reachability, not automatic certificate trust. API redirects are rejected to prevent key leakage. Cloudflare Access or another gateway may return HTML or block requests; this starter reports the problem and does not bypass it. Interactive gateway authentication is future work.

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

New photo backups default to `Photos/Year/Month/2026-09-26 16-31-00 [short ID]-0-IMG_1624.HEIC`, with all media directly inside the month. Photos → Organize by optionally adds a day folder. Settings apply to new items; completed and interrupted items are found in either layout, and legacy hash folders are recognized in place. Resources share an asset ID; resource indices avoid name collisions. Hidden per-asset JSON receipts sit alongside the media. The backup timezone is pinned on first use to keep paths stable when travelling. Items without capture dates use `Unknown date`. No existing backups are moved or deleted. This is an AsterOS organization convention; no Plex scanner/format compatibility certification is implied.

Standalone videos use `Videos/Year/Month` (plus optional day). Live Photo motion and edit resources stay with the image under Photos. New organization applies to new assets; completed or interrupted assets in previous mixed folders are found and reused in place. A local checkpoint remembers completed/total counts across app restarts; server receipts are authoritative for skipping uploads, so losing the local counter does not trigger duplicate uploads. Tap Back up now to resume after restarting. Completed files are validated against their stored sizes; incomplete resources without a receipt are byte-compared before reuse. Edited assets have a new version identity and are backed up as a new copy. An interrupted partial resource may need to restart; completed resources are retained. No existing library migration is performed.

## Docker app launch addresses

Tapping a container uses its configured Unraid WebUI automatically. Both HTTP and HTTPS web apps are supported; API access and API-key authorization use HTTPS by default, with explicit per-origin HTTP consent available for RFC1918 IPv4 servers. Unraid labels with `[IP]` and `[PORT:n]` are expanded using the selected server address and Docker TCP port mappings, so server-published apps can use the same private Tailscale host with their own port. Containers on br0/eth0 retain their own container IP and require a reachable LAN route. Explicit domains are preserved. App details show the resolved address and an optional HTTPS external override, with a Use Unraid WebUI instead action. No port scanning, certificate bypass or API credential forwarding to app pages is used. The web-content-only ATS exception allows user-configured HTTP container WebUIs; it does not relax URLSession API connections.

## Interface and app folders

The interface uses open sections, rounded controls and native Liquid Glass on iOS 26, with material fallback on iOS 18 and opaque surfaces for Reduce Transparency/Increased Contrast. Apps → + → New folder creates a per-server folder. Touch and hold an app → Move to folder to organize it; Move out of folder returns it to the main grid. Folder menus rename or remove folders; removing a folder only changes organization, never stops or deletes containers. Membership uses container names so Docker container-ID changes after updates do not lose the arrangement. Renaming a container requires assigning its new name again. Saved external shortcuts can also be grouped.

## Install and remove containers

The App Store icon in Apps opens native catalog browsing, with access to the selected server's Community Applications page over the same private connection. It uses the server's own login, templates, settings and installation confirmation; a server web login may be required. AsterOS does not scrape credentials or forward its API key into the browser. Community Applications must be available on that Unraid server. Closing App Store refreshes the Docker list. This is an integrated WebGUI installer, not a native GraphQL catalog/install API (the published schema does not expose container creation).

Long-press a container → Remove container opens a confirmation explaining that its writable layer is deleted and running work is interrupted. The native API request specifies `withImage: false`; mounted shares, appdata and volumes are not deleted. Requires Docker delete permission. AsterOS never automatically retries destructive requests. No real server containers were created or removed during development verification.

## Native catalog browsing

App Store is a launcher icon in Apps, not a segmented tab. Its SwiftUI catalog, search, category filter and detail screens read Docker-card metadata from the selected server's authenticated Community Applications page. This is a version-sensitive adapter for CA card markup, not a supported GraphQL catalog API. The bridge only runs on the selected server's exact Apps route and exports card metadata, not login fields, cookies or tokens. Search uses the server's own search function; next/previous preserve its pagination and moderation. Category filtering applies to the loaded page.

A server login is still required when the web session expires. The final Review installation action opens the server's own information/requirements and install interface; it does not submit an installation automatically. If the plugin markup changes, Open server view remains available. This release provides native discovery/details, not a native container configuration/install form. The adapter is validated with a WebKit fixture; live server compatibility still needs user verification.

### Native container configuration

Edit container opens a SwiftUI AsterOS configuration screen directly. Installation also switches to this screen when Unraid opens its container template. Basic/Advanced follows the server template; native controls cover configuration values, networking, CPU selections and paths/ports/variables, including the server's add/edit/remove configuration dialogs. Host paths can be entered as text. Leaving an unapplied form asks before discarding it.

The authenticated WebGUI form stays behind the scenes as a version-sensitive adapter. AsterOS retains hidden CSRF/template metadata there and explicitly submits the original form only after Apply/Install confirmation, preserving Unraid's validation and preparation logic. Configuration secrets remain in memory, are masked for password fields, and are not written to the catalog cache. Server sign-in and Community Applications requirements may still use the server view. Response completion alone is not treated as proof that Docker recreation succeeded; check the refreshed container after applying, especially after a timeout. No automatic POST retries occur.

Validation: 38 simulator tests passed, including a WebKit fixture checking secret isolation, native field updates, item dialog handling, required-field validation and explicit-only submission. Development-signed iPhone build succeeded. Real container recreation was not performed during automated validation.

### Terminal and Desktop Commander

Settings → Server tools offers one in-app Terminal. Its options menu enables Desktop Commander controls in the same session. The terminal restores the selected server's existing WebGUI session and use the embedded Tailscale route. Unraid administrator login may be required if that session expired. Terminal chrome and shortcut controls are native; the terminal renderer is Unraid's authenticated ttyd/xterm surface. No new companion, SSH password or public endpoint is required.

Desktop Commander Start reuses the managed installation in `/mnt/user/appdata/asteros/desktop-commander`, or an existing `desktop-commander` executable on PATH. Only when neither is available does it install pinned package `@wonderwhy-er/desktop-commander@0.2.51` into appdata using npm. Successful installation is marked only after npm succeeds and the entrypoint exists. Later starts invoke the saved entrypoint with `remote` directly, without npm/npx or an update check. Node.js is required; npm is needed only for installation. The appdata share must be available. Failed installs release their installation lock for retry; a lock left by abrupt process termination requires inspection before retrying. The user completes Desktop Commander's account pairing using its terminal link/code. Start is only sent to a live terminal showing a shell prompt. Stop sends Ctrl+C to this terminal's foreground process. A wrapper emits scoped start/exit markers, and status distinguishes requested, starting, device ready, stop requested, exited and unknown. It never performs process-name kills or stops agents started elsewhere. The agent runs inside the terminal session, not an installed boot service. AsterOS retains that terminal while the app process remains alive. When tmux is available, the server session survives transport loss; without tmux, iOS suspension can still end the connection and foreground processes. Wait for Agent exited after Stop to verify the foreground agent stopped. No real remote agent was started during validation.

### Optional app security

Settings → Security → App security enables a six-digit PIN, then optional Face ID/Touch ID on supported devices. It is off by default. The app locks on launch/background; inactive scenes display a privacy shield. A separate scene window covers presented sheets and browsers while the root is hidden from interaction/accessibility. PIN changes and disabling the lock require the current PIN; biometrics use Apple's biometric-only policy with PIN fallback and biometric-enrollment change detection.

A random 32-byte salt and PBKDF2-HMAC-SHA256 verifier (200,000 rounds) are stored in this-device-only, when-unlocked Keychain alongside retry state. Failed PIN attempts introduce persisted exponential delays beginning at five failures. Keychain errors fail closed. No PIN plaintext is saved. This is a local app access lock; it does not replace server authentication or encrypt server storage. Remember the PIN: no email reset is implemented.

Validation: 45 simulator tests passed, including PIN lifecycle/rate-limiting/storage failures, separate security-window ordering, origin checks and terminal bridge controls. A stub-agent shell check verified Ctrl+C exit markers without contacting Desktop Commander. Development-signed iPhone build succeeded with the Face ID permission description. Physical biometric enrollment and live Unraid terminal/agent operation remain user acceptance checks.

Desktop Commander reconnect regression: `python3 scripts/verify_commander_reuse.py` runs the actual shell template with stub executables to verify first install, repeated starts without npm, failed-install handling and reuse of an existing global installation. It never downloads or connects a real agent. All 45 simulator tests and the signed iPhone build passed.

Terminal presentation now uses a device-width viewport, adjustable 12–24 point monospace text (15 by default), a matching app/terminal background, and a glass terminal-key strip. The tab bar is hidden on this screen. Font changes and keyboard/viewport resizing refit xterm without sending commands or replacing its input/scrollback engine. Empty WebKit frames are allowed without a false navigation warning; remote terminal navigation remains restricted to the selected HTTPS origin. Terminal → options → Desktop Commander shows Start/Stop/status in the same session. Pairing and installation output stay visible there.

Validation: 46 simulator tests passed, including mobile viewport/theme/font updates with ANSI-color preservation and no terminal input from styling. Signed iPhone build succeeded.

### Returning to a terminal

A per-server in-memory session registry retains WebKit and the terminal model when navigating away or backgrounding AsterOS. Observation pauses; the connection is not explicitly destroyed. Returning restores the private route and reloads a dead transport only when needed, without replaying commands or automatically starting another Desktop Commander agent. Removing a server clears its retained client.

On each fresh terminal transport, AsterOS waits for the shell prompt and attempts to attach/create a uniquely named session in a separate tmux server socket. Session IDs remain stable for the lifetime of the app model. When tmux is available, working directory, running programs and terminal history stay on Unraid through a client disconnect. When unavailable or session creation fails, the app displays the prerequisite and retains the ordinary terminal as far as iOS allows. Force-quitting is not a reliable remote stop signal; server sessions can remain alive until exited/stopped or the server reboots. No tmux package was installed during this change.

Validation: 48 simulator tests passed, including retained-model identity, cleanup and one attach per transport without replaying Desktop Commander commands. Signed iPhone build succeeded. Live tmux capability could not be verified: the Unraid Desktop Commander request timed out and read-only SSH with available keys was denied. Live background/reattach validation remains dependent on that server capability.

### Seafile files and photo backup

In Files, choose **Seafile → Connect Seafile**, enter the server HTTPS address, and sign in (including a two-factor code when enabled). An existing Seafile account API token can be used instead. Browse libraries, download/share files, upload files, and create folders. In Photos, select **Seafile**, load libraries, and choose a writable library and backup folder. The date-based layout, separate Photos/Videos folders, Live Photo resources, saved progress, and upload verification are retained. Existing SMB destinations stay saved separately.

This version supports unencrypted libraries and same-origin file-server URLs. It does not migrate existing SMB backups into Seafile automatically. Optional HTTP on a private home-network IP requires explicit consent and cannot use cellular. No direct writes to Seafile’s internal storage folders are made.
