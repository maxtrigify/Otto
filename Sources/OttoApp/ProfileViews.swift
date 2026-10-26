import AppKit
import OttoCore
import OttoMemory
import OttoModels
import OttoServices
import SwiftUI

/// Switching changes the visible space while its runtime stays alive in the app.
struct ProfileSwitcherMenu: View {
  @ObservedObject var services: ApplicationServices
  @ObservedObject var registry: OttoProfileRegistry
  var compact = false

  @State private var sheet: ProfileSheet?
  @Environment(\.ottoSwitchSpace) private var switchSpace
  @State private var error: String?
  @State private var switching = false

  enum ProfileSheet: Identifiable {
    case create
    case settings(UUID)
    var id: String {
      switch self {
      case .create: "create"
      case .settings(let id): id.uuidString
      }
    }
  }

  private var current: OttoProfile? { services.currentProfile }

  var body: some View {
    Menu {
      ForEach(registry.profiles) { profile in
        Button {
          requestSwitch(to: profile)
        } label: {
          if profile.id == current?.id {
            Label(profile.name, systemImage: "checkmark")
          } else {
            Label(profile.name, systemImage: profile.symbol)
          }
        }
      }
      Divider()
      if let current {
        Button("Space settings…") { sheet = .settings(current.id) }
      }
      Button("New space…") { sheet = .create }
    } label: {
      HStack(spacing: 7) {
        Image(systemName: current?.symbol ?? "square.stack")
          .font(.system(size: compact ? 11 : 12))
        Text(current?.name ?? "Space")
          .font(.ottoDisplay(compact ? 12 : 13).weight(.semibold))
          .lineLimit(1)
      }
      .contentShape(Rectangle())
    }
    .disabled(switching)
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel("Space")
    .accessibilityValue(current?.name ?? "")
    .help("Switch space (⌥Tab): each one has its own bots, chats, memory and brief")
    .sheet(item: $sheet) { sheet in
      Group {
        switch sheet {
        case .create:
          NewProfileSheet(services: services, registry: registry) { created in
            self.sheet = nil
            if let created { requestSwitch(to: created) }
          }
        case .settings(let id):
          ProfileSettingsSheet(services: services, registry: registry, profileID: id) {
            self.sheet = nil
          }
        }
      }
      // Sheets inherit the header's white-on-photo text; give them the system label colour
      // back, which follows the sheet's own light or dark appearance.
      .foregroundStyle(Color(nsColor: .labelColor))
    }
    .alert(
      "Space error",
      isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
    ) {
      Button("OK", role: .cancel) { error = nil }
    } message: {
      Text(error ?? "")
    }
  }

  private func requestSwitch(to profile: OttoProfile) {
    guard profile.id != current?.id else { return }
    guard !switching else { return }
    switching = true
    Task { @MainActor in
      defer { switching = false }
      do { try await switchSpace(profile) } catch { self.error = error.localizedDescription }
    }
  }

}

/// Creates a blank profile, optionally bringing across chosen "About me" facts and memories.
struct NewProfileSheet: View {
  @ObservedObject var services: ApplicationServices
  @ObservedObject var registry: OttoProfileRegistry
  let onFinish: (OttoProfile?) -> Void

  @State private var name = ""
  @State private var symbol = "heart"
  @State private var aboutMe: [CompactMemoryEntry] = []
  @State private var records: [MemoryRecord] = []
  @State private var chosenAboutMe: Set<String> = []
  @State private var chosenRecords: Set<String> = []
  @State private var creating = false
  @State private var error: String?

  static let symbols = [
    "briefcase", "heart", "house", "sterlingsign.circle", "leaf", "hammer", "paintbrush",
    "graduationcap", "sparkles",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New space").font(.title3.weight(.semibold))
      Text(
        "A space is its own place, like Work, Personal or a side project: its own bots, chats, memory and morning brief. It starts blank. You can bring a few things across to get going."
      )
      .font(.callout).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      Form {
        TextField("Name", text: $name, prompt: Text("Personal, Side Hustle…"))
        Picker("Icon", selection: $symbol) {
          ForEach(Self.symbols, id: \.self) { symbol in
            Label(symbol, systemImage: symbol).labelStyle(.iconOnly).tag(symbol)
          }
        }
        .pickerStyle(.segmented)
        Section {
          if aboutMe.isEmpty {
            Text("Nothing saved about you yet.").foregroundStyle(.secondary)
          } else {
            ForEach(aboutMe) { entry in
              Toggle(entry.text, isOn: binding(entry.id, in: $chosenAboutMe))
            }
          }
        } header: {
          HStack {
            Text("Bring across About me")
            Spacer()
            if !aboutMe.isEmpty {
              Button(chosenAboutMe.count == aboutMe.count ? "None" : "All") {
                chosenAboutMe =
                  chosenAboutMe.count == aboutMe.count ? [] : Set(aboutMe.map(\.id))
              }
              .buttonStyle(.link)
            }
          }
        }
        Section("Share memories") {
          if records.isEmpty {
            Text("No saved knowledge to share yet.").foregroundStyle(.secondary)
          } else {
            ForEach(records, id: \.id) { record in
              Toggle(isOn: binding(record.id, in: $chosenRecords)) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(record.title)
                  Text(record.body.prefix(110)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }
            }
          }
        }
      }
      .formStyle(.grouped)
      .frame(minHeight: 280, maxHeight: 460)

      if let error {
        Text(error).font(.callout).foregroundStyle(.orange)
      }
      HStack {
        Text("Copies are independent; nothing stays linked.")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Cancel", role: .cancel) { onFinish(nil) }.keyboardShortcut(.cancelAction)
        Button(creating ? "Creating…" : "Create and open", action: create)
          .keyboardShortcut(.defaultAction)
          .disabled(creating || name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(22)
    .frame(width: 520)
    .task {
      aboutMe = await services.personalMemory.entries().filter { $0.confidence == .confirmed }
      chosenAboutMe = Set(aboutMe.map(\.id))
      records = await services.shareableBrainRecords()
    }
  }

  private func binding(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
    Binding(
      get: { set.wrappedValue.contains(id) },
      set: { isOn in
        if isOn { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
      })
  }

  private func create() {
    creating = true
    Task {
      do {
        let profile = try await services.createProfile(
          name: name, symbol: symbol, themeID: nil,
          quickStart: ProfileQuickStart(
            aboutMeEntryIDs: chosenAboutMe, brainRecordIDs: chosenRecords))
        onFinish(profile)
      } catch {
        self.error = error.localizedDescription
      }
      creating = false
    }
  }
}

/// Rename, icon and cross-profile access. Removing a profile only forgets it; its folder stays.
struct ProfileSettingsSheet: View {
  @ObservedObject var services: ApplicationServices
  @ObservedObject var registry: OttoProfileRegistry
  let profileID: UUID
  let onFinish: () -> Void

  @State private var draft: OttoProfile?
  @State private var error: String?
  @State private var confirmingRemove = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Space settings").font(.title3.weight(.semibold))
      if let binding = Binding($draft) {
        Form {
          TextField("Name", text: binding.name)
          Picker("Icon", selection: binding.symbol) {
            ForEach(NewProfileSheet.symbols, id: \.self) { symbol in
              Label(symbol, systemImage: symbol).labelStyle(.iconOnly).tag(symbol)
            }
          }
          .pickerStyle(.segmented)
          Section {
            Toggle("Let agents look into my other spaces", isOn: binding.crossProfileAccess)
            Text(
              "Off by default. When on, agents in \(binding.wrappedValue.name) can search your other spaces' memory, read-only. Agents know this switch exists and will ask you before they need it."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          } header: {
            Text("Cross-space access")
          }
          Section("Folder") {
            Text(binding.wrappedValue.workspacePath)
              .font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
            Button("Show in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: binding.wrappedValue.workspacePath)
              ])
            }
          }
        }
        .formStyle(.grouped)
        .frame(minHeight: 300)
      }
      if let error {
        Text(error).font(.callout).foregroundStyle(.orange)
      }
      HStack {
        if registry.profiles.count > 1, profileID != services.currentProfile?.id {
          Button("Remove from Otto…", role: .destructive) { confirmingRemove = true }
        }
        Spacer()
        Button("Cancel", role: .cancel, action: onFinish).keyboardShortcut(.cancelAction)
        Button("Save", action: save).keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 480)
    .onAppear { draft = registry.profile(id: profileID) }
    .confirmationDialog(
      "Remove \(draft?.name ?? "this space") from Otto?", isPresented: $confirmingRemove
    ) {
      Button("Remove", role: .destructive) {
        do {
          try registry.remove(profileID)
          onFinish()
        } catch { self.error = error.localizedDescription }
      }
    } message: {
      Text("Its folder, bots, chats and memory stay on disk; Otto just stops listing it.")
    }
  }

  private func save() {
    guard let draft else { return }
    do {
      try registry.update(draft)
      onFinish()
    } catch { self.error = error.localizedDescription }
  }
}

/// The same right-hand header controls on every screen: profile, background, activity.
struct OttoHeaderControls: View {
  @ObservedObject var services: ApplicationServices
  @ObservedObject var store: CanvasStore
  var needsAttention = false
  let openActivity: () -> Void

  private var currentTheme: OttoThemeDefinition {
    OttoThemeCatalog.theme(id: store.activeCanvas.themeID)
  }

  var body: some View {
    HStack(spacing: 14) {
      if let registry = services.profiles {
        ProfileSwitcherMenu(services: services, registry: registry, compact: true)
      }
      Menu {
        ForEach(OttoThemeCatalog.all, id: \.id) { theme in
          Button {
            store.dispatch(.setTheme(theme.id))
            if let registry = services.profiles, var current = services.currentProfile {
              current.themeID = theme.id
              try? registry.update(current)
            }
          } label: {
            if currentTheme.id == theme.id {
              Label(theme.displayName, systemImage: "checkmark")
            } else {
              Text(theme.displayName)
            }
          }
        }
      } label: {
        Image(systemName: "paintpalette")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("Choose background")
      .help("Background: \(currentTheme.displayName)")
      Button(action: openActivity) {
        Image(systemName: "tray")
          .overlay(alignment: .topTrailing) {
            if needsAttention {
              Circle().fill(Color(red: 0.77, green: 0.85, blue: 0.70))
                .frame(width: 5, height: 5).offset(x: 2, y: -2)
            }
          }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Open activity")
      .help("Activity")
    }
    .foregroundStyle(.white.opacity(0.85))
  }
}
