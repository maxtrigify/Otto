import OttoModels
import OttoRuntime
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
  @State private var showingWhistleTerms = false
  @ObservedObject private var modelCatalog = ProviderModelCatalogStore.shared

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
        .modifier(LocalVoiceDownloadPrompt(voice: voice))
        selectedEngineStatus
        if voice.engine == .openaiLive {
          Text(
            "GPT-Live does the talking and \(VoiceController.thinkingName(voice.thinkingProvider)) does the work, on your own sign-in. OpenAI bills about 5 cents for each minute a conversation is open, so Otto opens one when you hold the Talk key and closes it after 45 seconds of quiet. It uses your OpenAI key."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Divider()

        Picker("Configure provider", selection: $configurationEngine) {
          // GPT-Live uses the same OpenAI key as GPT Realtime, so it has no key of its own to set.
          ForEach(VoiceEngine.allCases.filter { $0.requiresKey && $0 != .openaiLive }) { engine in
            Text(engine.displayName).tag(engine)
          }
        }
        .pickerStyle(.segmented)
        Text(
          "“On this Mac” needs no key. A cloud provider appears in “Run voice on” once its key is stored."
        )
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

      Section("Microphone and speaker") {
        Picker("Listen through", selection: $voice.inputDeviceUID) {
          Text(systemDefaultMicrophoneLabel).tag("")
          ForEach(voice.inputDevices) { device in
            Text(device.name).tag(device.id)
          }
        }
        .pickerStyle(.menu)
        HStack(spacing: 12) {
          Button("Test microphone") { Task { await voice.testMicrophone() } }
            .disabled(microphoneIsBeingTested)
          if case .listening(let level) = voice.microphoneTest {
            ProgressView(value: min(1, level * 8))
              .frame(maxWidth: 180)
            Text("Say something…").foregroundStyle(.secondary)
          } else {
            microphoneTestResult
          }
        }
        LabeledContent("Speaks through") {
          HStack(spacing: 10) {
            Text(voice.outputDeviceName)
            Button(voice.speakerTestIsPlaying ? "Playing…" : "Test speaker") {
              Task { await voice.testSpeaker() }
            }
            .disabled(voice.speakerTestIsPlaying)
          }
        }
        Text(
          "Otto speaks through your Mac's sound output. Change it in System Settings › Sound › Output."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if voice.microphoneDiffersFromSystem {
          HStack(alignment: .top) {
            Text(
              "macOS only cancels echo on its own default microphone. With a different one Otto still hears you, but it waits until it has finished speaking, so you cannot talk over it."
            )
            .font(.caption)
            .foregroundStyle(.orange)
            Spacer(minLength: 12)
            Button("Use for the whole Mac") {
              Task { await voice.makeChosenMicrophoneSystemDefault() }
            }
          }
        }
        Text(
          "This choice is for Otto only and leaves the rest of your Mac as it is. A MacBook's built-in microphone switches off when the lid is closed."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .task {
        // Devices are plugged in and switched while this is open, so keep the names current.
        while !Task.isCancelled {
          voice.refreshInputDevices()
          try? await Task.sleep(for: .seconds(2))
        }
      }

      if !voice.engine.requiresKey {
        Section("Set up voice on this Mac") {
          localSetupRow(
            title: "Hearing",
            detail: "Parakeet, open-source speech recognition by Nvidia. About 490 MB.",
            ready: voice.isParakeetInstalled,
            status: voice.isParakeetInstalled ? "Installed" : voice.parakeetInstallationState.detail
          ) {
            if !voice.isParakeetInstalled {
              Button("Install…") { Task { await voice.installParakeet() } }
                .disabled(voice.parakeetInstallationState.isBusy)
            }
          }
          localSetupRow(
            title: "Sharper hearing",
            detail:
              "Parakeet Ultra, a more accurate open-source model that also listens for the names of your harnesses, models, bots and projects. Optional. About 800 MB, kept on this Mac.",
            ready: voice.sharperHearingState == .ready,
            status: sharperHearingStatusText
          ) {
            if voice.sharperHearingState == .notDownloaded {
              Button("Download…") { Task { await voice.downloadSharperHearing() } }
            } else if case .failed = voice.sharperHearingState {
              Button("Try again") { Task { await voice.downloadSharperHearing() } }
            }
          }
          localSetupRow(
            title: "Thinking",
            detail:
              "Whichever harness you already use, on your own sign-in, so there is no extra bill. Claude Code answers fastest because Otto keeps it open between requests.",
            ready: voice.thinkingIsAvailable,
            status: voice.thinkingIsAvailable
              ? "Ready" : "\(VoiceController.thinkingName(voice.thinkingProvider)) is not installed"
          ) { EmptyView() }
          Picker("Think with", selection: $voice.thinkingProvider) {
            ForEach(HarnessVoiceBrain.providers, id: \.self) { provider in
              Text(
                voice.installedThinkingProviders.contains(provider)
                  ? VoiceController.thinkingName(provider)
                  : "\(VoiceController.thinkingName(provider)) · not installed"
              )
              .tag(provider)
            }
          }
          .pickerStyle(.menu)
          Picker("Model", selection: $voice.thinkingModel) {
            Text(
              voice.thinkingProvider == .claudeCode ? "Fastest (Haiku)" : "The harness's default"
            )
            .tag("")
            ForEach(thinkingModels, id: \.id) { model in
              Text(model.displayName).tag(model.id)
            }
          }
          .pickerStyle(.menu)
          .onChange(of: voice.thinkingProvider, initial: true) { _, provider in
            modelCatalog.load(provider)
          }
          Text("A change takes effect the next time Talk to Otto starts.")
            .font(.caption)
            .foregroundStyle(.secondary)
          localSetupRow(
            title: "Speaking",
            detail:
              "Kokoro, an open-source voice (Apache 2.0), with a small model that recognises your voice. About 450 MB, downloaded once and kept on this Mac. Until then Otto speaks with the built-in macOS voice.",
            ready: voice.kokoroState == .ready,
            status: kokoroStatusText
          ) {
            if voice.kokoroState == .notDownloaded {
              Button("Download…") { Task { await voice.downloadLocalVoiceModels() } }
            } else if case .failed = voice.kokoroState {
              Button("Try again") { Task { await voice.downloadLocalVoiceModels() } }
            }
          }
          Text(
            "Nothing you say is sent anywhere as audio. Only the words reach your Claude Code account."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .task { await voice.refreshThinkingProviders() }
        .task {
          // Downloads and learning progress while this is on screen, so keep it current.
          while !Task.isCancelled {
            await voice.refreshVoiceprintStatus()
            try? await Task.sleep(for: .seconds(1))
          }
        }

        Section("Your voice") {
          Toggle("Only respond to my voice", isOn: $voice.onlyMyVoice)
          LabeledContent("Status") { Text(voiceprintStatusText) }
          if case .listening(let secondsLeft) = voice.voiceLearningState {
            VStack(alignment: .leading, spacing: 6) {
              Text("Read this aloud (\(secondsLeft)s)")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text("“\(VoiceController.voiceLearningLine)”")
                .font(.title3)
            }
            .padding(.vertical, 4)
          } else {
            HStack {
              Button(voice.voiceprintStatus == .ready ? "Learn my voice again" : "Learn my voice") {
                Task { await voice.learnMyVoice() }
              }
              .disabled(voice.kokoroState != .ready || voice.voiceLearningState == .working)
              if voice.voiceprintStatus != .unavailable,
                voice.voiceprintStatus != .learning(heard: 0, needed: Voiceprint.sentencesNeeded)
              {
                Button("Forget my voice", role: .destructive) {
                  Task { await voice.forgetVoiceprint() }
                }
              }
            }
            if case .failed(let message) = voice.voiceLearningState {
              Text(message).foregroundStyle(.red)
            } else if voice.kokoroState != .ready {
              Text("Download the voice models above first.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Text(
            "Press “Learn my voice” and read one sentence for ten seconds. After that Otto ignores other voices while it is listening continuously. It keeps a short list of numbers, not a recording, and it never leaves this Mac. Anything you say with the Talk key held is always heard."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
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

      if voice.engine.requiresKey {
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
        if voice.localSpeechEngine == .whistle {
          whistleStatus
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
    .sheet(isPresented: $showingWhistleTerms) {
      WhistleTermsSheet(
        alreadyAccepted: voice.whistleTermsAccepted,
        onAgree: {
          voice.acceptWhistleTerms()
          showingWhistleTerms = false
          Task { await voice.installWhistle() }
        },
        onCancel: { showingWhistleTerms = false })
    }
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

  /// The chosen harness's models, with a saved choice kept even while the list is loading.
  private var thinkingModels: [AgentModel] {
    var models = modelCatalog.catalog(for: voice.thinkingProvider) ?? []
    if !voice.thinkingModel.isEmpty, !models.contains(where: { $0.id == voice.thinkingModel }) {
      models.append(AgentModel(id: voice.thinkingModel, displayName: voice.thinkingModel))
    }
    return models
  }

  private var systemDefaultMicrophoneLabel: String {
    let name = voice.inputDevices.first(where: \.isSystemDefault)?.name
    return name.map { "System default (\($0))" } ?? "System default"
  }

  private var microphoneIsBeingTested: Bool {
    if case .listening = voice.microphoneTest { return true }
    return false
  }

  @ViewBuilder private var microphoneTestResult: some View {
    switch voice.microphoneTest {
    case .heard:
      Label("Heard you clearly", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    case .faint:
      Label(
        "Very quiet. Move closer or raise the input level.",
        systemImage: "exclamationmark.triangle.fill"
      )
      .foregroundStyle(.orange)
    case .silent:
      Label("Nothing heard. Choose another microphone.", systemImage: "mic.slash.fill")
        .foregroundStyle(.red)
    case .failed(let message):
      Text(message).foregroundStyle(.red)
    case .idle, .listening:
      EmptyView()
    }
  }

  private var voiceprintStatusText: String {
    if voice.voiceLearningState == .working { return "Learning…" }
    switch voice.voiceprintStatus {
    case .unavailable: return "Not learned yet"
    case .learning(let heard, let needed):
      return heard == 0 ? "Not learned yet" : "Learning your voice (\(heard) of \(needed))"
    case .ready: return "Knows your voice"
    }
  }

  private var kokoroStatusText: String {
    switch voice.kokoroState {
    case .notDownloaded: "Not downloaded"
    case .downloading: "Getting ready…"
    case .ready: "Ready"
    case .failed(let message): message
    }
  }

  private var sharperHearingStatusText: String {
    switch voice.sharperHearingState {
    case .notDownloaded: "Not downloaded"
    case .downloading: "Downloading and preparing. Voice keeps working meanwhile."
    case .ready: "Installed"
    case .failed(let message): "Could not download: \(message)"
    }
  }

  private func localSetupRow(
    title: String, detail: String, ready: Bool, status: String,
    @ViewBuilder action: () -> some View
  ) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
        .foregroundStyle(ready ? .green : .orange)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.body.weight(.semibold))
        Text(detail).font(.caption).foregroundStyle(.secondary)
        Text(status).font(.caption).foregroundStyle(ready ? .green : .orange)
      }
      Spacer(minLength: 12)
      action()
    }
    .padding(.vertical, 2)
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
        Text(voice.engine.requiresKey ? voice.engine.modelName : voice.localVoiceSummary)
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
    if !voice.engine.requiresKey { return voice.localVoiceIsSetUp ? "Ready" : "Setup needed" }
    return voice.hasAPIKey ? "Ready" : "Key required"
  }

  private var selectedEngineBadgeColor: Color {
    if !voice.engine.requiresKey, !voice.selectedEngineIsRunning {
      return voice.localVoiceIsSetUp ? .green : .orange
    }
    if voice.selectedEngineIsRunning || voice.hasAPIKey { return .green }
    return .orange
  }

  private var selectedEngineDetail: String {
    if voice.selectedEngineIsRunning {
      return "Talk to Otto is connected with this engine."
    }
    if !voice.engine.requiresKey {
      return voice.localVoiceIsSetUp
        ? "No API key needed. Everything except the thinking runs on this Mac."
        : "No API key needed. Finish the setup below before Talk to Otto can start."
    }
    if voice.hasAPIKey {
      return "Ready when Talk to Otto starts."
    }
    return "Selected, but an API key is required before Talk to Otto can connect."
  }

  @ViewBuilder private var whistleStatus: some View {
    HStack {
      Label(
        voice.whistleInstallationState.detail,
        systemImage: voice.isWhistleInstalled
          ? "checkmark.circle.fill" : "externaldrive.badge.exclamationmark"
      )
      .foregroundStyle(voice.isWhistleInstalled ? .green : .orange)
      Spacer()
      if voice.isWhistleInstalled {
        Button("Remove", role: .destructive) { Task { await voice.removeWhistle() } }
          .disabled(voice.whistleInstallationState.isBusy)
      } else {
        // Downloading always goes through the terms sheet first.
        Button("Download Whistle…") { showingWhistleTerms = true }
          .disabled(voice.whistleInstallationState.isBusy)
      }
    }
    if case .failed(let message) = voice.whistleInstallationState {
      Text(message).foregroundStyle(.red)
    }
    Text(
      "Whistle by \(WhistleTerms.author), \(WhistleTerms.license). About \(WhistleTerms.downloadSize) on disk; audio stays on this Mac."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var selectedEngineDetailColor: Color {
    voice.hasAPIKey || voice.selectedEngineIsRunning ? .secondary : .orange
  }
}

/// Shown before Otto downloads Whistle: who made it, what is downloaded from where, and the
/// license the person agrees to. Nothing downloads until they tick the agreement.
private struct WhistleTermsSheet: View {
  let alreadyAccepted: Bool
  let onAgree: () -> Void
  let onCancel: () -> Void
  @State private var agreed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Download Whistle").font(.title2.weight(.semibold))
      Text(
        "Whistle is an open-source speech-to-text model made by \(WhistleTerms.author). Otto downloads two files from the authors' own Hugging Face repositories and checks each one against a pinned checksum:"
      )
      .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 6) {
        Label("Whistle model, 17 MB", systemImage: "waveform")
        Label("needle engine for Apple silicon, 1.1 MB", systemImage: "cpu")
      }
      .font(.callout)
      Text(
        "Both are licensed by \(WhistleTerms.author) under the \(WhistleTerms.license). The license covers how you may use, change and share them, and gives them without warranty. Transcription runs on this Mac; Otto sends no audio anywhere."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 16) {
        Link("Read the license", destination: WhistleTerms.licenseURL)
        Link("Model page", destination: WhistleTerms.modelPage)
        Link("Engine page", destination: WhistleTerms.enginePage)
      }
      .font(.callout)
      Toggle(
        "I have read and agree to the \(WhistleTerms.license) terms set by \(WhistleTerms.author).",
        isOn: $agreed
      )
      .toggleStyle(.checkbox)
      .accessibilityIdentifier("whistle-terms-agree")
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onCancel)
        Button("Agree and download", action: onAgree)
          .keyboardShortcut(.defaultAction)
          .disabled(!agreed)
          .accessibilityIdentifier("whistle-terms-download")
      }
    }
    .padding(22)
    .frame(width: 480)
    .onAppear { agreed = alreadyAccepted }
  }
}

/// Asks about the downloads at the moment someone first chooses voice on this Mac, so they
/// know what is being fetched, how big it is and that it is open source, before any of it starts.
private struct LocalVoiceDownloadPrompt: ViewModifier {
  @ObservedObject var voice: VoiceController
  @State private var isPresented = false

  func body(content: Content) -> some View {
    content
      .onChange(of: voice.engine) { _, engine in
        if !engine.requiresKey, voice.localVoiceNeedsDownloads { isPresented = true }
      }
      .sheet(isPresented: $isPresented) {
        VStack(alignment: .leading, spacing: 14) {
          Text("Download the voice models?").font(.title2.weight(.semibold))
          Text(
            "Voice on this Mac runs on open-source models that Otto downloads once and keeps on this Mac. Nothing you say is sent anywhere as audio."
          )
          .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 8) {
            if !voice.isParakeetInstalled {
              Label(
                "Parakeet, speech recognition by Nvidia · about 490 MB",
                systemImage: "ear")
            }
            if voice.kokoroNeedsDownload {
              Label(
                "Kokoro, the voice Otto speaks with (Apache 2.0) · about 430 MB",
                systemImage: "waveform")
              Label(
                "A small model that recognises your voice · about 15 MB",
                systemImage: "person.wave.2")
            }
          }
          Text(
            "If you skip this, Otto speaks with the built-in macOS voice, and you can download the models later in Voice settings."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          HStack {
            Spacer()
            Button("Not now") { isPresented = false }
              .keyboardShortcut(.cancelAction)
            Button("Download") {
              isPresented = false
              Task {
                if !voice.isParakeetInstalled { await voice.installParakeet() }
                await voice.downloadLocalVoiceModels()
              }
            }
            .keyboardShortcut(.defaultAction)
          }
        }
        .padding(24)
        .frame(width: 460)
      }
  }
}
