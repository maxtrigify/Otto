import Testing

@testable import OttoVoice

@Suite("Primary voice action routing")
struct VoicePrimaryActionRouterTests {
  @Test("active local command wins even when a cloud credential exists")
  func activeCommandWinsOverCloudCredential() {
    #expect(
      VoicePrimaryActionRouter.resolve(
        activeAction: .command,
        hasCloudCredential: true
      ) == .command
    )
  }

  @Test("active dictation wins even when a cloud credential exists")
  func activeDictationWinsOverCloudCredential() {
    #expect(
      VoicePrimaryActionRouter.resolve(
        activeAction: .dictate,
        hasCloudCredential: true
      ) == .dictate
    )
  }

  @Test("idle microphone chooses cloud only when a credential exists")
  func idleRoutingUsesCredentialAvailability() {
    #expect(
      VoicePrimaryActionRouter.resolve(
        activeAction: nil,
        hasCloudCredential: true
      ) == .talk
    )
    #expect(
      VoicePrimaryActionRouter.resolve(
        activeAction: nil,
        hasCloudCredential: false
      ) == .command
    )
  }
}
