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
