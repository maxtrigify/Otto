import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoServices
import Testing

@testable import OttoApp

/// The advanced canvas builder saves a flow as chained automations and loads it back.
@Suite(.serialized)
@MainActor
struct AutomationFlowDraftTests {
  private func services() throws -> (ApplicationServices, URL) {
    let workspace = FileManager.default.temporaryDirectory.appending(path: "draft-\(UUID())")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    return (ApplicationServices(store: CanvasStore(), workspacePath: workspace.path), workspace)
  }

  @Test func savingACanvasFlowChainsItsAgents() async throws {
    let (services, workspace) = try services()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let draft = AutomationFlowJourney.sampleDraft()
    let rootID = try await draft.save(services: services)

    let routines = services.routines
    let root = try #require(routines.routine(id: rootID))
    #expect(root.name == "Inbox triage")
    #expect(root.runAfter == nil)
    #expect(root.trigger == .schedule(cron: "0 8 * * 1-5", intervalSeconds: nil))
    #expect(root.model == "claude-opus-5-5")
    #expect(
      routines.followers(of: rootID).map(\.name).sorted() == ["CRM updater", "Reply drafter"])
    let crm = try #require(routines.routines.first { $0.name == "CRM updater" })
    #expect(crm.target == .spawnProvider(provider: "Hermes"))
    #expect(crm.permissionMode == AgentPermissionMode.workspaceWrite.rawValue)
    let digest = try #require(routines.routines.first { $0.name == "Send me the drafts" })
    #expect(digest.runAfter?.when == .finished)
    #expect(routines.flowRoot(of: digest.id)?.id == rootID)
  }

  @Test func aCanvasStepCanAskForApprovalAndOthersCarryStraightOn() async throws {
    let (services, workspace) = try services()
    defer { try? FileManager.default.removeItem(at: workspace) }
    var draft = AutomationFlowJourney.sampleDraft()
    let repliesIndex = try #require(draft.steps.firstIndex { $0.name == "Reply drafter" })
    draft.steps[repliesIndex].reviewOnHome = true
    draft.steps[repliesIndex].afterApproval = "  Send them from my Gmail  "
    let rootID = try await draft.save(services: services)

    let replies = try #require(services.routines.routines.first { $0.name == "Reply drafter" })
    #expect(replies.needsReview)
    #expect(replies.afterApproval == "Send them from my Gmail")
    // Only the step that asked waits; the rest are saved exactly as before.
    for other in services.routines.routines where other.id != replies.id {
      #expect(!other.needsReview)
      #expect(other.reviewOnHome == nil)
      #expect(other.afterApproval == nil)
    }

    var edit = AutomationFlowDraft(
      flowFrom: try #require(services.routines.routine(id: rootID)),
      in: services.routines.routines)
    let loaded = try #require(edit.steps.first { $0.name == "Reply drafter" })
    #expect(loaded.reviewOnHome)
    #expect(loaded.afterApproval == "Send them from my Gmail")

    // Turning it off clears the action too, so nothing is left waiting.
    let index = try #require(edit.steps.firstIndex { $0.name == "Reply drafter" })
    edit.steps[index].reviewOnHome = false
    _ = try await edit.save(services: services)
    let cleared = try #require(services.routines.routine(id: replies.id))
    #expect(cleared.reviewOnHome == nil)
    #expect(cleared.afterApproval == nil)
  }

  @Test func editingAFlowUpdatesInPlaceAndDeletesRemovedAgents() async throws {
    let (services, workspace) = try services()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let rootID = try await AutomationFlowJourney.sampleDraft().save(services: services)
    let root = try #require(services.routines.routine(id: rootID))

    var edit = AutomationFlowDraft(flowFrom: root, in: services.routines.routines)
    #expect(edit.steps.count == 4)
    #expect(edit.schedule.hour == 8)
    let crmIndex = try #require(edit.steps.firstIndex { $0.name == "CRM updater" })
    let crmID = edit.steps[crmIndex].id
    edit.steps.remove(at: crmIndex)
    let repliesIndex = try #require(edit.steps.firstIndex { $0.name == "Reply drafter" })
    edit.steps[repliesIndex].task = "Draft short replies."
    _ = try await edit.save(services: services)

    #expect(services.routines.routines.count == 3)
    #expect(services.routines.routine(id: crmID) == nil)
    #expect(
      services.routines.routines.first { $0.name == "Reply drafter" }?.instruction
        == "Draft short replies.")
  }
}

@Suite struct AutomationModelNameTests {
  @Test func modelIdsReadLikeProductNames() {
    #expect(AutomationModels.prettify("claude-opus-5-5") == "Opus 5.5")
    #expect(AutomationModels.prettify("claude-sonnet-5-5") == "Sonnet 5.5")
    #expect(AutomationModels.prettify("gpt-6-sol") == "GPT-6 Sol")
    #expect(AutomationModels.prettify("gpt-5.6-terra") == "GPT-5.6 Terra")
    #expect(AutomationModels.prettify("openai/gpt-6-mini") == "GPT-6 Mini")
  }
}
