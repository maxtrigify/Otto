import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@testable import OttoServices

@MainActor
@Suite("Home card tools")
struct HomeCardToolsTests {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "home-cards-\(UUID())")
  }

  private let caller = ToolContext(
    actorID: "agent", scopes: [.canvasWrite, .agentRead], source: .agent)

  private func call<Output: Decodable & Sendable>(
    _ services: ApplicationServices, _ name: String, _ input: some Encodable & Sendable,
    as: Output.Type = HomeCardOutput.self
  ) async throws -> Output {
    try await services.registry.call(
      name: name, input: try JSONValue.encode(input), context: caller
    ).decode(Output.self)
  }

  @Test("Add, refuse a look-alike until the user picks, then update and remove")
  func addUpdateRemove() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }

    let added = try await call(
      services, "home.add_card",
      HomeCardAddInput(
        title: "Social followers",
        rows: [.init(label: "LinkedIn", value: "12480"), .init(label: "Reddit", value: "310")]))
    #expect(added.created)
    #expect(added.card?.style == "metrics")

    let lookalike = try await call(
      services, "home.add_card", HomeCardAddInput(title: "My socials", style: "metrics"))
    #expect(!lookalike.created)
    #expect(lookalike.similarCards == ["Social followers"])
    #expect(services.homeCards.cards.count == 1)

    let forced = try await call(
      services, "home.add_card",
      HomeCardAddInput(title: "My socials", style: "text", text: "Hi", newCard: true))
    #expect(forced.created)

    let updated = try await call(
      services, "home.update_card",
      HomeCardUpdateInput(card: "social followers", rows: [.init(label: "Substack", value: "9")]))
    #expect(updated.card?.rows == ["LinkedIn: 12480", "Reddit: 310", "Substack: 9"])

    let listed = try await call(
      services, "home.list_cards", HomeCardListTool.Input(), as: HomeCardListOutput.self)
    #expect(listed.cards.map(\.title) == ["Social followers", "My socials"])

    _ = try await call(services, "home.remove_card", HomeCardRefInput(card: "My socials"))
    #expect(services.homeCards.cards.map(\.title) == ["Social followers"])
    await #expect(throws: (any Error).self) {
      _ = try await call(services, "home.update_card", HomeCardUpdateInput(card: "Nope"))
    }

    // Cards belong to the space and survive a relaunch.
    #expect(HomeCardsStore(workspacePath: root.path).cards.map(\.title) == ["Social followers"])
  }

  @Test("Keeping a card fresh links one read-only automation that fills the card")
  func keepFresh() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }

    _ = try await call(
      services, "home.add_card", HomeCardAddInput(title: "Today's meetings", style: "list"))
    let fresh = try await call(
      services, "home.keep_card_fresh",
      HomeCardFreshInput(
        card: "Today's meetings", task: "List my meetings today", cron: "30 7 * * 1-5",
        agent: "Codex"))
    #expect(fresh.card?.keptFreshBy == "Update Today's meetings")
    let card = try #require(services.homeCards.cards.first)
    let routine = try #require(card.automationID.flatMap { services.routines.routine(id: $0) })
    #expect(routine.delivery == .homeCard(cardID: card.id))
    #expect(routine.permissionMode == AgentPermissionMode.readOnly.rawValue)
    #expect(routine.target == .spawnProvider(provider: AgentProvider.codex.rawValue))
    #expect(
      try RoutineEngine.composePrompt(routine: routine, payload: nil, now: .now)
        .contains("updates a card on the user's Home page"))

    // Asking again re-schedules rather than adding a second automation.
    _ = try await call(
      services, "home.keep_card_fresh",
      HomeCardFreshInput(card: "meetings", task: "List my meetings", cron: "0 8 * * *"))
    #expect(services.routines.routines.count == 1)
    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "home.keep_card_fresh",
        HomeCardFreshInput(card: "meetings", task: "x", cron: "every morning"))
    }

    try await services.deliverRoutineResult(
      routine, nodeID: UUID(),
      result: """
        ```json
        {"rows":[{"label":"Acme pricing call","value":"11:00","detail":"Jo wants a decision"}]}
        ```
        """)
    #expect(services.homeCards.cards.first?.rows.map(\.label) == ["Acme pricing call"])
    #expect(services.homeCards.cards.first?.updatedBy == routine.name)

    _ = try await call(
      services, "home.remove_card",
      HomeCardRefInput(card: "Today's meetings", alsoDeleteAutomation: true))
    #expect(services.homeCards.cards.isEmpty)
    #expect(services.routines.routines.isEmpty)
  }

  @Test("Dashboards hold their own cards; similar titles only clash on the same page")
  func dashboards() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }

    let made = try await call(
      services, "dashboard.create", DashboardCreateInput(name: "Revenue"), as: DashboardOutput.self)
    #expect(made.created == "Revenue")
    let again = try await call(
      services, "dashboard.create", DashboardCreateInput(name: "revenue"), as: DashboardOutput.self)
    #expect(again.created == nil)
    #expect(again.dashboards == ["Revenue"])

    _ = try await call(
      services, "home.add_card",
      HomeCardAddInput(title: "MRR", rows: [.init(label: "MRR", value: "4200")]))
    // The same title on a dashboard is a different page, so no look-alike refusal.
    let chart = try await call(
      services, "home.add_card",
      HomeCardAddInput(
        title: "MRR", style: "line",
        rows: [.init(label: "Aug", value: "3900"), .init(label: "Sep", value: "4200")],
        dashboard: "Revenue", source: "Stripe balance transactions, Aug–Sep"))
    #expect(chart.created)
    #expect(chart.card?.dashboard == "Revenue")
    #expect(chart.card?.source == "Stripe balance transactions, Aug–Sep")
    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "home.add_card", HomeCardAddInput(title: "X", dashboard: "Nope"))
    }

    let board = try #require(services.homeCards.dashboard(named: "Revenue"))
    #expect(services.homeCards.cards.map(\.style) == [.metrics])
    #expect(services.homeCards.cards(on: board.id).map(\.style) == [.line])
    let listed = try await call(
      services, "home.list_cards", HomeCardListTool.Input(dashboard: "Revenue"),
      as: HomeCardListOutput.self)
    #expect(listed.cards.map(\.title) == ["MRR"])
    #expect(listed.dashboards == ["Revenue"])

    _ = try await call(
      services, "home.update_card",
      HomeCardUpdateInput(
        card: "MRR", rows: [.init(label: "Oct", value: "4500")], dashboard: "Revenue"))
    #expect(services.homeCards.cards(on: board.id).first?.rows.count == 3)
    #expect(services.homeCards.cards.first?.rows.count == 1)

    let removed = try #require(try services.homeCards.deleteDashboard(id: board.id))
    #expect(services.homeCards.allCards.count == 1)
    try services.homeCards.restoreDashboard(removed.0, cards: removed.1)
    #expect(services.homeCards.allCards.count == 2)
  }

  @Test("Agents arrange a dashboard: size, colour, order and the page's look")
  func arrange() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }

    _ = try await call(
      services, "dashboard.create", DashboardCreateInput(name: "Socials"), as: DashboardOutput.self)
    for title in ["Substack", "LinkedIn", "Reddit"] {
      _ = try await call(
        services, "home.add_card",
        HomeCardAddInput(
          title: title, rows: [.init(label: "Followers", value: "10")], newCard: true,
          dashboard: "Socials"))
    }
    let board = try #require(services.homeCards.dashboard(named: "Socials"))
    let before = try #require(services.homeCards.card(named: "Reddit", on: board.id)).updatedAt

    let sized = try await call(
      services, "home.update_card",
      HomeCardUpdateInput(
        card: "Reddit", dashboard: "Socials", width: "full", color: "Violet", moveTo: "Substack"))
    #expect(sized.card?.width == "full")
    #expect(sized.card?.color == "purple")
    #expect(
      services.homeCards.cards(on: board.id).map(\.title) == ["Reddit", "Substack", "LinkedIn"])
    // Arranging is not new data, so the "Updated" time stays put.
    #expect(services.homeCards.card(named: "Reddit", on: board.id)?.updatedAt == before)

    _ = try await call(
      services, "home.update_card",
      HomeCardUpdateInput(card: "Reddit", dashboard: "Socials", width: "regular", color: ""))
    let reddit = try #require(services.homeCards.card(named: "Reddit", on: board.id))
    #expect(reddit.width == nil)
    #expect(reddit.color == nil)
    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "home.update_card",
        HomeCardUpdateInput(card: "Reddit", dashboard: "Socials", color: "chartreuse"))
    }

    _ = try await call(
      services, "dashboard.update",
      DashboardUpdateInput(dashboard: "socials", accent: "blue", cardStyle: "solid"),
      as: DashboardOutput.self)
    #expect(services.homeCards.dashboard(id: board.id)?.accent == .blue)
    #expect(services.homeCards.dashboard(id: board.id)?.cardStyle == .solid)

    // Dragging a card onto a later one puts it in that card's place.
    let substack = try #require(services.homeCards.card(named: "Substack", on: board.id))
    let linkedIn = try #require(services.homeCards.card(named: "LinkedIn", on: board.id))
    try services.homeCards.move(id: substack.id, to: linkedIn.id)
    #expect(
      services.homeCards.cards(on: board.id).map(\.title) == ["Reddit", "LinkedIn", "Substack"])

    let reloaded = HomeCardsStore(workspacePath: root.path)
    #expect(reloaded.dashboard(id: board.id)?.accent == .blue)
    #expect(reloaded.cards(on: board.id).map(\.title) == ["Reddit", "LinkedIn", "Substack"])
  }

  @Test("Legacy card bindings survive an Otto folder created before migration")
  func legacyCardBindingsHideFailedSessions() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CanvasStore()
    let nodeID = try #require(
      store.dispatch(
        .createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))
      ).affectedNodeIDs.first)
    store.dispatch(.setNodeStatus(id: nodeID, status: .failed, detail: "Failed update"))
    let key = OfficeStore.cardRunKey(UUID())
    let legacy = root.appending(path: ".muse")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appending(path: ".otto/chat-attachments"), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "suggestions": [], "sessions": [key: nodeID.uuidString],
    ]).write(to: legacy.appending(path: "office.json"))

    let services = ApplicationServices(store: store, workspacePath: root.path)
    #expect(services.office.boundSessionIDs.contains(nodeID))
    #expect(!services.controlSessionList().sessions.contains { $0.sessionID == nodeID })
    #expect(store.activeCanvas.nodes.contains { $0.id == nodeID })
  }

  @Test("A card's update is background work: out of Chat, gone once the card is updated")
  @MainActor func cardRunSessions() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }

    let cardID = UUID()
    let first = UUID()
    let second = UUID()
    await services.bindCardRun(cardID: cardID, nodeID: first)
    #expect(services.office.boundSessionIDs.contains(first))
    #expect(services.workBindingContext(nodeID: first) == nil)

    await services.bindCardRun(cardID: cardID, nodeID: second)
    #expect(services.office.session(path: OfficeStore.cardRunKey(cardID)) == second)
    #expect(!services.office.boundSessionIDs.contains(first))

    await services.closeCardRun(cardID: cardID)
    #expect(services.office.session(path: OfficeStore.cardRunKey(cardID)) == nil)
    #expect(services.cardRunSession(cardID: cardID) == nil)

    // A finished update closes itself; a failed one stays so the person can see why.
    let failed = UUID()
    await services.bindCardRun(cardID: cardID, nodeID: failed)
    services.supervisor.eventBus.publish(
      OttoEvent(type: .routineCompleted, nodeID: failed, outcome: "failed"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(services.office.session(path: OfficeStore.cardRunKey(cardID)) == failed)

    let finished = UUID()
    await services.bindCardRun(cardID: cardID, nodeID: finished)
    services.supervisor.eventBus.publish(
      OttoEvent(type: .routineCompleted, nodeID: finished, outcome: "completed"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(services.office.session(path: OfficeStore.cardRunKey(cardID)) == nil)
    #expect(services.office.cardRunNodeIDs.isEmpty)
  }
}
