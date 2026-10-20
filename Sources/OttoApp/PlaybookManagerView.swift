import OttoModels
import OttoServices
import SwiftUI

struct PlaybookManagerView: View {
  @Environment(\.ottoPalette) private var palette
  @ObservedObject var services: ApplicationServices
  let profileID: UUID

  @State private var records: [Playbook] = []
  @State private var selectedID: UUID?
  @State private var name = ""
  @State private var steps: [PlaybookStep] = []
  @State private var intervalHours = 24
  @State private var permissions = ""
  @State private var overlap: ConcurrencyPolicy = .skip
  @State private var preview: PlaybookRoutinePreview?
  @State private var notice: String?
  @State private var voiceID = ""
  @State private var autoSpeak: BotAutoSpeakPolicy = .off

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HSplitView {
        roster.frame(minWidth: 190, idealWidth: 220, maxWidth: 260)
        editor.frame(minWidth: 430)
      }
      .frame(minWidth: 640)
      VStack(spacing: 0) {
        roster.frame(height: 150)
        editor
      }
    }
    .background(palette.paneSurface)
    .task {
      await reload()
      await loadVoice()
    }
    .onChange(of: name) { _, _ in preview = nil }
    .onChange(of: steps) { _, _ in preview = nil }
    .onChange(of: intervalHours) { _, _ in preview = nil }
    .onChange(of: permissions) { _, _ in preview = nil }
    .onChange(of: overlap) { _, _ in preview = nil }
  }

  private var roster: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("PLAYBOOKS").font(.ottoMono(8, weight: .black)).tracking(1.4)
          Text("Save steps. Reuse in routines.").font(.ottoDisplay(11)).foregroundStyle(
            palette.muted)
        }
        Spacer()
        Button {
          beginNew()
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.borderless).help("New playbook")
      }
      .padding(14)
      Divider().overlay(palette.paper.opacity(0.08))
      ScrollView {
        LazyVStack(spacing: 6) {
          ForEach(records) { record in
            Button {
              select(record)
            } label: {
              HStack(spacing: 9) {
                Image(systemName: stateSymbol(record.state))
                  .foregroundStyle(stateColor(record.state)).frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                  Text(record.name).font(.ottoDisplay(13).weight(.semibold)).lineLimit(1)
                  Text(record.state == .tested ? "VALIDATED" : record.state.rawValue.uppercased())
                    .font(.ottoMono(6.5, weight: .black)).tracking(1)
                    .foregroundStyle(palette.muted)
                }
                Spacer()
              }
              .foregroundStyle(palette.paper).padding(10)
              .background(
                selectedID == record.id ? palette.raised : palette.raised.opacity(0.28),
                in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
          }
        }.padding(8)
      }
    }
    .background(palette.ink.opacity(0.28))
  }

  private var editor: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        identityStrip
        section(
          "TASK STEPS",
          "Validation checks these fields only. Use a routine test run to verify real execution.")
        TextField("Playbook name", text: $name).textFieldStyle(.roundedBorder)
        ForEach($steps) { $step in stepEditor(step: $step) }
        Button {
          addStep()
        } label: {
          Label("Add step", systemImage: "plus.circle")
        }
        .buttonStyle(.borderless).foregroundStyle(palette.cyan)

        VStack(alignment: .leading, spacing: 8) {
          Button("Save draft") { Task { _ = await saveDraft() } }
          Button("Validate steps") { Task { await testDraft() } }
            .buttonStyle(.borderedProminent).tint(palette.signal)
          Button("Save validated playbook") { Task { await saveTested() } }
            .disabled(hasUnsavedChanges)
        }

        section("ROUTINE PREVIEW", "Nothing is enabled until you review and add it.")
        Stepper(
          "Every \(intervalHours) hour\(intervalHours == 1 ? "" : "s")", value: $intervalHours,
          in: 1...720)
        TextField("Allowed tools, comma separated", text: $permissions).textFieldStyle(
          .roundedBorder)
        Picker("Overlap", selection: $overlap) {
          Text("Skip while busy").tag(ConcurrencyPolicy.skip)
          Text("Queue latest").tag(ConcurrencyPolicy.queueLatest)
        }
        Button("Preview routine") { Task { await makePreview() } }
          .disabled(hasUnsavedChanges)
        if let preview { routineCard(preview) }

        if let notice {
          Text(notice).font(.ottoDisplay(11)).foregroundStyle(palette.cyan)
            .padding(10).background(
              palette.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
      }
      .padding(18)
    }
  }

  private var identityStrip: some View {
    VStack(alignment: .leading, spacing: 10) {
      section("VOICE", "Presentation only—the bot identity and runtime do not change.")
      VStack(alignment: .leading, spacing: 8) {
        TextField("System voice ID (optional)", text: $voiceID).textFieldStyle(.roundedBorder)
        Picker("Auto-speak", selection: $autoSpeak) {
          ForEach(BotAutoSpeakPolicy.allCases, id: \.self) { Text(autoSpeakTitle($0)).tag($0) }
        }.frame(width: 180)
        Button("Apply") { Task { await saveVoice() } }
      }
    }
  }

  private func stepEditor(step: Binding<PlaybookStep>) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("STEP").font(.ottoMono(7, weight: .black)).foregroundStyle(palette.signal)
        Spacer()
        Button(role: .destructive) {
          steps.removeAll { $0.id == step.wrappedValue.id }
        } label: {
          Image(systemName: "trash")
        }.buttonStyle(.borderless)
      }
      TextField("Instruction", text: step.instruction).textFieldStyle(.roundedBorder)
      VStack(alignment: .leading, spacing: 8) {
        TextField("Role, e.g. button", text: step.anchor.role).textFieldStyle(.roundedBorder)
        TextField("Accessible name", text: step.anchor.name).textFieldStyle(.roundedBorder)
      }
      TextField("Nearby text (optional)", text: optionalText(step.anchor.nearbyText))
        .textFieldStyle(.roundedBorder)
    }
    .padding(12).background(palette.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 11))
    .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.paper.opacity(0.08)))
  }

  private func routineCard(_ value: PlaybookRoutinePreview) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Label("READY, DISABLED", systemImage: "checkmark.shield")
        .font(.ottoMono(7, weight: .black)).foregroundStyle(palette.signal)
      Text(value.routine.trigger.summary).font(.ottoDisplay(13).weight(.semibold))
      Text("Disabled until enabled in Routines")
      Text("Inputs: \(value.inputs.isEmpty ? "None" : value.inputs.joined(separator: ", "))")
      Text(
        "Permissions: \(value.permissions.isEmpty ? "None" : value.permissions.joined(separator: ", "))"
      )
      Button("Add disabled routine") { addRoutine(value) }.buttonStyle(.borderedProminent).tint(
        palette.signal)
    }
    .font(.ottoDisplay(11)).foregroundStyle(palette.paper).padding(13)
    .background(palette.ink.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
  }

  private func section(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.ottoMono(8, weight: .black)).tracking(1.3).foregroundStyle(palette.signal)
      Text(subtitle).font(.ottoDisplay(11)).foregroundStyle(palette.muted)
    }
  }

  private func beginNew() {
    selectedID = nil
    name = ""
    steps = []
    preview = nil
    addStep()
  }
  private func addStep() {
    steps.append(PlaybookStep(instruction: "", anchor: SemanticAnchor(role: "", name: "")))
  }
  private func select(_ value: Playbook) {
    preview = nil
    selectedID = value.id
    name = value.name
    steps = value.steps
    preview = nil
  }

  @MainActor private func reload(select id: UUID? = nil) async {
    records = await services.playbooks.all().filter { $0.profileID == profileID }.sorted {
      $0.updatedAt > $1.updatedAt
    }
    if let id, let value = records.first(where: { $0.id == id }) {
      select(value)
    } else if selectedID == nil, let first = records.first {
      select(first)
    } else if records.isEmpty {
      beginNew()
    }
  }

  private var hasUnsavedChanges: Bool {
    guard let record = records.first(where: { $0.id == selectedID }) else { return true }
    return record.name != name || record.steps != steps
  }

  @MainActor private func saveDraft() async -> Bool {
    do {
      let value: Playbook
      if let selectedID {
        value = try await services.playbooks.update(id: selectedID, name: name, steps: steps)
      } else {
        value = try await services.playbooks.capture(
          name: name, profileID: profileID, demonstratedSteps: steps)
      }
      notice = "Draft saved. Editing invalidates any previous test."
      await reload(select: value.id)
      return true
    } catch {
      notice = error.localizedDescription
      return false
    }
  }

  @MainActor private func testDraft() async {
    guard await saveDraft(), let selectedID else { return }
    do {
      let value = try await services.playbooks.runSafeTest(id: selectedID)
      let evidence = value.lastTestEvidence
      notice =
        "Validated \(evidence?.validatedStepCount ?? 0) step(s). No actions were executed; test the routine to check real results."
      await reload(select: selectedID)
    } catch { notice = error.localizedDescription }
  }

  @MainActor private func saveTested() async {
    guard !hasUnsavedChanges, let selectedID else {
      notice = "Save and validate the current steps first."
      return
    }
    do {
      _ = try await services.playbooks.save(id: selectedID)
      notice = "Playbook saved."
      await reload(select: selectedID)
    } catch { notice = error.localizedDescription }
  }

  @MainActor private func makePreview() async {
    guard !hasUnsavedChanges, let selectedID else {
      notice = "Save a validated playbook first."
      return
    }
    do {
      preview = try await services.playbooks.routinePreview(
        id: selectedID, intervalSeconds: intervalHours * 3_600,
        permissions: permissions.split(separator: ",").map {
          $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty },
        overlap: overlap)
    } catch { notice = error.localizedDescription }
  }

  @MainActor private func loadVoice() async {
    let value = await services.botVoices.preference(profileID: profileID)
    voiceID = value.voiceID ?? ""
    autoSpeak = value.autoSpeak
  }
  @MainActor private func saveVoice() async {
    do {
      try await services.botVoices.set(
        BotVoicePreference(
          profileID: profileID, voiceID: voiceID.isEmpty ? nil : voiceID, autoSpeak: autoSpeak))
      notice = "Voice preference applied without revising the bot."
    } catch { notice = error.localizedDescription }
  }
  @MainActor private func addRoutine(_ value: PlaybookRoutinePreview) {
    do {
      _ = try services.routines.save(value.routine)
      notice = "Disabled routine added for final review."
    } catch { notice = error.localizedDescription }
  }

  private func optionalText(_ binding: Binding<String?>) -> Binding<String> {
    Binding(
      get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
  }
  private func stateSymbol(_ state: PlaybookState) -> String {
    state == .saved
      ? "checkmark.seal.fill" : state == .tested ? "checkmark.shield" : "pencil.and.outline"
  }
  private func stateColor(_ state: PlaybookState) -> Color {
    state == .saved ? palette.signal : state == .tested ? palette.cyan : palette.muted
  }
  private func autoSpeakTitle(_ policy: BotAutoSpeakPolicy) -> String {
    policy == .off
      ? "Off"
      : policy == .needsYou ? "Needs You" : policy == .completions ? "Completions" : "Everything"
  }
}
