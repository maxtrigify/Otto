import OttoRuntime
import SwiftUI

/// An inline, provider-independent view of actual child events. The animated surface is small:
/// transcript text and expanded logs do not re-render at animation frame rate.
struct AgentChildrenPanel: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let children: [AgentChildRun]
  let parentName: String
  var scale: Double = 1
  @State private var expanded = true
  @State private var selectedID: String?
  @State private var showAll = false

  init(
    children: [AgentChildRun], parentName: String, scale: Double = 1,
    initiallyExpanded: Bool = true, initiallySelectedID: String? = nil
  ) {
    self.children = children
    self.parentName = parentName
    self.scale = scale
    _expanded = State(initialValue: initiallyExpanded)
    _selectedID = State(initialValue: initiallySelectedID)
  }

  private var visible: [AgentChildRun] { showAll ? children : Array(children.prefix(8)) }
  private var running: Bool { children.contains { $0.state == .working || $0.state == .starting } }
  private var rowHeight: CGFloat { max(32, 40 * scale) }
  private var gap: CGFloat { max(4, 7 * scale) }
  private var labelSize: CGFloat { max(11, 14 * scale) }
  private var selection: AgentChildRun? { children.first { $0.id == selectedID } }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded.toggle() }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "point.3.connected.trianglepath.dotted")
          Text(children.contains { $0.kind == "command" } ? "Agents & tasks" : "Agents")
            .fontWeight(.semibold)
          Text(summary).foregroundStyle(palette.muted).lineLimit(2)
          Spacer(minLength: 4)
          Text("\(children.reduce(0) { $0 + $1.toolCount }) actions")
            .foregroundStyle(palette.muted).font(.system(size: max(10, labelSize - 2)))
            .fixedSize()
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .medium)).frame(width: 14)
        }
        .font(.system(size: labelSize))
        .foregroundStyle(palette.paper)
        .padding(max(10, 16 * scale))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(expanded ? "Collapse" : "Expand") agents. \(summary)")
      if expanded {
        Divider().overlay(palette.muted.opacity(0.15))
        ViewThatFits(in: .horizontal) {
          branchList(compact: false).frame(minWidth: 560)
          branchList(compact: true)
        }
        if children.count > 8 {
          Button(showAll ? "Show fewer agents" : "Show all \(children.count) agents") {
            showAll.toggle()
          }
          .buttonStyle(.plain).font(.system(size: labelSize - 1))
          .foregroundStyle(palette.cyan).padding(.horizontal, 16).padding(.bottom, 12)
        }
        if let selection { details(selection).transition(.opacity) }
      }
    }
    .background(palette.ink.opacity(0.35))
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.muted.opacity(0.22), lineWidth: 1))
    .accessibilityElement(children: .contain)
  }

  private func branchList(compact: Bool) -> some View {
    let height = compact ? max(46, 56 * scale) : rowHeight
    return HStack(spacing: 0) {
      Text(compact ? "Agent" : parentName)
        .font(.system(size: max(10, labelSize - 2), weight: .semibold))
        .foregroundStyle(palette.paper).lineLimit(2)
        .frame(width: compact ? 42 : max(48, 80 * scale))
      branches(height: height).frame(width: compact ? 24 : max(24, 48 * scale))
      VStack(spacing: gap) {
        ForEach(visible) { child in childRow(child, compact: compact) }
      }
    }
    .padding(max(10, 16 * scale))
  }

  private var summary: String {
    let states: [(AgentChildRunState, String)] = [
      (.working, "running"), (.starting, "starting"), (.waiting, "waiting"), (.done, "done"),
      (.failed, "failed"), (.stopped, "stopped"), (.unknown, "unconfirmed"),
    ]
    return states.compactMap { state, label in
      let count = children.filter { $0.state == state }.count
      return count == 0 ? nil : "\(count) \(label)"
    }.joined(separator: " · ")
  }

  private func branches(height: CGFloat) -> some View {
    TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !running)) { time in
      Canvas { context, size in
        let phase = reduceMotion ? 0 : -time.date.timeIntervalSinceReferenceDate * 18
        for (index, child) in visible.enumerated() {
          let endY = height / 2 + CGFloat(index) * (height + gap)
          var path = Path()
          path.move(to: CGPoint(x: 0, y: size.height / 2))
          path.addCurve(
            to: CGPoint(x: size.width - 2, y: endY),
            control1: CGPoint(x: size.width * 0.5, y: size.height / 2),
            control2: CGPoint(x: size.width * 0.5, y: endY))
          context.stroke(path, with: .color(palette.muted.opacity(0.25)), lineWidth: 1)
          if child.state == .working || child.state == .starting {
            context.stroke(
              path, with: .color(.blue.opacity(0.85)),
              style: StrokeStyle(lineWidth: 1.3, dash: [3, 5], dashPhase: phase))
          }
          context.fill(
            Path(ellipseIn: CGRect(x: size.width - 4, y: endY - 2, width: 4, height: 4)),
            with: .color(color(child.state)))
        }
      }
    }
    .frame(height: CGFloat(visible.count) * (height + gap) - gap)
    .accessibilityHidden(true)
  }

  private func childRow(_ child: AgentChildRun, compact: Bool) -> some View {
    Button {
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
        selectedID = selectedID == child.id ? nil : child.id
      }
    } label: {
      HStack(spacing: 8) {
        statusIcon(child.state).frame(width: 18, height: 18)
        if compact {
          VStack(alignment: .leading, spacing: 3) {
            Text(child.name).fontWeight(.semibold).lineLimit(1)
            Text(child.activity).font(.system(size: max(10, labelSize - 2)))
              .foregroundStyle(child.state == .failed ? palette.red : palette.muted)
              .lineLimit(1).truncationMode(.middle)
          }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Text(child.name).fontWeight(.semibold).lineLimit(1)
            .frame(width: max(70, 100 * scale), alignment: .leading)
          Text(child.activity)
            .foregroundStyle(child.state == .failed ? palette.red : palette.muted)
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Image(systemName: selectedID == child.id ? "chevron.down" : "chevron.right")
          .font(.system(size: 10)).foregroundStyle(palette.muted).frame(width: 14)
      }
      .font(.system(size: labelSize))
      .foregroundStyle(palette.paper)
      .padding(.horizontal, 10)
      .frame(height: compact ? max(46, 56 * scale) : rowHeight)
      .background(selectedID == child.id ? palette.raised : palette.surface)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("\(child.name): \(child.activity)")
    .accessibilityLabel("\(child.name), \(stateLabel(child.state)). \(child.activity)")
    .accessibilityHint("Show task and reported activity")
  }

  @ViewBuilder private func statusIcon(_ state: AgentChildRunState) -> some View {
    if (state == .working || state == .starting) && !reduceMotion {
      TimelineView(.animation(minimumInterval: 1.0 / 24)) { time in
        Circle().trim(from: 0.15, to: 0.85).stroke(
          color(state), style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )
        .frame(width: 13, height: 13)
        .rotationEffect(.degrees(time.date.timeIntervalSinceReferenceDate * 240))
      }
      .accessibilityHidden(true)
    } else {
      Image(systemName: icon(state)).foregroundStyle(color(state))
    }
  }

  private func details(_ child: AgentChildRun) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Divider().overlay(palette.muted.opacity(0.15))
      HStack {
        Text("\(child.name) · \(stateLabel(child.state))").fontWeight(.semibold)
        Spacer()
        if let model = child.model { Text(model).foregroundStyle(palette.muted) }
        TimelineView(.periodic(from: .now, by: 1)) { time in
          Text(duration(child, now: time.date)).monospacedDigit().foregroundStyle(palette.muted)
        }
      }
      if let task = child.task { Text(task).foregroundStyle(palette.muted).textSelection(.enabled) }
      if let parentID = child.parentID, let parent = children.first(where: { $0.id == parentID }) {
        Text("Delegated by \(parent.name)").foregroundStyle(palette.muted)
      }
      if child.state == .failed || child.state == .unknown || child.state == .stopped {
        Text(
          child.state == .unknown
            ? "The parent run ended without a confirmed child result." : child.activity
        )
        .foregroundStyle(child.state == .failed ? palette.red : palette.muted)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(color(child.state).opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
      }
      if let log = child.activityLog, !log.isEmpty {
        ForEach(Array(log.suffix(12).enumerated()), id: \.offset) { _, entry in
          Text(entry).font(.system(size: max(10, labelSize - 2), design: .monospaced))
            .foregroundStyle(palette.muted).textSelection(.enabled)
        }
      } else {
        Text("No detailed activity reported by this harness yet.").foregroundStyle(palette.muted)
      }
    }
    .font(.system(size: labelSize - 1)).foregroundStyle(palette.paper)
    .padding([.horizontal, .bottom], max(10, 16 * scale))
  }

  private func duration(_ child: AgentChildRun, now: Date) -> String {
    let seconds = max(0, Int((child.completedAt ?? now).timeIntervalSince(child.startedAt)))
    return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
  }
  private func stateLabel(_ state: AgentChildRunState) -> String {
    switch state {
    case .working: "Running"
    case .starting: "Starting"
    case .waiting: "Waiting"
    case .done: "Done"
    case .failed: "Failed"
    case .stopped: "Stopped"
    case .unknown: "Unconfirmed"
    }
  }
  private func color(_ state: AgentChildRunState) -> Color {
    switch state {
    case .done: .green
    case .failed: palette.red
    case .working, .starting: .blue
    case .waiting: palette.amber
    case .stopped, .unknown: palette.muted
    }
  }
  private func icon(_ state: AgentChildRunState) -> String {
    switch state {
    case .done: "checkmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .waiting: "pause.circle"
    case .stopped: "stop.circle"
    case .unknown: "questionmark.circle"
    case .working, .starting: "circle.dotted"
    }
  }
}
