import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoSecurity
import OttoTools
import Testing

@testable import OttoServices

@MainActor
@Suite("Daily brief store and tools")
struct DailyBriefStoreTests {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "brief-\(UUID())")
  }

  @Test("A first launch has one Home profile; profiles persist and the last cannot be deleted")
  func profiles() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DailyBriefStore(workspacePath: root.path)
    #expect(store.profiles.map(\.name) == ["Home"])
    #expect(store.selectedProfile.includesEverything)
    #expect(throws: DailyBriefStore.BriefError.self) {
      try store.deleteProfile(store.profiles[0].id)
    }

    let project = UUID()
    let work = try store.createProfile(name: " Work ", symbol: "briefcase", projectIDs: [project])
    #expect(work.name == "Work")
    #expect(work.defaultProjectID == project)
    #expect(store.selectedProfile.id == work.id)
    #expect(throws: DailyBriefStore.BriefError.self) { try store.createProfile(name: "work") }
    #expect(throws: DailyBriefStore.BriefError.self) { try store.createProfile(name: "  ") }

    var edited = work
    edited.projectIDs = [UUID()]
    try store.updateProfile(edited)
    // A default outside the profile's projects falls back to one inside it.
    #expect(store.profile(id: work.id)?.defaultProjectID == edited.projectIDs.first)

    let restored = DailyBriefStore(workspacePath: root.path)
    #expect(restored.profiles.map(\.name) == ["Home", "Work"])
    #expect(restored.selectedProfile.id == work.id)
    try restored.deleteProfile(work.id)
    #expect(restored.selectedProfile.name == "Home")
  }

  @Test("User to-dos tick off, routine reruns replace their items, and Otto items dismiss")
  func items() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DailyBriefStore(workspacePath: root.path)
    let profileID = store.selectedProfile.id
    #expect(throws: DailyBriefStore.BriefError.self) {
      try store.addTodo(title: " ", profileID: nil)
    }
    let todo = try store.addTodo(title: "Book dentist", profileID: profileID)
    try store.setCompleted(todo.id, true)
    #expect(store.compose(derived: [], legacyProjectID: nil).completedTodayCount == 1)
    try store.setCompleted(todo.id, false)
    #expect(store.compose(derived: [], legacyProjectID: nil).todos.map(\.id) == [todo.id])

    let routine = UUID()
    try store.replace(
      origin: .routine(routine),
      with: [BriefItem(kind: .update, title: "First", origin: .routine(routine))])
    try store.replace(
      origin: .routine(routine),
      with: [BriefItem(kind: .update, title: "Second", origin: .routine(routine))])
    #expect(store.items.filter { $0.origin == .routine(routine) }.map(\.title) == ["Second"])

    let derived = BriefItem(id: "attention:x", kind: .todo, title: "Answer", origin: .otto)
    #expect(store.compose(derived: [derived], legacyProjectID: nil).todos.count == 2)
    try store.setCompleted(derived.id, true)
    #expect(store.compose(derived: [derived], legacyProjectID: nil).todos.count == 1)
    try store.restore(derived.id)
    #expect(store.compose(derived: [derived], legacyProjectID: nil).todos.count == 2)

    let restored = DailyBriefStore(workspacePath: root.path)
    #expect(restored.items.count == store.items.count)
  }

  @Test("Old updates and long-finished items are pruned on load; open to-dos are kept")
  func pruning() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DailyBriefStore(workspacePath: root.path)
    let old = Date.now.addingTimeInterval(-10 * 24 * 60 * 60)
    try store.add([
      BriefItem(id: "todo", kind: .todo, title: "Keep", origin: .user, createdAt: old),
      BriefItem(id: "update", kind: .update, title: "Drop", origin: .user, createdAt: old),
      BriefItem(
        id: "done", kind: .todo, title: "Drop", origin: .user, createdAt: old, completedAt: old),
    ])
    let restored = DailyBriefStore(workspacePath: root.path)
    #expect(restored.items.map(\.id) == ["todo"])
  }

  @Test("brief.add files agent items under the caller's project and validates profiles")
  func agentTool() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    let node = try #require(
      services.store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
        .affectedNodeIDs.first)
    let project = try services.conversationProjects.create(name: "Otto")
    try services.selectProject(channelID: node, projectID: project.id)
    let caller = ToolContext(
      actorID: "agent", scopes: [.canvasWrite, .agentRead], source: .agent, sourceNodeID: node)
    let input = BriefAddInput(items: [
      .init(kind: "todo", title: "Reply to Jo", reason: "Asked overnight", needsYou: true),
      .init(kind: "event", title: "Standup", time: "2026-10-07T09:30:00Z"),
      .init(title: "   "),
    ])
    let output = try await services.registry.call(
      name: "brief.add", input: try JSONValue.encode(input), context: caller
    ).decode(BriefAddOutput.self)
    #expect(output.added == 2)
    #expect(services.dailyBrief.items.allSatisfy { $0.projectID == project.id })
    // The same item again replaces rather than duplicates.
    _ = try await services.registry.call(
      name: "brief.add", input: try JSONValue.encode(input), context: caller)
    #expect(services.dailyBrief.items.count == 2)

    let work = try services.dailyBrief.createProfile(name: "Work", projectIDs: [project.id])
    let personal = try services.dailyBrief.createProfile(name: "Personal", projectIDs: [UUID()])
    let workBrief = services.dailyBrief.compose(
      derived: [], profile: work, legacyProjectID: services.legacyProjectID)
    #expect(workBrief.todos.map(\.title) == ["Reply to Jo"])
    #expect(
      services.dailyBrief.compose(
        derived: [], profile: personal, legacyProjectID: services.legacyProjectID
      ).isEmpty)

    await #expect(throws: (any Error).self) {
      _ = try await services.registry.call(
        name: "brief.add",
        input: try JSONValue.encode(BriefAddInput(items: [.init(title: "X")], profile: "Nope")),
        context: caller)
    }
    let listed = try await services.registry.call(
      name: "brief.list", input: try JSONValue.encode(BriefListInput(profile: "work")),
      context: caller
    ).decode(BriefListOutput.self)
    #expect(listed.profile == "Work")
    #expect(listed.todos.count == 1)
  }

  @Test("The morning brief routine is created once per profile and delivers into the brief")
  func morningRoutine() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    let profile = services.dailyBrief.selectedProfile
    let routine = try await services.setUpMorningBrief(
      profileID: profile.id, target: .spawnProvider(provider: AgentProvider.claudeCode.rawValue))
    #expect(routine.enabled)
    #expect(routine.delivery == .brief(profileID: profile.id))
    #expect(routine.permissionMode == AgentPermissionMode.readOnly.rawValue)
    #expect(services.dailyBrief.profile(id: profile.id)?.briefRoutineID == routine.id)
    let again = try await services.setUpMorningBrief(
      profileID: profile.id, target: .spawnProvider(provider: AgentProvider.codex.rawValue))
    #expect(again.id == routine.id)
    #expect(
      services.routines.routines.filter { $0.delivery == .brief(profileID: profile.id) }.count == 1)

    try await services.deliverRoutineResult(
      again, nodeID: UUID(),
      result: """
        ```json
        {"items":[{"kind":"todo","title":"Approve invoice","needsYou":true}]}
        ```
        """)
    let brief = services.dailyBrief.compose(derived: [], legacyProjectID: services.legacyProjectID)
    #expect(brief.todos.map(\.title) == ["Approve invoice"])
    #expect(brief.todos.first?.profileID == profile.id)
  }

  @Test("The brief reads every signed-in account: one run each, labelled, duplicates merged")
  func everyAccount() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let accounts = ProviderAccountStore(
      rootDirectory: root.appending(path: "support"), userHome: root.appending(path: "home"),
      secrets: InMemorySecretStore())
    let work = try accounts.create(name: "Work")
    let personal = try accounts.create(name: "Personal")
    _ = try accounts.create(name: "Never signed in")
    try accounts.setDefault(work.id)
    func signIn(_ account: ProviderAccount) throws {
      let data = accounts.providerDataDirectory(accountID: account.id, provider: .claudeCode)
      try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: data.appending(path: ".credentials.json"))
    }
    try signIn(work)
    try signIn(personal)
    let services = ApplicationServices(
      store: CanvasStore(), providerAccounts: accounts, workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    let profile = services.dailyBrief.selectedProfile

    let main = try await services.setUpMorningBrief(
      profileID: profile.id, target: .spawnProvider(provider: AgentProvider.claudeCode.rawValue))
    // The main run uses the default (Work); only the other signed-in account gets its own run.
    var runs = services.morningBriefRoutines(profileID: profile.id)
    #expect(runs.count == 2)
    let extra = try #require(runs.last)
    #expect(extra.accountID == personal.id)
    #expect(extra.delivery == .brief(profileID: profile.id))
    #expect(extra.permissionMode == AgentPermissionMode.readOnly.rawValue)
    #expect(extra.trigger == main.trigger)

    // Changing the main brief carries over; doing it twice creates nothing new.
    var paused = main
    paused.enabled = false
    paused.trigger = .schedule(cron: "0 8 * * *", intervalSeconds: nil)
    _ = try await services.saveRoutine(paused)
    runs = services.morningBriefRoutines(profileID: profile.id)
    #expect(runs.count == 2)
    #expect(runs.last?.id == extra.id)
    #expect(runs.last?.enabled == false)
    #expect(runs.last?.trigger == paused.trigger)

    // The same meeting from both calendars shows once; items say which account they came from.
    let meeting = """
      ```json
      {"items":[{"kind":"event","title":"Acme call","source":"Google Calendar",\
      "time":"\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)))"}]}
      ```
      """
    try await services.deliverRoutineResult(runs[0], nodeID: UUID(), result: meeting)
    try await services.deliverRoutineResult(runs[1], nodeID: UUID(), result: meeting)
    let brief = services.dailyBrief.compose(derived: [], legacyProjectID: services.legacyProjectID)
    if Calendar.current.isDate(Date().addingTimeInterval(3600), inSameDayAs: Date()) {
      #expect(brief.events.count == 1)
      #expect(brief.events.first?.source == "Google Calendar · Work")
    }

    // Deleting an account's run leaves that account out from then on.
    try services.deleteRoutine(id: extra.id)
    try await services.syncMorningBriefAccounts(profileID: profile.id)
    #expect(services.morningBriefRoutines(profileID: profile.id).map(\.id) == [main.id])
    #expect(services.dailyBrief.profile(id: profile.id)?.briefSkippedAccountIDs == [personal.id])

    // Deleting the main brief takes the per-account runs with it.
    var cleared = try #require(services.dailyBrief.profile(id: profile.id))
    cleared.briefSkippedAccountIDs = nil
    try services.dailyBrief.updateProfile(cleared)
    try await services.syncMorningBriefAccounts(profileID: profile.id)
    let again = try #require(services.morningBriefRoutines(profileID: profile.id).last)
    #expect(again.accountID == personal.id)
    try services.deleteRoutine(id: main.id)
    try await services.syncMorningBriefAccounts(profileID: profile.id)
    #expect(services.routines.routine(id: again.id) == nil)
  }

  @Test("After an update, an existing brief picks up other signed-in accounts at launch")
  func accountsAtLaunch() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let accounts = ProviderAccountStore(
      rootDirectory: root.appending(path: "support"), userHome: root.appending(path: "home"),
      secrets: InMemorySecretStore())
    let personal = try accounts.create(name: "Personal")
    let data = accounts.providerDataDirectory(accountID: personal.id, provider: .codex)
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: data.appending(path: "auth.json"))
    // A brief set up by an older version: one run, no per-account runs.
    let before = DailyBriefStore(workspacePath: root.path)
    let routines = RoutineStore(workspacePath: root.path)
    let old = try routines.save(
      Routine(
        name: "Home morning brief", instruction: "Brief",
        trigger: .schedule(cron: "30 7 * * *", intervalSeconds: nil),
        target: .spawnProvider(provider: AgentProvider.codex.rawValue), enabled: true,
        delivery: .brief(profileID: before.selectedProfile.id)))
    var profile = before.selectedProfile
    profile.briefRoutineID = old.id
    try before.updateProfile(profile)

    let services = ApplicationServices(
      store: CanvasStore(), providerAccounts: accounts, workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    let runs = services.morningBriefRoutines(profileID: profile.id)
    #expect(runs.map(\.accountID) == [nil, personal.id])
  }

  @Test("Terminals and plain sessions never reach the brief; bot work does, in plain words")
  func derivedUpdatesAreHumanNews() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = CanvasStore()
    let services = ApplicationServices(store: canvas, workspacePath: root.path)
    let bowie = try services.agentProfiles.save(
      AgentProfile(name: "Bowie", instructions: "Research", provider: .codex))
    func node(_ kind: NodeKind) throws -> UUID {
      try #require(
        canvas.dispatch(.createNode(kind: kind, at: WorldPoint(x: 0, y: 0)))
          .affectedNodeIDs.first)
    }
    let terminal = try node(.terminal)
    let session = try node(.agent)
    let botFailed = try node(.agent)
    let botDone = try node(.agent)
    services.botActivity.consume(
      OttoEvent(sequence: 1, type: .agentExited, nodeID: terminal, exitCode: 1))
    services.botActivity.consume(OttoEvent(sequence: 2, type: .agentRunFailed, nodeID: session))
    services.botActivity.consume(
      OttoEvent(sequence: 3, type: .agentRunFailed, nodeID: botFailed, profileID: bowie.id))
    services.botActivity.consume(
      OttoEvent(sequence: 4, type: .agentRunCompleted, nodeID: botDone, profileID: bowie.id))

    let updates = services.derivedBriefItems().filter { $0.kind == .update }
    #expect(updates.count == 2)
    #expect(Set(updates.map(\.title)) == ["Bowie couldn’t finish", "Bowie finished a task"])
    #expect(!updates.contains { $0.title.contains("Terminal") || $0.title.contains("error") })
  }

  @Test("An automation keeps the AI account the user picked")
  func automationAccount() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    let account = UUID()
    let saved = try await services.saveRoutine(
      Routine(
        name: "Inbox", instruction: "Triage my inbox",
        trigger: .schedule(cron: "0 9 * * 1-5", intervalSeconds: nil),
        target: .spawnProvider(provider: AgentProvider.claudeCode.rawValue), enabled: true,
        delivery: .brief(profileID: nil), accountID: account))
    let reloaded = RoutineStore(workspacePath: root.path)
    #expect(reloaded.routine(id: saved.id)?.accountID == account)
    let data = Data(
      #"{"id":"\#(UUID())","name":"Old","instruction":"x","trigger":{"schedule":{"cron":"0 9 * * *"}},"target":{"spawnProvider":{"provider":"Codex"}},"enabled":false,"concurrency":"skip","delivery":{"canvas":{}},"quietWhenUnchanged":false,"timeZoneIdentifier":"UTC","revision":1,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","fireCount":0}"#
        .utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(Routine.self, from: data).accountID == nil)
  }
}
