// Opt-in network check: temporarily copy to AsterOSTests and regenerate the project.
// Creates an unapproved ephemeral node; never signs into a user account.
import XCTest
import TailscaleKit
@testable import AsterOS
final class TailnetSmokeTests: XCTestCase {
 func testInteractiveNodeAndLocalProxy() async throws {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
  let node = try TailscaleNode(config: Configuration(hostName: "asteros-build-check", path: path.path, authKey: nil, controlURL: kDefaultControlURL, ephemeral: true), logger: nil)
  do {
   var found = false
   for _ in 0..<30 {
    let status = try JSONSerialization.jsonObject(with: try await node.statusJSON()) as! [String: Any]
    if TailnetPolicy.loginURL(status["AuthURL"] as? String) != nil { found = true; break }
    try await Task.sleep(for: .seconds(1))
   }
   XCTAssertTrue(found, "Embedded node must obtain an official interactive login URL")
   let (config, loop) = try await URLSessionConfiguration.tailscaleSession(node)
   let session = URLSession(configuration: config)
   var request = URLRequest(url: URL(string: "http://\(loop.address)/localapi/v0/status")!)
   request.setValue("Basic " + Data("tsnet:\(loop.localAPIKey)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
   request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
   let (_, response) = try await session.data(for: request)
   session.invalidateAndCancel()
   XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
   try await node.close()
  } catch { try? await node.close(); throw error }
  try FileManager.default.removeItem(at: path)
 }
}
