import Foundation
import OttoModels
import Testing

@Suite("Whiteboard node model")
struct WhiteboardModelTests {
  @Test("Whiteboard documents and queued actions survive JSON round-trips")
  func contentRoundTrip() throws {
    let shape = WhiteboardShape(
      id: "auth-start",
      type: .rectangle,
      x: 40,
      y: 80,
      width: 220,
      height: 120,
      text: "Authenticate",
      color: "green"
    )
    let content = NodeContent.whiteboard(
      document: "{\"store\":{}}",
      pendingActions: [WhiteboardAction(kind: .createShapes, shapes: [shape])]
    )

    let decoded = try JSONDecoder().decode(
      NodeContent.self,
      from: try JSONEncoder().encode(content)
    )

    #expect(decoded == content)
  }

  @Test("Whiteboards default to a useful drawing footprint")
  func defaultSize() {
    let size = NodeKind.whiteboard.defaultSize
    #expect(size.width >= 700)
    #expect(size.height >= 500)
  }
}
