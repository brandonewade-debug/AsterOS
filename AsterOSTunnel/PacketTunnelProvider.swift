import NetworkExtension
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    // Never log WireGuard configuration or runtime output: both may contain private keys.
    private lazy var adapter = WireGuardAdapter(with: self) { _, _ in }
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let configuration = protocolConfiguration as? NETunnelProviderProtocol,
                  let reference = configuration.passwordReference else { throw VPNConfigurationError.invalid }
            let tunnel = try VPNConfiguration.parse(VPNKeychain.read(reference))
            adapter.start(tunnelConfiguration: tunnel) { error in
                if error != nil {
                    completionHandler(NSError(domain: "AsterOS.VPN", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to start the tunnel. Check the endpoint, network access and VPN profile."]))
                } else { completionHandler(nil) }
            }
        } catch {
            completionHandler(NSError(domain: "AsterOS.VPN", code: 2, userInfo: [NSLocalizedDescriptionKey: "The saved VPN profile could not be loaded. Import it again in AsterOS."]))
        }
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        adapter.stop { _ in completionHandler() }
    }
}
