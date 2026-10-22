import AppKit
import Combine
import OttoCore
import OttoModels
import OttoObservability
import OttoPersistence
import OttoServices
import OttoTools
import SwiftUI

private struct SpaceVisibleKey: EnvironmentKey {
  static let defaultValue = true
}
private struct SwitchSpaceKey: EnvironmentKey {
  static let defaultValue: @MainActor (OttoProfile) async throws -> Void = { _ in
    throw OttoProfileRegistry.RegistryError.unavailable("Space switching is not ready.")
  }
}
extension EnvironmentValues {
  var ottoSpaceVisible: Bool {
    get { self[SpaceVisibleKey.self] }
    set { self[SpaceVisibleKey.self] = newValue }
  }
  var ottoSwitchSpace: @MainActor (OttoProfile) async throws -> Void {
    get { self[SwitchSpaceKey.self] }
    set { self[SwitchSpaceKey.self] = newValue }
  }
}

/// Strong ownership lasts until the app quits, independent of which view is on screen.
@MainActor
final class OttoSpaceRuntime: Identifiable {
  let id: String
  let store: CanvasStore
  let services: ApplicationServices
  let voice: VoiceController
  let uiState = WorkspaceUIState()
  private var startup: Task<Void, Never>?

  init(store: CanvasStore, services: ApplicationServices, voice: VoiceController) {
    id = URL(fileURLWithPath: services.defaultWorkspacePath).standardizedFileURL.path
    self.store = store
    self.services = services
    self.voice = voice
  }

  func start() {
    guard startup == nil else { return }
    // A view's .task is cancelled when it leaves the hierarchy; runtime startup must survive it.
    startup = Task { @MainActor in
      if store.isAwaitingRestore { await store.restore() }
      await BrowserRendererPool.configure(store: store, runtime: services.browserRuntime)
      await services.start()
      services.websiteAccounts.onOpenLogin = { [weak services = services] id in
        guard let services else { return }
        PrivateWebsiteLoginWindows.shared.open(id, service: services.websiteAccounts)
      }
      services.messaging.start()
    }
  }

  func ready() async { await startup?.value }
}

@MainActor
final class OttoSpaceController: ObservableObject {
  @Published private(set) var active: OttoSpaceRuntime
  @Published private(set) var opened: [OttoSpaceRuntime]
  private let registry: OttoProfileRegistry?
  private let observability: ObservabilityStore?
  private let presentationEnabled: Bool
  private var presentation: Task<Void, Never>?
  private var isSwitching = false

  init(
    initial: OttoSpaceRuntime, registry: OttoProfileRegistry?,
    observability: ObservabilityStore? = nil,
    presentationEnabled: Bool = true
  ) {
    active = initial
    opened = [initial]
    self.registry = registry
    self.observability = observability
    self.presentationEnabled = presentationEnabled
    CompletionNotifications.shared.onOpenConversation = { [weak self] nodeID in
      guard let self,
        let owner = opened.first(where: {
          $0.store.snapshot.canvases.contains { $0.nodes.contains { $0.id == nodeID } }
        })
      else { return }
      Task { @MainActor in
        if let profile = registry?.profile(workspacePath: owner.id) {
          do { try await switchTo(profile) } catch { return }
        }
        await Task.yield()
        NotificationCenter.default.post(name: .ottoOpenCompletedConversation, object: nodeID)
      }
    }
  }

  func startActive() {
    active.start()
    presentActive(previous: nil)
  }

  func switchTo(_ profile: OttoProfile) async throws {
    guard !isSwitching else {
      throw OttoProfileRegistry.RegistryError.unavailable(
        "Another space is opening. Try again in a moment.")
    }
    isSwitching = true
    defer { isSwitching = false }
    guard let registry, let target = registry.profile(id: profile.id) else {
      throw OttoProfileRegistry.RegistryError.unknownProfile
    }
    let key = URL(fileURLWithPath: target.workspacePath).standardizedFileURL.path
    guard key != active.id else { return }
    // Construct/open the destination before touching the current space. A failed database open
    // leaves both the running agents and the visible space alone.
    let runtime: OttoSpaceRuntime
    if let existing = opened.first(where: { $0.id == key }) {
      runtime = existing
    } else {
      runtime = try await makeRuntime(profile: target, registry: registry)
    }
    try registry.setActive(target.id)
    let previous = active
    if !opened.contains(where: { $0.id == key }) { opened.append(runtime) }
    NSApp?.keyWindow?.makeFirstResponder(nil)
    active = runtime
    runtime.start()
    presentActive(previous: previous)
  }

  private func makeRuntime(profile: OttoProfile, registry: OttoProfileRegistry) async throws
    -> OttoSpaceRuntime
  {
    let locations = registry.locations(for: profile)
    OttoWorkspaceMigration.migrateStateFolder(workspacePath: profile.workspacePath)
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: locations.databasePath).deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let database = SQLiteWorkspaceStore(path: locations.databasePath)
    try await database.migrate()
    let store = CanvasStore(persistence: database)
    await store.restore()
    if let error = store.persistenceError {
      throw OttoProfileRegistry.RegistryError.unavailable(error)
    }
    var sinks: [any ToolAuditSink] = [database]
    if let observability { sinks.append(observability) }
    let tools = ToolRegistry(auditSink: CompositeToolAuditSink(sinks))
    Task { try? await tools.register(AuditRecentTool(store: database)) }
    let services = ApplicationServices(
      store: store, registry: tools, observability: observability,
      providerAccounts: opened[0].services.providerAccounts, workspacePath: profile.workspacePath,
      personalMemoryPath: locations.personalMemoryPath,
      profiles: registry)
    let voice = VoiceController(
      registry: tools, store: store, services: services, observability: observability,
      workspacePath: profile.workspacePath)
    return OttoSpaceRuntime(store: store, services: services, voice: voice)
  }

  private func presentActive(previous: OttoSpaceRuntime?) {
    guard presentationEnabled else { return }
    CompletionNotifications.shared.start(services: active.services, store: active.store)
    // Serialize microphone ownership even when the user switches again during startup.
    let preceding = presentation
    let target = active
    presentation = Task { @MainActor in
      await preceding?.value
      if let previous { await previous.voice.setSpaceActive(false) }
      await target.ready()
      guard active === target else { return }
      ProviderModelCatalogStore.shared.configure(
        accounts: target.services.providerAccounts, projects: target.services.conversationProjects)
      OttoBuddyController.shared.start(services: target.services, store: target.store)
      await target.voice.setSpaceActive(true)
    }
  }

  var activeProcessCount: Int { opened.reduce(0) { $0 + $1.services.activeProcessCount } }
  func busyProcessCount() async -> Int {
    var count = 0
    for runtime in opened { count += await runtime.services.busyProcessCount() }
    return count
  }
  func stopAllProcesses() async {
    for runtime in opened { await runtime.services.stopAllProcesses() }
  }
  func markCleanTermination() {
    for runtime in opened { runtime.services.markCleanTermination() }
  }
  func flushPersistence() async {
    for runtime in opened { await runtime.services.flushPersistence() }
  }
}

struct SpaceWorkspace: View {
  let runtime: OttoSpaceRuntime
  var body: some View {
    WorkspaceView(
      store: runtime.store, services: runtime.services,
      voice: runtime.voice, uiState: runtime.uiState
    )
    .environmentObject(runtime.services.messageQueue)
    .environment(\.providerAccounts, ProviderAccountUIContext.shared(for: runtime.services))
    .onReceive(runtime.store.$snapshot) { snapshot in
      BrowserRendererPool.prune(snapshot: snapshot, runtime: runtime.services.browserRuntime)
    }
  }
}

/// Keep each view mounted: composer drafts, selection and drawer state belong to its space.
struct SpaceWorkspaceStack: View {
  @ObservedObject var spaces: OttoSpaceController
  var body: some View {
    ZStack {
      ForEach(spaces.opened) { runtime in
        SpaceWorkspace(runtime: runtime)
          .opacity(runtime.id == spaces.active.id ? 1 : 0)
          .zIndex(runtime.id == spaces.active.id ? 1 : 0)
          .allowsHitTesting(runtime.id == spaces.active.id)
          .disabled(runtime.id != spaces.active.id)
          .accessibilityHidden(runtime.id != spaces.active.id)
          .environment(\.ottoSpaceVisible, runtime.id == spaces.active.id)
          .environment(\.ottoSwitchSpace, { profile in try await spaces.switchTo(profile) })
      }
    }
  }
}
