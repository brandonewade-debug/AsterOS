import Foundation
import Network

/// A saved local opt-in is distinct from the Tailscale route; neither silently falls back.
@MainActor enum ShareTransport {
    static func isLocal(_ connection: ShareConnection) -> Bool {
        connection.allowLocalNetwork == true && LocalHTTPPolicy.isPrivateIPv4(connection.host)
    }
    static func validate(_ connection: ShareConnection) throws {
        if isLocal(connection) { return }
        try TailnetStore.shared.requirePrivateFileRoute(host: connection.host)
    }
    static func parameters(for connection: ShareConnection) -> NWParameters {
        if isLocal(connection) {
            let parameters = NWParameters.tcp
            parameters.prohibitedInterfaceTypes = [.cellular]
            return parameters
        }
        return TailnetStore.shared.smbParameters()
    }
}
