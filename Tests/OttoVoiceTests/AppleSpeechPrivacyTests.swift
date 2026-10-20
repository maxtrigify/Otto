import OttoVoice
import Testing

@Suite("Apple Speech privacy policy")
struct AppleSpeechPrivacyTests {
  @Test("Local recognition fails closed when an on-device model is unavailable")
  func rejectsServerFallback() throws {
    #expect(throws: AppleSpeechError.self) {
      try AppleSpeechPrivacyPolicy.requireOnDeviceRecognition(false)
    }
  }

  @Test("An available on-device recognizer is accepted")
  func acceptsOnDeviceRecognizer() throws {
    try AppleSpeechPrivacyPolicy.requireOnDeviceRecognition(true)
  }
}
