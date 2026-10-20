import AppKit
import OttoBrowser
import OttoModels
import SwiftUI

enum BrowserBookmarkPreferences {
  static let onboardingCompletedKey = "otto.browser.import.completed"
  private static let bookmarksKey = "otto.browser.bookmarks"

  static func load(from defaults: UserDefaults = .standard) -> [BrowserBookmark] {
    guard let data = defaults.data(forKey: bookmarksKey),
      let bookmarks = try? JSONDecoder().decode([BrowserBookmark].self, from: data)
    else { return [] }
    return bookmarks
  }

  static func save(_ bookmarks: [BrowserBookmark], to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(bookmarks) else { return }
    defaults.set(data, forKey: bookmarksKey)
  }

  static func merging(
    _ imported: [BrowserBookmark],
    into existing: [BrowserBookmark]
  ) -> [BrowserBookmark] {
    var seen = Set(existing.map(\.url))
    return existing + imported.filter { seen.insert($0.url).inserted }
  }
}

@MainActor
enum BrowserImportPresentationGate {
  private static var hasPresentedThisLaunch = false

  static func claim() -> Bool {
    guard !hasPresentedThisLaunch else { return false }
    hasPresentedThisLaunch = true
    return true
  }
}

struct BrowserImportRequest: Identifiable {
  let id = UUID()
  let sources: [BrowserImportSource]
}

struct BrowserImportView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.ottoPalette) private var palette
  let sources: [BrowserImportSource]
  let importSources: ([BrowserImportSource], _ includeSignIns: Bool) async throws -> Int
  let skip: () -> Void
  @State private var selectedIDs: Set<String>
  @State private var includeSignIns = true
  @State private var isImporting = false
  @State private var errorMessage: String?

  init(
    sources: [BrowserImportSource],
    importSources: @escaping ([BrowserImportSource], _ includeSignIns: Bool) async throws -> Int,
    skip: @escaping () -> Void
  ) {
    self.sources = sources
    self.importSources = importSources
    self.skip = skip
    _selectedIDs = State(initialValue: Set(sources.map(\.id)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 7) {
          Text("Bring your browser with you")
            .font(.ottoDisplay(28))
            .foregroundStyle(palette.paper)
          Text(
            "Import bookmarks and stay signed in to your sites. Your existing browser is left untouched."
          )
          .font(.ottoDisplay(13))
          .foregroundStyle(palette.muted)
        }
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(palette.muted)
            .frame(width: 28, height: 28)
            .background(palette.raised.opacity(0.65), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Close import")
      }
      .padding(.horizontal, 24)
      .padding(.top, 23)
      .padding(.bottom, 18)

      Rectangle().fill(.white.opacity(0.08)).frame(height: 1)

      ScrollView {
        if sources.isEmpty {
          VStack(spacing: 10) {
            Image(systemName: "safari")
              .font(.system(size: 28, weight: .light))
            Text("No browser profiles found")
              .font(.ottoDisplay(17))
            Text("You can continue now and import bookmarks later from the browser sidebar.")
              .font(.ottoDisplay(12))
              .multilineTextAlignment(.center)
          }
          .foregroundStyle(palette.muted)
          .frame(maxWidth: .infinity, minHeight: 260)
          .padding(24)
        } else {
          VStack(spacing: 7) {
            ForEach(sources) { source in
              Button {
                if selectedIDs.contains(source.id) {
                  selectedIDs.remove(source.id)
                } else {
                  selectedIDs.insert(source.id)
                }
              } label: {
                HStack(spacing: 12) {
                  BrowserSourceIcon(browser: source.browser)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(source.browser.rawValue)
                      .font(.ottoDisplay(14))
                      .foregroundStyle(palette.paper)
                    Text(source.profileName)
                      .font(.ottoMono(8))
                      .foregroundStyle(palette.muted)
                  }
                  Spacer()
                  Image(
                    systemName: selectedIDs.contains(source.id)
                      ? "checkmark.circle.fill" : "circle"
                  )
                  .font(.system(size: 17, weight: .medium))
                  .foregroundStyle(selectedIDs.contains(source.id) ? palette.cyan : palette.muted)
                }
                .padding(.horizontal, 13)
                .frame(height: 58)
                .background(palette.raised.opacity(0.66), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07)))
              }
              .buttonStyle(.plain)
            }
          }
          .padding(18)
        }
      }

      if sources.contains(where: \.canImportSignIns) {
        Toggle(isOn: $includeSignIns) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Stay signed in")
              .font(.ottoDisplay(13))
              .foregroundStyle(palette.paper)
            Text(
              "Brings over sign-in cookies. macOS asks once per browser; choose Always Allow. Passwords are not copied."
            )
            .font(.ottoDisplay(11))
            .foregroundStyle(palette.muted)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
      }

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .font(.ottoMono(8, weight: .medium))
          .foregroundStyle(palette.red)
          .padding(.horizontal, 24)
          .padding(.bottom, 10)
      }

      Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
      HStack {
        Button("Continue without importing") {
          skip()
          dismiss()
        }
        .font(.ottoMono(9, weight: .medium))
        .foregroundStyle(palette.muted)
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .frame(height: 34)

        Spacer()
        Button(action: primaryAction) {
          HStack(spacing: 7) {
            if isImporting { ProgressView().controlSize(.small) }
            Text(primaryTitle)
          }
          .font(.ottoMono(9, weight: .bold))
          .foregroundStyle(palette.ink)
          .padding(.horizontal, 15)
          .frame(height: 34)
          .background(palette.paper, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled((!sources.isEmpty && selectedIDs.isEmpty) || isImporting)
      }
      .padding(18)
    }
    .frame(width: 500, height: 470)
    .background(palette.ink)
  }

  private func runImport() async {
    isImporting = true
    errorMessage = nil
    do {
      let selected = sources.filter { selectedIDs.contains($0.id) }
      _ = try await importSources(selected, includeSignIns)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
    isImporting = false
  }

  private var primaryTitle: String {
    if isImporting { return "Importing…" }
    return sources.isEmpty ? "Continue" : "Import selected"
  }

  private func primaryAction() {
    if sources.isEmpty {
      skip()
      dismiss()
    } else {
      Task { await runImport() }
    }
  }
}

private struct BrowserSourceIcon: View {
  let browser: BrowserImportSource.Browser

  var body: some View {
    if let icon = appIcon {
      Image(nsImage: icon)
        .resizable()
        .scaledToFit()
        .frame(width: 31, height: 31)
    } else {
      Image(systemName: "globe")
        .font(.system(size: 18, weight: .medium))
        .frame(width: 31, height: 31)
    }
  }

  private var appIcon: NSImage? {
    let path = browser.applicationPath
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    return NSWorkspace.shared.icon(forFile: path)
  }
}
