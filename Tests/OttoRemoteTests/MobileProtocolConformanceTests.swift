import Foundation
import OttoRemote
import Testing

@Suite("Mobile protocol conformance")
struct MobileProtocolConformanceTests {
  @Test("Platform-neutral schema exactly lists the host's v1 method surface")
  func schemaMethods() throws {
    let data = try Data(contentsOf: contractRoot.appending(path: "mobile-chat-v1.schema.json"))
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let properties = try #require(root["properties"] as? [String: Any])
    let version = try #require(properties["protocolVersion"] as? [String: Any])
    #expect(version["const"] as? Int == MobileChatProtocol.version)
    let methods = try #require(properties["methods"] as? [String: Any])
    let items = try #require(methods["items"] as? [String: Any])
    let wireMethods = try #require(items["enum"] as? [String])
    #expect(Set(wireMethods) == Set(MobileChatMethod.allCases.map(\.rawValue)))
    #expect(!wireMethods.contains(where: { $0.contains("canvas") }))
  }

  @Test("Golden host event decodes and re-encodes without attribution drift")
  func goldenEvent() throws {
    let fixture = try Data(
      contentsOf: contractRoot.appending(path: "examples/mobile-host-event-v1.json"))
    let event = try MobileChatCodec.decode(MobileHostEvent.self, from: fixture)
    #expect(event.sequence == 42)
    #expect(event.type == .threadMessage)
    #expect(event.profileID?.uuidString == "33333333-3333-4333-8333-333333333333")
    #expect(event.correlationID?.uuidString == "44444444-4444-4444-8444-444444444444")
    let roundTrip = try MobileChatCodec.decode(
      MobileHostEvent.self, from: MobileChatCodec.encode(event))
    #expect(roundTrip == event)
  }

  private var contractRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Contracts")
  }
}
