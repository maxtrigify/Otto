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
  @Environment(\.ottoSpaceManagement) private var management
  @State private var error: String?
  @State private var switching = false
  @State private var deleting: OttoProfile?

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
      Menu("Manage spaces") {
        ForEach(registry.profiles) { profile in
          Menu {
            Button("Rename and settings…") { sheet = .settings(profile.id) }
            Button("Change folder…") { chooseFolder(for: profile) }
              .disabled(profile.id == current?.id)
            Button("Delete space…", role: .destructive) { deleting = profile }
              .disabled(profile.id == current?.id || registry.profiles.count < 2)
            if profile.id == current?.id {
              Text("Switch to another space to move or delete this one.")
            }
          } label: {
            Label(profile.name, systemImage: profile.symbol)
          }
        }
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
      // Sheets inherit the header band's foreground; give them the system label colour
      // back, which follows the sheet's own light or dark appearance.
      .foregroundStyle(Color(nsColor: .labelColor))
      .environment(\.ottoSpaceManagement, management)
    }
    .spaceDeleteConfirmation(profile: $deleting, registry: registry) { profile, removingData in
      Task { @MainActor in
        do {
          let report = try await management.delete(profile, removingData)
          if !report.failed.isEmpty {
            error = SpaceDeleteConfirmation.failureMessage(report)
          }
        } catch { self.error = error.localizedDescription }
      }
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

  private func chooseFolder(for profile: OttoProfile) {
    guard let folder = SpaceFolderPicker.choose(for: profile) else { return }
    Task { @MainActor in
      do { _ = try await management.relocate(profile, folder) } catch {
        self.error = error.localizedDescription
      }
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

/// Rename, icon, folder and cross-profile access, plus Delete. Deleting never touches the user's
/// own files in the space's folder.
struct ProfileSettingsSheet: View {
  @ObservedObject var services: ApplicationServices
  @ObservedObject var registry: OttoProfileRegistry
  let profileID: UUID
  let onFinish: () -> Void

  @Environment(\.ottoSpaceManagement) private var management
  @State private var draft: OttoProfile?
  @State private var error: String?
  @State private var deleting: OttoProfile?
  @State private var relocating = false

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
          Section {
            Text(binding.wrappedValue.workspacePath)
              .font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
            HStack {
              Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([
                  URL(fileURLWithPath: binding.wrappedValue.workspacePath)
                ])
              }
              Button("Change folder…", action: changeFolder)
                .disabled(isCurrent || relocating)
            }
            Text(
              isCurrent
                ? "Switch to another space to point this one at a different folder."
                : "Points this space at another folder. Nothing is moved: Otto uses the bots, chats and memory in that folder’s .otto folder, or starts them fresh."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          } header: {
            Text("Folder")
          }
        }
        .formStyle(.grouped)
        .frame(minHeight: 300)
      }
      if let error {
        Text(error).font(.callout).foregroundStyle(.orange)
      }
      HStack {
        if registry.profiles.count > 1 {
          Button("Delete space…", role: .destructive) { deleting = draft }
            .disabled(isCurrent)
            .help(
              isCurrent
                ? "Switch to another space to delete this one." : "Delete this space")
        }
        Spacer()
        Button("Cancel", role: .cancel, action: onFinish).keyboardShortcut(.cancelAction)
        Button("Save", action: save).keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 480)
    .onAppear { draft = registry.profile(id: profileID) }
    .spaceDeleteConfirmation(profile: $deleting, registry: registry) { profile, removingData in
      Task { @MainActor in
        do {
          let report = try await management.delete(profile, removingData)
          if report.failed.isEmpty {
            onFinish()
          } else {
            error = SpaceDeleteConfirmation.failureMessage(report)
          }
        } catch { self.error = error.localizedDescription }
      }
    }
  }

  private var isCurrent: Bool { profileID == services.currentProfile?.id }

  private func changeFolder() {
    guard let profile = registry.profile(id: profileID),
      let folder = SpaceFolderPicker.choose(for: profile)
    else { return }
    relocating = true
    Task { @MainActor in
      defer { relocating = false }
      do {
        let moved = try await management.relocate(profile, folder)
        draft?.workspacePath = moved.workspacePath
      } catch { self.error = error.localizedDescription }
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

/// Picks the folder a space should point at. Returns nil when cancelled.
enum SpaceFolderPicker {
  @MainActor
  static func choose(for profile: OttoProfile) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: profile.workspacePath).deletingLastPathComponent()
    panel.prompt = "Use Folder"
    panel.message =
      "Choose the folder for \(profile.name). Nothing is moved or copied; Otto uses the bots, chats and memory in that folder’s .otto folder."
    return panel.runModal() == .OK ? panel.url : nil
  }
}

/// The one confirmation every Delete path uses, so the wording about files is always the same.
struct SpaceDeleteConfirmation: ViewModifier {
  @Binding var profile: OttoProfile?
  let registry: OttoProfileRegistry
  let confirm: (OttoProfile, Bool) -> Void

  func body(content: Content) -> some View {
    content.confirmationDialog(
      "Delete \(profile?.name ?? "this space")?",
      isPresented: Binding(get: { profile != nil }, set: { if !$0 { profile = nil } }),
      presenting: profile
    ) { profile in
      if registry.ottoDataLocations(for: profile).isEmpty {
        Button("Delete space", role: .destructive) { confirm(profile, false) }
      } else {
        Button("Delete space and its Otto data", role: .destructive) { confirm(profile, true) }
        Button("Remove from list only") { confirm(profile, false) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { profile in
      Text(Self.message(for: profile, registry: registry))
    }
  }

  static func message(for profile: OttoProfile, registry: OttoProfileRegistry) -> String {
    let folder = profile.workspacePath
    if registry.ottoDataLocations(for: profile).isEmpty {
      return
        "Otto stops listing \(profile.name) and stops anything running in it. This was your first space: its sessions and About me are shared with Otto’s app-wide data, so they stay on disk. Your files in \(folder) are not touched."
    }
    return
      "Otto stops listing \(profile.name) and stops anything running in it. “Delete space and its Otto data” also moves Otto’s own data for it to the Trash: its chats and sessions, bots, memory and routines (the .otto folder in \(folder) and its Otto database). Your own files in \(folder) are never deleted."
  }

  static func failureMessage(_ report: OttoProfileRegistry.DeletionReport) -> String {
    "The space was deleted, but Otto couldn’t move this data to the Trash: \(report.failed.joined(separator: ", ")). You can remove it yourself in Finder."
  }
}

extension View {
  func spaceDeleteConfirmation(
    profile: Binding<OttoProfile?>, registry: OttoProfileRegistry,
    confirm: @escaping (OttoProfile, Bool) -> Void
  ) -> some View {
    modifier(SpaceDeleteConfirmation(profile: profile, registry: registry, confirm: confirm))
  }
}

/// The same right-hand header controls on every screen: profile, background, activity.
struct OttoHeaderControls: View {
  @Environment(\.ottoPalette) private var palette
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
              Circle().fill(palette.signal)
                .frame(width: 5, height: 5).offset(x: 2, y: -2)
            }
          }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Open activity")
      .help("Activity")
    }
    // These controls always sit on a `chromeBand`, so they take its theme-matched foreground.
    .foregroundStyle(palette.chromeForeground)
  }
}
