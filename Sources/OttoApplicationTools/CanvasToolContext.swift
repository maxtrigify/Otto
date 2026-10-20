import Foundation
import OttoCore
import OttoModels
import OttoTools

extension CanvasStore {
  @MainActor
  func resolvedCanvasID(for context: ToolContext) throws -> UUID {
    if let targetCanvasID = context.targetCanvasID {
      guard snapshot.canvases.contains(where: { $0.id == targetCanvasID }) else {
        throw ToolRegistryError.invalidInput("Target canvas not found: \(targetCanvasID)")
      }
      return targetCanvasID
    }
    if let sourceCanvasID = context.sourceCanvasID {
      guard snapshot.canvases.contains(where: { $0.id == sourceCanvasID }) else {
        throw ToolRegistryError.invalidInput("Source canvas not found: \(sourceCanvasID)")
      }
      return sourceCanvasID
    }
    if let sourceNodeID = context.sourceNodeID,
      let canvasID = canvasID(containing: sourceNodeID)
    {
      return canvasID
    }
    switch context.source {
    case .agent, .automation:
      throw ToolRegistryError.invalidInput(
        "Background requests require a source or target canvas"
      )
    case .userInterface, .voice, .cli, .system:
      return snapshot.activeCanvasID
    }
  }

  @MainActor
  func canvas(for context: ToolContext) throws -> OttoCanvas {
    let canvasID = try resolvedCanvasID(for: context)
    guard let canvas = snapshot.canvases.first(where: { $0.id == canvasID }) else {
      throw ToolRegistryError.invalidInput("Canvas not found: \(canvasID)")
    }
    return canvas
  }

  @MainActor
  func dispatch(_ command: CanvasCommand, context: ToolContext) throws -> CommandReceipt {
    dispatch(command, targetCanvasID: try resolvedCanvasID(for: context))
  }

  @MainActor
  func requiredNode(_ nodeID: UUID, context: ToolContext) throws -> OttoNode {
    let canvas = try canvas(for: context)
    guard let node = canvas.nodes.first(where: { $0.id == nodeID }) else {
      throw ToolRegistryError.invalidInput("Node not found on target canvas: \(nodeID)")
    }
    return node
  }
}
