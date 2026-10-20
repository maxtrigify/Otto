import OttoModels
import OttoRuntime
import Testing

@testable import OttoServices

@MainActor
@Suite("Derived bot avatar state")
struct BotAvatarStateTests {
  @Test("Attention overrides lifecycle and runtime states map without persistence")
  func lifecycleProjection() {
    #expect(
      ApplicationServices.botAvatarState(
        lifecycle: .working, hasRuntimeIdentity: true, needsYou: true) == .needsUser)
    #expect(
      ApplicationServices.botAvatarState(
        lifecycle: .working, hasRuntimeIdentity: true, needsYou: false) == .working)
    #expect(
      ApplicationServices.botAvatarState(
        lifecycle: .failed, hasRuntimeIdentity: true, needsYou: false) == .failed)
    #expect(
      ApplicationServices.botAvatarState(
        lifecycle: .stopped, hasRuntimeIdentity: true, needsYou: false) == .offline)
    #expect(
      ApplicationServices.botAvatarState(
        lifecycle: nil, hasRuntimeIdentity: true, needsYou: false) == .offline)
    #expect(
      ApplicationServices.botAvatarState(
        lifecycle: nil, hasRuntimeIdentity: false, needsYou: false) == .idle)
  }
}
