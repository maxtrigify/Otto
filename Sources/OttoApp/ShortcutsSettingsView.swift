import SwiftUI

/// Every keyboard command Otto responds to, in one discoverable place. Keep this table in sync
/// with the commands declared in OttoApp.swift.
struct ShortcutsSettingsView: View {
  @ObservedObject var voice: VoiceController

  private struct Shortcut: Identifiable {
    let keys: String
    let action: String
    var id: String { keys + action }
  }

  private struct ShortcutGroup: Identifiable {
    let title: String
    let shortcuts: [Shortcut]
    var id: String { title }
  }

  private let groups: [ShortcutGroup] = [
    ShortcutGroup(
      title: "Window",
      shortcuts: [
        Shortcut(keys: "⌘W", action: "Close the active browser tab, or the window elsewhere")
      ]),
    ShortcutGroup(
      title: "Otto on screen",
      shortcuts: [
        Shortcut(
          keys: OttoBuddyPreferences.summonShortcut,
          action: "From any app: open Otto’s quick menu (while he’s on screen)")
      ]),
    ShortcutGroup(
      title: "Command palette",
      shortcuts: [
        Shortcut(keys: "⌘F", action: "Open the command palette"),
        Shortcut(keys: "↑ / ↓", action: "Move between matching actions"),
        Shortcut(keys: "↩", action: "Run the highlighted action"),
        Shortcut(keys: "Esc", action: "Close the palette"),
      ]),
    ShortcutGroup(
      title: "Browser",
      shortcuts: [
        Shortcut(keys: "⌘B", action: "Go to Browser (Bold while editing document text)"),
        Shortcut(keys: "⌘T / ⌃T", action: "Open a blank tab in the selected browser"),
        Shortcut(keys: "⌘L", action: "Select the browser address or new-tab search box"),
        Shortcut(keys: "⇧⌘T", action: "Reopen the most recently closed tab"),
        Shortcut(keys: "⌘R", action: "Reload the active page"),
        Shortcut(keys: "⌃Tab / ⇧⌃Tab", action: "Go to the next / previous browser tab"),
        Shortcut(keys: "⌘[ / ⌘]", action: "Go back / forward"),
        Shortcut(keys: "Mouse back / forward", action: "Navigate the active tab's history"),
        Shortcut(keys: "Swipe left / right", action: "Navigate with a Magic Mouse or trackpad"),
      ]),
  ]

  var body: some View {
    Form {
      ForEach(groups) { group in
        Section(group.title) {
          ForEach(group.shortcuts) { shortcut in
            LabeledContent {
              Text(shortcut.action)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
            } label: {
              Text(shortcut.keys)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(minWidth: 130, alignment: .leading)
            }
          }
        }
      }
      Section("Voice") {
        ForEach(VoiceInteractionMode.allCases) { mode in
          LabeledContent {
            Picker(
              mode.displayName,
              selection: Binding(
                get: { voice.shortcut(for: mode) },
                set: { voice.setShortcut($0, for: mode) }
              )
            ) {
              ForEach(VoiceShortcut.allCases) { shortcut in
                Text(shortcut.label)
                  .tag(shortcut)
                  .disabled(
                    VoiceInteractionMode.allCases.contains {
                      $0 != mode && voice.shortcut(for: $0) == shortcut
                    }
                  )
              }
            }
            .labelsHidden()
            .frame(width: 150)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(mode.displayName)
              Text(mode.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        Text("Each voice mode must use a different shortcut.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
    .frame(width: 560, height: 620)
  }
}
