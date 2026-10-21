import OttoApplicationTools
import OttoMemory
import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI

/// UserDefaults keys for the first-run welcome, Home's Getting started card and the tour.
enum FirstRunPreferences {
  /// What the user asked to be called on the welcome screen; Home greets them with it.
  static let preferredName = "otto.user.preferredName"
  /// Set when someone finishes the new welcome, so the Getting started card only appears for
  /// people who came through it, not for everyone already using Otto.
  static let gettingStartedActive = "otto.gettingStarted.active"
  static let gettingStartedDismissed = "otto.gettingStarted.dismissed"
  /// The starter agent hired on the welcome screen, named in the checklist.
  static let starterBotID = "otto.gettingStarted.botID"
  static let voiceCommandUsed = "otto.onboarding.voiceCommandUsed"
  static let tourCompleted = "otto.tour.home.completed"

  static var preferredFirstName: String? {
    let saved = UserDefaults.standard.string(forKey: preferredName)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let saved, !saved.isEmpty { return saved }
    return nil
  }
}

/// What the welcome flow hands back to Home when it finishes.
struct FirstRunResult {
  var hiredBot: AgentProfile?
  var firstTask: String?
}

/// The first thing a new user sees: what Otto is, who they are, which agents are ready, and a
/// starter agent to hire. It fills the window over the theme artwork and never blocks on
/// voice or cloud settings; those move to Home's checklist.
struct FirstRunWelcomeView: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.openSettings) private var openSettings
  @Environment(\.ottoMotion) private var motion
  @ObservedObject var services: ApplicationServices
  let complete: (FirstRunResult) -> Void

  private enum Step: Int, CaseIterable {
    case welcome, aboutYou, connect, firstAgent
  }

  @State private var step: Step = .welcome
  @State private var name =
    FirstRunPreferences.preferredFirstName
    ?? NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
  @State private var interests: Set<OnboardingInterest> = [.research]
  @State private var availability: [AgentProviderInfo] = []
  @State private var loadingProviders = true
  @State private var starter = OnboardingInterest.research.starter
  @State private var starterName = OnboardingInterest.research.starter.name
  @State private var hiring = false
  @State private var errorMessage: String?
  @AppStorage(OttoBuddyPreferences.enabledKey) private var ottoOnScreen = false

  /// `startStep` and `knownProviders` let snapshot tests render a step without a live runtime.
  init(
    services: ApplicationServices, startStep: Int = 0, knownProviders: [AgentProviderInfo]? = nil,
    complete: @escaping (FirstRunResult) -> Void
  ) {
    self.services = services
    self.complete = complete
    let step = Step(rawValue: startStep) ?? .welcome
    _step = State(initialValue: step)
    if let knownProviders {
      _availability = State(initialValue: knownProviders)
      _loadingProviders = State(initialValue: false)
    }
    if step == .firstAgent {
      _starter = State(initialValue: OnboardingInterest.starter(for: [.research]))
    }
  }

  var body: some View {
    ZStack {
      Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
      palette.ink.opacity(0.18).ignoresSafeArea()
      ScrollView {
        panel
          .frame(maxWidth: 760)
          .padding(.horizontal, 32)
          .padding(.vertical, 60)
          .frame(maxWidth: .infinity, minHeight: 0)
      }
      .scrollIndicators(.hidden)
    }
    .accessibilityIdentifier("onboarding.sheet")
    .task { if loadingProviders { await loadProviders() } }
  }

  private var panel: some View {
    VStack(alignment: .leading, spacing: 0) {
      progress.padding(.bottom, 22)
      Group {
        switch step {
        case .welcome: welcomeStep
        case .aboutYou: aboutYouStep
        case .connect: connectStep
        case .firstAgent: firstAgentStep
        }
      }
      .transition(.opacity)
      if let errorMessage {
        Text(errorMessage)
          .font(.ottoDisplay(12))
          .foregroundStyle(palette.red)
          .padding(.top, 12)
      }
      footer.padding(.top, 26)
    }
    .padding(.horizontal, 40)
    .padding(.top, 34)
    .padding(.bottom, 26)
    .background(
      palette.raised.opacity(0.94), in: RoundedRectangle(cornerRadius: 22, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .strokeBorder(palette.paper.opacity(0.10), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.28), radius: 40, y: 18)
    .foregroundStyle(palette.paper)
    .animation(motion.enter(.moderate), value: step)
  }

  private var progress: some View {
    HStack(spacing: 6) {
      ForEach(Step.allCases, id: \.self) { item in
        Capsule()
          .fill(item.rawValue <= step.rawValue ? palette.signal : palette.paper.opacity(0.12))
          .frame(height: 4)
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
  }

  // MARK: Steps

  private var welcomeStep: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("WELCOME TO OTTO")
        .font(.ottoMicro)
        .tracking(2.4)
        .foregroundStyle(palette.signal)
      Text("A team of AI agents that works for you.")
        .font(.ottoDisplay(30).weight(.medium))
        .tracking(-0.4)
        .accessibilityIdentifier("onboarding.title")
      Text(
        "Ask for anything. Otto hands it to the right agent, shows you the work as it happens, and checks in only when it needs you."
      )
      .font(.ottoDisplay(15))
      .foregroundStyle(palette.muted)
      .fixedSize(horizontal: false, vertical: true)
      HStack(alignment: .top, spacing: 12) {
        loopCard(
          number: 1, title: "Ask", symbol: "text.cursor",
          detail: "Type or say what you need from Home. You can talk to Otto with ⌃⌥Space.")
        loopCard(
          number: 2, title: "Agents do the work", symbol: "person.2",
          detail:
            "Hire agents for ongoing jobs. They run on a schedule and remember what they've learnt."
        )
        loopCard(
          number: 3, title: "Hear back on Home", symbol: "sunrise",
          detail:
            "Results, your morning brief and anything that needs a decision come back to Home.")
      }
      .padding(.top, 14)
    }
  }

  private func loopCard(number: Int, title: String, symbol: String, detail: String)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(palette.signal)
        .frame(width: 38, height: 38)
        .background(palette.signal.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
      Text("\(number) · \(title)").font(.ottoDisplay(14).weight(.semibold))
      Text(detail)
        .font(.ottoDisplay(12))
        .foregroundStyle(palette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
  }

  private var aboutYouStep: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("What should we call you?").font(.ottoDisplay(30).weight(.medium))
      Text(
        "And what would you like a hand with first? Choose a few. We'll set Otto up around them, and you can change this any time."
      )
      .font(.ottoDisplay(15))
      .foregroundStyle(palette.muted)
      .fixedSize(horizontal: false, vertical: true)
      fieldLabel("YOUR NAME").padding(.top, 14)
      TextField("First name", text: $name)
        .textFieldStyle(.plain)
        .font(.ottoDisplay(16))
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: 320)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
          RoundedRectangle(cornerRadius: 10).strokeBorder(palette.paper.opacity(0.14))
        )
        .accessibilityIdentifier("onboarding.name")
      fieldLabel("HELP ME WITH").padding(.top, 14)
      WelcomeChipLayout(spacing: 8) {
        ForEach(OnboardingInterest.allCases) { interest in
          let on = interests.contains(interest)
          Button {
            if on { interests.remove(interest) } else { interests.insert(interest) }
          } label: {
            Label(interest.title, systemImage: interest.symbol)
              .font(.ottoDisplay(13).weight(.medium))
              .padding(.horizontal, 13)
              .padding(.vertical, 8)
              .foregroundStyle(on ? palette.onSignal : palette.paper)
              .background(on ? palette.signal : palette.surface, in: Capsule())
              .overlay(Capsule().strokeBorder(palette.paper.opacity(on ? 0 : 0.14)))
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(on ? .isSelected : [])
        }
      }
    }
  }

  private var readyProviders: [AgentProviderInfo] {
    availability.filter { $0.installed && $0.compatibility == .supported }
  }

  private var connectStep: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        readyProviders.isEmpty && !loadingProviders ? "Connect an agent" : "Your agents are ready"
      )
      .font(.ottoDisplay(30).weight(.medium))
      Text(connectLede)
        .font(.ottoDisplay(15))
        .foregroundStyle(palette.muted)
        .fixedSize(horizontal: false, vertical: true)
      if loadingProviders {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(services.isOnline ? "Checking this Mac…" : "Starting Otto…")
            .font(.ottoDisplay(13))
            .foregroundStyle(palette.muted)
        }
        .padding(.top, 16)
      } else {
        LazyVGrid(
          columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
          spacing: 10
        ) {
          ForEach(primaryProviders, id: \.provider) { provider in
            providerRow(provider)
          }
        }
        .padding(.top, 14)
        if !otherProviders.isEmpty {
          HStack(spacing: 12) {
            Text("Also works with").font(.ottoDisplay(12)).foregroundStyle(palette.muted)
            ForEach(otherProviders, id: \.provider) { info in
              AgentProviderLogo(provider: info.provider, size: 15, color: palette.paper)
                .opacity(0.75)
                .help(info.provider.rawValue)
            }
            Spacer()
            Button("Add another…") { openSettings() }
              .buttonStyle(.plain)
              .font(.ottoDisplay(12).weight(.medium))
              .foregroundStyle(palette.cyan)
          }
          .padding(.top, 8)
          .padding(.horizontal, 4)
        }
      }
    }
  }

  private var connectLede: String {
    if loadingProviders { return "Otto runs on the AI apps you already use." }
    switch readyProviders.count {
    case 0:
      return
        "Otto runs on the AI apps you already use, like Claude Code or Codex. Install and sign in to one, then come back. You can carry on and do this later."
    case 1:
      return "Otto runs on the AI apps you already use. We found one on this Mac, so you're set."
    default:
      return
        "Otto runs on the AI apps you already use. We found \(readyProviders.count) on this Mac, so you're set."
    }
  }

  /// Ready providers first, then Claude Code and Codex even when missing, so there's always
  /// something to act on.
  private var primaryProviders: [AgentProviderInfo] {
    let ready = readyProviders
    let readyIDs = Set(ready.map(\.provider))
    let essentials = availability.filter {
      [.claudeCode, .codex].contains($0.provider) && !readyIDs.contains($0.provider)
    }
    return ready + essentials
  }

  private var otherProviders: [AgentProviderInfo] {
    let shown = Set(primaryProviders.map(\.provider))
    return availability.filter { !shown.contains($0.provider) && $0.provider != .shell }
  }

  private func providerRow(_ info: AgentProviderInfo) -> some View {
    let ready = info.installed && info.compatibility == .supported
    return HStack(spacing: 11) {
      AgentProviderLogo(provider: info.provider, size: 18, color: palette.paper)
        .frame(width: 34, height: 34)
        .background(palette.ink.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
      VStack(alignment: .leading, spacing: 2) {
        Text(info.provider.rawValue).font(.ottoDisplay(14).weight(.semibold))
        Text(ready ? "Ready on this Mac" : (info.installed ? "Needs an update" : "Not set up yet"))
          .font(.ottoDisplay(11))
          .foregroundStyle(palette.muted)
      }
      Spacer(minLength: 4)
      if ready {
        Label("Ready", systemImage: "checkmark")
          .font(.ottoDisplay(11).weight(.semibold))
          .foregroundStyle(palette.signal)
      } else {
        Button("Set up") { openSettings() }
          .buttonStyle(.plain)
          .font(.ottoDisplay(11).weight(.semibold))
          .padding(.horizontal, 11)
          .padding(.vertical, 5)
          .foregroundStyle(palette.ink)
          .background(palette.paper, in: Capsule())
          .help(info.remediation ?? "Install it, sign in, then come back.")
      }
    }
    .padding(12)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.paper.opacity(0.08)))
  }

  private var firstAgentStep: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Meet your first agent").font(.ottoDisplay(30).weight(.medium))
      Text(
        "Based on what you picked, here's an agent to start with. Hire it now, or skip and do it later from Home."
      )
      .font(.ottoDisplay(15))
      .foregroundStyle(palette.muted)
      .fixedSize(horizontal: false, vertical: true)
      HStack(alignment: .top, spacing: 16) {
        Text(String(starterName.prefix(1)).uppercased())
          .font(.ottoDisplay(22).weight(.bold))
          .foregroundStyle(.white)
          .frame(width: 56, height: 56)
          .background(
            LinearGradient(
              colors: [palette.signal, palette.cyan], startPoint: .topLeading,
              endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16))
        VStack(alignment: .leading, spacing: 10) {
          TextField("Name", text: $starterName)
            .textFieldStyle(.plain)
            .font(.ottoDisplay(18).weight(.semibold))
            .accessibilityIdentifier("onboarding.starter-name")
          Text(starter.jobTitle).font(.ottoDisplay(13)).foregroundStyle(palette.muted)
          detailRow("JOB", starter.responsibility)
          detailRow("FIRST TASK", starter.firstTask)
          detailRow("RUNS ON", starterProvider.rawValue)
        }
      }
      .padding(18)
      .background(palette.surface, in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(palette.paper.opacity(0.08)))
      .padding(.top, 14)
      let alternatives = OnboardingInterest.allCases.map(\.starter).filter {
        $0.name != starter.name
      }.prefix(3)
      HStack(spacing: 8) {
        Text("Or start with:").font(.ottoDisplay(12)).foregroundStyle(palette.muted)
        ForEach(Array(alternatives), id: \.name) { option in
          Button("\(option.name), \(option.jobTitle.lowercased())") { choose(option) }
            .buttonStyle(.plain)
            .font(.ottoDisplay(12))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.paper.opacity(0.14)))
        }
      }
      .padding(.top, 8)
      ottoOnScreenOffer.padding(.top, 18)
    }
  }

  /// Otto on screen is opt-in: offered once here, and later from Settings or Getting started.
  private var ottoOnScreenOffer: some View {
    HStack(alignment: .center, spacing: 14) {
      if let image = OttoBuddyPose.waving.image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 58)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text("Want me to hang out on your screen?").font(.ottoDisplay(15).weight(.semibold))
        Text(
          "I’ll stay over every app, take quick questions and tell you when work is done. Click me for shortcuts or press \(OttoBuddyPreferences.summonShortcut)."
        )
        .font(.ottoDisplay(12))
        .foregroundStyle(palette.muted)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Toggle("Otto on screen", isOn: $ottoOnScreen)
        .toggleStyle(.switch)
        .labelsHidden()
        .accessibilityIdentifier("onboarding.otto-on-screen")
    }
    .padding(14)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(palette.paper.opacity(0.08)))
  }

  private func detailRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label)
        .font(.ottoMicro)
        .tracking(1.2)
        .foregroundStyle(palette.muted)
        .frame(width: 84, alignment: .leading)
      Text(value).font(.ottoDisplay(13)).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func fieldLabel(_ text: String) -> some View {
    Text(text).font(.ottoMicro).tracking(1.6).foregroundStyle(palette.muted)
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 14) {
      switch step {
      case .welcome:
        Label(
          "Everything stays on this Mac unless you choose a cloud service.", systemImage: "lock"
        )
        .font(.ottoDisplay(11))
        .foregroundStyle(palette.muted)
        Spacer()
        primaryButton("Get started") { go(.aboutYou) }
      case .aboutYou:
        backButton(.welcome)
        Spacer()
        primaryButton("Continue") {
          saveAboutYou()
          go(.connect)
        }
      case .connect:
        backButton(.aboutYou)
        Spacer()
        primaryButton("Continue") { go(.firstAgent) }
      case .firstAgent:
        backButton(.connect)
        Spacer()
        Button("Skip for now") { complete(FirstRunResult(hiredBot: nil, firstTask: nil)) }
          .buttonStyle(.plain)
          .font(.ottoDisplay(13))
          .foregroundStyle(palette.muted)
          .disabled(hiring)
        primaryButton(hiring ? "Hiring…" : "Hire \(displayStarterName)", prominent: true) {
          hire()
        }
        .disabled(hiring)
        .accessibilityIdentifier("onboarding.enter-workspace")
      }
    }
  }

  private var displayStarterName: String {
    let trimmed = starterName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? starter.name : trimmed
  }

  private func backButton(_ target: Step) -> some View {
    Button {
      go(target)
    } label: {
      Label("Back", systemImage: "chevron.left")
    }
    .buttonStyle(.plain)
    .font(.ottoDisplay(13))
    .foregroundStyle(palette.muted)
  }

  private func primaryButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Text(title)
        .font(.ottoDisplay(14).weight(.semibold))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .foregroundStyle(prominent ? palette.onSignal : palette.ink)
        .background(prominent ? palette.signal : palette.paper, in: Capsule())
    }
    .buttonStyle(.plain)
    .keyboardShortcut(.defaultAction)
  }

  // MARK: Actions

  private func go(_ target: Step) {
    errorMessage = nil
    if target == .firstAgent, step != .firstAgent {
      choose(OnboardingInterest.starter(for: interests))
    }
    step = target
  }

  private func choose(_ option: StarterAgent) {
    starter = option
    starterName = option.name
  }

  /// The ready provider a starter agent runs on: Claude Code, then Codex, then anything ready.
  private var starterProvider: AgentProvider {
    let ready = readyProviders.map(\.provider)
    return [.claudeCode, .codex].first { ready.contains($0) } ?? ready.first ?? .claudeCode
  }

  /// Saves the name for Home's greeting and both answers to this space's memory, so every
  /// agent starts out knowing them.
  private func saveAboutYou() {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    UserDefaults.standard.set(trimmed, forKey: FirstRunPreferences.preferredName)
    let picks = OnboardingInterest.allCases.filter { interests.contains($0) }.map(\.title)
    let memory = services.personalMemory
    Task {
      if !trimmed.isEmpty {
        _ = try? await memory.add(
          CompactMemoryEntry(
            id: "onboarding-preferred-name", text: "Prefers to be called \(trimmed).",
            source: "welcome"))
      }
      if !picks.isEmpty {
        _ = try? await memory.add(
          CompactMemoryEntry(
            id: "onboarding-interests",
            text: "Wants help with: \(picks.joined(separator: ", ")).", source: "welcome"))
      }
    }
  }

  private func hire() {
    hiring = true
    errorMessage = nil
    do {
      let profile = try services.createBot(
        BotCreationRequest(
          name: displayStarterName,
          role: starter.jobTitle,
          responsibility: starter.responsibility,
          persistResponsibilityAsJobTitle: false,
          provider: starterProvider))
      UserDefaults.standard.set(
        profile.id.uuidString, forKey: FirstRunPreferences.starterBotID)
      complete(FirstRunResult(hiredBot: profile, firstTask: starter.firstTask))
    } catch {
      errorMessage = error.localizedDescription
    }
    hiring = false
  }

  private func loadProviders() async {
    let deadline = ContinuousClock.now + .seconds(8)
    while !services.isOnline, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
    do {
      availability = try await services.providerAvailability()
    } catch {
      availability = []
    }
    loadingProviders = false
  }
}

/// Wraps chips onto as many rows as they need.
private struct WelcomeChipLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
    let width = rows.map(\.width).max() ?? 0
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = [Row()]
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      if !rows[rows.count - 1].indices.isEmpty,
        rows[rows.count - 1].width + spacing + size.width > width
      {
        rows.append(Row())
      }
      var row = rows[rows.count - 1]
      row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
      row.height = max(row.height, size.height)
      row.indices.append(index)
      rows[rows.count - 1] = row
    }
    return rows
  }
}
