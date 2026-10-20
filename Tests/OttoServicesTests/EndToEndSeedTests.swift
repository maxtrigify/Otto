import Foundation
import OttoModels
import OttoRuntime
import Testing

@testable import OttoServices

/// Opt-in: seeds a throwaway workspace with an automation that has a real agent drive the
/// document, sheet, slide and dashboard tools through Otto's MCP bridge. Set
/// OTTO_E2E_WORKSPACE, launch Otto on that workspace, and read `e2e-result.md`.
@MainActor
@Suite("End-to-end seed")
struct EndToEndSeedTests {
  static let instruction = """
    This is an automated end-to-end check of Otto's document tools. Use only the Otto MCP \
    tools named below. Do not use the shell, and do not read or write files directly.
    1. docs.create with title "E2E brief", kind document, content "# E2E brief\\nOtto helps \
    people work with agents.\\n- Docs\\n- Sheets".
    2. docs.suggest_edit with doc "E2E brief", find "Otto helps people work with agents.", \
    replace "Otto is a personal OS where agents help with everyday work.", note "Clearer opening".
    3. docs.create with title "E2E budget", kind spreadsheet. Then sheet.set_cells with doc \
    "E2E budget" and cells {"A1":"Item","B1":"Cost","A2":"Rent","B2":"1200","A3":"Food", \
    "B3":"300","A4":"Total","B4":"=SUM(B2:B3)"}.
    4. docs.create with title "E2E pitch", kind presentation. Then slides.add_slide with doc \
    "E2E pitch", title "Problem", bullets ["Too many apps","No memory"]. Then \
    slides.update_slide with doc "E2E pitch", slide 1, title "Otto", bullets ["Your personal OS"].
    5. dashboard.create with name "E2E". Then home.add_card with dashboard "E2E", title \
    "Budget", style bar, rows [{"label":"Rent","value":"1200"},{"label":"Food","value":"300"}], \
    source "E2E budget sheet".
    6. docs.read with doc "E2E budget".
    Finally reply with exactly one line: "E2E-PASS B4=<value>" if step 6 shows B4 evaluates to \
    1500 and every step succeeded, otherwise "E2E-FAIL <which step and the error>".
    """

  @Test func seed() throws {
    guard let path = ProcessInfo.processInfo.environment["OTTO_E2E_WORKSPACE"] else { return }
    let store = RoutineStore(workspacePath: path)
    var routine = Routine(
      name: "Documents end-to-end", instruction: Self.instruction,
      trigger: .schedule(cron: "* * * * *", intervalSeconds: nil),
      target: .spawnProvider(provider: AgentProvider.claudeCode.rawValue))
    routine.delivery = .document(relativePath: "e2e-result.md")
    routine.permissionMode = AgentPermissionMode.unrestricted.rawValue
    routine.quietWhenUnchanged = false
    routine.enabled = true
    _ = try store.save(routine)
    #expect(store.routines.count == 1)
  }

  static let deckInstruction = """
    Automated end-to-end check of Otto's slides. Use only the Otto MCP tools named below; no \
    shell, no files.
    1. docs.create with title "Otto pitch", kind presentation.
    2. slides.guide, and follow it closely.
    3. Design a beautiful 7-slide investor pitch deck for Otto: a personal OS for everyday \
    people where AI agents write documents, build dashboards and run automations for them. \
    Use clearly different layouts from the guide: a title slide, the problem, the solution \
    with a 3D feature visual, how it works as steps, traction with count-up stats, a growth \
    chart, and a closing slide. Invent plausible numbers. Add short speaker notes. Write it in \
    one call with slides.set_deck on doc "Otto pitch" with theme aurora.
    Finally reply with exactly one line: "DECK-DONE <number of slides>" or "DECK-FAIL <reason>".
    """

  @Test func seedDeck() throws {
    guard let path = ProcessInfo.processInfo.environment["OTTO_E2E_DECK_WORKSPACE"] else { return }
    let store = RoutineStore(workspacePath: path)
    var routine = Routine(
      name: "Slides end-to-end", instruction: Self.deckInstruction,
      trigger: .schedule(cron: "* * * * *", intervalSeconds: nil),
      target: .spawnProvider(provider: AgentProvider.claudeCode.rawValue))
    routine.delivery = .document(relativePath: "e2e-result.md")
    routine.permissionMode = AgentPermissionMode.unrestricted.rawValue
    routine.quietWhenUnchanged = false
    routine.enabled = true
    _ = try store.save(routine)
  }
}
