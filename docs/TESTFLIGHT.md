# AsterOS TestFlight preparation

## Build and upload
Edit Config/Version.json before each new upload. scripts/generate_project.py reads this file, so regeneration preserves the version.
Run scripts/bootstrap_tailnet.sh on a clean checkout to prepare pinned dependencies.
Set DEVELOPMENT_TEAM locally, then run python3 scripts/testflight.py.
Run python3 scripts/testflight.py --upload to upload the verified archive.
Xcode sign-in is used by default. Optional ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID must all be provided together; keep the private key outside the repository and synced folders.
Distribution output lives in ignored .release/. Never commit signing logs or credentials.
A successful archive is not an uploaded or approved build. Verify processing and the build number in App Store Connect.

## Encryption and review
ITSAppUsesNonExemptEncryption is deliberately not hard-coded to NO. This binary embeds Go/Tailscale/WireGuard encryption in addition to Apple's APIs. Complete Apple's encryption questionnaire for the actual distribution territories and attach any required documentation.
Describe the private app-scoped Tailscale connection accurately to App Review; Guideline 5.4 classification remains unresolved.
Docker applications and Desktop Commander run on the user's server, not on iOS.
Reviewer access must use a dedicated test server or sufficient demonstration mode, never the owner's production root account.
An external TestFlight release requires completed beta contact/review metadata, review access, and any required Beta App Review. Do not invite testers before these are ready.

## What to Test
- Add your Unraid server and reconnect after app restart, network changes, and server reboot.
- Confirm saved app folders, order, custom icons, and photo destination survive a build update.
- Check CPU, memory, network, storage, and GPU status. GPU details depend on the server's GPU Statistics plugin and authenticated server session.
- Browse Discover and install/edit/remove disposable Docker containers, including advanced options.
- Connect Files using a share account. Back up a small test selection of photos, videos, and Live Photos; interrupt and resume, then open the backed-up originals to verify them.
- Reopen terminal sessions and exercise the optional Desktop Commander integration.
- Test PIN/Face ID, large text, VoiceOver, and iPad rotation.

## Known beta limitations
Photo backup is explicit-start. Build 4 continues across tabs and requests iOS 26 continued background processing; older systems or denied requests get limited background time. iOS may expire the task and force-quit stops it. Server alerts are in-app, not background push.
GPU telemetry is hardware/plugin-dependent; missing data should be shown as unavailable.
Build 3 adds offline demo navigation for dashboard, sample files, simulated backup, and sample container configuration. It does not perform real transfers, authentication, terminal sessions, or container operations. Apple may still request a dedicated review server.
Preferences export excludes credentials, Tailscale identity, custom icon images, and server-side backup receipts.
Do not uninstall the development build as an update step; an uninstall removes local settings/files.
Use disposable data and containers when testing destructive actions.

## Privacy manifest scope
The app declares UserDefaults (CA92.1) for local preferences and FileTimestamp (C617.1, 3B52.1) for its own files and user-selected imports.
Each local TailscaleKit framework slice receives a manifest before Xcode embeds/signs it: FileTimestamp (C617.1) for app-contained state and SystemBootTime (35F9.1) for Go runtime timers and elapsed intervals.
These required-reason declarations do not replace the complete third-party data-flow audit, App Store privacy labels, or published privacy policy. No blanket data-not-collected declaration is made here.

Sources:
https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance
https://developer.apple.com/app-store/review/guidelines/

## First uploaded build
0.1.0 (2) uploaded September 27, 2026 at 08:46 America/Chicago. Xcode confirmed processing began. This is not confirmation of testing availability or Beta App Review approval. Complete encryption compliance, beta metadata, and group assignment in App Store Connect. The uploader reported missing TailscaleKit debug symbols; correct framework dSYM packaging for future builds.


## Build 3 review walkthrough
On first launch, scroll down in Connect your server and tap Explore demo. No account, server, VPN configuration, or Photos permission is needed for the demo. Existing users can enter it from Settings > Explore demo.
- Server: sample CPU, RAM, temperature, network, GPU and storage cards.
- Files: Documents has sample text previews; Photos and Videos contain 2026 > 09 with date-ordered sample media.
- Photos: select a sample destination, toggle day folders and separate videos, start/pause/resume/reset the six-item simulated backup.
- Apps: Discover contains four fictional samples. Install Notes, edit its port/path/time zone and advanced network/privileged choices, change its symbol, save, inspect sample logs, or remove it.
- Touch and hold an app to move it into Favorites; Reorder apps changes the sample order.
- Exit demo returns to the prior server without overwriting its saved selection. Sample changes are in memory and reset on a new demo session.

The demo is clearly labeled for everyone; it is not a hidden reviewer-only mode. Live server functions still require the user's server authorization and share account.
Connection stages include Tailscale state/elapsed time and server/app/metrics request elapsed time plus the 30-second resource-timeout budget, not a guaranteed connection ETA.
Cancellation during normal task transitions no longer surfaces as a server failure.

## September 27 build 3 handoff
0.1.0 (3) signed archive and upload succeeded; App Store Connect shows Complete/Missing Compliance. Build 3 is not yet assigned to a testing group or submitted for external review. The standard-encryption option was selected because Tailscale embeds encryption outside Apple OS APIs; the remaining questionnaire is not confirmed saved. Automatic browser review blocked further inspection of the open form. Do not mark this build compliant or approved without verifying Apple state.

Published website (HTTP 200 verified):
- Marketing: https://brandonewade-debug.github.io/asterline-labs/apps/asteros/
- Privacy: https://brandonewade-debug.github.io/asterline-labs/privacy/asteros/
- Support: https://brandonewade-debug.github.io/asterline-labs/support/

App Store Connect saved: beta description/contact/reviewer demo notes; distribution description/promotional text/keywords/copyright/contact; subtitle; Utilities category; calculated age rating 16+ (17+ on older OS) reflecting unrestricted website access. Public release is manual. Website URL fields still need entry, including the privacy policy in both TestFlight and App Privacy. Build-specific What to Test, group assignment and external submission remain pending. Do not claim the expanded demo exercises real server connections or actual transfers. The SDK dSYM warning is still outstanding.

## September 27 review and build 4 follow-up
Build 3 was subsequently marked compliant (standard non-OS encryption; France excluded per the selected distribution scope), assigned to Family, and submitted to the empty External Beta group. Apple displayed Waiting for Review. Automatic tester notification was disabled; no new invitations or public App Store release were sent. TestFlight marketing/privacy and distribution marketing/support/privacy URLs were saved. App Privacy data disclosures remain unfinished.

Build 4 fixes photo backup ownership and resume:
- Switching tabs leaves the same app-owned backup task running.
- Explicitly starting backup requests iOS 26 continued processing with system progress/Stop UI; older iOS/denied requests use a finite UIKit background lease. Expiration cancels work safely; users resume with Back up now.
- A destination-scoped local completion journal skips per-item network receipt reads on ordinary restart. It is updated only after successful server receipt verification/commit.
- Existing receipts are imported once on first use of this build. A changed server/account/share/root or missing/replaced root marker triggers a different index. Edited assets use a new identity.
- Verify existing backup explicitly rebuilds the index from server receipts and file sizes. It is not a checksum audit of previously backed-up media.
- PhotoKit resource exports can be cancelled, including in-flight iCloud retrieval.

Hardware acceptance for build 4: begin with a disposable five-item selection; leave Photos for another tab, switch apps/lock the phone, return, and confirm progress. Test system Stop, manual Pause, force-quit during a transfer, and resume. After one receipt-migration pass, compare a second resume. Verify originals/Live Photo paired resources/videos on the server. Network setup and local Photos enumeration still take time; the 27,000-record journal test is not an end-to-end phone performance promise.

Build 4 release result: signed archive and upload succeeded September 27, 2026 (Apple upload time 11:53 America/Chicago). App Store Connect processed build 4, saved its standard-encryption questionnaire with the existing France exclusion, and shows Family internal group assignment. Build-specific testing notes are saved. Build 3 remains Waiting for Review; Apple permits only one build of 0.1.0 in Beta App Review at a time, so build 4 was not submitted externally. PR 23 merged normally to main (7650222). GitHub Actions did not run because account payments/spending limits blocked the job; the 77-test signed Mac suite passed. The pre-existing TailscaleKit symbols warning remains.
