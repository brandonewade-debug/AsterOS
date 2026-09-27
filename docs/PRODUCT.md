# AsterOS product direction

AsterOS by Asterline Labs is a native iPhone/iPad Unraid manager with original branding, a soft glass interface and a configurable app launcher. The name is a working product name, not a trademark clearance.

## Current approach

- Connect to a reachable HTTPS Unraid server, optionally through embedded Tailscale. Local/custom domains and configured Unraid Connect server URLs are supported address choices; this is not Unraid.net cloud account discovery.
- Sign in on the server and approve AsterOS. Callback validation and Keychain protect the API credential; the app does not collect the root password. Existing credentials can be renewed without removing a profile.
- Server overview and Docker controls use the API. Native Discover and Docker configuration forms use the server's Community Applications/web session. Version and permission gaps must be explained rather than treated as success.
- File access and foreground photo/video backup use direct SMB. A separate AsterOS companion is not required for these features. Live Photo resources are preserved; server receipts support resumable backup. This is not a claim of a complete Photos-library restore product or uninterrupted background upload.
- App URLs come from Unraid by default; users may set an external override. Never forward Unraid API keys to application websites. Folders, order and custom icons are saved locally per server.
- Terminal is a native-styled server terminal with persistent tmux sessions when available. Desktop Commander is an optional explicit-start integration. Closing the transport does not necessarily stop server processes; Stop is explicit.
- Optional PIN and biometrics lock the app. Server alerts, searchable container logs, preferences backup and redacted support reports are available in the preview.

## Next release gates

See RELEASE_READINESS.md for completed hardening and remaining hardware/beta/commercial checks. Reliability, safe backup/restore and durable configuration take priority over widgets, broader VM management or managed relays. Pricing and purchase implementation remain undecided. No paid App Store release is authorized by the development work itself.

## References

- https://docs.unraid.net/API/
- https://docs.unraid.net/API/api-key-app-developer-authorization-flow/
- https://docs.unraid.net/unraid-connect/remote-access/
- https://github.com/unraid/api

An upstream development schema alone does not prove compatibility with every deployed Unraid version. Verify installed capabilities and fail clearly when unavailable.
