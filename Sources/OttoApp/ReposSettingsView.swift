import AppKit
import OttoModels
import OttoServices
import SwiftUI

/// Manage repositories Otto has imported (issue #71). Pasted git URLs are cloned into the
/// workspace's `repos/` folder so sessions and workflows can build on a real checkout.
struct ReposSettingsView: View {
  let services: ApplicationServices
  @ObservedObject private var store: ReposStore
  @State private var draftURL = ""
  @State private var errorMessage: String?
  @State private var workingID: UUID?

  init(services: ApplicationServices) {
    self.services = services
    _store = ObservedObject(wrappedValue: services.repos)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("Repos").font(.title2.weight(.semibold))
        Text("Import repositories Otto can work on. Each one is cloned into your workspace's "
          + "repos/ folder so sessions and workflows can build on it.")
          .font(.caption).foregroundStyle(.secondary)

        addCard

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.red)
        }

        if store.repos.isEmpty {
          ContentUnavailableView(
            "No repos yet",
            systemImage: "arrow.down.circle",
            description: Text("Paste a GitHub or git URL above to import one."))
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
        } else {
          repoList
        }
      }
      .padding(28)
    }
    .frame(minWidth: 640, minHeight: 560)
  }

  private var addCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Add a repository").font(.headline)
      HStack(spacing: 8) {
        TextField("https://github.com/owner/repo", text: $draftURL)
          .textFieldStyle(.roundedBorder)
          .onSubmit(add)
        Button("Add", action: add)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.return, modifiers: [])
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
  }

  private var repoList: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(store.repos) { repo in
        HStack(spacing: 10) {
          Image(systemName: "shippingbox")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(repo.name).font(.body.weight(.medium))
            Text(repo.url)
              .font(.caption).foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.middle)
          }
          Spacer()
          stateView(for: repo)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
      }
    }
  }

  @ViewBuilder
  private func stateView(for repo: GitRepo) -> some View {
    switch store.states[repo.id] {
    case .cloned(let path):
      HStack(spacing: 6) {
        Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
          .buttonStyle(.bordered)
        Button(role: .destructive) { remove(repo) } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.bordered)
        .help("Remove repo")
      }
    case .cloning:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Cloning…").font(.caption).foregroundStyle(.secondary)
      }
    case .failed(let detail):
      HStack(spacing: 6) {
        Text(detail).font(.caption).foregroundStyle(.red).lineLimit(1)
        Button("Retry") { clone(repo) }.buttonStyle(.bordered)
        Button(role: .destructive) { remove(repo) } label: {
          Image(systemName: "trash")
        }.buttonStyle(.bordered)
      }
    case .notCloned, .none:
      HStack(spacing: 6) {
        Button("Clone") { clone(repo) }.buttonStyle(.bordered)
        Button(role: .destructive) { remove(repo) } label: {
          Image(systemName: "trash")
        }.buttonStyle(.bordered)
      }
    }
  }

  private func add() {
    errorMessage = nil
    let url = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !url.isEmpty else { draftURL = ""; return }
    do {
      try store.add(url)
      draftURL = ""
    } catch {
      errorMessage = (error as? RepoCloneError)?.errorDescription ?? error.localizedDescription
    }
  }

  private func clone(_ repo: GitRepo) {
    errorMessage = nil
    Task { await store.clone(repo) }
  }

  private func remove(_ repo: GitRepo) {
    errorMessage = nil
    do {
      try store.remove(repo)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
