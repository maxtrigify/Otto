import Foundation
import OttoModels
import Testing

@Suite("Custom widget node model")
struct WidgetNodeModelTests {
  @Test("Widget packages and state survive JSON round-trips")
  func contentRoundTrip() throws {
    let content = NodeContent.widget(
      packagePath: "Widgets/social-pulse", state: #"{"lastUpdated":42}"#)
    let data = try JSONEncoder().encode(content)
    #expect(try JSONDecoder().decode(NodeContent.self, from: data) == content)
  }

  @Test("Widget manifests describe network access and local schedules")
  func manifestRoundTrip() throws {
    let manifest = WidgetManifest(
      name: "Social Pulse",
      description: "Creator metrics",
      permissions: WidgetPermissions(network: ["https://api.example.com"]),
      schedule: WidgetSchedule(enabled: true, intervalSeconds: 60)
    )
    let data = try JSONEncoder().encode(manifest)
    #expect(try JSONDecoder().decode(WidgetManifest.self, from: data) == manifest)
  }

  @Test("Widget is a stable canvas node with a compact dashboard footprint")
  func kindContract() throws {
    let data = try JSONEncoder().encode(NodeKind.widget)
    #expect(try JSONDecoder().decode(NodeKind.self, from: data) == .widget)
    #expect(NodeKind.allCases.contains(.widget))
    #expect(NodeKind.widget.defaultSize.width == 460)
    #expect(NodeKind.widget.defaultSize.height == 340)
  }
}
