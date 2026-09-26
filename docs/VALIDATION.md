# Validation status

## This environment

Linux; no Swift compiler, Xcode, iOS SDK, simulator, Apple signing credentials or connected Unraid test endpoint. No successful build, executed XCTest run, live API test or visual simulator verification is claimed.

Source review checks include: HTTPS-only saved addresses; user-info/query/fragment rejection; Keychain-only API key storage; rejecting API redirects; no API key injection into WebKit; capacities use kilobytes rather than disk counts; generation guards against a previous server's async results populating a new profile; sample mode disables writes.

## First CI attempt

The GitHub Actions job for commit `dfe1fb839edd978131d6f1b5747ed76fe29bf715` failed before any job steps were reported. The job-log endpoint returned no available log. The reason is unconfirmed; no compiler or XCTest outcome is available. Inspect the workflow annotation in GitHub before retrying.

Run: https://github.com/brandonewade-debug/AsterOS/actions/runs/36259461034

## Local Mac validation, 2026-09-26

The initial foundation compiled with Xcode 26.6 (17F113) on the development Mac. Four XCTest checks passed on the iPhone 17 Pro simulator running iOS 26.5. The companion Files integration also compiled and passed those four XCTest checks. Seventeen companion tests passed in the Python environment. No physical iPhone or TestFlight upload has occurred.

## Before internal TestFlight

- Run the included GitHub Actions workflow or Xcode Product → Test; resolve compiler/test failures.
- Run on iPhone and iPad; check Dynamic Type, VoiceOver, rotation, keyboard and sheet dismissal.
- Connect to an isolated test server before a production server. Test scoped read-only and Docker-update keys, expiry/revocation, unsupported metrics and Docker disabled.
- Validate custom-domain and Unraid Connect remote URL behavior on supported Unraid/API versions.
- Validate redirects, certificate errors, HTML gateway pages, offline state, scene backgrounding, slow networks, profile switching during requests and action responses after server changes.
- Run a full app-browser login sequence including redirects; test an embedded-login-blocking provider and Safari fallback. This preview clears web sessions on close.
- Confirm start/stop only affects the selected container on the selected server; stale data and unknown outcomes must remain visible.
- Finalize launch assets, bundle ID, signing, privacy policy/support URL and App Store privacy answers. The approved app icon is now included.

## Before paid release

Complete the core features, capability negotiation, onboarding, security review and version/device matrix. Validate backup restoration and interrupted-transfer recovery before marketing backup reliability. Confirm name availability and any Unraid branding/integration requirements. No commercial-readiness claim should be based solely on this starter.

## Installed companion validation

The companion image built on Unraid 7.2.2 and Docker 27.5.1. The container reports healthy, runs as 99:100 with a read-only root, and restarts unless stopped. Its live HTTP smoke test passed device pairing, folder creation, a two-chunk upload with resume offset verification, SHA-256 completion and exact-content download. The temporary test device was revoked afterwards.

The deployment uses a dedicated AsterOS storage folder, 10 GiB free-space reserve, 1 GiB per-file test limit, localhost-only port 8790 and Tailscale Serve HTTPS on port 8791. No router forwarding or public domain route was added. TLS health verification succeeded with explicit address resolution; normal DNS lookup from the server did not resolve its tailnet hostname. End-to-end phone pairing over Tailscale remains to be validated.

## Sign-in and branding update, 2026-09-26

Xcode 26.6 built the updated app and all seven XCTest checks passed on iPhone 17 Pro / iOS 26.5. New tests cover callback origin/port/state/expiry, duplicate parameters, read-only default scopes, manual Safari fallback URLs, and redaction of sensitive redirect URL data. The approved AsterOS emblem is included in the asset catalog as the 1024-pixel iOS app icon and onboarding brand mark.

The development Mac reached the server directly over LAN HTTPS with a trusted certificate and received a GraphQL authentication response. The public domain's 302 was traced to Organizr middleware in Nginx. Interactive Unraid sign-in, automatic callback delivery, and authenticated dashboard loading still need the owner's end-to-end test; no API key or password was extracted from the screenshot. Cloudflare and Organizr policies were not changed.

### Post-login return correction

The owner confirmed password sign-in succeeds but Unraid 7.2.2 lands on Main, discarding the authorization request. The app now resumes consent once after a same-origin Main/Dashboard landing and includes Continue to approval. All eight XCTest checks passed on the development simulator, including the landing-origin regression test. Full approval-to-dashboard completion remains an owner test.

### Docker management authorization

At the owner's request, Manage Docker is selected in onboarding and adds explicit Docker read/create/update/delete scopes to Viewer monitoring. Full administrator access is not requested. Turning the switch off requests Viewer alone. Existing issued keys are unchanged. Native container installation/removal controls remain unimplemented. The scope assertion and all eight XCTest checks passed. Main-page authorization resumption now triggers at navigation commit instead of waiting for streamed resources to finish; the manual Continue button stays available during loading.

## Simulator Keychain fix, 2026-09-26

The owner completed Unraid login, approval, and the authenticated overview request, but saving failed. Simulator securityd reported AsterOS SecItemAdd error -34018: missing application-identifier/keychain-access-groups entitlements. A new hosted Keychain round-trip test reproduced this with CODE_SIGNING_ALLOWED=NO. Rebuilding with CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- supplied the simulator signing identity and all nine tests passed, including save/read/update/delete. CI now uses the same signing flags. No plaintext credential fallback was introduced. The correctly signed build was installed into the development simulator; the owner's final connection retry remains to be observed.


## Direct Files and VPN setup — 2026-09-26

- Signed iPhone 17 Pro simulator build passes 11 XCTest checks, including Keychain lifecycle, SMB address validation and filename traversal prevention.
- Direct Files uses SMBClient pinned to 66eafaa6d17e034e8036dee4b3ebc1b52cb53919, with its MIT license bundled. Debug builds now use the active architecture consistently with Swift packages.
- Share credentials are separate from API credentials, per selected server. No root password reuse. No plaintext secrets in defaults.
- Browse shares/directories, create folders, stream downloads to temporary storage and upload through a unique staging file. Rename refuses overwrites. Temporary downloads are removed after sharing. Interrupted uploads can leave a hidden staging file on the share and must be restarted.
- SMB 2.x transport requires a trusted LAN or VPN; this is not an SMB3 encryption implementation. Network session signing is requested. Server permissions remain authoritative.
- Live authenticated file transfers and on-device VPN automation have NOT been validated; a user share account and physical iPhone are required. This is a development preview.
- Settings → VPN automation describes Tailscale Connect/Disconnect personal automations and opens Shortcuts. It does not install automations, imply VPN state, or control another app’s tunnel. Switching away triggers the close automation and can interrupt transfers or other apps using Tailscale.
- Cloudflare tunnel idea cancelled by user before any Cloudflare changes.


## Native VPN — 2026-09-26

- Complete signed simulator app + embedded VPN extension built and 14 XCTest checks passed. Native split-route parser tests cover valid import, public/default routes, invalid prefixes, duplicate settings, command hooks, extra peers, DNS overrides and sanitized errors. Existing API/Keychain checks still pass.
- Generic physical iOS app + Packet Tunnel extension code build succeeded with signing disabled. This verifies device compilation, not tunnel operation.
- Development signing attempted with team FXN5ZF63XW. Apple refused provisioning because the team has no registered devices. `devicectl` found no connected physical devices. No physical installation or VPN handshake is claimed.
- Updated simulator app installed and launched. VPN operations are explicitly unavailable in the simulator.
- Private configuration uses a shared Keychain persistent reference. No raw config in defaults, preferences, logs or source. Files are capped at 64 KiB.
- The server has no active/populated WireGuard tunnel. Its network configuration was not changed. Peer setup and endpoint reachability remain required.
- Earlier Tailscale connect/disconnect automation guide is superseded by native VPN controls. Backgrounding never triggers a disconnect.


## Physical iPhone installation — 2026-09-26 14:34 America/Chicago

- User paired iPhone 17 Pro Max running iOS 26.6.2 and enabled Developer Mode.
- Development build succeeded using team FXN5ZF63XW with provisioning updates/device registration enabled.
- Strict deep signature verification passed. Both app and extension have the packet-tunnel-provider entitlement and the matching shared VPN Keychain access group.
- devicectl confirmed installation and successful launch of com.asterlinelabs.asteros on the physical iPhone. Earlier device-signing blocker is resolved.
- No VPN profile or WireGuard handshake has been tested yet; Unraid peer and reachable UDP endpoint setup remain outstanding.
