import AppKit
import OttoCore
import OttoModels
import OttoObservability
import OttoPersistence
import OttoServices
import OttoTools
import SwiftUI

@main
struct OttoApp: App {
  @NSApplicationDelegateAdaptor(OttoApplicationDelegate.self) private var applicationDelegate
  @StateObject private var store: CanvasStore
  @StateObject private var services: ApplicationServices
  @StateObject private var voice: VoiceController
  @StateObject private var uiState = WorkspaceUIState()
  @StateObject private var updates = AppUpdateController()

  init() {
    // The Muse → Otto rename moves app folders and imports preferences. It must finish before
    // anything below opens a store or reads a preference.
    let migration = OttoLaunchMigration()
    migration.writeLog(migration.run())
    #if DEBUG
      // Memory preview exercises the real chat UI with an isolated workspace and no saved sessions.
      let isIsolatedPreview =
        MessagingPreview.enabled
        || ProcessInfo.processInfo.arguments.contains("--message-queue-preview")
        || ProcessInfo.processInfo.arguments.contains("--apps-preview")
        || ProcessInfo.processInfo.arguments.contains("--memory-preview")
      let previewRoot = FileManager.default.temporaryDirectory.appending(
        path: "Otto Preview-\(UUID())")
      // An explicit --workspace lets an isolated preview start from seeded fixture data, and
      // --profiles-root gives that preview its own profile list instead of the real one.
      let profileRegistry: OttoProfileRegistry? =
        isIsolatedPreview
        ? commandLineValue(for: "--profiles-root").map {
          OttoProfileRegistry(
            applicationSupport: URL(fileURLWithPath: $0),
            originalWorkspacePath: commandLineValue(for: "--workspace") ?? previewRoot.path)
        }
        : .live(originalWorkspacePath: defaultWorkspacePath())
    #else
      let isIsolatedPreview = false
      let profileRegistry: OttoProfileRegistry? = .live(
        originalWorkspacePath: defaultWorkspacePath())
    #endif
    // Each profile is its own place: its folder, its sessions database and its "About me".
    let explicitWorkspace = commandLineValue(for: "--workspace")
    let profile =
      explicitWorkspace.flatMap { profileRegistry?.profile(workspacePath: $0) }
      ?? (explicitWorkspace == nil ? profileRegistry?.active : nil)
    let locations = profile.flatMap { profileRegistry?.locations(for: $0) }
    #if DEBUG
      let fallbackWorkspace = isIsolatedPreview ? previewRoot.path : defaultWorkspacePath()
    #else
      let fallbackWorkspace = defaultWorkspacePath()
    #endif
    let workspacePath = explicitWorkspace ?? profile?.workspacePath ?? fallbackWorkspace
    // Every profile's `.muse` state folder becomes `.otto` before its stores open.
    var workspaceLines: [String] = []
    for path in Set((profileRegistry?.profiles.map(\.workspacePath) ?? []) + [workspacePath]) {
      let outcome = OttoWorkspaceMigration.migrateStateFolder(workspacePath: path)
      if outcome != .nothingToMigrate && outcome != .alreadyMigrated {
        workspaceLines.append("Workspace \(path): .muse → .otto \(outcome)")
      }
    }
    migration.writeLog(.init(lines: workspaceLines, migratedFromMuse: false))
    let database: SQLiteWorkspaceStore? = {
      if isIsolatedPreview && locations == nil { return nil }
      guard let path = locations?.databasePath else { return try? SQLiteWorkspaceStore.live() }
      try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: path).deletingLastPathComponent(),
        withIntermediateDirectories: true)
      return SQLiteWorkspaceStore(path: path)
    }()
    let store = CanvasStore(persistence: database)
    if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "--demo-browser"),
      ProcessInfo.processInfo.arguments.indices.contains(flag + 1),
      let url = normalizedDemoURL(ProcessInfo.processInfo.arguments[flag + 1])
    {
      let receipt = store.dispatch(.createNode(kind: .browser, at: WorldPoint(x: 260, y: 160)))
      if let nodeID = receipt.affectedNodeIDs.first {
        store.dispatch(.setNodeContent(id: nodeID, content: .browser(url: url)))
      }
    }
    if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "--demo-media"),
      ProcessInfo.processInfo.arguments.indices.contains(flag + 1),
      let url = normalizedDemoURL(ProcessInfo.processInfo.arguments[flag + 1])
    {
      let receipt = store.dispatch(.createNode(kind: .media, at: WorldPoint(x: 260, y: 160)))
      if let nodeID = receipt.affectedNodeIDs.first {
        store.dispatch(.setNodeContent(id: nodeID, content: .media(source: url)))
      }
    }
    let observability = try? ObservabilityStore(
      directory: observabilityDirectory(),
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "0.1.0"
    )
    var auditSinks: [any ToolAuditSink] = []
    if let database { auditSinks.append(database) }
    if let observability { auditSinks.append(observability) }
    let registry = ToolRegistry(auditSink: CompositeToolAuditSink(auditSinks))
    if let database {
      // The audit chain is readable, not just written: users and coordinating agents can ask
      // what every actor actually did (names and outcomes only, never payloads).
      Task { try? await registry.register(AuditRecentTool(store: database)) }
    }
    _store = StateObject(wrappedValue: store)
    let services = ApplicationServices(
      store: store,
      registry: registry,
      observability: observability,
      workspacePath: workspacePath,
      personalMemoryPath: locations?.personalMemoryPath,
      profiles: profileRegistry
    )
    #if DEBUG
      if MessagingPreview.enabled { MessagingPreview.configure(services, root: previewRoot) }
    #endif
    _services = StateObject(wrappedValue: services)
    _voice = StateObject(
      wrappedValue: VoiceController(
        registry: registry,
        store: store,
        services: services,
        observability: observability,
        workspacePath: workspacePath
      ))
  }

  var body: some Scene {
    WindowGroup(id: "otto-workspace", for: String.self) { _ in
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--message-queue-preview") {
          MessageQueuePreview()
        } else if ProcessInfo.processInfo.arguments.contains("--apps-preview") {
          MarketplaceView(
            connections: services.appConnections, accounts: services.providerAccounts,
            workspacePath: services.defaultWorkspacePath,
            initialAccountID: services.providerAccounts.defaultAccountID)
        } else if MessagingPreview.enabled {
          MessagingPreviewView(services: services, store: store)
            .environmentObject(services.messageQueue)
        } else {
          mainWorkspace.environmentObject(services.messageQueue)
        }
      #else
        mainWorkspace.environmentObject(services.messageQueue)
      #endif
    } defaultValue: {
      "primary"
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1440, height: 900)
    .commands {
      BrowserNavigationCommands(uiState: uiState)
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") { updates.checkNow() }
      }
      // Otto is a single-window app: there is no New Window, and ⌘W closes the window.
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .saveItem) {
        Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut("w", modifiers: .command)
      }
      CommandMenu("Voice") {
        Button("Talk to Otto") {
          Task { await voice.toggleTalk() }
        }
        Button("Give Local Voice Command") {
          Task { await voice.toggleCommand() }
        }
        .keyboardShortcut(voice.commandShortcut.key, modifiers: voice.commandShortcut.modifiers)
        Button("Dictate Verbatim") {
          Task { await voice.toggleDictation() }
        }
        .keyboardShortcut(voice.dictateShortcut.key, modifiers: voice.dictateShortcut.modifiers)
      }
      CommandGroup(after: .appInfo) {
        Button("Command Palette…") { uiState.showsCommandPalette = true }
          .keyboardShortcut("f", modifiers: .command)
        Button("Replay Welcome…") {
          NotificationCenter.default.post(name: .ottoReplayVoiceOnboarding, object: nil)
        }
        Button("Take the Home Tour") {
          NotificationCenter.default.post(name: .ottoStartHomeTour, object: nil)
        }
      }
      CommandGroup(replacing: .help) {
        Button("Send Feedback…") { uiState.showsFeedback = true }
      }
    }

    Settings {
      TabView {
        VoiceSettingsView(voice: voice)
          .tabItem { Label("Voice", systemImage: "waveform") }
        ShortcutsSettingsView(voice: voice)
          .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        AppearanceSettingsView()
          .tabItem { Label("Appearance", systemImage: "textformat.size") }
        CompletionNotificationSettingsView()
          .tabItem { Label("Notifications", systemImage: "bell") }
        AgentDefaultsSettingsView()
          .tabItem { Label("Agents", systemImage: "sparkles") }
        ModelProviderSettingsView()
          .tabItem { Label("Models", systemImage: "cpu") }
        ProviderAccountsSettingsView(services: services)
          .tabItem { Label("Accounts", systemImage: "person.2.crop.square.stack") }
        SummarizerSettingsView()
          .tabItem { Label("Summarizer", systemImage: "text.badge.star") }
        WebsiteAccountsView(
          accounts: services.websiteAccounts, profiles: services.agentProfiles.activeProfiles
        )
        .tabItem { Label("Websites", systemImage: "lock.shield") }
        MessagingSettingsView(messaging: services.messaging)
          .tabItem { Label("Messaging", systemImage: "message") }
        BoatCloudView(cloud: services.boatCloud)
          .tabItem { Label("Cloud", systemImage: "cloud") }
        MobileSettingsView(services: services)
          .tabItem { Label("Mobile", systemImage: "iphone.and.arrow.forward") }
      }
      .frame(minWidth: 820)
    }
  }

  private var providerAccountContext: ProviderAccountUIContext {
    ProviderAccountUIContext.shared(for: services)
  }

  private var mainWorkspace: some View {
    WorkspaceView(store: store, services: services, voice: voice, uiState: uiState)
      .environment(\.providerAccounts, providerAccountContext)
      .frame(minWidth: 1100, minHeight: 720)
      .onAppear {
        applicationDelegate.configure(services: services)
        Task {
          await BrowserRendererPool.configure(store: store, runtime: services.browserRuntime)
        }
        DevelopmentAutoReloader.startIfNeeded()
        updates.startAutomaticChecks()
      }
      .onReceive(store.$snapshot) { snapshot in
        BrowserRendererPool.prune(snapshot: snapshot)
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        updates.checkAfterActivation()
      }
      .sheet(isPresented: $updates.isPresentingUpdateSheet) {
        AppUpdateSheet(controller: updates)
      }
      .task {
        await store.restore()
        ProviderModelCatalogStore.shared.configure(
          accounts: services.providerAccounts, projects: services.conversationProjects)
        CompletionNotifications.shared.start(services: services, store: store)
        await services.start()
        services.websiteAccounts.onOpenLogin = { id in
          PrivateWebsiteLoginWindows.shared.open(id, service: services.websiteAccounts)
        }
        services.messaging.start()
        // Only now are the workspace tools registered; the voice session projects them once at
        // connect, so the mode's persistent connection must not start any earlier.
        await voice.activateOperatingMode()
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
      ) { _ in
        services.markCleanTermination()
        Task { await store.flushPersistence() }
      }
  }
}

private func observabilityDirectory() -> URL {
  FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
    .appending(path: "Otto/Diagnostics", directoryHint: .isDirectory)
    ?? FileManager.default.temporaryDirectory.appending(
      path: "Otto/Diagnostics", directoryHint: .isDirectory)
}

private func commandLineValue(for flag: String) -> String? {
  guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: flag),
    ProcessInfo.processInfo.arguments.indices.contains(index + 1)
  else { return nil }
  return ProcessInfo.processInfo.arguments[index + 1]
}

private func defaultWorkspacePath() -> String {
  let fileManager = FileManager.default
  let candidates = [
    fileManager.urls(for: .documentDirectory, in: .userDomainMask).first.map {
      OttoPaths.preferredUserFolder(
        in: $0, name: OttoPaths.defaultWorkspaceFolder,
        legacyName: OttoPaths.legacyDefaultWorkspaceFolder)
    },
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appending(path: "Otto/Workspace", directoryHint: .isDirectory),
  ].compactMap { $0 }
  for candidate in candidates {
    do {
      try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
      if fileManager.isWritableFile(atPath: candidate.path) { return candidate.path }
    } catch {
      continue
    }
  }
  return fileManager.currentDirectoryPath
}

private func normalizedDemoURL(_ value: String) -> String? {
  guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased()) else {
    return nil
  }
  return url.absoluteString
}

@MainActor
private final class OttoApplicationDelegate: NSObject, NSApplicationDelegate {
  private weak var services: ApplicationServices?

  func configure(services: ApplicationServices) {
    self.services = services
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    // A pre-rename updater installs Otto as /Applications/Muse.app. Rename it once; the
    // relaunched Otto.app then shows the rename notice.
    if let plan = AppInstallLocation.launchRelocation(
      currentBundle: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier),
      (try? AppInstallLocation.relocateAndRelaunch(plan)) != nil
    {
      return
    }
    presentRenameNoticeIfNeeded()
  }

  /// One time, and only for people whose Muse data was carried over: explain the new name and
  /// why macOS may ask for permissions again (TCC grants and keychain access belong to the old
  /// bundle identifier).
  private func presentRenameNoticeIfNeeded() {
    guard OttoRenameNotice.isPending() else { return }
    OttoRenameNotice.dismiss()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      let alert = NSAlert()
      alert.alertStyle = .informational
      alert.messageText = "Otto is the new name for Muse"
      alert.informativeText = """
        Your sessions, settings and saved sign-ins came across. Because the app has a new \
        identity, macOS may ask once more for microphone, screen recording, accessibility, \
        automation or notification permission, and for keychain access to passwords saved by \
        Muse. Choose Always Allow for those keychain prompts.
        """
      alert.addButton(withTitle: "Got It")
      alert.runModal()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if UpdateRelaunchRequest.shared.isActive {
      guard let services else { return .terminateNow }
      let gate = UpdateTerminationGate {
        sender.reply(toApplicationShouldTerminate: true)
      }
      Task { @MainActor in
        await services.stopAllProcesses()
        services.markCleanTermination()
        await services.flushPersistence()
        gate.finish()
      }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(6))
        gate.finish()
      }
      return .terminateLater
    }

    guard let services, services.activeProcessCount > 0 else { return .terminateNow }

    // Idle agent harnesses and quiet shells hold no in-flight work — sessions resume from
    // their persisted IDs on next launch. Only interrupt the quit when an agent is mid-run,
    // waiting on the user, or a terminal still has a live child process.
    Task { @MainActor in
      let busyCount = await services.busyProcessCount()
      if busyCount == 0 {
        await services.stopAllProcesses()
        services.markCleanTermination()
        await services.flushPersistence()
        sender.reply(toApplicationShouldTerminate: true)
        return
      }

      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText =
        "\(busyCount) \(busyCount == 1 ? "agent is" : "agents are") still working or waiting for you"
      alert.informativeText =
        "Quitting now interrupts their work. Stop them and quit, or keep Otto open so the sessions finish safely. Otto never leaves an unmanaged PTY behind."
      alert.addButton(withTitle: "Stop Processes and Quit")
      alert.addButton(withTitle: "Keep Otto Open")

      guard alert.runModal() == .alertFirstButtonReturn else {
        sender.reply(toApplicationShouldTerminate: false)
        return
      }
      await services.stopAllProcesses()
      services.markCleanTermination()
      await services.flushPersistence()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

/// Cleanup and a timeout race to approve an update restart. AppKit must receive exactly one reply.
@MainActor
final class UpdateTerminationGate {
  private var hasFinished = false
  private let action: () -> Void

  init(action: @escaping () -> Void) {
    self.action = action
  }

  func finish() {
    guard !hasFinished else { return }
    hasFinished = true
    action()
  }
}

/// Opens Otto again in the newly active profile. Profiles own separate databases and agent
/// runtimes, so a clean relaunch is the safe way to swap everything at once.
@MainActor
func relaunchOttoIntoActiveProfile() {
  var arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
  if let index = arguments.firstIndex(of: "--workspace") {
    arguments.removeSubrange(index...min(index + 1, arguments.count - 1))
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments =
    ["-c", "sleep 1; /usr/bin/open -n \"$0\" --args \"$@\"", Bundle.main.bundlePath]
    + arguments
  try? process.run()
  NSApp.terminate(nil)
}

/// Native navigation stays available while editing text or viewing Settings.
private struct BrowserNavigationCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var uiState: WorkspaceUIState

  var body: some Commands {
    CommandMenu("Go") {
      Button("Browser") {
        if !BrowserNavigationShortcut.formatDocumentIfNeeded(
          firstResponder: NSApp.keyWindow?.firstResponder,
          isKeyPress: NSApp.currentEvent?.type == .keyDown)
        {
          uiState.requestsBrowser = true
          openWindow(id: "otto-workspace", value: "primary")
        }
      }
      .keyboardShortcut("b", modifiers: .command)
    }
  }
}
