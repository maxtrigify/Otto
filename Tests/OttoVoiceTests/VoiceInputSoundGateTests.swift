import Testing

@testable import OttoVoice

@Suite("Voice speech and music gate")
struct VoiceInputSoundGateTests {
  @Test("Music and singing do not open microphone upload")
  func rejectsMusicAndSinging() {
    var gate = VoiceInputSoundGate()
    gate.observe(.init(speech: 0.12, music: 0.82, singing: 0.04))
    gate.observe(.init(speech: 0.12, music: 0.82, singing: 0.04))
    #expect(!gate.isOpen)
    gate.observe(.init(speech: 0.28, music: 0.18, singing: 0.71))
    gate.observe(.init(speech: 0.28, music: 0.18, singing: 0.71))
    #expect(!gate.isOpen)
  }

  @Test("Confident speech opens even with quiet background music")
  func acceptsForegroundSpeech() {
    var gate = VoiceInputSoundGate()
    gate.observe(.init(speech: 0.74, music: 0.19, singing: 0.02))
    #expect(gate.isOpen)
  }

  @Test("Singing wins when it is stronger than the speech label")
  func rejectsVocalMusic() {
    var gate = VoiceInputSoundGate()
    gate.observe(.init(speech: 0.62, music: 0.45, singing: 0.68))
    gate.observe(.init(speech: 0.62, music: 0.45, singing: 0.68))
    #expect(!gate.isOpen)
  }

  @Test("Quiet and ambiguous audio opens instead of dropping the user")
  func acceptsAmbiguousSpeech() {
    var gate = VoiceInputSoundGate()
    gate.observe(.init(speech: 0.18, music: 0.20, singing: 0.08))
    #expect(gate.isOpen)
  }
}

@Suite("Voice microphone forwarding policy")
struct VoiceInputForwardingPolicyTests {
  @Test("Normal listening forwards audio even when Sound Analysis rejects it")
  func normalListeningDoesNotDependOnClassifier() {
    let decision = VoiceInputForwardingPolicy.decide(
      manualInputEnabled: true,
      playbackActive: false,
      interruptionReported: false,
      classifierAllowsSpeech: false
    )

    #expect(decision == .forward)
  }

  @Test("Sound Analysis only gates audio while Otto is speaking")
  func classifierOnlyProtectsPlayback() {
    #expect(
      VoiceInputForwardingPolicy.decide(
        manualInputEnabled: true,
        playbackActive: true,
        interruptionReported: false,
        classifierAllowsSpeech: false
      ) == .dropPlaybackLeakage
    )
    #expect(
      VoiceInputForwardingPolicy.decide(
        manualInputEnabled: true,
        playbackActive: true,
        interruptionReported: false,
        classifierAllowsSpeech: true
      ) == .bufferForBargeIn
    )
    #expect(
      VoiceInputForwardingPolicy.decide(
        manualInputEnabled: true,
        playbackActive: true,
        interruptionReported: true,
        classifierAllowsSpeech: false
      ) == .forward
    )
  }

  @Test("Push-to-talk privacy still emits silence while released")
  func disabledInputRemainsSilent() {
    #expect(
      VoiceInputForwardingPolicy.decide(
        manualInputEnabled: false,
        playbackActive: false,
        interruptionReported: false,
        classifierAllowsSpeech: true
      ) == .silence
    )
  }
}
