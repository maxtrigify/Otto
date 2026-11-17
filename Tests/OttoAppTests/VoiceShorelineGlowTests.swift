import Foundation
import OttoModels
import OttoVoice
import Testing

@testable import OttoApp

@Test func anOpenMicrophoneThatHearsNothingShowsNoGlow() {
  #expect(VoiceGlowPhase.resolve(state: .listening, holding: false) == .hidden)
  #expect(VoiceGlowPhase.resolve(state: .sleeping, holding: false) == .hidden)
}

@Test func theGlowFollowsWhoeverIsTalking() {
  #expect(VoiceGlowPhase.resolve(state: .listening, holding: true) == .hearing)
  #expect(VoiceGlowPhase.resolve(state: .userSpeaking, holding: false) == .hearing)
  #expect(VoiceGlowPhase.resolve(state: .thinking, holding: false) == .working)
  #expect(VoiceGlowPhase.resolve(state: .callingTool, holding: false) == .working)
  #expect(VoiceGlowPhase.resolve(state: .speaking, holding: false) == .speaking)
}

@Test func quietSpeechStillMovesTheGlowAndLoudSpeechDoesNotClip() {
  #expect(VoiceGlowPhase.energy(forLevel: 0) == 0)
  #expect(VoiceGlowPhase.energy(forLevel: 0.04) > 0.4)
  #expect(VoiceGlowPhase.energy(forLevel: 0.9) == 1)
}

private func emptyContext() -> VoiceContext {
  VoiceContext(
    activeCanvas: VoiceCanvasContext(
      id: UUID(), name: "Main", workspace: "/tmp", layout: .freeform),
    nodes: [])
}

@Test func voiceKnowsWhichPlaceThePersonIsIn() {
  let home = VoiceController.screen(
    onHome: true, navigation: .init(destination: .documents), context: emptyContext(),
    canvases: [], openDocumentPath: "/tmp/Plan.md", browserNodeID: nil)
  #expect(home == VoiceScreenContext(place: "Home"))

  let activity = VoiceController.screen(
    onHome: false, navigation: .init(destination: .activity), context: emptyContext(),
    canvases: [], openDocumentPath: "", browserNodeID: nil)
  #expect(activity.place == "Activity")
  #expect(activity.summary == "The user is looking at Activity in Otto.")
}

@Test func voiceKnowsWhichDocumentOrBotIsOpen() {
  let document = VoiceController.screen(
    onHome: false, navigation: .init(destination: .documents), context: emptyContext(),
    canvases: [], openDocumentPath: "/Users/me/Docs/How Otto is used.board", browserNodeID: nil)
  #expect(document.kind == "document")
  #expect(document.showing == "How Otto is used.board")
  #expect(document.path == "/Users/me/Docs/How Otto is used.board")
  #expect(
    document.summary
      == "The user is in Documents in Otto, looking at the document \"How Otto is used.board\".")

  var context = emptyContext()
  let bot = VoiceBotContext(
    id: UUID(), name: "Coder", handle: "coder", jobTitle: nil, nodeID: UUID())
  context.bots = [bot]
  let chat = VoiceController.screen(
    onHome: false, navigation: .init(selectedProfileID: bot.id, destination: .conversation),
    context: context, canvases: [], openDocumentPath: "", browserNodeID: nil)
  #expect(chat.kind == "bot")
  #expect(chat.showing == "Coder")
  #expect(chat.nodeID == bot.nodeID)
}
