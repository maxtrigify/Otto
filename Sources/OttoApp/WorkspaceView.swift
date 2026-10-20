import AppKit
import OttoApplicationTools
import OttoCore
import OttoDocuments
import OttoModels
import OttoObservability
import OttoRemote
import OttoRuntime
import OttoServices
import OttoVoice
import OttoWorktrees
import SwiftUI

extension Notification.Name {
  static let ottoReplayVoiceOnboarding = Notification.Name("io.openotto.replay-voice-onboarding")
}

struct WorkspaceView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.ottoMotion) private var motion
  @State private var showingBoatCloud = false
  @Namespace private var surfacePickerSelection
  @ObservedObject var store: CanvasStore
  @ObservedObject var services: ApplicationServices
  @ObservedObject var voice: VoiceController
  @ObservedObject var uiState: WorkspaceUIState
  /// Home is where Otto opens: the brief, cards and the composer.
  @State private var showingPersonalHome = true
  /// When the person last left Otto or their Mac, for opening Home on a new day.
  @State private var awaySince: Date?
  @State private var homeDraft = ""
  @State private var homeProvider: AgentProvider = .codex
  @State private var homeConversationTarget: HomeConversationTarget = .newSession
  @State private var showingAgentLauncher = false
  @State private var showingHireBot = false
  @State private var showingCreateTeam = false
  @State private var showingCustomAgentCreator = false
  @State private var showingAgentManager = false
  @State private var createsAgentAfterManagerDismiss = false
  @State private var agentProfileLaunchError: String?
  @State private var widgetActionError: String?
  @State private var agentLaunchPoint = WorldPoint(x: 0, y: 0)
  @State private var showingMediaLauncher = false
  @State private var mediaLaunchPoint = WorldPoint(x: 0, y: 0)
  @AppStorage("otto.onboarding.completed") private var onboardingCompleted = false
  @AppStorage(OttoPreferenceKey.fontScale) private var fontScaleRaw = OttoFontScale.standard
    .rawValue
  // 0 (never set) defers to the active theme's designed nodeOpacity.
  @AppStorage(OttoPreferenceKey.matteOpacity) private var matteOpacity = 0.0
  @State private var showingOnboarding = false
  @AppStorage(FirstRunPreferences.tourCompleted) private var tourCompleted = false
  @State private var showingTour = false
  @State private var tourStep = 0
  @State private var windowIsVisible = true
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private var activeTheme: OttoThemeDefinition {
    OttoThemeCatalog.theme(id: store.activeCanvas.themeID)
  }

  private var palette: OttoPalette {
    OttoPalette(theme: activeTheme, matteOpacity: matteOpacity > 0 ? matteOpacity : nil)
  }

  var body: some View {
    ZStack {
      // Window-glass themes need the base gone so the desktop shows through; the frost in
      // ThemeBackgroundView carries legibility. Reduced transparency drops the backdrop
      // entirely, so the solid base must come back with it.
      if activeTheme.resolvedSurfaceMaterial != .windowGlass || reduceTransparency {
        palette.ink.ignoresSafeArea()
      }
      // The backdrop is pinned to the window's frame so artwork can never size this root
      // ZStack; inside it, photos are aspect-filled and cropped like a wallpaper.
      GeometryReader { geometry in
        ThemeBackgroundView(
          theme: activeTheme,
          isActive: scenePhase == .active && windowIsVisible,
          scrimScale: 0.25
        )
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipped()
        .id(activeTheme.id)
      }
      .ignoresSafeArea()
      .allowsHitTesting(false)
      WindowVisibilityObserver(isVisible: $windowIsVisible)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
      if showingPersonalHome {
        personalHome
      } else {
        chatSurface
      }

      if uiState.showsCommandPalette {
        // The palette choreographs its own entrance and exit (slow in, faster out).
        CommandPaletteOverlay(
          services: services, uiState: uiState, quickActions: paletteQuickActions
        )
        .transition(.identity)
      }

      // The surface switch shares the traffic lights' line in both surfaces, sitting just
      // after the chat band's sidebar toggle (80pt + 26pt control + 6pt gap). Centred over
      // content it covered the transcript and the node cards, and it moved relative to the
      // conversation whenever the sidebar collapsed.
      VStack {
        HStack {
          workspaceSurfacePicker
            .homeTourTarget(.surfaceSwitcher)
            .padding(.leading, 112)
          Spacer()
        }
        .padding(.top, 2.5)
        Spacer()
      }
      // The surfaces draw under the titlebar, so the switch has to as well. Respecting the
      // safe area here dropped it a full row below the sidebar toggle it belongs beside.
      .ignoresSafeArea(.container, edges: .top)
      .zIndex(6)

      if showingOnboarding {
        FirstRunWelcomeView(services: services, complete: finishWelcome)
          .transition(.opacity)
          .zIndex(20)
      }
    }
    .overlayPreferenceValue(HomeTourAnchorsKey.self) { anchors in
      if showingTour, showingPersonalHome, !showingOnboarding {
        HomeTourOverlay(anchors: anchors, stepIndex: $tourStep, finish: finishTour)
          .transition(.opacity)
      }
    }
    .preferredColorScheme(
      // Black text on bright photos, white on dark ones, on every screen including Home.
      activeTheme.isLightAppearance ? .light : .dark
    )
    .alert("Persistence notice", isPresented: errorBinding) {
      Button("Dismiss", role: .cancel) {}
    } message: {
      Text(store.persistenceError ?? "Unknown database error")
    }
    .alert("Could not open custom agent", isPresented: agentProfileErrorBinding) {
      Button("Dismiss", role: .cancel) { agentProfileLaunchError = nil }
    } message: {
      Text(agentProfileLaunchError ?? "Unknown custom-agent launch error")
    }
    .alert("Could not manage widget", isPresented: widgetActionErrorBinding) {
      Button("Dismiss", role: .cancel) { widgetActionError = nil }
    } message: {
      Text(widgetActionError ?? "Unknown widget error")
    }
    .sheet(isPresented: $showingAgentLauncher) {
      AgentLaunchSheet(services: services, point: agentLaunchPoint)
    }
    .sheet(isPresented: $showingHireBot) {
      HireBotSheet(services: services, hired: openHiredBot)
        .environment(\.ottoPalette, palette)
    }
    .sheet(isPresented: $showingCreateTeam) {
      CreateTeamSheet(services: services) { _ in }
        .environment(\.ottoPalette, palette)
    }
    .sheet(isPresented: $showingCustomAgentCreator) {
      CustomAgentCreationView(services: services, point: agentLaunchPoint)
    }
    .sheet(isPresented: $showingAgentManager, onDismiss: finishAgentManagerDismissal) {
      AgentManagerView(
        services: services,
        createAgent: {
          createsAgentAfterManagerDismiss = true
          showingAgentManager = false
        },
        openAgent: { profile, forceNew in
          showingAgentManager = false
          openAgentProfile(profile, forceNew: forceNew)
        }
      )
    }
    .sheet(isPresented: $showingMediaLauncher) {
      MediaLaunchSheet(services: services, point: mediaLaunchPoint)
    }
    .sheet(isPresented: $uiState.showsMemoryInspector) {
      MemoryInspectorView(services: services)
    }
    .sheet(isPresented: $uiState.showsWidgetManager) {
      WidgetManagerView(store: store, services: services)
    }
    .sheet(isPresented: $showingBoatCloud) {
      VStack {
        HStack {
          Spacer()
          Button("Done") { showingBoatCloud = false }
        }.padding()
        BoatCloudView(cloud: services.boatCloud)
      }
    }
    .sheet(isPresented: $uiState.showsRoutineManager) {
      RoutineManagerView(store: store, services: services)
    }
    .onAppear {
      if !onboardingCompleted { showingOnboarding = true }
    }
    .onReceive(NotificationCenter.default.publisher(for: .ottoReplayVoiceOnboarding)) { _ in
      showingTour = false
      showingOnboarding = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .ottoStartHomeTour)) { _ in
      startTour()
    }
    .onReceive(MorningHome.leaving) { _ in
      if awaySince == nil { awaySince = .now }
    }
    .onReceive(MorningHome.returning) { _ in
      guard let since = awaySince else { return }
      awaySince = nil
      if MorningHome.shouldOpenHome(awaySince: since), !showingPersonalHome {
        withAnimation(motion.enter(.moderate)) { showingPersonalHome = true }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .ottoOpenCompletedConversation)) { notification in
      if let nodeID = notification.object as? UUID { openHomeAgent(nodeID) }
    }
    .onChange(of: services.botNavigationRequest) { _, request in
      if request != nil { showingPersonalHome = false }
    }
    .environment(\.ottoPalette, palette)
    .dynamicTypeSize(dynamicTypeSize)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.activeCanvas.themeID)
  }

  /// Lands a new user on Home with their starter agent ready and its first task in the box,
  /// then offers the tour.
  private func finishWelcome(_ result: FirstRunResult) {
    onboardingCompleted = true
    UserDefaults.standard.set(true, forKey: FirstRunPreferences.gettingStartedActive)
    UserDefaults.standard.set(false, forKey: FirstRunPreferences.gettingStartedDismissed)
    if let bot = result.hiredBot {
      homeConversationTarget = .bot(bot.id)
      homeDraft = result.firstTask ?? ""
    }
    withAnimation(motion.exit(.moderate)) {
      showingOnboarding = false
      showingPersonalHome = true
    }
    if !tourCompleted { startTour() }
  }

  private func startTour() {
    showingPersonalHome = true
    tourStep = 0
    withAnimation(motion.enter(.moderate)) { showingTour = true }
  }

  private func finishTour() {
    tourCompleted = true
    withAnimation(motion.exit(.fast)) { showingTour = false }
  }

  private var personalHome: some View {
    PersonalHomeView(
      store: store, services: services, activity: services.botActivity,
      brief: services.dailyBrief, draft: $homeDraft, provider: $homeProvider,
      conversationTarget: $homeConversationTarget,
      openMarkdown: openHomeMarkdown,
      openNode: openHomeNode,
      openBot: { profile in
        showingPersonalHome = false
        agentLaunchPoint = nextPlacementPoint()
        openHiredBot(profile)
      },
      openAgent: openHomeAgent,
      openCloud: { showingBoatCloud = true },
      openLibrary: { destination in
        var navigation = store.snapshot.chatNavigation
        navigation.destination = destination
        store.updateChatNavigation(navigation)
        store.setWorkspaceSurface(.chat)
        showingPersonalHome = false
      },
      hireBot: {
        agentLaunchPoint = nextPlacementPoint()
        showingHireBot = true
      },
      submit: { target, provider, prompt in
        let id: UUID
        switch target {
        case .newSession:
          guard let newID = await quickLaunchAgentForChat(provider) else {
            throw NSError(
              domain: "OttoHome", code: 1,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "Could not start the agent. Check its connection in Settings."
              ])
          }
          id = newID
          // File the session under the Home profile's project so its folders and account apply.
          if let projectID = services.dailyBrief.selectedProfile.defaultProjectID {
            try? services.selectProject(channelID: newID, projectID: projectID)
          }
        case .bot(let profileID):
          guard let entry = services.botRoster().first(where: { $0.profile.id == profileID }) else {
            throw NSError(
              domain: "OttoHome", code: 2,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "This bot is no longer available. Choose another conversation."
              ])
          }
          if let existing = existingHomeBotNodeID(
            profileID: profileID,
            canonicalNodeID: entry.nodeID, canvases: store.snapshot.canvases)
          {
            id = existing
          } else {
            id = try await services.openBotChannel(entry.profile, at: nextPlacementPoint())
          }
        case .session(let sessionID):
          let roster = services.botRoster()
          guard
            homeSessionNodes(
              canvases: store.snapshot.canvases,
              botProfileIDs: Set(roster.map { $0.profile.id }),
              botNodeIDs: Set(roster.compactMap(\.nodeID)),
              backgroundNodeIDs: services.office.boundSessionIDs
            ).contains(where: { $0.id == sessionID })
          else {
            throw NSError(
              domain: "OttoHome", code: 3,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "This session is no longer available. Choose another conversation."
              ])
          }
          id = sessionID
        }
        do {
          try await services.sendPrompt(agentID: id, prompt: prompt)
        } catch {
          await services.recordConversationSendFailure(agentID: id, prompt: prompt, error: error)
          openHomeAgent(id)
          agentProfileLaunchError = error.localizedDescription
          return
        }
        openHomeAgent(id)
      }
    )
    .ignoresSafeArea(.container, edges: .top)
  }

  /// Pinned widgets and other non-conversation nodes open the Widgets library in Chat.
  private func openHomeNode(_ id: UUID) {
    var navigation = store.snapshot.chatNavigation
    navigation.destination = .widgets
    store.updateChatNavigation(navigation)
    store.setWorkspaceSurface(.chat)
    showingPersonalHome = false
  }

  /// A note opens in the user's own editor.
  private func openHomeMarkdown(_ path: String) {
    NSWorkspace.shared.open(
      URL(fileURLWithPath: services.documents.rootPath).appending(path: path))
  }

  /// "Jump to" entries: the places, bots and recent sessions people move between most.
  private var jumpActions: [PaletteQuickAction] {
    var jumps: [PaletteQuickAction] = [
      PaletteQuickAction(
        id: "go.home", title: "Home", subtitle: "Your brief, to-dos and day",
        symbol: "house", keywords: "home brief today dashboard",
        perform: { showingPersonalHome = true }),
      PaletteQuickAction(
        id: "go.automations", title: "Automations", subtitle: "Tasks that run on a schedule",
        symbol: "clock", keywords: "automations routines schedule",
        perform: { openChatDestination(.routines) }),
      PaletteQuickAction(
        id: "go.activity", title: "Activity", subtitle: "What your agents did and need",
        symbol: "tray", keywords: "activity inbox needs you",
        perform: { openChatDestination(.activity) }),
      PaletteQuickAction(
        id: "go.files", title: "Files & notes", subtitle: "Notes and media",
        symbol: "doc.text", keywords: "files notes documents media",
        perform: { openChatDestination(.files) }),
    ]
    for entry in services.botRoster() {
      jumps.append(
        PaletteQuickAction(
          id: "go.bot.\(entry.profile.id.uuidString)", title: entry.profile.name,
          subtitle: "Bot", symbol: "person.crop.circle",
          keywords: "bot chat \(entry.profile.name) \(entry.profile.role)", accent: .cyan,
          perform: {
            showingPersonalHome = false
            agentLaunchPoint = nextPlacementPoint()
            openHiredBot(entry.profile)
          }))
    }
    let roster = services.botRoster()
    let sessions = homeSessionNodes(
      canvases: store.snapshot.canvases, botProfileIDs: Set(roster.map { $0.profile.id }),
      botNodeIDs: Set(roster.compactMap(\.nodeID)),
      backgroundNodeIDs: services.office.boundSessionIDs)
    for node in sessions.prefix(8) {
      jumps.append(
        PaletteQuickAction(
          id: "go.session.\(node.id.uuidString)", title: node.displayName,
          subtitle: "Session", symbol: "bubble.left",
          keywords: "session chat \(node.displayName)",
          agentProvider: node.declaredAgentProvider,
          perform: { openHomeAgent(node.id) }))
    }
    return jumps
  }

  private func openChatDestination(_ destination: ChatSurfaceDestination) {
    var navigation = store.snapshot.chatNavigation
    navigation.destination = destination
    store.updateChatNavigation(navigation)
    store.setWorkspaceSurface(.chat)
    showingPersonalHome = false
  }

  private func openHomeAgent(_ id: UUID) {
    guard let canvas = store.snapshot.canvases.first(where: { $0.nodes.contains { $0.id == id } }),
      let node = canvas.nodes.first(where: { $0.id == id })
    else { return }
    if let profileID = node.agentDefinition?.profileID,
      services.botRoster().contains(where: { $0.profile.id == profileID })
    {
      store.updateChatNavigation(
        chatNavigationSelectingHiredBot(
          store.snapshot.chatNavigation, profileID: profileID, nodeID: id))
    } else {
      store.updateChatNavigation(
        ChatSurfaceNavigationState(
          selectedAgentID: id, selectedSessionID: id, sessionCanvasID: canvas.id,
          sidebarList: .sessions, destination: .conversation))
    }
    store.dispatch(.focusNode(id), targetCanvasID: canvas.id)
    store.setWorkspaceSurface(.chat)
    showingPersonalHome = false
  }

  private var chatSurface: some View {
    ChatWorkspaceView(
      store: store,
      services: services,
      voice: voice,
      navigation: chatNavigationBinding,
      launchAgent: {
        agentLaunchPoint = WorldPoint(
          x: store.activeCanvas.viewport.centerX,
          y: store.activeCanvas.viewport.centerY
        )
        showingHireBot = true
      },
      quickLaunchAgent: quickLaunchAgentForChat
    )
    .environment(\.ottoWindowIsActive, scenePhase == .active && windowIsVisible)
    .ignoresSafeArea(.container, edges: .top)
  }

  private var dynamicTypeSize: DynamicTypeSize {
    switch OttoFontScale(rawValue: fontScaleRaw) ?? .standard {
    case .extraSmall: .xSmall
    case .small: .small
    case .standard: .medium
    case .large: .large
    case .extraLarge: .xLarge
    }
  }

  private var chatNavigationBinding: Binding<ChatSurfaceNavigationState> {
    Binding(
      get: { store.snapshot.chatNavigation },
      set: { store.updateChatNavigation($0) }
    )
  }

  private func openHiredBot(_ profile: AgentProfile) {
    showingPersonalHome = false
    store.setWorkspaceSurface(.chat)
    store.updateChatNavigation(
      chatNavigationSelectingHiredBot(
        store.snapshot.chatNavigation, profileID: profile.id, nodeID: nil))
    Task {
      do {
        let nodeID = try await services.openBotChannel(profile, at: agentLaunchPoint)
        store.updateChatNavigation(
          chatNavigationSelectingHiredBot(
            store.snapshot.chatNavigation, profileID: profile.id, nodeID: nodeID))
        store.dispatch(.focusNode(nodeID))
      } catch {
        agentProfileLaunchError = error.localizedDescription
      }
    }
  }

  /// The Home/Chat switch looks the same on every screen and theme.
  private var surfacePickerPalette: OttoPalette { OttoPalette(theme: OttoThemeCatalog.aurora) }

  private var workspaceSurfacePicker: some View {
    // Segmented tabs after Fluid Functionalism: the selected plate slides on the moderate
    // spring while a hover wash glides between segments on the fast one.
    OttoFluidHover(
      axis: .horizontal,
      style: OttoFluidHoverStyle(fill: surfacePickerPalette.paper.opacity(0.06), cornerRadius: 5)
    ) {
      HStack(spacing: 2) {
        Button {
          withAnimation(motion.enter(.moderate)) { showingPersonalHome = true }
        } label: {
          Text("Home")
            .font(.ottoDisplay(11).weight(showingPersonalHome ? .semibold : .medium))
            .foregroundStyle(
              showingPersonalHome
                ? surfacePickerPalette.paper : surfacePickerPalette.paper.opacity(0.75)
            )
            .frame(minWidth: 52, minHeight: 22)
            .padding(.horizontal, 8)
            .background(
              showingPersonalHome ? surfacePickerPalette.raised : .clear,
              in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Home")
        .accessibilityValue(showingPersonalHome ? "Selected" : "Not selected")
        .ottoHoverItem("personal-home")
        workspaceSurfaceButton(.chat)
          .ottoHoverItem(WorkspaceSurface.chat)
      }
    }
    // A flat segmented control, not a floating pill: it lives in reserved chrome now, so
    // the signal colour stays reserved for status and selection elsewhere.
    .padding(2)
    .frame(height: 26)
    .background(
      Color.black.opacity(0.55),
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Workspace surface")
  }

  private func workspaceSurfaceButton(_ surface: WorkspaceSurface) -> some View {
    let isSelected = !showingPersonalHome
    return Button {
      withAnimation(motion.enter(.moderate)) {
        showingPersonalHome = false
        _ = store.setWorkspaceSurface(surface)
      }
    } label: {
      OttoWeightStableText(
        surface.rawValue.capitalized, size: 11, active: isSelected,
        activeWeight: .semibold, restingWeight: .medium,
        activeColor: surfacePickerPalette.paper,
        restingColor: surfacePickerPalette.paper.opacity(0.75)
      )
      .frame(minWidth: 52, minHeight: 22)
      .padding(.horizontal, 8)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(surfacePickerPalette.raised)
            .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
            .matchedGeometryEffect(id: "workspace-surface", in: surfacePickerSelection)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Open \(surface.rawValue.capitalized)")
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
  }

  private var errorBinding: Binding<Bool> {
    Binding(get: { store.persistenceError != nil }, set: { _ in })
  }

  private var agentProfileErrorBinding: Binding<Bool> {
    Binding(
      get: { agentProfileLaunchError != nil },
      set: { if !$0 { agentProfileLaunchError = nil } }
    )
  }

  private var widgetActionErrorBinding: Binding<Bool> {
    Binding(
      get: { widgetActionError != nil },
      set: { if !$0 { widgetActionError = nil } }
    )
  }

  /// Quick actions are the friendly face of Cmd+K: each one runs immediately with the same
  /// defaults the toolbar flows use, no JSON required. The raw tool catalog stays below them.
  private var paletteQuickActions: [PaletteQuickAction] {
    let profileActions = services.agentProfileList.map { profile in
      PaletteQuickAction(
        id: "agent.profile.\(profile.id.uuidString)",
        title: profile.name,
        subtitle: profile.role.isEmpty
          ? "Custom agent · \(profile.provider.rawValue)"
          : "\(profile.role) · \(profile.provider.rawValue)",
        symbol: "person.crop.circle.badge.sparkles",
        keywords: "custom saved agent profile \(profile.name) \(profile.role)",
        accent: profile.provider == .codex ? .amber : .cyan,
        agentProvider: profile.provider,
        perform: { openAgentProfile(profile) }
      )
    }
    var actions = [
      PaletteQuickAction(
        id: "agent.claude",
        title: "New Claude Code agent",
        subtitle: "Start a Claude chat agent here with your default permissions",
        symbol: "sparkles",
        keywords: "claude code agent ai chat launch spawn",
        accent: .cyan,
        agentProvider: .claudeCode,
        perform: { quickLaunchAgent(.claudeCode) }
      ),
      PaletteQuickAction(
        id: "agent.codex",
        title: "New Codex agent",
        subtitle: "Start a Codex chat agent here with your default permissions",
        symbol: "chevron.left.forwardslash.chevron.right",
        keywords: "codex openai agent ai chat launch spawn",
        accent: .amber,
        agentProvider: .codex,
        perform: { quickLaunchAgent(.codex) }
      ),
      PaletteQuickAction(
        id: "agent.hermes",
        title: "New Hermes agent",
        subtitle: "Use the Hermes connection configured in Agent settings",
        symbol: "wing",
        keywords: "hermes agent local remote gateway launch spawn",
        accent: .red,
        agentProvider: .hermes,
        perform: { quickLaunchAgent(.hermes) }
      ),
      PaletteQuickAction(
        id: "agent.kimi",
        title: "New Kimi agent",
        subtitle: "Start a Kimi Code chat agent here with your default permissions",
        symbol: "moon.stars",
        keywords: "kimi code moonshot agent ai chat launch spawn",
        agentProvider: .kimi,
        perform: { quickLaunchAgent(.kimi) }
      ),
      PaletteQuickAction(
        id: "agent.cursor",
        title: "New Cursor agent",
        subtitle: "Start a Cursor CLI agent here with your default permissions",
        symbol: "cursorarrow.rays",
        keywords: "cursor composer agent ai chat launch spawn grok",
        agentProvider: .cursor,
        perform: { quickLaunchAgent(.cursor) }
      ),
      PaletteQuickAction(
        id: "agent.opencode",
        title: "New OpenCode agent",
        subtitle: "Start an OpenCode chat agent here with your default permissions",
        symbol: "chevron.right.square",
        keywords: "opencode open code sst agent ai chat launch spawn",
        agentProvider: .openCode,
        perform: { quickLaunchAgent(.openCode) }
      ),
      PaletteQuickAction(
        id: "agent.grok",
        title: "New Grok agent",
        subtitle: "Start a Grok chat agent here with your default permissions",
        symbol: "bolt.fill",
        keywords: "grok xai x.ai agent ai chat launch spawn",
        agentProvider: .grok,
        perform: { quickLaunchAgent(.grok) }
      ),
      PaletteQuickAction(
        id: "bot.hire",
        title: "Hire a bot",
        subtitle: "Create a persistent bot with a name, job, and canonical channel",
        symbol: "person.crop.circle.badge.plus",
        keywords: "hire bot custom agent profile persona job title teammate",
        perform: {
          agentLaunchPoint = nextPlacementPoint()
          showingHireBot = true
        }
      ),
      PaletteQuickAction(
        id: "bot.team",
        title: "Create a team",
        subtitle: "Start a persistent group conversation between saved bots",
        symbol: "person.3",
        keywords: "team group bots conversation",
        perform: { showingCreateTeam = true }
      ),
      PaletteQuickAction(
        id: "agent.custom.create",
        title: "Create custom agent…",
        subtitle: "Save a named teammate with its own instructions and harness",
        symbol: "person.crop.circle.badge.plus",
        keywords: "custom agent profile persona instructions system prompt create",
        perform: { createCustomAgent() }
      ),
      PaletteQuickAction(
        id: "agent.custom.manage",
        title: "Manage agents…",
        subtitle: "Edit prompts, defaults, and your saved agent fleet",
        symbol: "person.2.badge.gearshape",
        keywords: "agents manage fleet edit delete duplicate system prompt profiles",
        perform: { showingAgentManager = true }
      ),
      PaletteQuickAction(
        id: "agent.options",
        title: "Launch agent with options…",
        subtitle: "Choose provider, name, prompt, directory, and permissions",
        symbol: "slider.horizontal.3",
        keywords: "agent launch configure options prompt workspace permissions",
        perform: { createNode(.agent) }
      ),
      PaletteQuickAction(
        id: "node.terminal",
        title: "New terminal",
        subtitle: "Open a local shell on the canvas",
        symbol: "terminal",
        keywords: "terminal shell console command line",
        accent: .signal,
        perform: { createNode(.terminal) }
      ),
      PaletteQuickAction(
        id: "node.browser",
        title: "New browser",
        subtitle: "Open a web browser card",
        symbol: "safari",
        keywords: "browser web safari url internet",
        accent: .cyan,
        perform: { createNode(.browser) }
      ),
      PaletteQuickAction(
        id: "node.widget",
        title: "New custom widget",
        subtitle: "Create a user-owned HTML widget package",
        symbol: "square.stack.3d.up",
        keywords: "widget custom code html dashboard visualization schedule",
        accent: .signal,
        perform: { createNode(.widget) }
      ),
      PaletteQuickAction(
        id: "node.markdown",
        title: "New note",
        subtitle: "Create a markdown note",
        symbol: "doc.text",
        keywords: "note markdown document text write",
        accent: .signal,
        perform: { createNode(.markdown) }
      ),
      PaletteQuickAction(
        id: "node.whiteboard",
        title: "New whiteboard",
        subtitle: "Sketch freely on a drawing card",
        symbol: "pencil.and.scribble",
        keywords: "whiteboard draw sketch scribble",
        perform: { createNode(.whiteboard) }
      ),
      PaletteQuickAction(
        id: "node.label",
        title: "New label",
        subtitle: "Drop a text label on the canvas",
        symbol: "textformat",
        keywords: "label text caption title",
        perform: { createNode(.label) }
      ),
      PaletteQuickAction(
        id: "node.media",
        title: "Open media…",
        subtitle: "Add audio or video to the canvas",
        symbol: "waveform",
        keywords: "media audio video sound play",
        perform: { createNode(.media) }
      ),
      PaletteQuickAction(
        id: "recording.toggle",
        title: services.isRecordingCanvas ? "Stop recording" : "Record the canvas",
        subtitle: services.isRecordingCanvas
          ? "Finish the screen recording and drop the video on the canvas"
          : "Screen-record the canvas window to an .mp4 in the workspace",
        symbol: services.isRecordingCanvas ? "stop.circle.fill" : "record.circle",
        keywords: "record recording video capture screen demo stop rec",
        perform: { Task { await services.toggleCanvasRecording() } }
      ),
      PaletteQuickAction(
        id: "memory.inspector",
        title: "Memory inspector",
        subtitle: "Review proposals, budgets, and the Project Brain",
        symbol: "brain",
        keywords: "memory brain inspector review proposals budget knowledge",
        perform: { uiState.showsMemoryInspector = true }
      ),
      PaletteQuickAction(
        id: "widget.manager",
        title: "Manage widgets",
        subtitle: "See every installed widget, open one, or delete it",
        symbol: "square.stack.3d.up.badge.automatic",
        keywords: "widget widgets manage manager list delete remove all",
        perform: { uiState.showsWidgetManager = true }
      ),
      PaletteQuickAction(
        id: "routine.manager",
        title: "New automation",
        subtitle: "Give an agent a task and a time",
        symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
        keywords: "routine routines automation automations automate schedule webhook cron new",
        perform: { openChatDestination(.routines) }
      ),
    ]
    actions.insert(contentsOf: profileActions, at: 0)
    actions.insert(contentsOf: jumpActions, at: 0)
    actions.append(contentsOf: widgetOpenActions)
    return actions
  }

  private func openAgentProfile(_ profile: AgentProfile, forceNew: Bool = false) {
    let point = nextPlacementPoint()
    Task {
      do {
        _ = try await services.openAgentProfile(profile, at: point, forceNew: forceNew)
      } catch {
        agentProfileLaunchError = error.localizedDescription
      }
    }
  }

  private func createCustomAgent() {
    agentLaunchPoint = nextPlacementPoint()
    showingCustomAgentCreator = true
  }

  /// SwiftUI cannot reliably replace one sheet with another during the first sheet's dismissal
  /// transaction. Wait for the manager to finish closing before presenting the creator.
  private func finishAgentManagerDismissal() {
    guard createsAgentAfterManagerDismiss else { return }
    createsAgentAfterManagerDismiss = false
    createCustomAgent()
  }

  /// Installed packages, not just currently visible canvas cards, are the source of truth. Closing
  /// a card therefore leaves its widget searchable and gives the palette a way to restore it.
  private struct PaletteWidget {
    let packagePath: String
    let name: String
    let liveNodeID: UUID?
    let liveCanvasID: UUID?
    let liveCanvasName: String?
  }

  private var installedPaletteWidgets: [PaletteWidget] {
    let liveEntries = store.snapshot.canvases.flatMap { canvas in
      canvas.nodes.compactMap { node -> (String, UUID, UUID, String, String)? in
        guard node.kind == .widget, case .widget(let path, _) = node.content, !path.isEmpty
        else { return nil }
        return (path, node.id, canvas.id, canvas.name, node.displayName)
      }
    }
    let liveByPath = Dictionary(
      liveEntries.map { ($0.0, $0) }, uniquingKeysWith: { first, _ in first })
    let widgetsURL = URL(fileURLWithPath: services.documents.rootPath, isDirectory: true)
      .appendingPathComponent("Widgets", isDirectory: true)
    let packageURLs =
      (try? FileManager.default.contentsOfDirectory(
        at: widgetsURL, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])) ?? []
    var widgets = packageURLs.compactMap { url -> PaletteWidget? in
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
        let data = try? Data(contentsOf: url.appendingPathComponent("widget.json")),
        let manifest = try? JSONDecoder().decode(WidgetManifest.self, from: data)
      else { return nil }
      let path = "Widgets/\(url.lastPathComponent)"
      let live = liveByPath[path]
      return PaletteWidget(
        packagePath: path,
        name: manifest.name,
        liveNodeID: live?.1,
        liveCanvasID: live?.2,
        liveCanvasName: live?.3
      )
    }
    let installedPaths = Set(widgets.map(\.packagePath))
    widgets.append(
      contentsOf: liveEntries.compactMap { live in
        guard !installedPaths.contains(live.0) else { return nil }
        return PaletteWidget(
          packagePath: live.0, name: live.4, liveNodeID: live.1,
          liveCanvasID: live.2, liveCanvasName: live.3)
      })
    return widgets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// Every installed widget gets an Open result. Visible widgets additionally get a Close result;
  /// closed packages say so explicitly and are recreated on the active canvas when opened.
  private var widgetOpenActions: [PaletteQuickAction] {
    installedPaletteWidgets.flatMap { widget in
      var actions = [
        PaletteQuickAction(
          id: "node.widget.open.\(widget.packagePath)",
          title: "Open \(widget.name)",
          subtitle: widget.liveCanvasName.map { "Widget · \($0)" }
            ?? "Widget · Closed · opens on this canvas",
          symbol: "square.stack.3d.up",
          keywords:
            "widget open find show restore \(widget.name) "
            + "\(widget.liveCanvasName ?? "closed")",
          accent: .signal,
          perform: {
            if let nodeID = widget.liveNodeID, let canvasID = widget.liveCanvasID {
              openWidget(nodeID: nodeID, canvasID: canvasID)
            } else {
              runWidgetCommand("widget.open", name: widget.name)
            }
          }
        )
      ]
      if widget.liveNodeID != nil {
        actions.append(
          PaletteQuickAction(
            id: "node.widget.close.\(widget.packagePath)",
            title: "Close \(widget.name)",
            subtitle: "Hide its canvas card · keep the widget installed",
            symbol: "xmark.square",
            keywords: "widget close hide dismiss \(widget.name)",
            accent: .amber,
            perform: { runWidgetCommand("widget.close", name: widget.name) }
          ))
      }
      return actions
    }
  }

  private func openWidget(nodeID: UUID, canvasID: UUID) {
    if store.snapshot.activeCanvasID != canvasID {
      store.dispatch(.switchCanvas(canvasID))
    }
    store.dispatch(.focusNode(nodeID), targetCanvasID: canvasID)
  }

  private func runWidgetCommand(_ toolName: String, name: String) {
    Task {
      do {
        _ = try await services.callUserTool(
          name: toolName, input: .object(["name": .string(name)]))
      } catch {
        widgetActionError = error.localizedDescription
      }
    }
  }

  private func quickLaunchAgent(_ provider: AgentProvider) {
    Task { _ = await quickLaunchAgentForChat(provider) }
  }

  private func quickLaunchAgentForChat(_ provider: AgentProvider) async -> UUID? {
    let point = nextPlacementPoint()
    let key =
      switch provider {
      case .claudeCode: OttoPreferenceKey.claudePermissionMode
      case .codex: OttoPreferenceKey.codexPermissionMode
      case .openAI: OttoPreferenceKey.codexPermissionMode
      case .hermes: OttoPreferenceKey.hermesPermissionMode
      case .cursor: OttoPreferenceKey.cursorPermissionMode
      case .kimi: OttoPreferenceKey.kimiPermissionMode
      case .openCode: OttoPreferenceKey.openCodePermissionMode
      case .grok: OttoPreferenceKey.grokPermissionMode
      case .shell: OttoPreferenceKey.shellPermissionMode
      }
    let mode =
      AgentPermissionMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "")
      ?? .workspaceWrite
    return try? await services.spawnAgent(
      provider: provider,
      at: point,
      permissionMode: mode
    ).agentID
  }

  private func nextPlacementPoint() -> WorldPoint {
    let canvas = store.activeCanvas
    let offset = Double(canvas.nodes.count * 22)
    return WorldPoint(
      x: canvas.viewport.centerX - 170 + offset,
      y: canvas.viewport.centerY - 100 + offset
    )
  }

  private func createNode(_ kind: NodeKind) {
    let point = nextPlacementPoint()
    if kind == .agent {
      agentLaunchPoint = point
      showingAgentLauncher = true
      return
    }
    if kind == .media {
      mediaLaunchPoint = point
      showingMediaLauncher = true
      return
    }
    if kind == .terminal {
      Task { try? await services.openTerminal(at: point) }
      return
    }
    if kind == .markdown {
      createNote(.blank)
      return
    }
    if kind == .widget {
      createWidget(at: point)
      return
    }
    store.dispatch(
      .createNode(
        kind: kind,
        at: point
      ))
  }

  private func createWidget(at point: WorldPoint) {
    let canvas = store.activeCanvas
    Task {
      let packagePath = "Widgets/\(UUID().uuidString.lowercased())"
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(WidgetScaffold.manifest)
        guard let manifestText = String(data: manifestData, encoding: .utf8) else { return }
        try await services.documents.replace(
          relativePath: "\(packagePath)/widget.json", text: manifestText + "\n")
        try await services.documents.replace(
          relativePath: "\(packagePath)/index.html", text: WidgetScaffold.html + "\n")
        let receipt = store.dispatch(
          .createNode(kind: .widget, at: point), targetCanvasID: canvas.id)
        guard let nodeID = receipt.affectedNodeIDs.first else { return }
        store.dispatch(
          .setNodeContent(
            id: nodeID, content: .widget(packagePath: packagePath, state: "{}")),
          targetCanvasID: canvas.id
        )
        store.dispatch(
          .renameNode(id: nodeID, name: WidgetScaffold.manifest.name),
          targetCanvasID: canvas.id
        )
      } catch {
        _ = store.dispatch(.createNode(kind: .widget, at: point), targetCanvasID: canvas.id)
      }
    }
  }

  private func createNote(_ template: CanvasNoteTemplate) {
    let canvas = store.activeCanvas
    let point = nextPlacementPoint()
    Task {
      do {
        let note = try await services.documents.createCanvasNote(
          canvasID: canvas.id,
          canvasName: canvas.name,
          template: template
        )
        let text = try await services.documents.read(relativePath: note.relativePath)
        let receipt = store.dispatch(
          .createNode(kind: .markdown, at: point),
          targetCanvasID: canvas.id
        )
        guard let nodeID = receipt.affectedNodeIDs.first else { return }
        store.dispatch(
          .setNodeContent(
            id: nodeID,
            content: .markdown(relativePath: note.relativePath, text: text)
          ),
          targetCanvasID: canvas.id
        )
      } catch {
        // A pathless note remains recoverable in canvas persistence if disk creation fails.
        _ = store.dispatch(.createNode(kind: .markdown, at: point), targetCanvasID: canvas.id)
      }
    }
  }
}

private struct MediaLaunchSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.ottoPalette) private var palette
  @ObservedObject var services: ApplicationServices
  let point: WorldPoint
  @State private var source = ""
  @State private var opening = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("OPEN MEDIA")
        .font(.ottoMono(10, weight: .black))
        .tracking(2)
        .foregroundStyle(palette.signal)
      Text("Enter an HTTP(S) audio URL or a path inside this workspace.")
        .font(.ottoDisplay(17))
        .foregroundStyle(palette.paper)
      TextField("https://… or audio/file.mp3", text: $source)
        .textFieldStyle(.roundedBorder)
      if let errorMessage {
        Text(errorMessage).font(.ottoMono(9)).foregroundStyle(palette.red)
      }
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button(opening ? "Opening…" : "Open") { open() }
          .disabled(opening || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 500)
    .background(palette.surface)
  }

  private func open() {
    opening = true
    Task {
      do {
        try await services.openMedia(source: source, at: point)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
        opening = false
      }
    }
  }
}

private struct AgentLaunchSheet: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var services: ApplicationServices
  let point: WorldPoint
  @State private var provider = AgentProvider.codex
  @State private var displayName = ""
  @State private var workingDirectory = ""
  @State private var prompt = ""
  @State private var executionStrategy = AgentExecutionStrategy.direct
  @State private var permissionMode = AgentPermissionMode.workspaceWrite
  @AppStorage(OttoPreferenceKey.claudePermissionMode) private var claudePermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.codexPermissionMode) private var codexPermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.cursorPermissionMode) private var cursorPermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.kimiPermissionMode) private var kimiPermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.openCodePermissionMode) private var openCodePermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.grokPermissionMode) private var grokPermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.hermesPermissionMode) private var hermesPermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.shellPermissionMode) private var shellPermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @State private var isolatedWorktree = false
  @State private var availability: [AgentProviderInfo] = []
  @State private var scanningProviders = false
  @State private var launching = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("LAUNCH AGENT")
        .font(.ottoMono(10, weight: .black))
        .tracking(2)
        .foregroundStyle(palette.signal)
      Text("Open a focused agent chat, with the full provider terminal one click away.")
        .font(.ottoDisplay(18))
        .foregroundStyle(palette.paper)

      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Picker("Provider", selection: $provider) {
          ForEach(AgentProvider.allCases, id: \.self) { provider in
            Text(providerLabel(provider)).tag(provider)
          }
        }
        .onChange(of: provider) { _, provider in
          applyPermissionDefault()
          if !executionStrategy.isSupported(by: provider) { executionStrategy = .direct }
        }
        Button {
          Task { await loadProviders(autoSelect: false) }
        } label: {
          Label(scanningProviders ? "Scanning…" : "Rescan", systemImage: "arrow.clockwise")
        }
        .disabled(scanningProviders)
        .accessibilityLabel("Rescan installed agent providers")
      }
      TextField("Agent name", text: $displayName)
        .textFieldStyle(.roundedBorder)
      HStack(spacing: 8) {
        TextField("Working directory", text: $workingDirectory)
          .textFieldStyle(.roundedBorder)
        Button("Choose…") { chooseWorkingDirectory() }
      }
      .disabled(isRemoteHermes)
      if isRemoteHermes {
        Text("Hermes will use the remote working directory configured in Settings › Agents.")
          .font(.ottoMono(9))
          .foregroundStyle(palette.paper.opacity(0.58))
      }
      if provider == .claudeCode || provider == .codex {
        Picker("Execution", selection: $executionStrategy) {
          ForEach(
            AgentExecutionStrategy.allCases.filter { $0.isSupported(by: provider) },
            id: \.self
          ) { strategy in
            Text(executionStrategyLabel(strategy)).tag(strategy)
          }
        }
        Text(executionStrategyHelp)
          .font(.ottoMono(9))
          .foregroundStyle(palette.paper.opacity(0.58))
      }
      Picker("Permissions", selection: $permissionMode) {
        ForEach(AgentPermissionMode.allCases, id: \.self) { mode in
          Text(permissionLabel(mode)).tag(mode)
        }
      }
      if provider == .kimi, permissionMode == .readOnly {
        Text(
          "Kimi has no read-only chat mode: its non-interactive runs always auto-approve tool "
            + "calls. Read only applies to Kimi's terminal, which opens in plan mode."
        )
        .font(.ottoMono(9))
        .foregroundStyle(palette.paper.opacity(0.58))
      }
      Toggle("Isolated Git worktree", isOn: $isolatedWorktree)
        .toggleStyle(.ottoSwitch)
        .disabled(permissionMode == .readOnly || isRemoteHermes)
        .onChange(of: permissionMode) { _, mode in
          if mode == .readOnly { isolatedWorktree = false }
        }
      TextEditor(text: $prompt)
        .font(.ottoMono(11))
        .frame(minHeight: 110)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12)))
      Text("Add a first prompt to begin immediately, or leave it blank and start in chat.")
        .font(.ottoMono(9))
        .foregroundStyle(palette.paper.opacity(0.58))

      if let errorMessage {
        Text(errorMessage).font(.ottoMono(9)).foregroundStyle(palette.red)
      }
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button(launching ? "Launching…" : "Launch") { launch() }
          .disabled(
            launching
              || availability.first(where: { $0.provider == provider })?.installed != true
          )
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 520)
    .background(palette.surface)
    .task {
      applyPermissionDefault()
      if workingDirectory.isEmpty { workingDirectory = services.defaultWorkspacePath }
      await loadProviders(autoSelect: true)
    }
  }

  private func applyPermissionDefault() {
    let raw: String
    switch provider {
    case .claudeCode: raw = claudePermission
    case .codex: raw = codexPermission
    case .openAI: raw = codexPermission
    case .hermes: raw = hermesPermission
    case .cursor: raw = cursorPermission
    case .kimi: raw = kimiPermission
    case .openCode: raw = openCodePermission
    case .grok: raw = grokPermission
    case .shell: raw = shellPermission
    }
    permissionMode = AgentPermissionMode(rawValue: raw) ?? .workspaceWrite
  }

  private var isRemoteHermes: Bool {
    provider == .hermes && HermesConnectionConfiguration.load().mode == .remote
  }

  private func launch() {
    launching = true
    errorMessage = nil
    Task {
      do {
        try await services.spawnAgent(
          provider: provider,
          displayName: normalizedDisplayName,
          prompt: initialPrompt,
          workingDirectory: workingDirectory,
          at: point,
          executionStrategy: executionStrategy,
          permissionMode: permissionMode,
          isolatedWorktree: isolatedWorktree
        )
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
        launching = false
      }
    }
  }

  private var initialPrompt: String? {
    PromptSubmission.verbatimText(from: prompt)
  }

  private func loadProviders(autoSelect: Bool) async {
    scanningProviders = true
    defer { scanningProviders = false }
    do {
      availability = try await services.providerAvailability()
      errorMessage = nil
      if autoSelect,
        availability.first(where: { $0.provider == provider })?.installed != true,
        let installed = availability.first(where: \.installed)
      {
        provider = installed.provider
        applyPermissionDefault()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private var normalizedDisplayName: String? {
    let value = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private func chooseWorkingDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    if !workingDirectory.isEmpty {
      panel.directoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
    }
    if panel.runModal() == .OK, let url = panel.url { workingDirectory = url.path }
  }

  private func providerLabel(_ provider: AgentProvider) -> String {
    let info = availability.first { $0.provider == provider }
    if info?.installed == true { return "\(provider.rawValue) · \(info?.version ?? "installed")" }
    return "\(provider.rawValue) · not installed"
  }

  private func permissionLabel(_ mode: AgentPermissionMode) -> String {
    switch mode {
    case .readOnly: "Read only"
    case .workspaceWrite: "Ask to approve (workspace write)"
    case .unrestricted: "Bypass all permissions"
    }
  }

  private func executionStrategyLabel(_ strategy: AgentExecutionStrategy) -> String {
    switch strategy {
    case .direct: "Direct"
    case .delegated: "Delegate to subagents"
    case .scriptedWorkflow: "Claude dynamic workflow"
    }
  }

  private var executionStrategyHelp: String {
    switch executionStrategy {
    case .direct:
      "The main agent handles each prompt itself."
    case .delegated:
      "The agent may split independent work across its native subagents."
    case .scriptedWorkflow:
      "Claude runs a phased, resumable workflow for large fan-out tasks."
    }
  }
}
