import Combine
import OttoCore
import OttoModels
import OttoRuntime
import SwiftUI

/// Agent node statuses for Automations, published only when a status actually changes, so
/// streaming text elsewhere in Otto doesn't redraw the flow.
@MainActor
final class AutomationLiveNodes: ObservableObject {
  @Published private(set) var statuses: [UUID: NodeStatus]
  private var subscription: AnyCancellable?

  init(store: CanvasStore) {
    statuses = Self.project(store.snapshot)
    subscription = store.$snapshot
      .map(Self.project)
      .removeDuplicates()
      .sink { [weak self] in self?.statuses = $0 }
  }

  private static func project(_ snapshot: WorkspaceSnapshot) -> [UUID: NodeStatus] {
    var statuses: [UUID: NodeStatus] = [:]
    for canvas in snapshot.canvases {
      for node in canvas.nodes where statuses[node.id] == nil { statuses[node.id] = node.status }
    }
    return statuses
  }
}

// The shared look for Automations' Flow view and the canvas builder: a solid board that stays
// crisp over theme artwork, compact node cards, and motion only where something is running.

/// A compact AI-agent node: logo, name, model, status, task and a footer line.
struct AutomationNodeCard: View {
  enum Badge: Equatable {
    case state(AutomationsView.StepState)
    case tag(String)
  }

  let title: String
  let subtitle: String
  let logo: AnyView
  let badge: Badge
  let task: String
  var taskIsPlaceholder = false
  var meta: String?
  var trailing: String?
  var childCount = 0
  var selected = false
  var dimmed = false
  @Environment(\.ottoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let width: CGFloat = 248

  private var live: Bool {
    if case .state(let state) = badge { return state.isLive }
    return false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        logo
          .frame(width: 26, height: 26)
          .background(palette.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .strokeBorder(palette.paper.opacity(0.09)))
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.ottoDisplay(13).weight(.semibold)).lineLimit(1)
          Text(subtitle).font(.ottoDisplay(11.5)).foregroundStyle(palette.muted).lineLimit(1)
        }
        Spacer(minLength: 4)
        switch badge {
        case .state(let state): AutomationStatusPill(state: state)
        case .tag(let text):
          Text(text).font(.ottoMicro).tracking(1.2).foregroundStyle(palette.muted)
            .padding(.top, 3)
        }
      }
      Text(task)
        .font(.ottoDisplay(12))
        .foregroundStyle(taskIsPlaceholder ? palette.amber : palette.paper.opacity(0.82))
        .lineLimit(2)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
      HStack(spacing: 6) {
        if let meta {
          Text(meta).font(.ottoMono(10.5)).foregroundStyle(palette.muted).lineLimit(1)
        }
        Spacer(minLength: 4)
        if let trailing {
          Text(trailing).font(.ottoDisplay(10.5)).foregroundStyle(palette.muted).lineLimit(1)
        }
        if childCount > 0 {
          HStack(spacing: 2) {
            Text("\(childCount)")
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
          }
          .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
          .help("\(childCount) agent\(childCount == 1 ? "" : "s") run after this")
        }
      }
    }
    .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 10)
    .frame(width: Self.width, alignment: .leading)
    .background(palette.raised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    .overlay(alignment: .bottom) { if live { progressSweep } }
    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .strokeBorder(
          selected || live ? palette.signal.opacity(live ? 0.75 : 1) : palette.paper.opacity(0.1),
          lineWidth: selected || live ? 1.5 : 1)
    )
    .background { if live { halo } }
    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
    .shadow(color: .black.opacity(selected ? 0.1 : 0.04), radius: selected ? 10 : 4, y: 3)
    .opacity(dimmed ? 0.6 : 1)
  }

  /// A soft ring that breathes while the agent works. Driven by a native repeating animation,
  /// not a per-frame redraw.
  private var halo: some View { AutomationHalo(color: palette.signal) }

  /// A light that sweeps along the bottom edge while the agent works.
  private var progressSweep: some View { AutomationSweep(color: palette.signal) }
}

private struct AutomationHalo: View {
  let color: Color
  @State private var breathing = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
      .stroke(color, lineWidth: 6)
      .padding(-3)
      .opacity(breathing ? 0.26 : 0.08)
      .animation(
        reduceMotion ? nil : .easeInOut(duration: 1.3).repeatForever(autoreverses: true),
        value: breathing
      )
      .onAppear { breathing = true }
      .allowsHitTesting(false)
  }
}

private struct AutomationSweep: View {
  let color: Color
  @State private var moving = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { proxy in
      LinearGradient(
        colors: [color.opacity(0), color, color.opacity(0)], startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: 120, height: 2)
      .offset(x: moving ? proxy.size.width : -120)
      .animation(
        reduceMotion ? nil : .linear(duration: 1.6).repeatForever(autoreverses: false),
        value: moving)
    }
    .frame(height: 2)
    .onAppear { moving = true }
    .allowsHitTesting(false)
  }
}

/// Status pill; the running ring spins so it is obvious something is happening.
struct AutomationStatusPill: View {
  let state: AutomationsView.StepState
  @Environment(\.ottoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static func color(_ state: AutomationsView.StepState, palette: OttoPalette) -> Color {
    switch state {
    case .running: palette.signal
    case .needsYou: palette.amber
    case .done: Color(red: 0.18, green: 0.54, blue: 0.34)
    case .failed: palette.red
    case .nothingNew, .paused, .idle: palette.muted
    }
  }

  var body: some View {
    let color = Self.color(state, palette: palette)
    HStack(spacing: 4) {
      if state == .running {
        AutomationSpinner(color: color, size: 9)
      } else {
        Image(systemName: state.symbol).font(.system(size: 8, weight: .bold))
      }
      Text(state.label).font(.ottoDisplay(11).weight(.medium))
    }
    .foregroundStyle(color)
    .padding(.horizontal, 7).padding(.vertical, 2.5)
    .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .fixedSize()
  }
}

/// A small ring that spins continuously while something runs.
struct AutomationSpinner: View {
  let color: Color
  var size: CGFloat = 9
  var lineWidth: CGFloat = 1.6
  @State private var spinning = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      Circle().stroke(color.opacity(0.22), lineWidth: lineWidth)
      Circle().trim(from: 0, to: 0.32)
        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(spinning ? 360 : 0))
        .animation(
          reduceMotion ? nil : .linear(duration: 0.85).repeatForever(autoreverses: false),
          value: spinning)
    }
    .frame(width: size, height: size)
    .onAppear { spinning = true }
    .accessibilityLabel("Running")
  }
}

/// Chips that insert `{{Step name}}` into a task, so a step can use earlier steps' output.
struct AutomationVariableChips: View {
  /// Earlier steps, nearest first.
  let steps: [String]
  let insert: (String) -> Void
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    if !steps.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Use output from an earlier step")
          .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
        FlowLayoutChips(spacing: 6) {
          chip("previous", label: "Previous step")
          ForEach(steps, id: \.self) { name in chip(name, label: name) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func chip(_ token: String, label: String) -> some View {
    Button {
      insert("{{\(token)}}")
    } label: {
      HStack(spacing: 4) {
        Text("{ }").font(.ottoMono(9.5, weight: .semibold))
        Text(label).font(.ottoDisplay(11.5).weight(.medium)).lineLimit(1)
      }
      .foregroundStyle(palette.signal)
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(palette.signal.opacity(0.1), in: Capsule())
      .overlay(Capsule().strokeBorder(palette.signal.opacity(0.25)))
    }
    .buttonStyle(.plain)
    .help("Insert {{\(token)}}. When the flow runs it becomes that step’s output.")
  }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayoutChips: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = min(proposal.width ?? 300, 10_000)
    var x: CGFloat = 0
    var y: CGFloat = 0
    var row: CGFloat = 0
    var widest: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        y += row + spacing
        x = 0
        row = 0
      }
      x += size.width + spacing
      row = max(row, size.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: min(widest, width), height: y + row)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var x = bounds.minX
    var y = bounds.minY
    var row: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        y += row + spacing
        x = bounds.minX
        row = 0
      }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      row = max(row, size.height)
    }
  }
}

/// The dotted canvas behind flows.
struct AutomationDotGrid: View {
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    dots.drawingGroup()
  }

  private var dots: some View {
    Canvas { context, size in
      let spacing: CGFloat = 20
      let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1.5, height: 1.5))
      var y: CGFloat = 0
      while y < size.height {
        var x: CGFloat = 0
        while x < size.width {
          context.fill(dot.offsetBy(dx: x, dy: y), with: .color(palette.paper.opacity(0.12)))
          x += spacing
        }
        y += spacing
      }
    }
  }
}

/// A connector between two cards. Live ones carry dashes that flow towards the child.
struct AutomationWire: View {
  let from: CGRect
  let to: CGRect
  let live: Bool
  let failedBranch: Bool
  @State private var flowing = false
  @Environment(\.ottoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let path = AutomationsView.wirePath(from: from, to: to)
    ZStack {
      if live {
        path.stroke(palette.signal.opacity(0.25), lineWidth: 1.5)
        FlowingDashes(path: path, phase: flowing ? -22 : 0)
          .fill(palette.signal)
          .animation(
            reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false),
            value: flowing
          )
          .onAppear { flowing = true }
      } else {
        path.stroke(
          failedBranch ? palette.red.opacity(0.55) : palette.paper.opacity(0.2),
          style: StrokeStyle(
            lineWidth: 1.4, lineCap: .round, lineJoin: .round,
            dash: failedBranch ? [3, 4] : []))
      }
      Circle()
        .fill(palette.raised)
        .overlay(
          Circle().strokeBorder(
            live ? palette.signal : palette.paper.opacity(0.3), lineWidth: 1.4)
        )
        .frame(width: 8, height: 8)
        .position(x: from.midX, y: from.maxY)
    }
  }
}

/// A dashed line whose dashes move as `phase` animates.
private struct FlowingDashes: Shape {
  let path: Path
  var phase: CGFloat
  var animatableData: CGFloat {
    get { phase }
    set { phase = newValue }
  }

  func path(in rect: CGRect) -> Path {
    path.strokedPath(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 6], dashPhase: phase))
  }
}

extension View {
  /// The solid board a flow sits on, so it reads crisply over any theme artwork.
  func automationBoard(_ palette: OttoPalette) -> some View {
    background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(palette.paper.opacity(0.08))
      )
      .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
      .shadow(color: .black.opacity(0.12), radius: 24, y: 10)
  }
}

// MARK: - Models

/// Which models an automation step can use. Live lists come from each harness when they
/// have loaded; until then (or when a harness can't be asked) the built-in list is offered.
enum AutomationModels {
  @MainActor static func options(
    _ provider: AgentProvider, accountID: UUID?, catalog: ProviderModelCatalogStore
  ) -> [AgentModel] {
    if let live = catalog.catalog(for: provider, accountID: accountID), !live.isEmpty {
      return live
    }
    return AgentModelCatalog.options(for: provider)
  }

  @MainActor static func displayName(
    _ id: String?, provider: AgentProvider, accountID: UUID?, catalog: ProviderModelCatalogStore
  ) -> String? {
    guard let id, !id.isEmpty else { return nil }
    return options(provider, accountID: accountID, catalog: catalog).first { $0.id == id }?
      .displayName ?? prettify(id)
  }

  /// Turns a model id like "claude-opus-5-5" or "gpt-6-sol" into "Opus 5.5" / "GPT-6 Sol".
  static func prettify(_ id: String) -> String {
    var parts =
      id.split(separator: "/").last.map(String.init)?.split(separator: "-")
      .map(String.init) ?? [id]
    if parts.first == "claude" { parts.removeFirst() }
    guard !parts.isEmpty else { return id }
    var words: [String] = []
    var index = 0
    while index < parts.count {
      let part = parts[index]
      if part.first?.isNumber == true, part.allSatisfy({ $0.isNumber || $0 == "." }) {
        var number = part
        while index + 1 < parts.count, parts[index + 1].allSatisfy(\.isNumber),
          parts[index + 1].count <= 2
        {
          number += "." + parts[index + 1]
          index += 1
        }
        if let last = words.last, last.uppercased() == last, last.count <= 4 {
          words[words.count - 1] = last + "-" + number
        } else {
          words.append(number)
        }
      } else if ["gpt", "gpt5", "o3", "k2"].contains(part.lowercased()) {
        words.append(part.uppercased())
      } else {
        words.append(part.prefix(1).uppercased() + part.dropFirst())
      }
      index += 1
    }
    return words.joined(separator: " ")
  }

  /// Hermes picks its model through its own profile, so Otto doesn't offer one.
  static func choosable(_ provider: AgentProvider) -> Bool {
    provider != .hermes && provider != .shell
  }
}

/// A model menu for one harness, with the harness default first.
struct AutomationModelPicker: View {
  let provider: AgentProvider
  let accountID: UUID?
  @Binding var model: String?
  @ObservedObject private var catalog = ProviderModelCatalogStore.shared
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    let options = AutomationModels.options(provider, accountID: accountID, catalog: catalog)
    let title =
      AutomationModels.displayName(
        model, provider: provider, accountID: accountID, catalog: catalog)
      ?? "Default for \(provider.rawValue)"
    Group {
      if AutomationModels.choosable(provider) {
        Menu {
          Button {
            model = nil
          } label: {
            if model == nil {
              Label("Default for \(provider.rawValue)", systemImage: "checkmark")
            } else {
              Text("Default for \(provider.rawValue)")
            }
          }
          if !options.isEmpty { Divider() }
          ForEach(options, id: \.id) { option in
            Button {
              model = option.id
            } label: {
              if option.id == model {
                Label(option.displayName, systemImage: "checkmark")
              } else {
                Text(option.displayName)
              }
            }
          }
        } label: {
          Text(title).font(.ottoDisplay(12.5).weight(.medium)).lineLimit(1)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
      } else {
        Text("Set by its \(provider.rawValue) profile")
          .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
      }
    }
    .onAppear { catalog.load(provider, accountID: accountID) }
    .onChange(of: provider) { _, next in catalog.load(next, accountID: accountID) }
  }
}

/// Every harness Otto can run an automation on, in a sensible order.
enum AutomationHarnesses {
  static let all: [AgentProvider] = [
    .claudeCode, .codex, .cursor, .openCode, .grok, .kimi, .hermes, .openAI,
  ]
}
