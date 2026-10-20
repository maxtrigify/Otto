import Foundation
import OttoModels
import Testing

@Suite("Legacy Muse markers and names still parse")
struct OttoLegacyNamesTests {
  @Test("Hidden control prompts are recognised in both spellings; Otto emits the new one")
  func hiddenControlPrompts() {
    let prompt = PromptSubmission.hiddenControlPrompt("resume")
    #expect(prompt.hasPrefix("[OTTO HIDDEN CONTROL PROMPT]"))
    #expect(PromptSubmission.isHiddenControlPrompt(prompt))
    #expect(PromptSubmission.isHiddenControlPrompt("[MUSE HIDDEN CONTROL PROMPT]\nresume"))
    #expect(!PromptSubmission.isHiddenControlPrompt("hello"))
  }

  @Test("Context envelopes unwrap whether written by Otto or Muse, even nested")
  func contextEnvelopes() {
    let ask = "What changed?"
    let otto = PromptSubmission.contextualPrompt(ask, context: "ctx")
    #expect(otto.hasPrefix("[OTTO CONTEXT PROMPT user-utf8-count:"))
    #expect(PromptSubmission.originalUserText(otto) == ask)
    let legacy =
      "[MUSE CONTEXT PROMPT user-utf8-count:\(ask.utf8.count)]\nPrevious conversation context…\n"
      + "Current user message:\n\(ask)"
    #expect(PromptSubmission.originalUserText(legacy) == ask)
    let nested = PromptSubmission.contextualPrompt(legacy, context: "outer")
    #expect(PromptSubmission.originalUserText(nested) == ask)
  }

  @Test("Status and result markers parse in both spellings")
  func statusMarkers() {
    #expect(OttoTranscriptMarkers.statusValue(in: "OTTO_STATUS:DONE") == "DONE")
    #expect(OttoTranscriptMarkers.statusValue(in: "x MUSE_STATUS:IDLE") == "IDLE")
    #expect(OttoTranscriptMarkers.resultValue(in: "MUSE_RESULT:ok") == "ok")
    #expect(OttoTranscriptMarkers.resultValue(in: "OTTO_RESULT:ok") == "ok")
    #expect(OttoTranscriptMarkers.statusValue(in: "plain output") == nil)
  }

  @Test("Details markers and fenced blocks accept the legacy muse names")
  func detailsAndFences() {
    #expect(OttoTranscriptMarkers.detailsMarker == "<!-- otto:details -->")
    #expect(OttoTranscriptMarkers.detailsMarkerRange(in: "a\n<!-- muse:details -->\nb") != nil)
    #expect(OttoTranscriptMarkers.detailsMarkerRange(in: "a\n<!-- otto:details -->\nb") != nil)
    #expect(OttoTranscriptMarkers.emailFences == ["otto-email", "muse-email"])
    #expect(OttoTranscriptMarkers.inboxFences == ["otto-inbox", "muse-inbox"])
    #expect(OttoTranscriptMarkers.teamTagPairs.map(\.0) == ["<otto_team>", "<muse_team>"])
    #expect(OttoTranscriptMarkers.teamPromptEnd == "[OTTO TEAM PROMPT END]")
  }

  @Test("A stored muse naming mode reads as Otto's roster")
  func namingMode() throws {
    #expect(AgentNamingMode(rawValue: "muse") == .otto)
    #expect(AgentNamingMode(rawValue: "otto") == .otto)
    #expect(AgentNamingMode(rawValue: "custom") == .custom)
    #expect(AgentNamingMode(rawValue: "other") == nil)
    let decoded = try JSONDecoder().decode([AgentNamingMode].self, from: Data(#"["muse"]"#.utf8))
    #expect(decoded == [.otto])
    let suite = "otto-naming-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("muse", forKey: OttoPreferenceKey.agentNamingMode)
    #expect(AgentNamingPolicy.load(from: defaults).mode == .otto)
  }

  @Test("Brief item origins keep their JSON shape and read the legacy muse key")
  func briefOrigin() throws {
    let encoded = try JSONEncoder().encode(BriefItemOrigin.otto)
    #expect(String(decoding: encoded, as: UTF8.self) == #"{"otto":{}}"#)
    #expect(
      try JSONDecoder().decode(BriefItemOrigin.self, from: Data(#"{"muse":{}}"#.utf8)) == .otto)
    let routine = BriefItemOrigin.routine(UUID())
    #expect(
      try JSONDecoder().decode(BriefItemOrigin.self, from: JSONEncoder().encode(routine)) == routine
    )
    let agent = BriefItemOrigin.agent("Aria")
    #expect(
      try JSONDecoder().decode(BriefItemOrigin.self, from: JSONEncoder().encode(agent)) == agent)
  }

  @Test("Saved browser tabs on muse://start still show the start page")
  func startURL() {
    #expect(BrowserDefaults.startURL == "otto://start")
    #expect(BrowserDefaults.isStartURL("muse://start"))
    #expect(BrowserDefaults.isStartURL("otto://start"))
    #expect(!BrowserDefaults.isStartURL("https://example.com"))
  }

  @Test("Wire and crypto constants keep their deployed spelling")
  func wireConstants() {
    #expect(OttoLegacyWire.privateInputLabel == "muse-private-input-v1")
    #expect(OttoLegacyWire.privateInputHPKEInfo == "muse-private-input-hpke-auth-v1")
    #expect(OttoLegacyWire.phoneHostSignatureLabel == "muse-phone-host-v1")
    #expect(OttoLegacyWire.deviceIDHeader == "X-Muse-Device-ID")
    #expect(OttoLegacyWire.updateFeedURL == "https://maxtrigify.github.io/muse-releases/")
    #expect(OttoLegacyWire.releaseSigningKeyID == "muse-2026-1")
  }

  @Test("Default user folders: an existing Muse folder is reused, otherwise Otto")
  func defaultFolders() throws {
    let parent = FileManager.default.temporaryDirectory
      .appending(path: "otto-folders-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    func preferred() -> String {
      OttoPaths.preferredUserFolder(
        in: parent, name: OttoPaths.defaultWorkspaceFolder,
        legacyName: OttoPaths.legacyDefaultWorkspaceFolder
      ).lastPathComponent
    }
    #expect(preferred() == "Otto Workspace")
    try FileManager.default.createDirectory(
      at: parent.appending(path: "Muse Workspace"), withIntermediateDirectories: true)
    #expect(preferred() == "Muse Workspace")
    try FileManager.default.createDirectory(
      at: parent.appending(path: "Otto Workspace"), withIntermediateDirectories: true)
    #expect(preferred() == "Otto Workspace")
  }
}
