import AppKit
import OttoCore
import OttoDocuments
import OttoModels
import OttoServices
import SwiftUI
import UniformTypeIdentifiers

struct HomePinnedCards: View {
  @ObservedObject var services: ApplicationServices
  let openMarkdown: (String) -> Void
  /// Nil for the workspace's first profile, which owns the pins saved before profiles existed.
  var profileID: UUID? = nil
  @Environment(\.ottoPalette) private var palette
  @StateObject private var pins = HomePinsStore()
  @State private var customizing = false
  @State private var filePicker: NSOpenPanel?
  @State private var error: String?

  private var visiblePins: [HomePin] {
    pins.visiblePins
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Make it yours").font(.ottoDisplay(16).weight(.semibold))
          .foregroundStyle(palette.paper)
          .shadow(color: palette.textHalo, radius: 6)
        Spacer()
        if !visiblePins.isEmpty {
          Button(customizing ? "Done" : "Customize") { customizing.toggle() }
            .accessibilityLabel("Customize Home cards")
        }
        Menu {
          Button("Pin Markdown file…", action: chooseMarkdown)
        } label: {
          Label("Add to Home", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
      if visiblePins.isEmpty {
        Text("Keep a note, checklist, or reference file here.")
          .font(.ottoDisplay(12).weight(.medium)).foregroundStyle(palette.paper.opacity(0.85))
          .shadow(color: palette.textHalo, radius: 6)
      }
      if let error {
        Text(error).font(.ottoDisplay(12)).foregroundStyle(.orange)
      }
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 280), spacing: 14, alignment: .top)], spacing: 14
      ) {
        ForEach(visiblePins) { pin in card(pin) }
      }
    }
    .buttonStyle(.plain)
    .task(id: "\(services.documents.rootPath)|\(profileID?.uuidString ?? "")") {
      pins.load(workspace: services.documents.rootPath, profileID: profileID)
    }
  }

  private func card(_ pin: HomePin) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(title(pin)).font(.ottoDisplay(13).weight(.medium)).lineLimit(1)
        Spacer()
        if customizing {
          Button {
            pins.move(pin.id, by: -1)
          } label: {
            Image(systemName: "arrow.left")
          }
          .accessibilityLabel("Move \(title(pin)) earlier")
          .disabled(visiblePins.first?.id == pin.id)
          Button {
            pins.move(pin.id, by: 1)
          } label: {
            Image(systemName: "arrow.right")
          }
          .accessibilityLabel("Move \(title(pin)) later")
          .disabled(visiblePins.last?.id == pin.id)
          Menu {
            Button(pin.expanded ? "Make compact" : "Make taller") { pins.resize(pin.id) }
            Button("Remove from Home") { pins.remove(pin.id) }
          } label: {
            Image(systemName: "ellipsis")
          }
          .menuStyle(.borderlessButton).fixedSize()
          .accessibilityLabel("Options for \(title(pin))")
        } else {
          Button {
            switch pin.source {
            case .markdown(let path): openMarkdown(path)
            case .widget: break // Legacy pins are decoded but not displayed.
            }
          } label: {
            Image(systemName: "arrow.up.right")
          }
          .accessibilityLabel("Open \(title(pin))")
        }
      }
      switch pin.source {
      case .markdown(let path):
        HomeMarkdownPreview(path: path, documents: services.documents)
      case .widget:
        EmptyView() // Compatibility with saved pins; filtered from visiblePins.
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(height: pin.expanded ? 340 : 220, alignment: .top)
    .frame(maxWidth: .infinity, alignment: .leading)
    .ottoGlass(cornerRadius: 14)
    .foregroundStyle(palette.paper)
    .clipped()
  }

  private func title(_ pin: HomePin) -> String {
    switch pin.source {
    case .markdown(let path): URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    case .widget: "Legacy card"
    }
  }

  private func chooseMarkdown() {
    let panel = NSOpenPanel()
    panel.title = "Pin a Markdown file to Home"
    panel.directoryURL = URL(fileURLWithPath: services.documents.rootPath)
    panel.allowedContentTypes = [.data]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard
      let window = NSApp.keyWindow ?? NSApp.mainWindow
        ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
    else { return }
    filePicker = panel
    panel.beginSheetModal(for: window) { response in
      filePicker = nil
      guard response == .OK, let url = panel.url else { return }
      guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
        error = "Choose a Markdown file (.md or .markdown)."
        return
      }
      let root = services.documents.rootPath + "/"
      let path = url.standardizedFileURL.resolvingSymlinksInPath().path
      guard path.hasPrefix(root) else {
        error = "Choose a Markdown file inside this workspace."
        return
      }
      let relative = String(path.dropFirst(root.count))
      Task {
        do {
          _ = try await services.documents.read(relativePath: relative)
          pins.add(.markdown(relative))
          error = nil
        } catch { self.error = error.localizedDescription }
      }
    }
  }
}

private struct HomeMarkdownPreview: View {
  let path: String
  let documents: WorkspaceDocumentStore
  @State private var text = ""
  @State private var error: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        if let error {
          Text(error).foregroundStyle(.orange)
        } else {
          Text(.init(text)).textSelection(.enabled)
        }
      }
      .font(.ottoDisplay(12))
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task(id: path) {
      await reload()
      do {
        let changes = try await documents.watch(relativePath: path)
        for await _ in changes {
          guard !Task.isCancelled else { break }
          await reload()
        }
      } catch { self.error = error.localizedDescription }
    }
  }

  private func reload() async {
    do {
      text = String(try await documents.read(relativePath: path).prefix(12_000))
      error = nil
    } catch { self.error = "This note could not load: \(error.localizedDescription)" }
  }
}
