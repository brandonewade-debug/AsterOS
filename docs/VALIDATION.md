# Validation status

## This environment

Linux; no Swift compiler, Xcode, iOS SDK, simulator, Apple signing credentials or connected Unraid test endpoint. No successful build, executed XCTest run, live API test or visual simulator verification is claimed.

Source review checks include: HTTPS-only saved addresses; user-info/query/fragment rejection; Keychain-only API key storage; rejecting API redirects; no API key injection into WebKit; capacities use kilobytes rather than disk counts; generation guards against a previous server's async results populating a new profile; sample mode disables writes.

## Before internal TestFlight

- Run the included GitHub Actions workflow or Xcode Product → Test; resolve compiler/test failures.
- Run on iPhone and iPad; check Dynamic Type, VoiceOver, rotation, keyboard and sheet dismissal.
- Connect to an isolated test server before a production server. Test scoped read-only and Docker-update keys, expiry/revocation, unsupported metrics and Docker disabled.
- Validate custom-domain and Unraid Connect remote URL behavior on supported Unraid/API versions.
- Validate redirects, certificate errors, HTML gateway pages, offline state, scene backgrounding, slow networks, profile switching during requests and action responses after server changes.
- Run a full app-browser login sequence including redirects; test an embedded-login-blocking provider and Safari fallback. This preview clears web sessions on close.
- Confirm start/stop only affects the selected container on the selected server; stale data and unknown outcomes must remain visible.
- Add app icon/launch assets, finalized bundle ID, signing, privacy policy/support URL and App Store privacy answers.

## Before paid release

Complete the core features, capability negotiation, onboarding, security review and version/device matrix. Validate backup restoration and interrupted-transfer recovery before marketing backup reliability. Confirm name availability and any Unraid branding/integration requirements. No commercial-readiness claim should be based solely on this starter.
