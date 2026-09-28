# Privacy hardening — 2026-09-28

Baseline reviewed: 612ef32047d4296798e3a01aa4d9d5fa8cfd2352 (build 10 source).
This is a source review and mitigation pass, not an independent audit or a release-device traffic capture.

## Implemented protections

- File login and photo backup require an active embedded Tailscale connection and a Tailscale destination. SMB clients use an unscoped per-client SOCKS proxy, or a closed loopback endpoint when unavailable; they cannot deliberately fall back to direct TCP. Existing LAN-only share addresses now display actionable connection instructions.
- This is containment, not SMB3 encryption support: the pinned SMBClient negotiates SMB 2.0.2/2.1, signs requests, but does not verify incoming signatures in its response path. Replace or harden that dependency before enabling direct LAN SMB again. Do not describe the dependency as fixed.
- Container browser HTTP is restricted to the initial known Tailscale peer. Private browsers use an unscoped authenticated Tailscale proxy, or a blocking loopback proxy when disconnected; they never switch to an empty/direct proxy list. HTTP resources outside that exact host are blocked before the first page loads. Public pages require HTTPS. The WebKit ATS exception remains necessary for private HTTP, so application routing and content rules are part of the security boundary. HTTP links cannot be handed to Safari, which does not share the app-owned tunnel.
- Native external app-icon requests are opt-in, default off. Same-origin container icons and local custom icons remain available. This toggle does not govern resources loaded by Unraid's own Discover web page or other websites; the UI says so.
- On process launch, remove only temporary paths matching the two owned UUID naming schemes. Symlinks are skipped. Cleanup failures are reported in Settings. No server files or Photos originals are deleted.
- Explain original photo/location metadata preservation, administrative web sessions, and local removal versus server-side credential revocation in Settings.

## Existing controls inspected

API and SMB credentials and archived web-session cookies use device-only Keychain storage. API URLs require HTTPS; API redirects are rejected. Authorization callbacks validate origin, state and expiry. App pages do not receive the server API header. PIN uses salted PBKDF2 and retry delays. Support reports use an allowlist of version/count/boolean fields and require explicit sharing. Tailscale state is excluded from device backup and auth/status console output is discarded by the build patch.

## Remaining work / limitations

- Run physical-device release traffic capture for login, Files, Photos, Discover, icon toggles, redirects, reconnection, and background transfers. Verify NWParameters proxy failure does not permit direct traffic on each supported iOS release.
- Test the migration from LAN SMB to Tailscale against a disposable share. Destination identity contains the host, so existing receipt verification may run once after changing it. Never delete existing backup data.
- Audit Tailscale's transitive telemetry and data handling; a silent app logger does not establish no SDK network logging. Match published disclosures to observed behavior.
- Desktop Commander is optional but grants paired clients terminal-user authority. Its tmux session can outlive the phone app. Keep explicit start consent and make revocation/disconnection behavior clear.
- Server removal currently removes local credentials/session data, not the server-side API key. Provide a revocation workflow after validating Unraid support.
- Persistent WebKit storage, settings/custom icons, local backup journals, and server receipts need a documented retention/delete policy. Keychain is not the sole storage used by WebKit.
- Original photo metadata is preserved. No metadata-stripping option is promised.
- No public source-to-binary reproducibility guarantee or independent security certification.

## Verification

Privacy tests exercise protected-destination gating, disconnected denial, private HTTP host restrictions, public HTTPS navigation, and scoped temporary cleanup (including symlinks and unrelated files). All 95 simulator tests passed on 2026-09-28, including WebKit rule compilation and the existing dashboard/demo render tests. Real-device route and packet validation remain required before treating this as a completed security release.
