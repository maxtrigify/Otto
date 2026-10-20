import Foundation
import OttoModels

public enum BrowserAction: String, Codable, Equatable, Sendable {
  case navigate
  case activateTab
  case back
  case forward
  case refresh
  case stop
}

public enum BrowserAgentControlPhase: String, Codable, Equatable, Sendable {
  case observing
  case acting
}

public struct BrowserRuntimeState: Codable, Equatable, Sendable {
  public var nodeID: UUID
  public var url: String
  public var title: String?
  public var canGoBack: Bool
  public var canGoForward: Bool
  public var isLoading: Bool
  public var errorMessage: String?
  public var revision: Int
  public var requestedAction: BrowserAction
  public var agentControlPhase: BrowserAgentControlPhase?
  public var lastActivity: BrowserActivityEntry?
  public var tabs: [BrowserRuntimeTab]
  public var activeTabID: UUID
  public var selectionModeEnabled: Bool
  public var selectedElement: BrowserElementSelection?

  public init(
    nodeID: UUID,
    url: String,
    title: String? = nil,
    canGoBack: Bool = false,
    canGoForward: Bool = false,
    isLoading: Bool = false,
    errorMessage: String? = nil,
    revision: Int = 0,
    requestedAction: BrowserAction = .navigate,
    agentControlPhase: BrowserAgentControlPhase? = nil,
    lastActivity: BrowserActivityEntry? = nil,
    tabs: [BrowserRuntimeTab]? = nil,
    activeTabID: UUID? = nil,
    selectionModeEnabled: Bool = false,
    selectedElement: BrowserElementSelection? = nil
  ) {
    self.nodeID = nodeID
    self.url = url
    self.title = title
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    self.isLoading = isLoading
    self.errorMessage = errorMessage
    self.revision = revision
    self.requestedAction = requestedAction
    self.agentControlPhase = agentControlPhase
    self.lastActivity = lastActivity
    let resolvedTabs =
      tabs.flatMap { $0.isEmpty ? nil : $0 } ?? [BrowserRuntimeTab(url: url, title: title)]
    self.tabs = resolvedTabs
    self.activeTabID =
      activeTabID.flatMap { id in
        resolvedTabs.contains(where: { $0.id == id }) ? id : nil
      } ?? resolvedTabs[0].id
    self.selectionModeEnabled = selectionModeEnabled
    self.selectedElement = selectedElement
  }
}

public struct BrowserCapture: Equatable, Sendable {
  public var pngData: Data
  public var pixelWidth: Int
  public var pixelHeight: Int

  public init(pngData: Data, pixelWidth: Int, pixelHeight: Int) {
    self.pngData = pngData
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }
}

public typealias BrowserCaptureHandler = @MainActor @Sendable () async throws -> BrowserCapture

public actor BrowserRuntime {
  private var states: [UUID: BrowserRuntimeState] = [:]
  private var subscribers: [UUID: [UUID: AsyncStream<BrowserRuntimeState>.Continuation]] = [:]
  private var captureHandlers: [UUID: BrowserCaptureHandler] = [:]
  private var captureHandlerOwners: [UUID: UUID] = [:]
  private var pageSnapshotHandlers: [UUID: BrowserPageSnapshotHandler] = [:]
  private var interactionHandlers: [UUID: BrowserInteractionHandler] = [:]
  private var interactionAssessmentHandlers: [UUID: BrowserInteractionAssessmentHandler] = [:]
  private var pageHandlerOwners: [UUID: UUID] = [:]
  private var pageSnapshots: [UUID: BrowserPageSnapshot] = [:]

  private var prepareRenderer: (@MainActor @Sendable (BrowserRuntimeState) async throws -> Void)?

  public func setRendererPreparation(
    _ prepare: @escaping @MainActor @Sendable (BrowserRuntimeState) async throws -> Void
  ) {
    prepareRenderer = prepare
  }

  private func ensureRenderer(nodeID: UUID) async throws {
    guard let state = states[nodeID] else { throw BrowserRuntimeError.unknownNode(nodeID) }
    try await prepareRenderer?(state)
  }

  public init() {}

  @discardableResult
  public func register(nodeID: UUID, url: String, tabID: UUID = UUID()) -> BrowserRuntimeState {
    if let state = states[nodeID] { return state }
    let tab = BrowserRuntimeTab(id: tabID, url: url)
    let state = BrowserRuntimeState(
      nodeID: nodeID, url: url, tabs: [tab], activeTabID: tab.id)
    states[nodeID] = state
    return state
  }

  /// Reconciles runtime tab metadata with the persisted browser session.
  ///
  /// BrowserSession owns tab identity and ordering. The runtime retains ephemeral state such as
  /// loading progress and page selection while removing phantom runtime-only tabs left by older
  /// callers. `navigatingTabID` marks a newly opened or retargeted tab whose web view must load.
  @discardableResult
  public func synchronize(
    nodeID: UUID,
    session: BrowserSession,
    navigatingTabID: UUID? = nil
  ) -> BrowserRuntimeState {
    let persistedTabs =
      session.tabs.isEmpty
      ? [
        BrowserRuntimeTab(
          id: session.activeTabID, url: BrowserDefaults.blankURL, title: "New Tab")
      ]
      : session.tabs.map { BrowserRuntimeTab(id: $0.id, url: $0.url, title: $0.title) }
    let persistedActive =
      persistedTabs.first(where: { $0.id == session.activeTabID }) ?? persistedTabs[0]

    guard var state = states[nodeID] else {
      var state = BrowserRuntimeState(
        nodeID: nodeID,
        url: persistedActive.url,
        title: persistedActive.title,
        tabs: persistedTabs,
        activeTabID: persistedActive.id
      )
      if navigatingTabID != nil {
        state.isLoading = true
      }
      states[nodeID] = state
      return state
    }

    var previousTabs: [UUID: BrowserRuntimeTab] = [:]
    for tab in state.tabs { previousTabs[tab.id] = tab }
    state.tabs = persistedTabs.map { persisted in
      guard let current = previousTabs[persisted.id] else { return persisted }
      return BrowserRuntimeTab(
        id: persisted.id,
        url: current.url,
        title: current.title ?? persisted.title
      )
    }

    if navigatingTabID == persistedActive.id {
      state.activeTabID = persistedActive.id
      if let index = state.tabs.firstIndex(where: { $0.id == persistedActive.id }) {
        state.tabs[index] = persistedActive
      }
      state.title = persistedActive.title
      prepareNavigation(&state, url: persistedActive.url)
      return publish(state)
    }

    if state.activeTabID != persistedActive.id {
      prepareTabActivation(&state, tab: persistedActive)
      return publish(state)
    }

    return publish(state)
  }

  public func state(nodeID: UUID) -> BrowserRuntimeState? { states[nodeID] }

  @discardableResult
  public func openTab(nodeID: UUID, url: String, tabID: UUID = UUID()) throws
    -> BrowserRuntimeState
  {
    guard var state = states[nodeID] else { throw BrowserRuntimeError.unknownNode(nodeID) }
    let tab = BrowserRuntimeTab(id: tabID, url: url)
    if let index = state.tabs.firstIndex(where: { $0.id == tabID }) {
      state.tabs[index] = tab
    } else {
      state.tabs.append(tab)
    }
    state.activeTabID = tab.id
    prepareNavigation(&state, url: url)
    return publish(state)
  }

  @discardableResult
  public func selectTab(nodeID: UUID, tabID: UUID) throws -> BrowserRuntimeState {
    guard let state = states[nodeID] else { throw BrowserRuntimeError.unknownNode(nodeID) }
    guard let tab = state.tabs.first(where: { $0.id == tabID }) else {
      throw BrowserRuntimeError.unknownTab(tabID)
    }
    guard state.activeTabID != tabID else { return state }
    return try activateTab(nodeID: nodeID, tab: tab)
  }

  /// Makes an existing rendered tab active without requesting a new navigation.
  ///
  /// Tab switching must not be expressed as `.navigate`: the renderer keeps one live page per
  /// tab, and loading the recorded URL again destroys transient DOM state such as verification
  /// forms. The tab is upserted because persisted canvas sessions can be restored before the
  /// runtime has seen all of their tab identifiers.
  @discardableResult
  public func activateTab(nodeID: UUID, tab: BrowserRuntimeTab) throws -> BrowserRuntimeState {
    guard var state = states[nodeID] else { throw BrowserRuntimeError.unknownNode(nodeID) }
    if let index = state.tabs.firstIndex(where: { $0.id == tab.id }) {
      state.tabs[index] = tab
    } else {
      state.tabs.append(tab)
    }
    prepareTabActivation(&state, tab: tab)
    return publish(state)
  }

  @discardableResult
  public func closeTab(
    nodeID: UUID,
    tabID: UUID,
    activating replacementTab: BrowserRuntimeTab? = nil
  ) throws -> BrowserRuntimeState {
    guard var state = states[nodeID] else { throw BrowserRuntimeError.unknownNode(nodeID) }
    guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
      throw BrowserRuntimeError.unknownTab(tabID)
    }
    if state.tabs.count == 1 {
      let replacement = replacementTab ?? BrowserRuntimeTab(url: "https://www.google.com")
      state.tabs = [replacement]
      state.activeTabID = replacement.id
      state.title = nil
      prepareTabActivation(&state, tab: replacement)
    } else {
      let wasActive = state.activeTabID == tabID
      state.tabs.remove(at: index)
      guard wasActive else { return publish(state) }
      let next = replacementTab ?? state.tabs[min(index, state.tabs.count - 1)]
      if let replacementTab,
        let nextIndex = state.tabs.firstIndex(where: { $0.id == replacementTab.id })
      {
        state.tabs[nextIndex] = replacementTab
      }
      prepareTabActivation(&state, tab: next)
    }
    return publish(state)
  }

  @discardableResult
  public func setSelectionMode(nodeID: UUID, enabled: Bool) throws -> BrowserRuntimeState {
    guard var state = states[nodeID] else { throw BrowserRuntimeError.unknownNode(nodeID) }
    state.selectionModeEnabled = enabled
    if enabled { state.selectedElement = nil }
    return publish(state)
  }

  @discardableResult
  public func reportSelection(nodeID: UUID, selection: BrowserElementSelection)
    throws -> BrowserRuntimeState
  {
    guard var state = states[nodeID] else { throw BrowserRuntimeError.unknownNode(nodeID) }
    state.selectionModeEnabled = false
    state.selectedElement = selection
    return publish(state)
  }

  @discardableResult
  public func clearSelection(nodeID: UUID) throws -> BrowserRuntimeState {
    guard var state = states[nodeID] else { throw BrowserRuntimeError.unknownNode(nodeID) }
    state.selectionModeEnabled = false
    state.selectedElement = nil
    return publish(state)
  }

  public func registerCaptureHandler(
    nodeID: UUID,
    ownerID: UUID? = nil,
    handler: @escaping BrowserCaptureHandler
  ) {
    captureHandlers[nodeID] = handler
    captureHandlerOwners[nodeID] = ownerID
  }

  public func unregisterCaptureHandler(nodeID: UUID, ownerID: UUID? = nil) {
    if let ownerID, captureHandlerOwners[nodeID] != ownerID { return }
    captureHandlers[nodeID] = nil
    captureHandlerOwners[nodeID] = nil
  }

  public func registerPageHandler(
    nodeID: UUID,
    ownerID: UUID? = nil,
    snapshot: @escaping BrowserPageSnapshotHandler,
    interact: @escaping BrowserInteractionHandler,
    assess: BrowserInteractionAssessmentHandler? = nil
  ) {
    pageSnapshotHandlers[nodeID] = snapshot
    interactionHandlers[nodeID] = interact
    interactionAssessmentHandlers[nodeID] = assess
    pageHandlerOwners[nodeID] = ownerID
  }

  public func unregisterPageHandler(nodeID: UUID, ownerID: UUID? = nil) {
    if let ownerID, pageHandlerOwners[nodeID] != ownerID { return }
    pageSnapshotHandlers[nodeID] = nil
    interactionHandlers[nodeID] = nil
    interactionAssessmentHandlers[nodeID] = nil
    pageSnapshots[nodeID] = nil
    pageHandlerOwners[nodeID] = nil
  }

  public func inspectPage(nodeID: UUID) async throws -> BrowserPageSnapshot {
    try await ensureRenderer(nodeID: nodeID)
    guard states[nodeID] != nil else { throw BrowserRuntimeError.unknownNode(nodeID) }
    guard let handler = pageSnapshotHandlers[nodeID] else {
      throw BrowserRuntimeError.pageInspectionUnavailable(nodeID)
    }
    setAgentControlPhase(.observing, nodeID: nodeID)
    defer { setAgentControlPhase(nil, nodeID: nodeID) }
    do {
      let snapshot = try await handler(nodeID)
      pageSnapshots[nodeID] = snapshot
      recordActivity(
        nodeID: nodeID,
        kind: .observation,
        title: "Mapped page",
        detail: "\(snapshot.elements.count) interactive elements"
      )
      return snapshot
    } catch {
      recordActivity(
        nodeID: nodeID, kind: .warning, title: "Page inspection failed",
        detail: error.localizedDescription, succeeded: false)
      throw error
    }
  }

  public func resolveElement(
    nodeID: UUID,
    reference: String
  ) async throws -> BrowserResolvedElement {
    let snapshot: BrowserPageSnapshot
    // Copy the optional before suspending. Holding a Dictionary subscript borrow across the
    // recursive await lets inspectPage re-enter this actor and violates Swift exclusivity.
    let cachedSnapshot = pageSnapshots[nodeID]
    if let cached = cachedSnapshot {
      snapshot = cached
    } else {
      snapshot = try await inspectPage(nodeID: nodeID)
    }
    if let element = snapshot.elements.first(where: { $0.id == reference }) {
      return BrowserResolvedElement(elementID: element.id, pageRevision: snapshot.pageRevision)
    }
    let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    let matches = snapshot.elements.filter {
      $0.name.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive])
        == .orderedSame
    }
    guard matches.count == 1, let element = matches.first else {
      if matches.count > 1 { throw BrowserRuntimeError.pageElementAmbiguous(reference) }
      throw BrowserRuntimeError.pageElementNotFound(reference)
    }
    return BrowserResolvedElement(elementID: element.id, pageRevision: snapshot.pageRevision)
  }

  public func latestPageRevision(nodeID: UUID) async throws -> String {
    let cachedRevision = pageSnapshots[nodeID]?.pageRevision
    if let revision = cachedRevision { return revision }
    return try await inspectPage(nodeID: nodeID).pageRevision
  }

  public func interact(
    nodeID: UUID,
    request: BrowserInteractionRequest
  ) async throws -> BrowserInteractionResult {
    try await ensureRenderer(nodeID: nodeID)
    guard states[nodeID] != nil else { throw BrowserRuntimeError.unknownNode(nodeID) }
    guard let handler = interactionHandlers[nodeID] else {
      throw BrowserRuntimeError.pageInteractionUnavailable(nodeID)
    }
    setAgentControlPhase(.acting, nodeID: nodeID)
    defer { setAgentControlPhase(nil, nodeID: nodeID) }
    do {
      let result = try await handler(nodeID, request)
      let elementName = request.elementID.flatMap { id in
        pageSnapshots[nodeID]?.elements.first(where: { $0.id == id })?.name
      }
      let title: String
      switch request.kind {
      case .click:
        title = "Clicked \(elementName?.isEmpty == false ? elementName! : "page element")"
      case .type:
        title = "Entered text in \(elementName?.isEmpty == false ? elementName! : "field")"
      case .scroll: title = "Scrolled page"
      }
      recordActivity(nodeID: nodeID, kind: .interaction, title: title)
      return result
    } catch {
      recordActivity(
        nodeID: nodeID, kind: .warning, title: "Browser action failed",
        detail: error.localizedDescription, succeeded: false)
      throw error
    }
  }

  public func assessInteraction(
    nodeID: UUID,
    request: BrowserInteractionRequest
  ) async throws -> BrowserInteractionAssessment {
    try await ensureRenderer(nodeID: nodeID)
    guard states[nodeID] != nil else { throw BrowserRuntimeError.unknownNode(nodeID) }
    guard let handler = interactionAssessmentHandlers[nodeID] else {
      return BrowserInteractionAssessment(
        requiresConfirmation: true,
        reason: "This browser renderer cannot classify the selected action"
      )
    }
    return try await handler(nodeID, request)
  }

  public func capture(nodeID: UUID) async throws -> BrowserCapture {
    try await ensureRenderer(nodeID: nodeID)
    guard states[nodeID] != nil else { throw BrowserRuntimeError.unknownNode(nodeID) }
    guard let handler = captureHandlers[nodeID] else {
      throw BrowserRuntimeError.captureUnavailable(nodeID)
    }
    let capture = try await handler()
    recordActivity(
      nodeID: nodeID,
      kind: .evidence,
      title: "Captured evidence",
      detail: "\(capture.pixelWidth) × \(capture.pixelHeight)"
    )
    return capture
  }

  public func reportPageDiagnostic(nodeID: UUID, message: String) {
    guard states[nodeID] != nil else { return }
    let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    recordActivity(
      nodeID: nodeID,
      kind: .warning,
      title: "Page reported an error",
      detail: String(clean.prefix(320)),
      succeeded: false
    )
  }

  public func updates(nodeID: UUID) -> AsyncStream<BrowserRuntimeState> {
    let subscriberID = UUID()
    return AsyncStream { continuation in
      subscribers[nodeID, default: [:]][subscriberID] = continuation
      if let state = states[nodeID] { continuation.yield(state) }
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeSubscriber(subscriberID, nodeID: nodeID) }
      }
    }
  }

  @discardableResult
  public func navigate(nodeID: UUID, url: String) throws -> BrowserRuntimeState {
    guard var state = states[nodeID] else { throw BrowserRuntimeError.unknownNode(nodeID) }
    state.url = url
    if let index = state.tabs.firstIndex(where: { $0.id == state.activeTabID }) {
      state.tabs[index].url = url
      state.tabs[index].title = nil
    }
    state.requestedAction = .navigate
    state.isLoading = true
    state.errorMessage = nil
    state.revision += 1
    return publish(state)
  }

  @discardableResult
  public func back(nodeID: UUID) throws -> BrowserRuntimeState {
    try request(.back, nodeID: nodeID)
  }

  @discardableResult
  public func forward(nodeID: UUID) throws -> BrowserRuntimeState {
    try request(.forward, nodeID: nodeID)
  }

  @discardableResult
  public func refresh(nodeID: UUID) throws -> BrowserRuntimeState {
    try request(.refresh, nodeID: nodeID)
  }

  @discardableResult
  public func stop(nodeID: UUID) throws -> BrowserRuntimeState {
    try request(.stop, nodeID: nodeID)
  }

  public func reportLoaded(
    nodeID: UUID,
    url: String,
    title: String?,
    canGoBack: Bool,
    canGoForward: Bool,
    isLoading: Bool,
    errorMessage: String? = nil,
    expectedRevision: Int? = nil
  ) throws {
    guard var state = states[nodeID] else { throw BrowserRuntimeError.unknownNode(nodeID) }
    guard expectedRevision == nil || state.revision == expectedRevision else { return }
    let previousURL = state.url
    state.url = url
    state.title = title
    if let index = state.tabs.firstIndex(where: { $0.id == state.activeTabID }) {
      state.tabs[index].url = url
      state.tabs[index].title = title
    }
    state.canGoBack = canGoBack
    state.canGoForward = canGoForward
    state.isLoading = isLoading
    state.errorMessage = errorMessage
    _ = publish(state)
    if previousURL != url {
      recordActivity(nodeID: nodeID, kind: .navigation, title: "Opened page", detail: url)
    }
    if let errorMessage {
      recordActivity(
        nodeID: nodeID, kind: .warning, title: "Page failed to load",
        detail: errorMessage, succeeded: false)
    }
  }

  private func request(_ action: BrowserAction, nodeID: UUID) throws -> BrowserRuntimeState {
    guard var state = states[nodeID] else { throw BrowserRuntimeError.unknownNode(nodeID) }
    state.requestedAction = action
    state.isLoading = action != .stop
    if action != .stop { state.errorMessage = nil }
    state.revision += 1
    return publish(state)
  }

  private func prepareNavigation(_ state: inout BrowserRuntimeState, url: String) {
    state.url = url
    state.canGoBack = false
    state.canGoForward = false
    state.requestedAction = .navigate
    state.isLoading = true
    state.errorMessage = nil
    state.selectionModeEnabled = false
    state.selectedElement = nil
    state.revision += 1
  }

  private func prepareTabActivation(
    _ state: inout BrowserRuntimeState,
    tab: BrowserRuntimeTab
  ) {
    state.activeTabID = tab.id
    state.url = tab.url
    state.title = tab.title
    state.canGoBack = false
    state.canGoForward = false
    state.requestedAction = .activateTab
    state.isLoading = false
    state.errorMessage = nil
    state.selectionModeEnabled = false
    state.selectedElement = nil
    state.revision += 1
  }

  private func publish(_ state: BrowserRuntimeState) -> BrowserRuntimeState {
    states[state.nodeID] = state
    for continuation in subscribers[state.nodeID]?.values ?? [:].values {
      continuation.yield(state)
    }
    return state
  }

  private func setAgentControlPhase(_ phase: BrowserAgentControlPhase?, nodeID: UUID) {
    guard var state = states[nodeID] else { return }
    state.agentControlPhase = phase
    _ = publish(state)
  }

  private func removeSubscriber(_ subscriberID: UUID, nodeID: UUID) {
    subscribers[nodeID]?[subscriberID] = nil
    if subscribers[nodeID]?.isEmpty == true { subscribers[nodeID] = nil }
  }

  private func recordActivity(
    nodeID: UUID,
    kind: BrowserActivityKind,
    title: String,
    detail: String? = nil,
    succeeded: Bool = true
  ) {
    guard var state = states[nodeID] else { return }
    state.lastActivity = BrowserActivityEntry(
      kind: kind, title: title, detail: detail, succeeded: succeeded)
    _ = publish(state)
  }

}

public enum BrowserRuntimeError: Error, LocalizedError, Equatable, Sendable {
  case unknownNode(UUID)
  case unknownTab(UUID)
  case captureUnavailable(UUID)
  case pageInspectionUnavailable(UUID)
  case pageInteractionUnavailable(UUID)
  case stalePageSnapshot
  case pageElementNotFound(String)
  case pageElementAmbiguous(String)

  public var errorDescription: String? {
    switch self {
    case .unknownNode(let id): "Browser node \(id.uuidString) has no active session"
    case .unknownTab(let id): "Browser tab \(id.uuidString) is no longer open"
    case .captureUnavailable(let id):
      "Browser node \(id.uuidString) has no available renderer for screenshot capture"
    case .pageInspectionUnavailable(let id):
      "Browser node \(id.uuidString) has no available renderer for page inspection"
    case .pageInteractionUnavailable(let id):
      "Browser node \(id.uuidString) has no available renderer for page interaction"
    case .stalePageSnapshot:
      "The page changed after it was inspected; inspect it again before interacting"
    case .pageElementNotFound(let id):
      "Page element \(id) is no longer available; inspect the page again"
    case .pageElementAmbiguous(let name):
      "More than one page element is named \(name); inspect the page and use its element ID"
    }
  }
}
