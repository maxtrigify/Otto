import AppKit
import OttoCore
import OttoModels
import OttoServices
import SwiftUI

/// Every installed widget in one place: what it is, where it lives, and a way to open, reveal,
/// or delete it. Also surfaces orphaned packages — Widgets/ folders no canvas node references —
/// so stale experiments can be cleaned up. Deletions move the package to the Trash.
struct WidgetManagerView: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: CanvasStore
  @ObservedObject var services: ApplicationServices

  @State private var rows: [Row] = []
  @State private var orphans: [Row] = []
  @State private var pendingDeletion: Row?
  @State private var notice: String?

  struct Row: Identifiable, Equatable {
    let id: String
    let nodeID: UUID?
    let canvasID: UUID?
    let name: String
    let detail: String
    let packagePath: String
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("WIDGETS")
          .font(.ottoMono(10, weight: .black))
          .tracking(2)
          .foregroundStyle(palette.signal)
        Spacer()
        Button("Refresh") { reload() }
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(18)
      Divider().overlay(palette.paper.opacity(0.08))

      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if let notice {
            Text(notice)
              .font(.ottoMono(9))
              .foregroundStyle(palette.amber)
          }
          if rows.isEmpty, orphans.isEmpty {
            ContentUnavailableView(
              "No widgets yet",
              systemImage: "square.stack.3d.up",
              description: Text("Create one from the command palette or ask an agent.")
            )
            .foregroundStyle(palette.muted)
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
          }
          if !rows.isEmpty {
            section(title: "ON CANVAS", rows: rows, isOrphan: false)
          }
          if !orphans.isEmpty {
            section(title: "ORPHANED PACKAGES · NO CANVAS NODE", rows: orphans, isOrphan: true)
          }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 680, minHeight: 460)
    .background(palette.surface)
    .task { reload() }
    .confirmationDialog(
      "Delete \(pendingDeletion?.name ?? "widget")?",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete widget", role: .destructive) {
        if let row = pendingDeletion { delete(row) }
        pendingDeletion = nil
      }
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
    } message: {
      Text("The canvas card closes and the widget's package folder moves to the Trash.")
    }
  }

  private func section(title: String, rows: [Row], isOrphan: Bool) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.ottoMono(8, weight: .black))
        .tracking(1.6)
        .foregroundStyle(palette.muted)
      ForEach(rows) { row in
        rowView(row, isOrphan: isOrphan)
      }
    }
  }

  private func rowView(_ row: Row, isOrphan: Bool) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "square.stack.3d.up")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(isOrphan ? palette.muted : palette.signal)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.name)
          .font(.ottoDisplay(14))
          .fontWeight(.semibold)
          .foregroundStyle(palette.paper)
        Text(row.detail)
          .font(.ottoMono(8))
          .foregroundStyle(palette.muted)
          .lineLimit(1)
      }
      Spacer(minLength: 12)
      if !isOrphan {
        rowButton("Open", symbol: "arrow.up.forward.square") { open(row) }
      }
      rowButton("Reveal", symbol: "folder") { reveal(row) }
      rowButton("Delete", symbol: "trash", tint: palette.red) { pendingDeletion = row }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(palette.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.paper.opacity(0.06)))
  }

  private func rowButton(
    _ title: String, symbol: String, tint: Color? = nil, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .font(.ottoMono(8, weight: .bold))
        .foregroundStyle(tint ?? palette.paper)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(palette.ink.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .help("\(title) \(symbol == "trash" ? "this widget (package goes to the Trash)" : "")")
  }

  private func reload() {
    notice = nil
    let entries = store.snapshot.canvases.flatMap { canvas in
      canvas.nodes.compactMap { node -> (canvas: OttoCanvas, node: OttoNode, path: String)? in
        guard node.kind == .widget, case .widget(let path, _) = node.content, !path.isEmpty
        else { return nil }
        return (canvas, node, path)
      }
    }
    Task {
      var loaded: [Row] = []
      for entry in entries {
        let manifest = try? await readManifest(packagePath: entry.path)
        var pieces = [entry.canvas.name]
        if let kind = manifest?.view?.kind.rawValue { pieces.append(kind.uppercased()) }
        if let schedule = manifest?.schedule, schedule.enabled {
          pieces.append(schedule.cron ?? "every \(schedule.intervalSeconds)s")
        }
        pieces.append(entry.path)
        loaded.append(
          Row(
            id: entry.node.id.uuidString,
            nodeID: entry.node.id,
            canvasID: entry.canvas.id,
            name: manifest?.name ?? entry.node.displayName,
            detail: pieces.joined(separator: " · "),
            packagePath: entry.path
          ))
      }
      rows = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      orphans = orphanRows(referencedPaths: Set(entries.map(\.path)))
    }
  }

  private func orphanRows(referencedPaths: Set<String>) -> [Row] {
    let widgetsURL = URL(fileURLWithPath: services.documents.rootPath, isDirectory: true)
      .appendingPathComponent("Widgets", isDirectory: true)
    let contents =
      (try? FileManager.default.contentsOfDirectory(
        at: widgetsURL, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])) ?? []
    return contents.compactMap { url -> Row? in
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
        return nil
      }
      let path = "Widgets/\(url.lastPathComponent)"
      guard !referencedPaths.contains(path) else { return nil }
      let name = packageName(at: url) ?? url.lastPathComponent
      return Row(
        id: path, nodeID: nil, canvasID: nil, name: name,
        detail: "no canvas card · \(path)", packagePath: path)
    }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private func packageName(at url: URL) -> String? {
    let manifestURL = url.appendingPathComponent("widget.json")
    guard let data = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(WidgetManifest.self, from: data)
    else { return nil }
    return manifest.name
  }

  private func readManifest(packagePath: String) async throws -> WidgetManifest {
    let text = try await services.documents.read(relativePath: "\(packagePath)/widget.json")
    return try JSONDecoder().decode(WidgetManifest.self, from: Data(text.utf8))
  }

  private func open(_ row: Row) {
    guard let nodeID = row.nodeID, let canvasID = row.canvasID else { return }
    if store.snapshot.activeCanvasID != canvasID {
      store.dispatch(.switchCanvas(canvasID))
    }
    store.dispatch(.focusNode(nodeID), targetCanvasID: canvasID)
    dismiss()
  }

  private func reveal(_ row: Row) {
    let url = URL(fileURLWithPath: services.documents.rootPath)
      .appendingPathComponent(row.packagePath)
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func delete(_ row: Row) {
    if let nodeID = row.nodeID, let canvasID = row.canvasID {
      store.dispatch(.closeNode(nodeID), targetCanvasID: canvasID)
    }
    Task {
      do {
        try await services.documents.trash(relativePath: row.packagePath)
        notice = "Moved \(row.name) to the Trash"
      } catch {
        notice = "Package could not be removed: \(error.localizedDescription)"
      }
      reload()
    }
  }
}
