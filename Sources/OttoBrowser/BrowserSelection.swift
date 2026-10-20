import Foundation

public struct BrowserRuntimeTab: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var url: String
  public var title: String?

  public init(id: UUID = UUID(), url: String, title: String? = nil) {
    self.id = id
    self.url = url
    self.title = title
  }
}

public struct BrowserElementSelection: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var nodeID: UUID
  public var tabID: UUID
  public var url: String
  public var route: String
  public var tagName: String
  public var role: String?
  public var accessibleName: String
  public var text: String
  public var selector: String
  public var bounds: BrowserElementBounds
  public var styles: [String: String]
  public var capturedAt: Date

  public init(
    id: UUID = UUID(),
    nodeID: UUID,
    tabID: UUID,
    url: String,
    route: String,
    tagName: String,
    role: String? = nil,
    accessibleName: String,
    text: String,
    selector: String,
    bounds: BrowserElementBounds,
    styles: [String: String] = [:],
    capturedAt: Date = .now
  ) {
    self.id = id
    self.nodeID = nodeID
    self.tabID = tabID
    self.url = url
    self.route = route
    self.tagName = tagName
    self.role = role
    self.accessibleName = accessibleName
    self.text = text
    self.selector = selector
    self.bounds = bounds
    self.styles = styles
    self.capturedAt = capturedAt
  }
}
