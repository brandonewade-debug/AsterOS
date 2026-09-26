# Embedded Tailscale preview

AsterOS joins the owner's existing tailnet as its own persisted device, named `asteros-<random suffix>`. The server must already run Tailscale. The official browser flow authorizes this new node; no auth key or state is extracted from the separate Tailscale iOS app.

## Setup

1. Connect your server → Connect with Tailscale (also available in Settings → Private connection).
2. Sign in, approve AsterOS, and wait for Connected privately. Tailnets requiring device approval need their administrator's approval too.
3. Choose your Unraid device and its actual HTTPS port. Return and tap Sign in to Unraid, then approve its requested permissions.
4. Files uses the full Tailscale server name with a separate non-root Unraid SMB share account. Enable that account's required share permissions on Unraid.

HTTPS certificate names must match the server URL. Routing through Tailscale does not make an untrusted certificate trusted. The app does not bypass TLS errors or an Access gateway; use the server's private HTTPS listener.

## Transport

The app-scoped SOCKS proxy routes full `.ts.net` names, `100.64.0.0/10`, and `fd7a:115c:a1e0::/48`. Other destinations load directly. No exit node or LAN subnet routing is enabled. Short MagicDNS names are intentionally excluded to avoid collisions with public DNS suffixes. API redirects remain blocked; browser sessions never receive API keys.

URLSession, WebKit and SMB each receive a scoped proxy configuration. The SMB patch adds optional `NWParameters` through SMBClient → Session → Connection, preserving the original UNC hostname and signing. No local TCP forwarder or exposed file service is created. Container web URLs pointing at LAN-only IPs need a Tailscale HTTPS shortcut; they are not rewritten blindly.

The app stays connected when its scene becomes inactive/backgrounded; iOS still controls suspension. Foreground health checks verify the loopback LocalAPI through SOCKS, recreating the node from persisted state only on failure. Existing WebKit stores receive the replacement proxy. This does not guarantee uninterrupted background transfers or immediate remote offline status after force-quit.

## Build and validation

Run `bash scripts/bootstrap_tailnet.sh` before opening a fresh checkout, then `python3 scripts/generate_project.py`. Requires iOS 18.1+, Xcode 16.1+, Go with toolchain download access. Go is pinned to 1.25.5 for the library's JSON dependency. Do not link the historical WireGuard Go bridge into this app: it would introduce a second Go runtime.

The SDK is upstream experimental code. Regression tests and an opt-in unauthenticated network smoke check passed; authenticated API/SMB access and suspension recovery still require the owner-approved device test. `scripts/diagnostics/TailnetSmokeTests.swift` can temporarily be copied to AsterOSTests and included by regeneration for that opt-in check; remove it and regenerate afterward. It never approves a user account.

State is app-private, backup-excluded and protected until first unlock. User-facing errors omit SDK auth URLs/credentials; the app's SDK logger discards internal logs. Commercial release still needs a complete transitive license/privacy review, real-device reliability and upgrade testing. Included notices cover directly integrated libraries; this preview is not release approval.

The bootstrap applies `patch_tailnet_logging.py` to the pinned C/Go bridge: selecting silent logging also discards tsnet UserLogf, preventing its default console output of interactive auth URLs. Build stamps include this patch and Xcode version; a change rebuilds the generated framework.
