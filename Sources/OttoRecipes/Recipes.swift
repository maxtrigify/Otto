import Foundation
import OttoCore
import OttoModels

public struct RecipeNode: Codable, Sendable, Equatable {
  public var kind: NodeKind
  public var x: Double
  public var y: Double
  public var width: Double?
  public var height: Double?
  public var displayName: String?
  public var content: NodeContent?

  public init(
    kind: NodeKind,
    x: Double,
    y: Double,
    width: Double? = nil,
    height: Double? = nil,
    displayName: String? = nil,
    content: NodeContent? = nil
  ) {
    self.kind = kind
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.displayName = displayName
    self.content = content
  }
}

public struct RecipeDefinition: Codable, Sendable, Equatable {
  public var id: String
  public var name: String
  public var version: Int
  public var description: String
  public var nodes: [RecipeNode]
  public var themeID: String?
  public var layoutMode: LayoutMode?

  public init(
    id: String,
    name: String,
    version: Int = 1,
    description: String,
    nodes: [RecipeNode],
    themeID: String? = nil,
    layoutMode: LayoutMode? = nil
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.description = description
    self.nodes = nodes
    self.themeID = themeID
    self.layoutMode = layoutMode
  }
}

public enum RecipeError: Error, LocalizedError, Sendable, Equatable {
  case invalid(String)

  public var errorDescription: String? {
    switch self {
    case .invalid(let message): "Invalid recipe: \(message)"
    }
  }
}

public enum RecipeValidator {
  public static func validate(_ recipe: RecipeDefinition) throws {
    guard !recipe.id.isEmpty, recipe.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
    else {
      throw RecipeError.invalid("ID must contain only letters, numbers, and hyphens")
    }
    guard !recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RecipeError.invalid("Name is required")
    }
    guard recipe.version > 0 else { throw RecipeError.invalid("Version must be positive") }
    guard recipe.nodes.count <= 50 else {
      throw RecipeError.invalid("Recipes may create at most 50 nodes")
    }

    let encoded = String(decoding: try JSONEncoder().encode(recipe), as: UTF8.self).lowercased()
    let credentialMarkers = [
      "api_key=", "apikey=", "access_token=", "password=", "bearer ", "sk-ant-", "sk-proj-",
      "ghp_", "github_pat_", "xoxb-", "xapp-", "akia", "private key-----",
    ]
    if let marker = credentialMarkers.first(where: { encoded.contains($0) }) {
      throw RecipeError.invalid("Definition appears to contain a credential marker (\(marker))")
    }
    for node in recipe.nodes {
      guard node.x.isFinite, node.y.isFinite else {
        throw RecipeError.invalid("Node coordinates must be finite")
      }
      if let width = node.width, !width.isFinite || width < 260 || width > 4_000 {
        throw RecipeError.invalid("Node width is outside the supported range")
      }
      if let height = node.height, !height.isFinite || height < 180 || height > 4_000 {
        throw RecipeError.invalid("Node height is outside the supported range")
      }
      try validateContent(node.content, for: node.kind)
      if case .markdown(let path?, _) = node.content,
        path.hasPrefix("/") || NSString(string: path).pathComponents.contains("..")
      {
        throw RecipeError.invalid("Document paths must stay inside the workspace")
      }
    }
    if let themeID = recipe.themeID, OttoThemeCatalog.canonicalID(themeID) == nil {
      throw RecipeError.invalid("Unknown theme: \(themeID)")
    }
  }

  private static func validateContent(_ content: NodeContent?, for kind: NodeKind) throws {
    guard let content else { return }
    let matches =
      switch (kind, content) {
      case (.agent, .agent), (.terminal, .terminal), (.browser, .browser),
        (.markdown, .markdown), (.media, .media), (.label, .label), (.group, .group),
        (.connector, .connector), (.appMirror, .appMirror), (.whiteboard, .whiteboard),
        (.gtmGrid, .gtmGrid), (.widget, .widget):
        true
      default: false
      }
    guard matches else { throw RecipeError.invalid("Node content does not match its kind") }

    switch content {
    case .browser(let value):
      guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased())
      else { throw RecipeError.invalid("Browser URLs must use HTTP or HTTPS") }
      guard url.user == nil, url.password == nil, !containsSensitiveQuery(url) else {
        throw RecipeError.invalid("Browser URL appears to contain credentials")
      }
    case .media(let value):
      if let url = URL(string: value), url.scheme != nil {
        guard ["http", "https"].contains(url.scheme?.lowercased()),
          url.user == nil, url.password == nil, !containsSensitiveQuery(url)
        else { throw RecipeError.invalid("Media URL appears unsafe or credential-bearing") }
      } else if value.hasPrefix("/") || NSString(string: value).pathComponents.contains("..") {
        throw RecipeError.invalid("Media paths must stay inside the workspace")
      }
    case .terminal(let shell):
      guard shell.hasPrefix("/"), !NSString(string: shell).pathComponents.contains("..") else {
        throw RecipeError.invalid("Terminal shell must be an absolute normalized path")
      }
    case .agent, .markdown, .label, .group, .connector:
      break
    case .appMirror:
      // Window identifiers are session-scoped; recipes reproduce the node in picking mode.
      break
    case .whiteboard(let document, let pendingActions):
      guard (document?.utf8.count ?? 0) <= 4_194_304 else {
        throw RecipeError.invalid("Whiteboard documents are limited to 4 MB")
      }
      guard pendingActions.count <= 500 else {
        throw RecipeError.invalid("Whiteboard recipes may queue at most 500 actions")
      }
    case .gtmGrid:
      break
    case .widget(let packagePath, let state):
      guard !packagePath.isEmpty, !packagePath.hasPrefix("/"),
        !NSString(string: packagePath).pathComponents.contains("..")
      else { throw RecipeError.invalid("Widget packages must stay inside the workspace") }
      guard state.utf8.count <= 1_048_576,
        let data = state.data(using: .utf8),
        (try? JSONSerialization.jsonObject(with: data)) != nil
      else { throw RecipeError.invalid("Widget state must be valid JSON under 1 MB") }
    }
  }

  private static func containsSensitiveQuery(_ url: URL) -> Bool {
    let sensitive = ["key", "token", "secret", "password", "signature", "credential"]
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { item in
      sensitive.contains { item.name.lowercased().contains($0) }
    } ?? false
  }
}

public enum RecipeCapture {
  public static func capture(
    id: String,
    name: String,
    description: String,
    version: Int,
    canvas: OttoCanvas
  ) -> RecipeDefinition {
    RecipeDefinition(
      id: id,
      name: name,
      version: version,
      description: description,
      nodes: canvas.nodes.sorted { $0.zIndex < $1.zIndex }.map { node in
        RecipeNode(
          kind: node.kind,
          x: node.frame.x,
          y: node.frame.y,
          width: node.frame.width,
          height: node.frame.height,
          displayName: node.displayName,
          content: node.content
        )
      },
      themeID: canvas.themeID,
      layoutMode: canvas.layoutMode
    )
  }
}

@MainActor
public enum RecipeEngine {
  public static func boot(
    _ recipe: RecipeDefinition,
    into store: CanvasStore,
    targetCanvasID: UUID? = nil
  ) throws -> [UUID] {
    try RecipeValidator.validate(recipe)
    var ids: [UUID] = []
    for node in recipe.nodes {
      let receipt = store.dispatch(
        .createNode(kind: node.kind, at: WorldPoint(x: node.x, y: node.y)),
        targetCanvasID: targetCanvasID
      )
      guard let id = receipt.affectedNodeIDs.first else { continue }
      ids.append(id)
      if let content = node.content {
        store.dispatch(
          .setNodeContent(id: id, content: content),
          targetCanvasID: targetCanvasID
        )
      }
    }
    if let themeID = recipe.themeID {
      store.dispatch(.setTheme(themeID), targetCanvasID: targetCanvasID)
    }
    if let layout = recipe.layoutMode {
      store.dispatch(
        layout == .organized ? .organize : .setLayout(layout),
        targetCanvasID: targetCanvasID
      )
    }
    for (id, node) in zip(ids, recipe.nodes) {
      store.dispatch(
        .moveNode(id: id, to: WorldPoint(x: node.x, y: node.y)),
        targetCanvasID: targetCanvasID
      )
      if let width = node.width, let height = node.height {
        store.dispatch(
          .resizeNode(id: id, width: width, height: height),
          targetCanvasID: targetCanvasID
        )
      }
      if let displayName = node.displayName {
        store.dispatch(.renameNode(id: id, name: displayName), targetCanvasID: targetCanvasID)
      }
    }
    return ids
  }
}
