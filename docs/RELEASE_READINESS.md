# Release readiness — September 27, 2026

AsterOS remains a development preview. These changes improve recovery and add useful tools; they are not certification that the app is ready for commercial sale.

## Implemented in this pass

- Failed API refreshes preserve the last container list, label it stale, and disable launcher mutations until refreshed. Failed server refreshes clear old live metrics. Docker mutations are never automatically repeated. A successful mutation followed by a failed refresh has a distinct message; invalidated refreshes cannot leave loading stuck.
- Settings → Renew server access replaces a verified API credential while keeping the existing profile ID, app organization, SMB account and photo destination. TLS validation, redirect rejection and callback-state validation remain in place.
- Terminal tmux session identity persists by canonical server address on this device. The launcher holds a process-owned `flock` while Desktop Commander starts/runs, preventing duplicate starts from new AsterOS launchers. Existing older sessions/agents are not killed or migrated. Reconnecting attaches only; it never replays arbitrary commands. iOS may still suspend the network transport; persistence depends on tmux and a running server.
- New photo uploads, including receipt uploads, are read back in bounded chunks and compared byte-for-byte before their staging file is renamed. Size mismatches, corrupt data, cancellation and empty reads prevent completion. Existing receipt-based resume remains size-based; this is not a periodic full integrity audit of older backups. Backup is explicit-start. Build 4 keeps work alive across tabs and requests iOS 26 background processing; iOS resource limits, user Stop and force-quit can still interrupt it.
- Preferences export/import supports server-scoped app folders/order, shortcuts, photo destination/layout/time zone and terminal text size. Validate everything before mutation; 2 MB limit, version check, safe URL/path checks and duplicate membership checks. Import has a destination summary/confirmation and keeps the prior preferences for undo. No credentials, PIN, Tailscale state, custom icon images or photo receipts are exported. Existing local custom icons are untouched. Server receipt files rebuild the completion index when it is missing; normal resume uses the destination-scoped local completion journal.
- Native server alerts read up to 100 unread notifications. They refresh on opening or manually; no background push is advertised.
- Native container logs read the latest 500 lines, with local search and manual refresh. Logs remain in memory and are not included in support exports.
- Support reports use an explicit allowlist of version strings, booleans and counts. They exclude names, addresses, credentials, error text, file paths, photos and raw logs. The user previews and explicitly shares the report.
- The internal catalog is called Discover. Docker editor forms must POST to the same origin; unsupported forms cannot apply. Expired sign-in during apply is an unknown result, requiring inspection before retrying.

## Verification performed

- Simulator regression suite, including Keychain, authorization callbacks, native catalog/editor bridges, app folders/icons, stale refresh state, mutation refresh failure, preferences validation/round-trip/recovery, bounded upload verification and report allowlisting.
- Desktop Commander shell fixtures cover install reuse, direct-storage selection, duplicate-start rejection and error recovery. Real Node fixtures verify startup argv and import errors.
- An isolated temporary-file test on Unraid confirmed `flock` rejects a competing process and releases on process exit. No current agent was stopped and no second real agent was launched.
- Read-only inspection of the installed Unraid API bundle confirmed notifications and Docker logs resolvers and viewer read permissions. This does not prove the phone's saved credential can execute them.
- Signed iPhone build/installation results are recorded in the PR and validation history.

## Required before paid launch

- Hands-on beta with other Unraid installations and supported iPhones/iPads: fresh install, update preserving data, reauthorization, Wi-Fi/cellular transitions, offline server, server reboot, session expiry, VoiceOver, large text and rotation.
- Restore representative exported photos/videos and Live Photo resources; test low disk space, interrupted uploads and large iCloud originals. No personal photo library was accessed or uploaded by development tests.
- Exercise native Docker install/edit/remove against disposable test containers and several templates/Unraid versions. Never validate removal using irreplaceable personal containers.
- Verify real alerts/logs using saved phone permissions, and preferences export/import with the system Files picker. UI gestures and biometric enrollment require hardware testing.
- Complete dependency/transitive license notices, branding/catalog permissions, privacy policy, App Store privacy answers, support contact, accessibility review and a reviewer-accessible demo.
- Resolve Apple's treatment of embedded Tailscale/private connectivity for this app before submission; do not assume review approval.
- Choose and implement the business model, purchase/restore behavior if applicable, then external TestFlight feedback before paid release. Do not promise uninterrupted background backup or background push.
