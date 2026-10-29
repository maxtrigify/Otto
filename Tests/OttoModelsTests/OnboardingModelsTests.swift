import OttoModels
import Testing

@Suite("First workflow onboarding")
struct OnboardingModelsTests {
  @Test("Checklist derives completion only from durable canvas state")
  func progress() {
    var canvas = OttoCanvas(name: "Onboarding")
    canvas.nodes = [
      OttoNode(
        kind: .agent,
        displayName: "Ada",
        subtitle: "CLAUDE CODE",
        frame: WorldRect(x: 0, y: 0, width: 420, height: 270),
        zIndex: 0,
        status: .done,
        content: .agent(provider: .claudeCode)
      ),
      OttoNode(
        kind: .agent,
        displayName: "Bowie",
        subtitle: "CODEX",
        frame: WorldRect(x: 450, y: 0, width: 420, height: 270),
        zIndex: 1,
        content: .agent(provider: .codex)
      ),
      OttoNode(
        kind: .terminal,
        displayName: "Terminal 1",
        subtitle: "ZSH",
        frame: WorldRect(x: 0, y: 300, width: 420, height: 270),
        zIndex: 2,
        content: .terminal(shell: "/bin/zsh")
      ),
      OttoNode(
        kind: .browser,
        displayName: "Preview",
        subtitle: "LOCALHOST",
        frame: WorldRect(x: 450, y: 300, width: 520, height: 330),
        zIndex: 3,
        content: .browser(url: "http://localhost:3000")
      ),
      OttoNode(
        kind: .markdown,
        displayName: "Goals",
        subtitle: "MARKDOWN",
        frame: WorldRect(x: 0, y: 600, width: 360, height: 300),
        zIndex: 4,
        content: .markdown(relativePath: "goals.md", text: "# Goals\n- [ ] Ship Otto")
      ),
    ]
    canvas.layoutMode = .stage

    let steps = FirstWorkflowProgress.steps(for: canvas)
    #expect(steps.map(\.id) == [1, 2, 3, 4, 5, 6])
    #expect(steps.allSatisfy { $0.isComplete })
  }

  @Test("An empty canvas starts with every step incomplete")
  func emptyCanvas() {
    #expect(
      FirstWorkflowProgress.steps(for: OttoCanvas(name: "Empty")).allSatisfy {
        !$0.isComplete
      })
  }

  @Test("Voice onboarding teaches a complete keyless path before optional cloud Talk")
  func voiceLessons() {
    let lessons = VoiceOnboardingCatalog.lessons
    #expect(lessons.map(\.id) == ["local-command", "dictate", "command-palette", "talk"])
    #expect(lessons.prefix(3).allSatisfy { !$0.requiresAPIKey })
    #expect(lessons.last?.requiresAPIKey == true)
    #expect(lessons.contains { $0.instruction.contains("Command-F") })
    #expect(lessons.contains { $0.instruction.contains("verbatim") })
  }
}

@Suite("First-run welcome and Home tour")
struct FirstRunWelcomeTests {
  @Test("The first picked interest chooses the starter agent")
  func starterFollowsPicks() {
    #expect(OnboardingInterest.starter(for: []).name == "Scout")
    #expect(OnboardingInterest.starter(for: [.writing, .inbox]).name == "Iris")
    #expect(OnboardingInterest.starter(for: [.software]).name == "Forge")
    for interest in OnboardingInterest.allCases {
      #expect(!interest.starter.responsibility.isEmpty)
      #expect(!interest.starter.firstTask.isEmpty)
    }
  }

  @Test("Getting started ticks follow durable state and name the bot")
  func gettingStarted() {
    let state = GettingStartedState(
      hasPreferredName: true, hasBot: true, hasGivenTask: false, hasUsedVoiceCommand: false,
      hasMorningBrief: true)
    let items = GettingStartedProgress.items(state, botName: "Scout")
    #expect(items.map(\.id) == GettingStartedItemID.allCases)
    #expect(items.filter(\.isComplete).map(\.id) == [.aboutYou, .hireAgent, .morningBrief])
    #expect(items[2].title == "Give Scout its first task")
  }

  @Test("Joining the community is a checklist item that ticks once the Discord has been opened")
  func communityItem() {
    var state = GettingStartedState(
      hasPreferredName: true, hasBot: true, hasGivenTask: true, hasUsedVoiceCommand: true,
      hasMorningBrief: true)
    #expect(
      GettingStartedProgress.items(state, botName: nil).contains {
        $0.id == .joinCommunity && !$0.isComplete
      })
    state.hasJoinedCommunity = true
    #expect(
      GettingStartedProgress.items(state, botName: nil).contains {
        $0.id == .joinCommunity && $0.isComplete
      })
    #expect(OttoCommunity.discordInviteURL.host == "discord.gg")
  }

  @Test("The tour opens with an offer, covers each part of Otto, and ends on the checklist")
  func tour() {
    let steps = HomeTourCatalog.steps
    #expect(steps.first?.target == nil)
    #expect(steps.last?.target == .gettingStarted)
    #expect(Set(steps.map(\.id)).count == steps.count)
    for id in ["memory", "spaces", "kinds", "workspaces", "accounts"] {
      #expect(steps.contains { $0.id == id })
    }
  }
}
