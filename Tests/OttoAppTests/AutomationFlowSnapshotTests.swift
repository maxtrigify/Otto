import AppKit
import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI
import Testing

@testable import OttoApp

/// Opt-in visual check of Automations' Flow view. Set OTTO_FLOW_SNAPSHOT_DIR to render PNGs,
/// or OTTO_FLOW_SEED_WORKSPACE to write the sample flows into a try-out workspace.
@Suite("Automation flow snapshots", .serialized)
@MainActor
struct AutomationFlowSnapshotTests {
  @Test func renderFlow() throws {
    guard let output = ProcessInfo.processInfo.environment["OTTO_FLOW_SNAPSHOT_DIR"] else {
      return
    }
    let workspace = FileManager.default.temporaryDirectory.appending(path: "flow-\(UUID())")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    try AutomationFlowSample.seed(RoutineStore(workspacePath: workspace.path))
    let canvas = CanvasStore()
    let services = ApplicationServices(store: canvas, workspacePath: workspace.path)
    let rootID = try #require(services.routines.routines.first { $0.name == "Inbox triage" }?.id)
    for (themeID, file, flow) in [
      ("silverbough", "flow-list", UUID?.none), ("silverbough", "flow-light", rootID),
      ("halcyon", "flow-dark", rootID),
    ] {
      let theme = OttoThemeCatalog.theme(id: themeID)
      let palette = OttoPalette(theme: theme)
      let view = ZStack {
        palette.ink
        AutomationsView(
          store: canvas, services: services, routines: services.routines, initialFlowID: flow)
      }
      .environment(\.ottoPalette, palette)
      try render(
        view, size: CGSize(width: 1440, height: 900), to: "\(output)/\(file).png",
        light: theme.isLightAppearance)
    }
    let parent = try #require(services.routines.routines.first { $0.name == "Inbox triage" })
    let theme = OttoThemeCatalog.theme(id: "silverbough")
    let editor = AutomationEditor(services: services, target: .newStep(after: parent)) { _ in }
      .environment(\.ottoPalette, OttoPalette(theme: theme))
    try render(
      editor, size: CGSize(width: 620, height: 700), to: "\(output)/flow-new-step.png",
      light: true)
  }

  /// An advanced flow whose first agent asks for approval: the canvas builder with the
  /// switch on, then the saved flow waiting on Home.
  @Test func renderApprovalFlow() async throws {
    guard let output = ProcessInfo.processInfo.environment["OTTO_FLOW_SNAPSHOT_DIR"] else {
      return
    }
    let workspace = FileManager.default.temporaryDirectory.appending(path: "approval-\(UUID())")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let canvas = CanvasStore()
    let services = ApplicationServices(store: canvas, workspacePath: workspace.path)
    let palette = OttoPalette(theme: OttoThemeCatalog.theme(id: "shorelight"))
    var draft = AutomationFlowDraft()
    draft.name = "Tip of the day"
    draft.schedule = AutomationSchedule(frequency: .daily, hour: 9, minute: 0)
    var tip = AutomationFlowDraft.Step()
    tip.name = "Tip of the day"
    tip.task = "Write one practical Otto tip for the community."
    tip.reviewOnHome = true
    tip.afterApproval = "Post it in #tips on the Otto Discord"
    var log = AutomationFlowDraft.Step(parentID: tip.id)
    log.name = "Log the tip"
    log.task = "Add {{Tip of the day}} to tips.md with today's date."
    log.allowChanges = true
    draft.steps = [tip, log]
    try render(
      ZStack {
        palette.ink
        AutomationFlowBuilder(services: services, initial: draft) { _ in }
      }.environment(\.ottoPalette, palette), size: CGSize(width: 1440, height: 1000),
      to: "\(output)/approval-builder.png", light: true)

    let rootID = try await draft.save(services: services)
    let run = RoutineRunRecord(
      routineID: rootID, triggerSummary: "schedule 0 9 * * *",
      firedAt: .now.addingTimeInterval(-20 * 60), outcome: .completed, durationMs: 41_000,
      result: "💡 Press ⌃⌥Space anywhere and just say what you want.")
    try services.routines.appendRun(run)
    try services.homeReviews.add(
      HomeReview(
        title: "Tip of the day", requester: "Tip of the day", draft: run.result ?? "",
        afterApproval: tip.afterApproval, routineID: rootID, runID: run.runID))
    try render(
      ZStack {
        palette.ink
        AutomationsView(
          store: canvas, services: services, routines: services.routines, initialFlowID: rootID)
      }.environment(\.ottoPalette, palette), size: CGSize(width: 1440, height: 900),
      to: "\(output)/approval-flow.png", light: true)
  }

  /// The whole journey: empty Automations, the Simple/Advanced choice, the canvas builder
  /// empty and filled, and the saved flow in Flow view.
  @Test func renderJourney() async throws {
    guard let output = ProcessInfo.processInfo.environment["OTTO_FLOW_SNAPSHOT_DIR"] else {
      return
    }
    let workspace = FileManager.default.temporaryDirectory.appending(path: "journey-\(UUID())")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let canvas = CanvasStore()
    let services = ApplicationServices(store: canvas, workspacePath: workspace.path)
    let palette = OttoPalette(theme: OttoThemeCatalog.theme(id: "silverbough"))
    func shot<V: View>(_ view: V, _ name: String, size: CGSize = CGSize(width: 1440, height: 900))
      throws
    {
      try render(
        ZStack {
          palette.ink
          view
        }.environment(\.ottoPalette, palette), size: size,
        to: "\(output)/\(name).png", light: true)
    }
    try shot(
      AutomationsView(store: canvas, services: services, routines: services.routines),
      "journey-1-automations")
    try shot(
      AutomationModeChooser { _ in }, "journey-2-choose", size: CGSize(width: 600, height: 330))
    try shot(
      AutomationFlowBuilder(services: services, initial: AutomationFlowDraft()) { _ in },
      "journey-3-canvas-empty")
    let draft = AutomationFlowJourney.sampleDraft()
    try shot(
      AutomationFlowBuilder(services: services, initial: draft) { _ in },
      "journey-4-canvas-built")
    let rootID = try await draft.save(services: services)
    #expect(services.routines.routine(id: rootID) != nil)
    var chained = draft
    chained.steps.sort { lhs, _ in lhs.name == "Send me the drafts" }
    try shot(
      AutomationFlowBuilder(services: services, initial: chained) { _ in },
      "journey-4b-variables")
    try shot(
      AutomationsView(store: canvas, services: services, routines: services.routines),
      "journey-5-list")
    try shot(
      AutomationsView(
        store: canvas, services: services, routines: services.routines, initialFlowID: rootID),
      "journey-6-flow")
  }

  @Test func seedTryOutWorkspace() throws {
    guard let path = ProcessInfo.processInfo.environment["OTTO_FLOW_SEED_WORKSPACE"] else {
      return
    }
    try AutomationFlowSample.seed(RoutineStore(workspacePath: path))
  }

  private func render<V: View>(_ view: V, size: CGSize, to path: String, light: Bool) throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: path))
  }
}

/// The flow the journey snapshots build on the canvas.
enum AutomationFlowJourney {
  static func sampleDraft() -> AutomationFlowDraft {
    var draft = AutomationFlowDraft()
    draft.schedule = AutomationSchedule(frequency: .weekdays, hour: 8, minute: 0)
    var triage = AutomationFlowDraft.Step()
    triage.name = "Inbox triage"
    triage.task = "Sort overnight email into: needs a reply, leads and deals, meeting requests."
    triage.model = "claude-opus-5-5"
    var replies = AutomationFlowDraft.Step(parentID: triage.id)
    replies.name = "Reply drafter"
    replies.doer = .provider(.codex)
    replies.task = "Draft replies to the threads that need an answer. Don’t send."
    var crm = AutomationFlowDraft.Step(parentID: triage.id)
    crm.name = "CRM updater"
    crm.doer = .provider(.hermes)
    crm.task = "Log new leads and move deals forward in Attio."
    crm.allowChanges = true
    var digest = AutomationFlowDraft.Step(parentID: replies.id)
    digest.name = "Send me the drafts"
    digest.when = .finished
    digest.task = "Put these drafts in my brief: {{Reply drafter}}"
    digest.destination = .brief
    draft.steps = [triage, replies, crm, digest]
    return draft
  }
}

/// Two sample flows with a realistic run history: a morning inbox flow that branches into
/// three steps (one failed, with a fallback), and a paused weekly report.
@MainActor
enum AutomationFlowSample {
  static func seed(_ store: RoutineStore) throws {
    let claude = RoutineTarget.spawnProvider(provider: AgentProvider.claudeCode.rawValue)
    let codex = RoutineTarget.spawnProvider(provider: AgentProvider.codex.rawValue)
    let readOnly = AgentPermissionMode.readOnly.rawValue
    func step(
      _ name: String, _ instruction: String, _ target: RoutineTarget,
      after parent: Routine? = nil, when: RoutineChainCondition = .succeeded,
      delivery: RoutineDelivery = .canvas, enabled: Bool = true,
      cron: String = "0 8 * * 1-5"
    ) throws -> Routine {
      var routine = Routine(
        name: name, instruction: instruction,
        trigger: .schedule(cron: cron, intervalSeconds: nil), target: target, enabled: enabled,
        permissionMode: readOnly, delivery: delivery)
      if let parent { routine.chain(after: parent.id, when: when) }
      return try store.save(routine)
    }
    func run(
      _ routine: Routine, _ outcome: RoutineRunOutcome, minutesAgo: Double, seconds: Double?,
      error: String? = nil, result: String? = nil
    ) throws {
      try store.appendRun(
        RoutineRunRecord(
          routineID: routine.id, triggerSummary: routine.triggerSummary,
          firedAt: .now.addingTimeInterval(-minutesAgo * 60), outcome: outcome,
          durationMs: seconds.map { $0 * 1000 }, error: error, result: result))
    }

    let triage = try step(
      "Inbox triage",
      "Sort overnight email into piles: needs a reply, leads and deals, meeting requests. Hand each pile on.",
      claude)
    let replies = try step(
      "Reply drafter", "Draft replies to the threads that need an answer from me. Don’t send.",
      codex, after: triage)
    let crm = try step(
      "CRM updater", "Log new leads and move deals forward in Attio. Never delete records.",
      claude, after: triage)
    let calendar = try step(
      "Calendar check", "Find times for the meeting requests and hold them.", claude,
      after: triage)
    let digest = try step(
      "Send me the drafts", "Put the drafted replies in my brief so I can send them.", claude,
      after: replies, when: .finished, delivery: .brief(profileID: nil))
    let fallback = try step(
      "Tell me what broke", "Explain in one line why the calendar step failed.", claude,
      after: calendar, when: .failed, delivery: .brief(profileID: nil))
    let weekly = try step(
      "Weekly progress report", "Summarise what shipped, what’s blocked and what needs me.",
      codex, delivery: .brief(profileID: nil), enabled: false, cron: "0 16 * * 5")

    for day in stride(from: 9.0, through: 1.0, by: -1) {
      let ago = day * 1_440
      try run(triage, .completed, minutesAgo: ago, seconds: 38 + day * 3)
      try run(replies, day == 6 ? .failed : .completed, minutesAgo: ago - 2, seconds: 44 + day)
      try run(
        crm, day.truncatingRemainder(dividingBy: 3) == 0 ? .noChange : .completed,
        minutesAgo: ago - 2, seconds: 25 + day * 2)
      try run(calendar, .completed, minutesAgo: ago - 2, seconds: 12)
      try run(digest, .completed, minutesAgo: ago - 3, seconds: 9)
    }
    try run(
      triage, .completed, minutesAgo: 6, seconds: 41,
      result: """
        12 new emails since 18:00.

        Needs a reply (4): Acme renewal question, Priya re: onboarding call, Stripe dispute, Tom's intro to Northwind.
        Leads and deals (3): Northwind wants pricing, Lumen signed, Acme moved to procurement.
        Meeting requests (2): Priya Thu/Fri, Northwind next week.
        Skipped 3 newsletters.
        """)
    try run(replies, .completed, minutesAgo: 5, seconds: 48)
    try run(crm, .running, minutesAgo: 1.2, seconds: nil)
    try run(
      calendar, .failed, minutesAgo: 5, seconds: 6,
      error: "Google Calendar isn’t connected for the Work space.")
    try run(fallback, .completed, minutesAgo: 4.5, seconds: 7)
    try run(weekly, .completed, minutesAgo: 3 * 1_440, seconds: 95)
  }
}
