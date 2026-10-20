import OttoVoice
import SwiftUI

struct VoiceSettingsView: View {
  @ObservedObject var voice: VoiceController
  @State private var apiKey = ""
  @State private var saved = false
  @State private var configurationEngine = VoiceEngine.xai
  @State private var qualificationLabel = WakeWordQualificationLabel.positive
  @State private var qualificationSpeakerID = ""
  @State private var relaySpeakerID = ""
  @State private var relayTargetName = "Chase"
  @State private var relayExpectedTranscript = "Tell Chase verbatim don't paraphrase me"
  @State private var relayExpectedPayload = "don't paraphrase me"

  var body: some View {
    Form {
      Section("Voice engine") {
        Picker("Run voice on", selection: $voice.engine) {
          if voice.availableVoiceEngines.isEmpty {
            Text("No configured providers").tag(voice.engine)
          } else {
            ForEach(voice.availableVoiceEngines) { engine in
              Text(engine.displayName).tag(engine)
            }
          }
        }
        .pickerStyle(.menu)
        .disabled(voice.availableVoiceEngines.isEmpty)
        selectedEngineStatus

        Divider()

        Picker("Configure provider", selection: $configurationEngine) {
          ForEach(VoiceEngine.allCases) { engine in
            Text(engine.displayName).tag(engine)
          }
        }
        .pickerStyle(.segmented)
        Text("Only providers with a stored key appear in “Run voice on”.")
          .font(.caption)
          .foregroundStyle(.secondary)
        SecureField("\(configurationEngine.displayName) API key", text: $apiKey)
          .textFieldStyle(.roundedBorder)
        HStack {
          Button("Save in Keychain") {
            Task {
              await voice.saveAPIKey(apiKey, for: configurationEngine)
              saved = voice.credentialError == nil
              if saved { apiKey = "" }
            }
          }
          .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button("Remove key", role: .destructive) {
            Task {
              await voice.saveAPIKey("", for: configurationEngine)
              apiKey = ""
              saved = false
            }
          }
          .disabled(!voice.hasAPIKey(for: configurationEngine))
          Spacer()
          Label(
            voice.hasAPIKey(for: configurationEngine) ? "Key stored" : "No key stored",
            systemImage: voice.hasAPIKey(for: configurationEngine)
              ? "checkmark.shield.fill" : "key.slash"
          )
          .foregroundStyle(voice.hasAPIKey(for: configurationEngine) ? .green : .secondary)
        }
        if saved {
          Text("Saved securely. Otto does not display stored credentials.")
            .foregroundStyle(.secondary)
        }
        if let error = voice.credentialError {
          Text(error).foregroundStyle(.red)
        }
      }

      Section("Voice modes") {
        Picker("Operating mode", selection: $voice.operatingMode) {
          ForEach(VoiceOperatingMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        Text(voice.operatingMode.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
        Divider()
        ForEach(VoiceInteractionMode.allCases) { mode in
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
              Text(mode.displayName)
              Text(mode.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(voice.shortcut(for: mode).label)
              .font(.system(.body, design: .monospaced).weight(.semibold))
          }
        }
        Text("Command and Dictate stay on this Mac. Change their shortcuts in Shortcuts settings.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Spoken agent updates") {
        Toggle("Announce completions", isOn: $voice.announceCompletions)
        Toggle("Announce failures", isOn: $voice.announceFailures)
        Toggle("Announce requests for input", isOn: $voice.announceWaiting)
        Text(
          "Output Only keeps the microphone off and speaks compact summaries of the selected updates. Push to Talk can announce the same updates while waiting for the shortcut."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Live delegation") {
        LabeledContent("Conversation") {
          Text(voice.engine == .openai ? "GPT Realtime 2.1" : "xAI Grok Voice")
        }
        LabeledContent("Multi-task reasoning") {
          Text("GPT-5.6")
        }
        HStack {
          Label(
            voice.hasAPIKey(for: .openai) ? "Ready" : "OpenAI key required",
            systemImage: voice.hasAPIKey(for: .openai)
              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
          )
          .foregroundStyle(voice.hasAPIKey(for: .openai) ? .green : .orange)
          Spacer()
          Text("Up to 6 parallel tasks")
            .foregroundStyle(.secondary)
        }
        Text(
          "Otto keeps the live voice connection responsive while GPT-5.6 splits compound requests and starts independent local workers. Results return through spoken agent updates."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Local speech recognition") {
        Picker("Command and Dictate engine", selection: $voice.localSpeechEngine) {
          ForEach(LocalSpeechEngine.allCases) { engine in
            Text(engine.displayName).tag(engine)
          }
        }
        .pickerStyle(.menu)
        Text(voice.localSpeechEngineDetail)
          .foregroundStyle(
            voice.localSpeechEngine == .parakeet && !voice.isParakeetInstalled
              ? .orange : .secondary
          )
        if voice.localSpeechEngine == .parakeet {
          HStack {
            Label(
              voice.parakeetInstallationState.detail,
              systemImage: voice.isParakeetInstalled
                ? "checkmark.circle.fill" : "externaldrive.badge.exclamationmark"
            )
            .foregroundStyle(voice.isParakeetInstalled ? .green : .orange)
            Spacer()
            if !voice.isParakeetInstalled {
              Button("Install Parakeet…") {
                Task { await voice.installParakeet() }
              }
              .disabled(voice.parakeetInstallationState.isBusy)
            }
          }
          if case .failed(let message) = voice.parakeetInstallationState {
            Text(message).foregroundStyle(.red)
          }
          if voice.isParakeetInstalled {
            Text(voice.parakeetWarmState.detail)
              .font(.caption)
              .foregroundStyle(
                voice.parakeetWarmState == .ready ? .green : .secondary
              )
          }
        }
        Text(
          "Parakeet runs entirely on this Mac. Its model and runtime require roughly 700 MB of disk space and about 1 GB of memory while loaded."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Wake word") {
        Toggle(
          "Wake Otto with “\(AcousticWakeWordConfiguration.defaultPhrase)”",
          isOn: $voice.wakeWordEnabled
        )
        .disabled(!voice.wakeWordIsReady && !voice.wakeWordEnabled)
        Text(voice.wakeWordReadinessDetail)
          .foregroundStyle(voice.wakeWordIsReady ? Color.secondary : Color.orange)
        Text(
          "This is an opt-in acoustic detector: audio stays on this Mac and is not matched from a transcript. While enabled and Otto is asleep, the microphone remains continuously active, macOS shows its orange microphone indicator, and battery use increases slightly."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Text("Say “go to sleep” to stop the cloud voice session and return to wake-word listening.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Wake-word qualification") {
        Picker("Sample", selection: $qualificationLabel) {
          Text("“\(AcousticWakeWordConfiguration.defaultPhrase)” positive").tag(
            WakeWordQualificationLabel.positive)
          Text("Negative / ambient").tag(WakeWordQualificationLabel.negative)
        }
        .pickerStyle(.segmented)
        TextField("Anonymous speaker ID", text: $qualificationSpeakerID)
          .textFieldStyle(.roundedBorder)
          .disabled(voice.wakeQualificationRecordingState.isRecording)
        Text(
          qualificationLabel == .positive
            ? "Use the same anonymous ID for one person. Record natural “\(AcousticWakeWordConfiguration.defaultPhrase)” samples from at least five people."
            : "Record confusing phrases, ordinary conversation, room noise, and long ambient sessions without saying “\(AcousticWakeWordConfiguration.defaultPhrase)”."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        HStack {
          Button {
            Task {
              if voice.wakeQualificationRecordingState.isRecording {
                await voice.stopWakeQualificationRecording()
              } else {
                await voice.startWakeQualificationRecording(
                  label: qualificationLabel,
                  speakerID: qualificationSpeakerID
                )
              }
            }
          } label: {
            Label(
              voice.wakeQualificationRecordingState.isRecording ? "Stop and save" : "Record sample",
              systemImage: voice.wakeQualificationRecordingState.isRecording
                ? "stop.circle.fill" : "record.circle"
            )
          }
          .disabled(
            (voice.isMicrophoneActive && !voice.wakeQualificationRecordingState.isRecording)
              || (qualificationLabel == .positive
                && qualificationSpeakerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          )
          if voice.wakeQualificationRecordingState.isRecording {
            Button("Cancel", role: .cancel) {
              Task { await voice.cancelWakeQualificationRecording() }
            }
          }
          Spacer()
          Text(
            "\(voice.wakeQualificationPositiveSamples) positive · \(voice.wakeQualificationNegativeSamples) negative · \(voice.wakeQualificationSpeakerCount) speakers"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        Text(voice.wakeQualificationRecordingState.detail)
          .foregroundStyle(
            voice.wakeQualificationRecordingState.isFailure ? Color.red : Color.secondary)
        Text(
          "Release requires at least 100 positive samples across five held-out speakers, 10 hours of negative audio, ≥90% recall, and ≤0.1 false activations/hour."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Text(
          "Record only with each speaker’s consent. Samples stay on this Mac in Otto’s Application Support folder and are not uploaded by the app."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Exact-relay qualification") {
        TextField("Anonymous speaker ID", text: $relaySpeakerID)
          .textFieldStyle(.roundedBorder)
          .disabled(voice.relayQualificationRecordingState.isRecording)
        TextField("Target agent name", text: $relayTargetName)
          .textFieldStyle(.roundedBorder)
          .disabled(voice.relayQualificationRecordingState.isRecording)
        TextField("Full command to speak", text: $relayExpectedTranscript, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(2...4)
          .disabled(voice.relayQualificationRecordingState.isRecording)
        TextField("Expected delivered payload", text: $relayExpectedPayload, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(2...4)
          .disabled(voice.relayQualificationRecordingState.isRecording)
        HStack {
          Button {
            Task {
              if voice.relayQualificationRecordingState.isRecording {
                await voice.stopRelayQualificationRecording()
              } else {
                await voice.startRelayQualificationRecording(
                  speakerID: relaySpeakerID,
                  targetName: relayTargetName,
                  expectedTranscript: relayExpectedTranscript,
                  expectedPayload: relayExpectedPayload
                )
              }
            }
          } label: {
            Label(
              voice.relayQualificationRecordingState.isRecording
                ? "Stop and save" : "Record relay",
              systemImage: voice.relayQualificationRecordingState.isRecording
                ? "stop.circle.fill" : "record.circle"
            )
          }
          .disabled(
            (voice.isMicrophoneActive && !voice.relayQualificationRecordingState.isRecording)
              || [relaySpeakerID, relayTargetName, relayExpectedTranscript, relayExpectedPayload]
                .contains(where: {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
          )
          if voice.relayQualificationRecordingState.isRecording {
            Button("Cancel", role: .cancel) {
              Task { await voice.cancelRelayQualificationRecording() }
            }
          }
          Spacer()
          Text(
            "\(voice.relayQualificationCaseCount) cases · \(voice.relayQualificationSpeakerCount) speakers"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        Text(voice.relayQualificationRecordingState.detail)
          .foregroundStyle(
            voice.relayQualificationRecordingState.isFailure ? Color.red : Color.secondary)
        Text(
          "Record at least 100 varied relays from five consenting held-out speakers. Qualification requires ≥99% correct routing, ≥99% exact spoken-word payloads, and ≤1 s p95 warm latency. Audio stays on this Mac."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Selected microphone") {
        if let diagnostic = voice.currentInputDiagnostic {
          Label(
            diagnostic.actionableDetail,
            systemImage: diagnostic.quality == .good ? "waveform" : "exclamationmark.waveform"
          )
          Text(
            "\(Int(diagnostic.sampleRate)) Hz · \(diagnostic.channelCount) channel\(diagnostic.channelCount == 1 ? "" : "s") · RMS \(diagnostic.rootMeanSquare, format: .number.precision(.fractionLength(4)))"
          )
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        } else {
          Text("Start Local Command or Dictate to inspect the selected input and live signal.")
            .foregroundStyle(.secondary)
        }
      }

      if !voice.availableVoices.isEmpty {
        Section("Voice") {
          Picker("Voice", selection: $voice.selectedVoiceID) {
            ForEach(voice.availableVoices) { option in
              Text(option.recommended ? "\(option.name) · Recommended" : option.name)
                .tag(option.id)
            }
          }
          .pickerStyle(.menu)

          HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
              Text(voice.selectedVoice?.summary ?? "Provider voice")
                .foregroundStyle(.secondary)
              if voice.isMicrophoneActive {
                Text("This voice will be used the next time Otto wakes.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Spacer()
            Button {
              Task {
                if voice.previewState == .idle {
                  await voice.playVoicePreview()
                } else {
                  await voice.stopVoicePreview()
                }
              }
            } label: {
              switch voice.previewState {
              case .idle:
                Label("Listen", systemImage: "play.fill")
              case .connecting:
                Label("Connecting…", systemImage: "ellipsis")
              case .playing:
                Label("Stop", systemImage: "stop.fill")
              }
            }
            .disabled(!voice.hasAPIKey || voice.isMicrophoneActive)
          }

          if let error = voice.previewError {
            Text(error).foregroundStyle(.red)
          }
          Text(
            "Listen uses a short provider preview. It does not turn on the microphone or expose any Otto tools."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      Section("Microphone privacy") {
        Text(voice.engine.privacySummary)
          .foregroundStyle(.secondary)
        Text("Voice is off by default. Otto stops capture when voice sleeps or the app exits.")
          .foregroundStyle(.secondary)
        Label("The microphone state remains visible in the bottom command bar.", systemImage: "mic")
        Text(
          "Local Command and Dictate require an on-device recognizer. Otto fails closed rather than allowing Apple Speech to use a server. Talk mode is the only mode that sends microphone audio to the selected cloud provider."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
    .frame(width: 600, height: 740)
    .task {
      configurationEngine = voice.engine
      await voice.refreshCredentialStatus()
    }
    .onChange(of: configurationEngine) { _, _ in
      apiKey = ""
      saved = false
    }
    .onDisappear {
      Task {
        await voice.stopVoicePreview()
        await voice.cancelWakeQualificationRecording()
        await voice.cancelRelayQualificationRecording()
      }
    }
  }

  private var selectedEngineStatus: some View {
    HStack(spacing: 10) {
      Image(systemName: "waveform.circle.fill")
        .font(.title2)
        .foregroundStyle(.blue)
      VStack(alignment: .leading, spacing: 2) {
        Text("Voice will run on")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(voice.engine.displayName)
          .font(.body.weight(.semibold))
        Text(voice.engine.modelName)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
        Text(selectedEngineDetail)
          .font(.caption)
          .foregroundStyle(selectedEngineDetailColor)
      }
      Spacer(minLength: 12)
      Text(selectedEngineBadge)
        .font(.caption.weight(.semibold))
        .foregroundStyle(selectedEngineBadgeColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(selectedEngineBadgeColor.opacity(0.14), in: Capsule())
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }

  private var selectedEngineBadge: String {
    if voice.selectedEngineIsRunning { return "In use" }
    return voice.hasAPIKey ? "Ready" : "Key required"
  }

  private var selectedEngineBadgeColor: Color {
    if voice.selectedEngineIsRunning || voice.hasAPIKey { return .green }
    return .orange
  }

  private var selectedEngineDetail: String {
    if voice.selectedEngineIsRunning {
      return "Talk to Otto is connected with this engine."
    }
    if voice.hasAPIKey {
      return "Ready when Talk to Otto starts."
    }
    return "Selected, but an API key is required before Talk to Otto can connect."
  }

  private var selectedEngineDetailColor: Color {
    voice.hasAPIKey || voice.selectedEngineIsRunning ? .secondary : .orange
  }
}
