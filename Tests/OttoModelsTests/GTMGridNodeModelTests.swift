import Foundation
import OttoModels
import Testing

@Suite("GTM Grid node model")
struct GTMGridNodeModelTests {
  @Test("GTM Grid location survives JSON round-trips")
  func contentRoundTrip() throws {
    let content = NodeContent.gtmGrid(
      workspaceID: "workspace-1", projectID: "project-2", tableID: "table-3")
    let decoded = try JSONDecoder().decode(
      NodeContent.self, from: try JSONEncoder().encode(content))
    #expect(decoded == content)
  }

  @Test("GTM Grid has an application-sized default footprint")
  func defaultSize() {
    let size = NodeKind.gtmGrid.defaultSize
    #expect(size.width >= 900)
    #expect(size.height >= 600)
  }

  @Test("GTM Grid is a stable node kind")
  func kindRoundTrip() throws {
    let data = try JSONEncoder().encode(NodeKind.gtmGrid)
    #expect(try JSONDecoder().decode(NodeKind.self, from: data) == .gtmGrid)
    #expect(NodeKind.allCases.contains(.gtmGrid))
  }
}
