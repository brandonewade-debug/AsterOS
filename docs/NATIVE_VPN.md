# AsterOS native WireGuard VPN

## Behavior

- Import a client profile from Settings → AsterOS VPN and review its endpoint and private routes. iOS asks for VPN configuration permission.
- Connect-on-launch is enabled after import and can be turned off. An explicit Disconnect does not get retried in the same app process.
- Switching apps, locking the phone and normal backgrounding do not invoke disconnect. Force-quitting the UI is not a reliable tunnel shutdown signal.
- This is a device VPN with private destination routes, not an MDM per-app VPN. Other apps may use those routes. It may replace another active VPN.
- A running tunnel does not prove a successful WireGuard handshake or API connection. Test dashboard and SMB access separately.

## Server setup still required

The inspected Unraid server has no active WireGuard interface and no populated client-ready tunnel address/endpoint configuration. No existing VPN, Tailscale, Cloudflare, firewall or router settings were changed.

Use Unraid Settings → VPN Manager to configure a server tunnel on an unused UDP port and add a dedicated peer for this device. Choose remote access to the server or private LAN, export that peer’s configuration, and import it into AsterOS. Use only the private routes needed for Unraid and desired Docker endpoints; do not include 0.0.0.0/0 or ::/0. Remove the DNS override for this preview and use reachable IP addresses or an independently resolvable HTTPS hostname. Interface tunnel addresses must not overlap existing LAN/VPN ranges.

A public UDP endpoint and router forwarding to the Unraid WireGuard listener are required for conventional remote WireGuard behind NAT. A Cloudflare-proxied HTTP hostname cannot provide this. CGNAT or blocked inbound UDP needs a different network design. Do not forward the Unraid UI or SMB port for this setup.

Do not reuse one client private key across devices. This preview imports a peer configuration; it does not provision peers through the Unraid API.

## Apple signing

Both `com.asterlinelabs.asteros` and `com.asterlinelabs.asteros.tunnel` require Network Extension provisioning and the shared Keychain access group. The app retains its original default Keychain group for existing server credentials. Entitlements are excluded only from simulator signing, which cannot run a real packet tunnel.

On 2026-09-26 development signing with team FXN5ZF63XW was blocked because Apple reported no registered devices to create profiles. Connect an unlocked iPhone to the Mac, trust it, enable Developer Mode and let Xcode register it for development. Then build with the development team and provisioning updates enabled. A TestFlight distribution flow is an alternative but has not been performed for this app.

## Dependency provenance

WireGuardKit: upstream revision 2fec12a6e1f6e3460b6ee483aa00ad29cddadab1, vendored in Vendor/WireGuardKit. Package tools-version and an explicit sys/types.h include are adjusted for Xcode 26; protocol/cryptographic code is unchanged. Upstream Go module versions and checksums are preserved. Go 1.27.1 was used for builds and is pinned in CI. Licenses are bundled in ThirdPartyNotices.txt. Review dependency security and compatibility before a commercial release.
