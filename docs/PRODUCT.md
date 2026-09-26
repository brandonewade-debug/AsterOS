# AsterOS product direction

## Accepted direction

AsterOS by Asterline Labs. Native iPhone/iPad app for Unraid with Zima Client-like convenience, original branding and visual assets. Reference style: dark backgrounds, rounded bordered cards, readable large metrics, app icon grid, favorite folders, clear storage capacity and a bottom browser control panel. Use native accessibility and adaptive iPad layout. AsterOS is a working product name, not a trademark availability determination.

## Connection architecture

First iteration connects directly to the customer's reachable HTTPS GraphQL endpoint using a device-only Keychain API key. A custom URL, LAN/VPN hostname or configured Unraid Connect remote server URL may supply that endpoint. Current labels identify the user-selected address type; they do not measure the physical network route. Manual switching between saved profiles is implemented; per-server local/remote addresses and automatic switching are planned.

The documented Unraid server authorization flow can replace manual key entry in a later iteration. It requires HTTPS callbacks, state validation, requested scopes, and secure token handling. Do not publish a callback that logs keys or routes them through analytics. A proper Associated Domains configuration and registered domain are needed before enabling an automatic return-to-app flow.

Unraid Connect cloud dashboard login and third-party cloud discovery are separate, unverified integration questions. Do not use private cloud endpoints, scrape account cookies, or claim a supported cloud sign-in integration without confirmation from Unraid. Opening Connect in a browser is possible but is not native cloud integration.

Docker control through the API does not grant access to Docker websites. The app launcher initially uses customer-provided URLs. Later, discover supported template webUiUrl/iconUrl fields and allow a per-app local and remote override. Never automatically send the Unraid key to app origins. Capability-detect newer schema fields before requesting them.

## Companion service (planned, not implemented)

Install once for scoped file operations, resumable upload sessions, thumbnail jobs, photo backup indexing and optional remote transport. Select explicitly authorized shares; enforce canonical paths and symlink boundaries. Do not mount the whole host or give the service unrestricted Docker socket access by default. Privileged operations, if required, belong behind an allowlisted host helper and auditable permissions.

For transfers: chunking/resume, checksums, quota/free-space handling, cancellation and conflict handling. For photos: PhotoKit permission choices, preserve original media plus Live Photo pairing, idempotent asset tracking and restore verification. iOS background execution must be tested; do not promise uninterrupted backup after force quit.

Managed remote transport requires device pairing/revocation, encrypted sessions, direct-connect attempts and a relay fallback, plus operational support and bandwidth accounting. Own-network/custom-URL access should remain available without buying our relay service. Final pricing is undecided.

## Staged delivery

1. Foundation (this source): server profiles, HTTPS API, dashboard, Docker start/stop, app shortcuts/browser, demo, CI source.
2. Validate and harden: Mac build, real-server schema snapshots, URL/auth flows, redirects, network transitions, permissions, cancellation, stale data and accessibility; persistent isolated website sessions; icon/launch assets.
3. Core usable beta: automated authorization, local/remote failover, Docker metadata/icons, logs and safe update workflows, scoped file companion and resumable transfers.
4. Photo backup, VM controls, terminal session persistence, notifications and app discovery/installation. Confirm app catalog access/distribution terms and template compatibility.
5. Commercial release: supported server/version matrix, device testing, security review, onboarding/support, privacy disclosures, purchase/restore flows, demo for App Review and staged external TestFlight testing.

No TestFlight upload, server change, cloud deployment, paid service or public repository has been performed.

## Sources reviewed 2026-09-26

- https://docs.unraid.net/API/
- https://docs.unraid.net/API/how-to-use-the-api/
- https://docs.unraid.net/API/api-key-app-developer-authorization-flow/
- https://docs.unraid.net/unraid-connect/remote-access/
- https://raw.githubusercontent.com/unraid/api/main/api/generated-schema.graphql

The moving upstream main schema is a development reference, not proof that a particular installed release supports every field. The source check validates the selected query shape only.
