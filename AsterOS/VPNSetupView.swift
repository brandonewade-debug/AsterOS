import SwiftUI

struct VPNSetupView: View {
    @Environment(\.openURL) private var openURL
    @State private var openingError = false
    var body: some View {
        List {
            Section {
                Label("Connect when AsterOS opens", systemImage: "network.badge.shield.half.filled").font(.headline)
                Text("For Tailscale, set up two personal automations in Apple Shortcuts on this iPhone. Sign in to Tailscale and allow its VPN configuration first.")
                Text("AsterOS does not install these automations or control Tailscale itself.").font(.caption).foregroundStyle(.secondary)
            }
            Section("1 · Connect on open") {
                Text("In Shortcuts, choose Automation → + → App.")
                Text("Select AsterOS, choose Is Opened, and choose Run Immediately.")
                Text("Add Tailscale’s Connect action, then save the automation.")
            }
            Section("2 · Disconnect on exit") {
                Text("Create another App automation for AsterOS.")
                Text("Choose Is Closed and Run Immediately.")
                Text("Add Tailscale’s Disconnect action, then save.")
            }
            Section("What to expect") {
                Text("Leaving AsterOS or switching to another app triggers Is Closed. Finish file transfers before leaving; disconnecting the VPN interrupts them.")
                Text("This disconnects Tailscale for the whole device, including other apps using it. Check Tailscale’s VPN On Demand settings if it reconnects automatically.")
                Text("Use your server’s Tailscale hostname or IP for Files, and its valid HTTPS address for server management.")
            }
            Section {
                Button("Open Shortcuts", systemImage: "arrow.up.forward.app") {
                    openURL(URL(string: "shortcuts://")!) { accepted in openingError = !accepted }
                }
                Link("Tailscale automation guide", destination: URL(string: "https://tailscale.com/docs/features/mac-ios-shortcuts")!)
            }
        }
        .navigationTitle("VPN automation")
        .alert("Shortcuts unavailable", isPresented: $openingError) {
            Button("OK", role: .cancel) { }
        } message: { Text("Open Apple Shortcuts on your iPhone to configure the automations. A simulator cannot verify a real VPN connection.") }
    }
}
