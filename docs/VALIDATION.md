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


## Embedded Tailscale migration — September 26, 2026

- libtailscale `59d4bb82744915815178e0f0776d60026a397ee7`, Go 1.25.5: device and simulator frameworks built successfully. Go 1.27.1 is incompatible with this revision's JSON dependency, so the bootstrap pins the supported toolchain.
- 13 regression tests passed on iPhone 17 Pro simulator, including Keychain round-trip, API redirect/callback safety, private route boundaries and auth URL validation.
- An opt-in integration check created an unapproved ephemeral userspace node, obtained its official interactive auth URL and received HTTP 200 from the authenticated local API through SOCKS. It closed the node and removed its temporary state. Source preserved under scripts/diagnostics, excluded from ordinary offline CI tests.
- A development-signed generic iPhone build succeeded; phone was unavailable during the first installation attempt. Do not claim authenticated on-device validation from this build result.
- Server-side TLS check confirmed the selected server's private DNS name/HTTPS port returns 302 to the UI with normal certificate verification. This is not an authenticated API check from AsterOS.
- Pending: owner approval, native API sign-in over embedded route, Docker page/icon and SMB read/write validation, background/foreground recovery on hardware, account sign-out/reconnect. Packaging/license/privacy review and complete transitive notices are required before commercial distribution.

- Final generic iPhone build also passed deep/strict code-signature verification. The upstream console auth-URL logging default is suppressed by a documented source patch. Physical installation remains pending phone reconnection.


## Startup and Photos preview — September 26, 2026

Device preferences confirmed one saved server, a selected profile, embedded Tailscale enabled, and a saved SMB account. The incorrect startup button came from the dashboard empty-data branch, not lost credentials. Dashboard now displays private-connection progress; API refresh begins immediately on Running instead of waiting for the polling interval.

Photo backup uses explicit Photos authorization and explicit upload confirmation, a latest-five-item test option, original PhotoKit resources, per-asset completion receipts and non-overwriting staged writes. Two tests cover missing/changed/unsafe receipt resources and stable/versioned asset identities. Live uploads and restore suitability still require the owner-selected destination and photo permission; no user photo library was accessed or uploaded during development.


### Desktop Commander startup diagnostics (2026-09-27)

The user's terminal reached the saved-installation branch but showed no Desktop Commander startup output; the Unraid remote device was offline during investigation. The cause on that server is not yet confirmed. The pinned 0.2.51 CLI source accepts `remote`; reinstalling on each Start is not necessary.

AsterOS now prints the Node version before importing the installed CLI, reports import exceptions, and warns after 20 seconds if package import remains pending. It preserves the CLI argv and saved session location. The native status reports delayed startup after 30 seconds without treating it as a confirmed failure or launching another process. Only a Device ready message after the current invocation marker confirms startup; historical scrollback cannot do so. Stop remains scoped to the foreground terminal.

Validation includes reuse/install shell fixtures, real Node bootstrap fixtures for argv and import failures, and the WebKit regression for historical readiness output. Live reconnect on Unraid still requires verification; diagnostic success must not be presented as a connection fix.


### Desktop Commander direct storage startup (2026-09-27)

After the agent reconnected, read-only measurements on Unraid found the pinned CLI's `remote --help` package load took 39.740 seconds through `/mnt/user/appdata`, versus 1.154 seconds through the same installation on `/mnt/dockercache/appdata`. The appdata share uses only that cache pool. These measure package loading, not a complete remote login. No second remote agent was started.

The launcher now asks Unraid for the installation directory's `system.LOCATION`, accepts only a single safe pool/disk name (excluding user/user0), checks node_modules has the same backing location, requires the completed-install marker, and compares the CLI entry before using the direct mount path. Missing tools, ambiguous/invalid locations, absent files or a different entry retain the original share path. Installation remains in appdata; no files, credentials, shares or storage settings are moved or changed.

Shell fixtures cover direct path selection and invalid, ambiguous, absent and mismatched backing paths. Real Node bootstrap and targeted terminal policy/status tests also pass. Full remote reconnection timing should be checked on the next user Start; the running agent is left alone.


### Custom launcher icons and saved app order (2026-09-27)

Long-press a container or external shortcut and choose Change icon, or use the same action in container details. The native sheet supports the system Photos picker and Files importer, Fit/Fill preview, explicit Save, Cancel and Restore original icon. Only the selected image is read. Images over 20 MB and invalid image data are rejected; ImageIO downsamples to 512 pixels and the saved square PNG contains rendered pixels rather than the original photo metadata. Icons are atomic files in app-private Application Support, keyed by canonical server address and launcher identity, with a bounded in-memory cache. Container icons use the existing name identity rather than changing Docker IDs. App data is not deleted on updates; uninstalling the app still removes its local data. No icon is uploaded to Unraid.

Press and hold then drag to reorder root apps, folders and the App Store tile; apps inside folders can also be reordered. Existing context menus remain available. A process-local custom drag type is accepted, and reordering cannot move unrelated items into a folder. Root order and folder member order persist through the existing address-scoped folder store; older JSON without an order field migrates to its existing display order. Previously known app identities remain in the saved order when temporarily missing; new apps append. Folder membership is still changed through Move to folder.

Simulator regression tests cover icon decoding/size limits, persistence across store recreation, server/app isolation, restoring original icons, legacy layout decoding, saved root/folder order, unknown new apps, re-added server identity and rejecting foreign folder items. Full simulator suite passes. Actual picker/drag gestures still need hands-on iPhone verification; no personal photos were selected for development tests.

### Release hardening and native insights (2026-09-27)

Implemented retained/stale container lists on API failure, clearer mutation outcomes, faster foreground retry after an older refresh unwinds, credential renewal retaining server identity, stable terminal tmux identity, and process-owned Desktop Commander duplicate-start locking. Existing server agents and old sessions were left running.

New uploads are read back and compared in bounded chunks before commit; older completion receipts still use file-size checks during resume. Preferences export/import validates all included values before changes, keeps an undo archive, and deliberately excludes credentials/security state/custom icon image data. Native unread alerts, the latest 500 searchable container log lines, and allowlisted preview-before-share support reports are added. Internal catalog label is Discover. Docker editor form actions must remain on the server origin; unsupported or expired-session outcomes never automatically replay an apply.

The simulator suite passes 59 tests, including 9 new release-readiness tests. Shell reuse/duplicate-start fixtures and real Node bootstrap fixtures pass. A temporary isolated Unraid flock check passed without starting another agent. Installed Unraid API source contains the required alerts/log resolvers and viewer read permission policy; saved-phone-key execution remains a hands-on check. No personal photos were read/uploaded and no real Docker container was installed, edited or removed by this validation.

Remaining hardware, external-beta and paid-release gates are in RELEASE_READINESS.md. The code changes do not imply App Store approval or completion of an external security audit.

### Native dashboard telemetry (2026-09-27)

Replaced the basic overview grid with rounded glass cards: dotted CPU/RAM gauges, CPU temperature with saved °C/°F preference, optional CPU package power, one selectable network interface with receive/transmit bytes per second and link utilization, full-width GPU cards, and dotted array/cache/boot/data-disk capacity views. RAM uses binary memory formatting; filesystem counts from Unraid remain KB converted to bytes. Network interfaces are not summed, avoiding double counting bridge/bond/member traffic. Interface choice persists per server address.

Optional GraphQL requests for metrics, temperature sensors, CPU packages and storage run independently. Unsupported fields/permissions clear their readings without breaking basic server monitoring. Additional telemetry polls only while the dashboard is visible and the scene is active. Missing data shows an em dash, not zero; last refresh times remain visible. CPU temperature chooses CPU_PACKAGE/CPU_CORE sensors and supports Celsius/Fahrenheit/Kelvin/Rankine; package temperatures are a fallback.

The installed API has GPU inventory but no GPU utilization field. Native GPU cards therefore use the existing GPU Statistics plugin and the existing server web sign-in. AsterOS reads the dashboard's plugin configuration as JSON without executing its scripts, validates vendor/PCI/GPU identifiers, and requests only the server's fixed plugin endpoint. API keys are never sent there; only matching Unraid session cookies are used, HTTPS is required, and redirects are rejected. A missing plugin or expired login has an explanatory state and a retry backoff. No plugin, driver or companion is installed by this change.

Read-only server inspection confirmed GPU Statistics and NVIDIA Driver are installed. Its cached output identifies Quadro P4000 and uses temperature strings such as 100F, which the decoder converts correctly. Regression fixtures cover this format, N/A values, VFIO, configuration validation, CPU sensor types, network selection, mixed BigInt encodings and capacity formatting. The phone-sized native layout was rendered and visually inspected using sample data. Actual saved-session GPU requests on the phone still require hands-on confirmation; no server credentials were extracted for development.

## TestFlight preparation — 2026-09-27
- Config/Version.json now controls generator output: 0.1.0 (2).
- Added required-reason privacy manifests to app and both TailscaleKit slices before signing.
- Simulator suite: 65 tests passed, zero failures.
- Release archive succeeded; app version and both bundled manifests verified; strict deep codesign verification passed.
- Upload attempted using Xcode account; export stopped with Error Downloading App Information. User confirmed a new App Store Connect app record is needed. No build has been uploaded yet.
- Encryption exemption is intentionally unset pending the actual Apple questionnaire; no unsupported NO declaration.
- Added reproducible archive/upload helper, beta test notes, and documented remaining privacy/review gates.
