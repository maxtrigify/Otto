import OttoMemory
import OttoServices
import SwiftUI

/// Memory is automatic; the default view makes its recorded connections explorable.
/// Curation remains an optional, explicit user action in Manage.
struct MemoryInspectorView: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var services: ApplicationServices

  @State private var personalEntries: [CompactMemoryEntry] = []
  @State private var operatingEntries: [CompactMemoryEntry] = []
  @State private var personalUsage: CompactMemoryStore.Usage?
  @State private var operatingUsage: CompactMemoryStore.Usage?
  @State private var proposals: [CompactMemoryProposal] = []
  @State private var brainProposals: [MemoryRecord] = []
  @State private var projectMemories: [MemoryRecord] = []
  @State private var botMemories: [MemoryRecord] = []
  @State private var notice: String?
  @State private var showingManage = false
  @State private var graphRecords: [MemoryRecord] = []
  @State private var loadingRecords = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 18) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Memory").font(.ottoDisplay(24).weight(.semibold)).foregroundStyle(palette.paper)
          Text("Memory runs automatically. Explore what connects.")
            .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
        }
        Spacer()
        Picker("Memory view", selection: $showingManage) {
          Text("Explore").tag(false)
          Text("Manage").tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 180)
        if loadingRecords { ProgressView().controlSize(.small) }
        Button { notice = nil; reload() } label: { Image(systemName: "arrow.clockwise") }
          .disabled(loadingRecords).help("Refresh memory").accessibilityLabel("Refresh memory")
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      .padding(20)
      Divider().overlay(palette.paper.opacity(0.08))
      if let notice, !showingManage {
        Text(notice).font(.ottoDisplay(11)).foregroundStyle(palette.amber).padding(12)
      }
      ZStack {
        MemoryGraphView(
          records: graphRecords, personal: personalEntries, operating: operatingEntries,
          botNames: Dictionary(uniqueKeysWithValues: Set(graphRecords.compactMap(\.profileID)).map {
            ($0, services.agentProfiles.profile(id: $0)?.name ?? "Unnamed bot")
          }))
          .opacity(showingManage ? 0 : 1)
          .allowsHitTesting(!showingManage)
          .disabled(showingManage)
          .accessibilityHidden(showingManage)
        if showingManage { managementContent }
      }
    }
    .frame(width: 1040, height: 710)
    .background(palette.surface)
    .task { reload() }
  }

  private var managementContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        if let notice {
          Text(notice)
            .font(.ottoMono(9))
            .foregroundStyle(palette.amber)
        }
        budgetSection
        if !proposals.isEmpty { inboxSection }
        if !brainProposals.isEmpty { brainProposalSection }
        projectBrainSection
        botMemorySection
        compactSection(
          title: "USER CONTEXT · DEVICE-LOCAL",
          entries: personalEntries,
          store: services.personalMemory
        )
        compactSection(
          title: "OPERATING MEMORY · WORKSPACE",
          entries: operatingEntries,
          store: services.operatingMemory
        )
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }


  private var budgetSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader("ALWAYS-LOADED BUDGETS")
      if let personalUsage { budgetMeter("User context", personalUsage) }
      if let operatingUsage { budgetMeter("Operating memory", operatingUsage) }
    }
  }

  private func budgetMeter(_ label: String, _ usage: CompactMemoryStore.Usage) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(label).font(.ottoDisplay(12)).foregroundStyle(palette.paper)
        Spacer()
        Text(
          "\(usage.entryCount)/\(usage.budget.maximumEntries) entries · \(usage.characterCount)/\(usage.budget.maximumCharacters) chars"
        )
        .font(.ottoMono(8))
        .foregroundStyle(palette.muted)
      }
      GeometryReader { geometry in
        let fraction = min(
          1, Double(usage.characterCount) / Double(usage.budget.maximumCharacters))
        ZStack(alignment: .leading) {
          Capsule().fill(palette.raised)
          Capsule()
            .fill(fraction > 0.85 ? palette.amber : palette.signal)
            .frame(width: max(4, geometry.size.width * fraction))
        }
      }
      .frame(height: 5)
    }
  }

  private var inboxSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader("REVIEW INBOX — PROPOSED COMPACT MEMORIES")
      ForEach(proposals) { proposal in
        HStack(alignment: .top, spacing: 10) {
          VStack(alignment: .leading, spacing: 3) {
            Text(proposal.text).font(.ottoDisplay(12)).foregroundStyle(palette.paper)
            Text("\(proposal.target.rawValue) · from \(proposal.proposedBy) · \(proposal.source)")
              .font(.ottoMono(7.5)).foregroundStyle(palette.muted)
          }
          Spacer()
          Button("Accept") { accept(proposal) }
          Button("Reject") { reject(proposal) }
        }
        .padding(10)
        .background(palette.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
      }
    }
  }

  private var brainProposalSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader("MEMORIES AWAITING REVIEW")
      ForEach(brainProposals) { record in
        HStack(alignment: .top, spacing: 10) {
          VStack(alignment: .leading, spacing: 3) {
            Text(record.title).font(.ottoDisplay(12)).foregroundStyle(palette.paper)
            Text(
              "\(record.scope == .agentRole ? "Private bot: " + (record.profileID.flatMap { services.agentProfiles.profile(id: $0)?.name } ?? "Unknown bot") : "Shared project") · \(record.id) · by \(record.author)"
            )
            .font(.ottoMono(7.5)).foregroundStyle(palette.muted)
            Text(record.body.prefix(160))
              .font(.ottoDisplay(10)).foregroundStyle(palette.muted).lineLimit(2)
          }
          Spacer()
          Button("Confirm") {
            lifecycle {
              try await services.brain?.confirm(id: record.id, expectedRevision: record.revision)
            }
          }
          Button("Archive") {
            lifecycle {
              try await services.brain?.archive(id: record.id, expectedRevision: record.revision)
            }
          }
          Button("Delete") { lifecycle { try await services.brain?.delete(id: record.id) } }
        }
        .padding(10)
        .background(palette.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
      }
    }
  }

  private var projectBrainSection: some View {
    memoryRecordSection(
      title: "PROJECT OTTO MEMORY · SHARED BRAIN",
      empty: "No shared Project Brain records yet.",
      records: projectMemories,
      showsOwner: false
    )
  }

  private var botMemorySection: some View {
    memoryRecordSection(
      title: "BOT MEMORY · PRIVATE BRAIN SCOPES",
      empty: "No bot memories yet. Each bot writes and recalls only its own scope.",
      records: botMemories,
      showsOwner: true
    )
  }

  private func memoryRecordSection(
    title: String,
    empty: String,
    records: [MemoryRecord],
    showsOwner: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader(title)
      if records.isEmpty {
        Text(empty)
          .font(.ottoDisplay(11))
          .foregroundStyle(palette.muted)
      }
      ForEach(records.prefix(40)) { record in
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline) {
            Text(record.title)
              .font(.ottoDisplay(12).weight(.semibold))
              .foregroundStyle(palette.paper)
            Spacer()
            Text(record.factKind.rawValue.uppercased())
              .font(.ottoMono(7, weight: .black))
              .foregroundStyle(palette.signal)
          }
          Text(record.body.prefix(220))
            .font(.ottoDisplay(10.5))
            .foregroundStyle(palette.muted)
            .lineLimit(3)
          let owner = record.profileID.flatMap { services.agentProfiles.profile(id: $0)?.name }
          let provenance =
            record.sourceIDs.isEmpty
            ? "uncited" : record.sourceIDs.joined(separator: ", ")
          let entities =
            record.entityIDs.isEmpty
            ? "" : " · \(record.entityIDs.joined(separator: ", "))"
          let expiry =
            record.expiresAt.map {
              " · expires \($0.formatted(date: .abbreviated, time: .shortened))"
            } ?? ""
          Text(
            "\(showsOwner ? (owner ?? "Unknown bot") + " · " : "")source: \(provenance)\(entities) · trust \(record.trustScore.formatted(.number.precision(.fractionLength(2))))\(expiry)"
          )
          .font(.ottoMono(7.2))
          .foregroundStyle(palette.muted)
        }
        .padding(10)
        .background(palette.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
      }
    }
  }

  private func compactSection(
    title: String, entries: [CompactMemoryEntry], store: CompactMemoryStore
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader(title)
      if entries.isEmpty {
        Text("No entries yet. Agents propose additions; you accept them here.")
          .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
      }
      ForEach(entries) { entry in
        HStack(alignment: .top, spacing: 10) {
          VStack(alignment: .leading, spacing: 3) {
            Text(entry.text).font(.ottoDisplay(12)).foregroundStyle(palette.paper)
            Text(
              "\(entry.confidence.rawValue) · \(entry.source) · confirmed \(entry.lastConfirmedAt.formatted(date: .abbreviated, time: .omitted))"
            )
            .font(.ottoMono(7.5)).foregroundStyle(palette.muted)
          }
          Spacer()
          if entry.confidence != .confirmed {
            Button("Confirm") { lifecycle { _ = try await store.confirm(id: entry.id) } }
          }
          Button("Remove") { lifecycle { _ = try await store.remove(id: entry.id) } }
        }
        .padding(10)
        .background(palette.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
      }
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.ottoMono(7.5, weight: .black))
      .tracking(1.2)
      .foregroundStyle(palette.muted)
  }

  private func accept(_ proposal: CompactMemoryProposal) {
    lifecycle {
      let store =
        proposal.target == .personal ? services.personalMemory : services.operatingMemory
      _ = try await store.add(
        CompactMemoryEntry(
          id: proposal.id, text: proposal.text, source: proposal.source,
          confidence: .confirmed))
      _ = try await services.memoryInbox.remove(id: proposal.id)
    }
  }

  private func reject(_ proposal: CompactMemoryProposal) {
    lifecycle { _ = try await services.memoryInbox.remove(id: proposal.id) }
  }

  private func lifecycle(_ operation: @escaping () async throws -> Void) {
    Task {
      do {
        try await operation()
        notice = nil
      } catch {
        notice = error.localizedDescription
      }
      reload()
    }
  }

  private func reload() {
    Task {
      loadingRecords = true
      defer { loadingRecords = false }
      personalEntries = await services.personalMemory.entries()
      operatingEntries = await services.operatingMemory.entries()
      personalUsage = await services.personalMemory.usage()
      operatingUsage = await services.operatingMemory.usage()
      proposals = await services.memoryInbox.proposals()
      if let brain = services.brain {
        let all: [MemoryRecord]
        do { all = try await brain.allRecords() }
        catch { notice = "Could not refresh project memory: \(error.localizedDescription)"; return }
        graphRecords = all
        brainProposals = all.filter { $0.confidence != .confirmed && $0.isAvailable() }
        projectMemories = all.filter {
          $0.isAvailable() && [.project, .canvas].contains($0.scope)
        }.sorted { $0.updatedAt > $1.updatedAt }
        botMemories = all.filter {
          $0.isAvailable() && $0.scope == .agentRole
        }.sorted { $0.updatedAt > $1.updatedAt }
      }
    }
  }
}
