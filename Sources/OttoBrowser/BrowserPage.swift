import Foundation

public struct BrowserElementBounds: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public enum BrowserElementAction: String, Codable, Equatable, Sendable {
  case click
  case type
  case select
}

public struct BrowserPageElement: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var role: String
  public var name: String
  public var placeholder: String?
  public var bounds: BrowserElementBounds
  public var actions: [BrowserElementAction]
  public var isDisabled: Bool
  public var isSensitive: Bool

  public init(
    id: String,
    role: String,
    name: String,
    placeholder: String? = nil,
    bounds: BrowserElementBounds,
    actions: [BrowserElementAction],
    isDisabled: Bool = false,
    isSensitive: Bool = false
  ) {
    self.id = id
    self.role = role
    self.name = name
    self.placeholder = placeholder
    self.bounds = bounds
    self.actions = actions
    self.isDisabled = isDisabled
    self.isSensitive = isSensitive
  }
}

/// A renderer-neutral, accessibility-shaped view of the current page. Element identifiers are
/// deliberately scoped to `revision`: callers must inspect again after the DOM changes.
public struct BrowserPageSnapshot: Codable, Equatable, Sendable {
  public var nodeID: UUID
  public var url: String
  public var title: String?
  public var pageRevision: String
  public var elements: [BrowserPageElement]

  public init(
    nodeID: UUID,
    url: String,
    title: String? = nil,
    pageRevision: String,
    elements: [BrowserPageElement]
  ) {
    self.nodeID = nodeID
    self.url = url
    self.title = title
    self.pageRevision = pageRevision
    self.elements = elements
  }
}

public enum BrowserInteractionKind: String, Codable, Equatable, Sendable {
  case click
  case type
  case scroll
}

public struct BrowserInteractionRequest: Codable, Equatable, Sendable {
  public var revision: String
  public var kind: BrowserInteractionKind
  public var elementID: String?
  public var text: String?
  public var deltaX: Double?
  public var deltaY: Double?

  public init(
    revision: String,
    kind: BrowserInteractionKind,
    elementID: String? = nil,
    text: String? = nil,
    deltaX: Double? = nil,
    deltaY: Double? = nil
  ) {
    self.revision = revision
    self.kind = kind
    self.elementID = elementID
    self.text = text
    self.deltaX = deltaX
    self.deltaY = deltaY
  }
}

public struct BrowserInteractionResult: Codable, Equatable, Sendable {
  public var nodeID: UUID
  public var pageRevision: String
  public var url: String
  public var message: String

  public init(nodeID: UUID, pageRevision: String, url: String, message: String) {
    self.nodeID = nodeID
    self.pageRevision = pageRevision
    self.url = url
    self.message = message
  }
}

public struct BrowserResolvedElement: Equatable, Sendable {
  public var elementID: String
  public var pageRevision: String

  public init(elementID: String, pageRevision: String) {
    self.elementID = elementID
    self.pageRevision = pageRevision
  }
}

public struct BrowserInteractionAssessment: Codable, Equatable, Sendable {
  public var requiresConfirmation: Bool
  public var reason: String?

  public init(requiresConfirmation: Bool, reason: String? = nil) {
    self.requiresConfirmation = requiresConfirmation
    self.reason = reason
  }
}

public typealias BrowserPageSnapshotHandler =
  @MainActor @Sendable (_ nodeID: UUID) async throws -> BrowserPageSnapshot
public typealias BrowserInteractionHandler =
  @MainActor @Sendable (_ nodeID: UUID, _ request: BrowserInteractionRequest) async throws
  -> BrowserInteractionResult
public typealias BrowserInteractionAssessmentHandler =
  @MainActor @Sendable (_ nodeID: UUID, _ request: BrowserInteractionRequest) async throws
  -> BrowserInteractionAssessment
