import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI

/// The workspace's durable agent roster. Profiles are reusable configuration; deleting one never
/// closes or rewrites an already-launched canvas session, which keeps its launch-time snapshot.
struct AgentManagerView: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var services: ApplicationServices
  @ObservedObject private var catalogStore = ProviderModelCatalogStore.shared

  let createAgent: () -> Void
  let openAgent: (AgentProfile, Bool) -> Void

  @State private var selectedID: UUID?
  @State private var draft: AgentProfile?
  @State private var pendingDeletion: AgentProfile?
  @State private var notice: Notice?

  private struct Notice {
    let message: String
    let isError: Bool
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(palette.paper.opacity(0.08))
      HSplitView {
        roster
          .frame(minWidth: 250, idealWidth: 280, maxWidth: 330)
        editor
          .frame(minWidth: 500, idealWidth: 590)
      }
    }
    .frame(minWidth: 820, minHeight: 590)
    .background(palette.surface)
    .onAppear {
      selectInitialProfile()
      if let provider = draft?.provider { catalogStore.load(provider, accountID: modelAccountID) }
    }
    .task(id: catalogStore.request(for: draft?.provider ?? .codex, accountID: modelAccountID)) {
      if let provider = draft?.provider {
        await catalogStore.load(provider, accountID: modelAccountID)?.value
      }
    }
    .onChange(of: services.agentProfileList) { _, profiles in
      reconcileSelection(with: profiles)
    }
    .confirmationDialog(
      "Delete \(pendingDeletion?.name ?? "agent")?",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete agent profile", role: .destructive) {
        if let profile = pendingDeletion { delete(profile) }
        pendingDeletion = nil
      }
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
    } message: {
      Text(
        "This removes the reusable profile. Existing canvas conversations remain available with "
          + "the profile revision they started with."
      )
    }
  }

  private var modelAccountID: UUID? {
    if let profile = draft,
      let nodeID = services.botChannels.canonicalChannel(for: profile.id)?.nodeID
    {
      return services.effectiveAccountID(nodeID: nodeID)
    }
    return draft?.accountID ?? services.providerAccounts.defaultAccountID
  }

  private var header: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("AGENT FLEET")
          .font(.ottoMono(10, weight: .black))
          .tracking(2)
          .foregroundStyle(palette.signal)
        Text("Shape the teammates you can summon anywhere in Otto.")
          .font(.ottoDisplay(15))
          .foregroundStyle(palette.paper)
      }
      Spacer()
      Button {
        createAgent()
      } label: {
        Label("New agent", systemImage: "person.crop.circle.badge.plus")
      }
      Button("Done") { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(18)
  }

  private var roster: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("SAVED TEAMMATES")
          .font(.ottoMono(8, weight: .black))
          .tracking(1.4)
          .foregroundStyle(palette.muted)
        Spacer()
        Text("\(services.agentProfileList.count)")
          .font(.ottoMono(8, weight: .bold))
          .foregroundStyle(palette.muted)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      if services.agentProfileList.isEmpty {
        ContentUnavailableView(
          "No custom agents",
          systemImage: "person.2.badge.plus",
          description: Text("Create a named teammate with its own system prompt and harness.")
        )
        .foregroundStyle(palette.muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(22)
      } else {
        ScrollView {
          OttoFluidHover(
            axis: .vertical,
            style: OttoFluidHoverStyle(fill: palette.paper.opacity(0.05), cornerRadius: 10)
          ) {
            LazyVStack(spacing: 6) {
              ForEach(services.agentProfileList) { profile in
                rosterRow(profile)
                  .ottoHoverItem(profile.id)
              }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
          }
        }
        .ottoScrollChrome()
      }
    }
    .background(palette.ink.opacity(0.3))
  }

  private func rosterRow(_ profile: AgentProfile) -> some View {
    let selected = selectedID == profile.id
    return Button {
      select(profile)
    } label: {
      HStack(spacing: 11) {
        ZStack {
          Circle()
            .fill(providerTint(profile.provider).opacity(selected ? 0.22 : 0.12))
          Image(systemName: providerSymbol(profile.provider))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(providerTint(profile.provider))
        }
        .frame(width: 34, height: 34)

        VStack(alignment: .leading, spacing: 3) {
          Text(profile.name)
            .font(.ottoDisplay(13).weight(.semibold))
            .foregroundStyle(palette.paper)
            .lineLimit(1)
          Text(rosterDetail(profile))
            .font(.ottoMono(7.5))
            .foregroundStyle(palette.muted)
            .lineLimit(1)
        }
        Spacer(minLength: 4)
        Text("R\(profile.revision)")
          .font(.ottoMono(6.5, weight: .black))
          .foregroundStyle(selected ? palette.signal : palette.muted)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 9)
      .background(
        selected ? palette.raised.opacity(0.95) : palette.raised.opacity(0.28),
        in: RoundedRectangle(cornerRadius: 10)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(selected ? palette.signal.opacity(0.38) : palette.paper.opacity(0.04))
      )
      .animation(OttoMotion.tint, value: selected)
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var editor: some View {
    if let currentDraft = draft {
      let profile = Binding(
        get: { draft ?? currentDraft },
        set: { draft = $0 }
      )
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          editorIdentity(profile: profile)
          Divider().overlay(palette.paper.opacity(0.08))
          editorInstructions(profile: profile)
          Divider().overlay(palette.paper.opacity(0.08))
          editorRuntime(profile: profile)
          Divider()
          BotSubagentsEditor(
            accounts: services.providerAccounts,
            helpers: Binding(
              get: { profile.wrappedValue.subagents ?? [] },
              set: { profile.wrappedValue.subagents = $0 }
            ))
          if let notice {
            Text(notice.message)
              .font(.ottoMono(9, weight: .medium))
              .foregroundStyle(notice.isError ? palette.red : palette.signal)
          }
          editorActions(profile: profile.wrappedValue)
        }
        .padding(22)
      }
    } else {
      ContentUnavailableView(
        "Select an agent",
        systemImage: "person.crop.circle.dashed",
        description: Text("Choose a teammate to inspect and edit its operating defaults.")
      )
      .foregroundStyle(palette.muted)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func editorIdentity(profile: Binding<AgentProfile>) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionHeading("IDENTITY", detail: "How this teammate appears across Otto")
      TextField("Agent name", text: profile.name)
        .textFieldStyle(.roundedBorder)
      TextField("Role or speciality", text: profile.role)
        .textFieldStyle(.roundedBorder)
    }
  }

  private func editorInstructions(profile: Binding<AgentProfile>) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      sectionHeading(
        "SYSTEM PROMPT",
        detail: "Applied privately on every turn; never posted as user chat"
      )
      TextEditor(text: profile.instructions)
        .font(.ottoMono(10.5))
        .scrollContentBackground(.hidden)
        .padding(9)
        .frame(minHeight: 170)
        .background(palette.ink.opacity(0.68), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.paper.opacity(0.1)))
    }
  }

  private func editorRuntime(profile: Binding<AgentProfile>) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionHeading("RUNTIME DEFAULTS", detail: "The harness and guardrails used for new sessions")
      Picker("Harness", selection: profile.provider) {
        ForEach(AgentProvider.allCases.filter { $0 != .shell }, id: \.self) { provider in
          Text(provider == .openAI ? "Otto Harness" : provider.rawValue).tag(provider)
        }
      }
      .onChange(of: profile.wrappedValue.provider) { _, provider in
        catalogStore.load(provider, accountID: modelAccountID)
        if !profile.wrappedValue.executionStrategy.isSupported(by: provider) {
          profile.wrappedValue.executionStrategy = .direct
        }
        let options = modelOptions(for: provider)
        if !options.contains(where: { $0.id == profile.wrappedValue.model }) {
          profile.wrappedValue.model = options.first?.id
        }
        let efforts = AgentModelCatalog.effortLevels(
          for: provider, modelID: profile.wrappedValue.model)
        if !efforts.contains(profile.wrappedValue.effort ?? "") {
          profile.wrappedValue.effort = nil
        }
      }
      if profile.wrappedValue.provider == .openAI {
        Text(
          "Otto owns the system prompt, tool loop, local conversation memory, and model session. Choose OpenAI, Claude, Grok, or Kimi below."
        )
        .font(.ottoMono(8))
        .foregroundStyle(palette.muted)
      }

      let models = modelOptions(for: profile.wrappedValue.provider)
      if !models.isEmpty {
        Picker(
          "Model",
          selection: Binding(
            get: { profile.wrappedValue.model ?? models.first?.id ?? "" },
            set: { profile.wrappedValue.model = $0 }
          )
        ) {
          ForEach(models, id: \.id) { model in
            Text(model.displayName).tag(model.id)
          }
          if let current = profile.wrappedValue.model,
            !models.contains(where: { $0.id == current })
          {
            Text(current).tag(current)
          }
        }
        .onChange(of: profile.wrappedValue.model) { _, model in
          let levels = AgentModelCatalog.effortLevels(
            for: profile.wrappedValue.provider, modelID: model)
          if !levels.contains(profile.wrappedValue.effort ?? "") {
            profile.wrappedValue.effort = nil
          }
        }
      }

      let efforts = AgentModelCatalog.effortLevels(
        for: profile.wrappedValue.provider, modelID: profile.wrappedValue.model)
      if !efforts.isEmpty {
        Picker(
          "Reasoning effort",
          selection: Binding(
            get: { profile.wrappedValue.effort ?? "" },
            set: { profile.wrappedValue.effort = $0.isEmpty ? nil : $0 }
          )
        ) {
          Text("Provider default").tag("")
          ForEach(efforts, id: \.self) { effort in
            Text(effort.capitalized).tag(effort)
          }
        }
      }

      Picker(
        "Execution",
        selection: profile.executionStrategy
      ) {
        ForEach(
          AgentExecutionStrategy.allCases.filter {
            $0.isSupported(by: profile.wrappedValue.provider)
          },
          id: \.self
        ) { strategy in
          Text(executionLabel(strategy)).tag(strategy)
        }
      }

      Picker(
        "Permissions",
        selection: Binding(
          get: {
            AgentPermissionMode(rawValue: profile.wrappedValue.permissionMode) ?? .workspaceWrite
          },
          set: {
            profile.wrappedValue.permissionMode = $0.rawValue
            if $0 == .readOnly { profile.wrappedValue.isolatedWorktree = false }
          }
        )
      ) {
        ForEach(AgentPermissionMode.allCases, id: \.self) { mode in
          Text(permissionLabel(mode)).tag(mode)
        }
      }

      Toggle("Use an isolated Git worktree", isOn: profile.isolatedWorktree)
        .toggleStyle(.ottoSwitch)
        .disabled(profile.wrappedValue.permissionMode == AgentPermissionMode.readOnly.rawValue)
    }
  }

  private func modelOptions(for provider: AgentProvider) -> [AgentModel] {
    catalogStore.catalog(for: provider, accountID: modelAccountID)
      ?? (ProviderModelCatalogStore.isDiscovered(provider)
        ? [] : AgentModelCatalog.options(for: provider))
  }

  private func editorActions(profile: AgentProfile) -> some View {
    HStack(spacing: 9) {
      Button {
        openAgent(profile, false)
      } label: {
        Label("Open", systemImage: "arrow.up.forward.square")
      }
      Button {
        openAgent(profile, true)
      } label: {
        Label("New session", systemImage: "plus.rectangle.on.rectangle")
      }
      Button {
        duplicate(profile)
      } label: {
        Label("Duplicate", systemImage: "square.on.square")
      }
      Spacer()
      Button(role: .destructive) {
        pendingDeletion = currentPersistedProfile(id: profile.id) ?? profile
      } label: {
        Label("Delete", systemImage: "trash")
      }
      Button("Save changes") { save(profile) }
        .disabled(!canSave(profile) || !hasUnsavedChanges(profile))
        .keyboardShortcut(.defaultAction)
    }
  }

  private func sectionHeading(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.ottoMono(8, weight: .black))
        .tracking(1.5)
        .foregroundStyle(palette.signal)
      Text(detail)
        .font(.ottoMono(8))
        .foregroundStyle(palette.muted)
    }
  }

  private func selectInitialProfile() {
    guard selectedID == nil, let profile = services.agentProfileList.first else { return }
    select(profile)
  }

  private func select(_ profile: AgentProfile) {
    selectedID = profile.id
    draft = profile
    notice = nil
    catalogStore.load(profile.provider, accountID: modelAccountID)
  }

  private func reconcileSelection(with profiles: [AgentProfile]) {
    guard let selectedID else {
      selectInitialProfile()
      return
    }
    guard let selected = profiles.first(where: { $0.id == selectedID }) else {
      self.selectedID = nil
      draft = nil
      selectInitialProfile()
      return
    }
    if let draft, draft.id == selectedID, draft.revision != selected.revision {
      self.draft = selected
    }
  }

  private func save(_ profile: AgentProfile) {
    do {
      let saved = try services.saveAgentProfile(profile)
      draft = saved
      selectedID = saved.id
      notice = Notice(
        message: "Saved revision \(saved.revision). New sessions use these defaults.",
        isError: false)
    } catch {
      notice = Notice(message: error.localizedDescription, isError: true)
    }
  }

  private func duplicate(_ profile: AgentProfile) {
    var copy = profile
    copy.id = UUID()
    copy.name = uniqueCopyName(for: profile.name)
    copy.revision = 1
    copy.createdAt = .now
    copy.updatedAt = .now
    do {
      let saved = try services.saveAgentProfile(copy)
      select(saved)
      notice = Notice(message: "Created \(saved.name).", isError: false)
    } catch {
      notice = Notice(message: error.localizedDescription, isError: true)
    }
  }

  private func delete(_ profile: AgentProfile) {
    do {
      try services.deleteAgentProfile(id: profile.id)
      selectedID = nil
      draft = nil
      notice = Notice(
        message: "Deleted \(profile.name). Existing canvas sessions were kept.", isError: false)
      selectInitialProfile()
    } catch {
      notice = Notice(message: error.localizedDescription, isError: true)
    }
  }

  private func currentPersistedProfile(id: UUID) -> AgentProfile? {
    services.agentProfileList.first { $0.id == id }
  }

  private func canSave(_ profile: AgentProfile) -> Bool {
    !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && profile.name.count <= 80
      && !profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && profile.provider != .shell
      && profile.executionStrategy.isSupported(by: profile.provider)
  }

  private func hasUnsavedChanges(_ profile: AgentProfile) -> Bool {
    currentPersistedProfile(id: profile.id) != profile
  }

  private func uniqueCopyName(for name: String) -> String {
    var candidate = "\(name) Copy"
    var suffix = 2
    let names = Set(
      services.agentProfileList.map {
        $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      })
    while names.contains(
      candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    ) {
      candidate = "\(name) Copy \(suffix)"
      suffix += 1
    }
    return candidate
  }

  private func rosterDetail(_ profile: AgentProfile) -> String {
    let harness = profile.provider.rawValue
    return profile.role.isEmpty ? harness : "\(profile.role) · \(harness)"
  }

  private func providerSymbol(_ provider: AgentProvider) -> String {
    provider == .claudeCode ? "sparkles" : "chevron.left.forwardslash.chevron.right"
  }

  private func providerTint(_ provider: AgentProvider) -> Color {
    provider == .claudeCode ? palette.cyan : palette.amber
  }

  private func executionLabel(_ strategy: AgentExecutionStrategy) -> String {
    switch strategy {
    case .direct: "Direct"
    case .delegated: "Delegated"
    case .scriptedWorkflow: "Scripted workflow"
    }
  }

  private func permissionLabel(_ mode: AgentPermissionMode) -> String {
    switch mode {
    case .readOnly: "Read only"
    case .workspaceWrite: "Workspace write"
    case .unrestricted: "Unrestricted"
    }
  }
}
