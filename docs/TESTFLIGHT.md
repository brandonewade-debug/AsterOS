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
Photo backup is explicit-start and foreground-only. Server alerts are in-app, not background push.
GPU telemetry is hardware/plugin-dependent; missing data should be shown as unavailable.
The dashboard demo alone does not provide a complete review path through files, photo backup, and installation.
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
