import AppKit
import Charts
import OttoDocuments
import OttoModels
import SwiftUI
import WebKit

enum WidgetScaffold {
  static let manifest = WidgetManifest(
    name: "New Widget",
    description: "A local-first custom Otto widget"
  )

  static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        :root { color-scheme: dark; font-family: Georgia, 'Times New Roman', serif; }
        body { margin: 0; min-height: 100vh; display: grid; place-items: center;
          color: #f5f0e6; background: #121715; }
        main { text-align: center; padding: 26px; }
        small { font: 700 10px/1.2 ui-monospace, monospace; letter-spacing: .18em; color: #88e6b4; }
        h1 { margin: 12px 0; font-size: 40px; font-weight: 400; letter-spacing: -.03em; }
        p { color: #a8afa9; font-size: 14px; }
      </style>
    </head>
    <body>
      <main>
        <small>CUSTOM OTTO WIDGET</small>
        <h1>New Widget</h1>
        <p>Edit this package to make it yours.</p>
      </main>
    </body>
    </html>
    """#
}

/// Colors one widget renders with: the manifest's custom theme when set, the app palette
/// otherwise. Custom text gets a derived muted tone so overrides stay one-line simple.
struct WidgetColors {
  let background: Color
  let accent: Color
  let text: Color
  let muted: Color

  init(theme: WidgetTheme?, palette: OttoPalette) {
    let custom = { (hex: String?) -> Color? in
      hex.flatMap(WidgetTheme.components).map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
    }
    background = custom(theme?.background) ?? Color(red: 0.07, green: 0.09, blue: 0.08)
    accent = custom(theme?.accent) ?? palette.signal
    if let text = custom(theme?.text) {
      self.text = text
      muted = text.opacity(0.55)
    } else {
      text = palette.paper
      muted = palette.muted
    }
  }
}

private struct LoadedWidget: Equatable {
  let manifest: WidgetManifest
  let html: String?
}

struct WidgetBody: View {
  @Environment(\.ottoPalette) private var palette
  let node: OttoNode
  let scale: Double
  let documents: WorkspaceDocumentStore
  let updateContent: (NodeContent) -> Void

  @State private var loaded: LoadedWidget?
  @State private var source = ""
  @State private var showingEditor = false
  @State private var errorMessage: String?
  @State private var revision = 0

  private var packagePath: String {
    guard case .widget(let path, _) = node.content else { return "" }
    return path
  }

  private var state: String {
    guard case .widget(_, let state) = node.content else { return "{}" }
    return state
  }

  var body: some View {
    let colors = WidgetColors(theme: loaded?.manifest.theme, palette: palette)
    ZStack(alignment: .topTrailing) {
      if let loaded {
        if let view = loaded.manifest.view {
          WidgetTypedBody(
            manifest: loaded.manifest, view: view, stateJSON: state, scale: scale,
            colors: colors)
        } else if let html = loaded.html {
          WidgetWebView(
            nodeID: node.id,
            html: html,
            manifest: loaded.manifest,
            state: state,
            revision: revision,
            saveState: saveState
          )
        } else {
          ContentUnavailableView(
            "Widget package is missing index.html",
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(palette.paper)
        }
      } else if let errorMessage {
        ContentUnavailableView(
          "Widget could not load",
          systemImage: "exclamationmark.triangle",
          description: Text(errorMessage)
        )
        .foregroundStyle(palette.paper)
      } else {
        ProgressView().controlSize(.small).tint(palette.signal)
      }

      HStack(spacing: 5) {
        if let schedule = loaded?.manifest.schedule, schedule.enabled {
          Text(schedule.cron.map { "CRON \($0)" } ?? "LOCAL · \(schedule.intervalSeconds)S")
            .font(.ottoMono(max(6, 7 * scale), weight: .black))
            .foregroundStyle(colors.accent)
        }
        widgetButton("arrow.clockwise", help: "Reload widget package") { load() }
        widgetButton("chevron.left.forwardslash.chevron.right", help: "Edit widget source") {
          showingEditor = true
        }
        widgetButton("folder", help: "Reveal widget package") { revealPackage() }
      }
      .padding(8 * scale)
    }
    .background(colors.background)
    .task(id: packagePath) { await loadPackage() }
    .sheet(isPresented: $showingEditor) {
      WidgetSourceEditor(
        source: $source,
        packagePath: packagePath,
        save: { Task { await saveSource() } }
      )
      .environment(\.ottoPalette, palette)
    }
  }

  private func widgetButton(_ symbol: String, help: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: max(8, 9 * scale), weight: .semibold))
        .frame(width: max(22, 25 * scale), height: max(22, 25 * scale))
        .background(palette.ink.opacity(0.72), in: Circle())
        .foregroundStyle(palette.paper)
    }
    .buttonStyle(.plain)
    .help(help)
  }

  private func load() {
    Task { await loadPackage() }
  }

  private func loadPackage() async {
    do {
      let manifestText = try await documents.read(relativePath: "\(packagePath)/widget.json")
      let manifest = try JSONDecoder().decode(WidgetManifest.self, from: Data(manifestText.utf8))
      if manifest.view != nil {
        // Typed widgets render natively; the editable source is the data script, if any.
        if let script = manifest.job?.script {
          source = (try? await documents.read(relativePath: "\(packagePath)/\(script)")) ?? ""
        } else {
          source = ""
        }
        loaded = LoadedWidget(manifest: manifest, html: nil)
      } else {
        let html = try await documents.read(relativePath: "\(packagePath)/index.html")
        guard manifest.entry == "index.html" else {
          throw WidgetError.unsupportedEntry(manifest.entry)
        }
        source = html
        loaded = LoadedWidget(manifest: manifest, html: html)
      }
      revision += 1
      errorMessage = nil
    } catch {
      loaded = nil
      errorMessage = error.localizedDescription
    }
  }

  private func saveSource() async {
    do {
      if let script = loaded?.manifest.job?.script, loaded?.manifest.view != nil {
        try await documents.replace(relativePath: "\(packagePath)/\(script)", text: source)
      } else {
        try await documents.replace(relativePath: "\(packagePath)/index.html", text: source)
      }
      showingEditor = false
      await loadPackage()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func saveState(_ value: String) {
    if usesDataRuntimeState {
      var runtime = WidgetRuntimeState.decode(from: state)
      runtime.widgetState = value
      updateContent(.widget(packagePath: packagePath, state: runtime.encoded()))
    } else {
      updateContent(.widget(packagePath: packagePath, state: value))
    }
  }

  private func revealPackage() {
    let url = URL(fileURLWithPath: documents.rootPath).appendingPathComponent(packagePath)
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private var usesDataRuntimeState: Bool {
    guard loaded?.manifest.job != nil || loaded?.manifest.view != nil else {
      return WidgetRuntimeState.decode(from: state).lastRunAt != nil
    }
    return true
  }
}

/// Native renderer for typed widgets: Otto owns the presentation (big number, line, bar, pie,
/// table) and the package's data job owns the payload.
private struct WidgetTypedBody: View {
  let manifest: WidgetManifest
  let view: WidgetViewDescriptor
  let stateJSON: String
  let scale: Double
  let colors: WidgetColors

  private var alert: Color { Color(red: 0.94, green: 0.55, blue: 0.45) }

  var body: some View {
    let state = WidgetRuntimeState.decode(from: stateJSON)
    let payload = state.payload.flatMap { try? WidgetPayload.parse(json: $0, kind: view.kind) }
    VStack(alignment: .leading, spacing: 10 * scale) {
      HStack {
        Text("\(view.kind.rawValue.uppercased()) · LIVE DATA")
          .font(.ottoMono(max(6, 7 * scale), weight: .black))
          .tracking(1.4)
          .foregroundStyle(colors.accent)
        Spacer()
      }
      if let payload {
        content(payload: payload, history: state.history)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        placeholder(state: state)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      footer(state: state)
    }
    .padding(16 * scale)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private func content(payload: WidgetPayload, history: [WidgetHistorySample]) -> some View {
    switch payload {
    case .number(let number):
      WidgetNumberView(
        number: number, unit: number.unit ?? view.unit, history: history, scale: scale,
        alert: alert, colors: colors)
    case .series(let series):
      WidgetSeriesView(kind: view.kind, points: series.points, scale: scale, colors: colors)
    case .table(let table):
      WidgetTableView(table: table, scale: scale, colors: colors)
    }
  }

  private func placeholder(state: WidgetRuntimeState) -> some View {
    VStack(spacing: 8 * scale) {
      if let error = state.lastError {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 18 * scale))
          .foregroundStyle(alert)
        Text(error)
          .font(.ottoMono(max(7, 8 * scale)))
          .foregroundStyle(alert)
          .lineLimit(3)
          .multilineTextAlignment(.center)
      } else {
        ProgressView().controlSize(.small).tint(colors.accent)
        Text("WAITING FOR FIRST RUN")
          .font(.ottoMono(max(6, 7 * scale), weight: .bold))
          .tracking(1.4)
          .foregroundStyle(colors.muted)
      }
    }
    .padding(12 * scale)
  }

  @ViewBuilder
  private func footer(state: WidgetRuntimeState) -> some View {
    HStack(spacing: 6 * scale) {
      if state.lastError != nil, state.payload != nil {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: max(6, 7 * scale)))
          .foregroundStyle(alert)
          .help(state.lastError ?? "")
      }
      if let at = state.lastSuccessAt {
        Text("UPDATED")
          .font(.ottoMono(max(6, 7 * scale), weight: .bold))
          .foregroundStyle(colors.muted)
        Text(at, style: .relative)
          .font(.ottoMono(max(6, 7 * scale)))
          .foregroundStyle(colors.muted)
        Text("AGO")
          .font(.ottoMono(max(6, 7 * scale), weight: .bold))
          .foregroundStyle(colors.muted)
      }
      Spacer()
    }
  }
}

private struct WidgetNumberView: View {
  let number: WidgetNumberPayload
  let unit: String?
  let history: [WidgetHistorySample]
  let scale: Double
  let alert: Color
  let colors: WidgetColors

  private var delta: (text: String, positive: Bool)? {
    guard history.count >= 2 else { return nil }
    let previous = history[history.count - 2].value
    let change = number.value - previous
    guard change != 0 else { return nil }
    let arrow = change > 0 ? "↗" : "↘"
    if previous != 0 {
      let percent = abs(change / previous * 100)
      let digits = percent < 10 ? 1 : 0
      return (
        "\(arrow) \(percent.formatted(.number.precision(.fractionLength(digits))))%",
        change > 0
      )
    }
    let formatted = abs(change).formatted(.number.precision(.fractionLength(0...1)))
    return ("\(arrow) \(formatted)", change > 0)
  }

  private var formattedValue: String {
    if abs(number.value) >= 10_000 {
      return number.value.formatted(
        .number.notation(.compactName).precision(.significantDigits(1...4)))
    }
    return number.value.formatted(.number.precision(.fractionLength(0...1)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6 * scale) {
      Spacer(minLength: 0)
      Text(formattedValue)
        .font(.ottoDisplay(52 * scale))
        .foregroundStyle(colors.text)
        .lineLimit(1)
        .minimumScaleFactor(0.4)
      HStack(spacing: 8 * scale) {
        if let delta {
          Text(delta.text)
            .font(.ottoMono(max(8, 10 * scale), weight: .bold))
            .foregroundStyle(delta.positive ? colors.accent : alert)
        }
        if let caption = number.label ?? unit {
          Text(caption.uppercased())
            .font(.ottoMono(max(7, 8 * scale)))
            .tracking(1.2)
            .foregroundStyle(colors.muted)
            .lineLimit(1)
        }
      }
      if history.count >= 2 {
        Chart(history, id: \.at) { sample in
          AreaMark(x: .value("Time", sample.at), y: .value("Value", sample.value))
            .interpolationMethod(.monotone)
            .foregroundStyle(
              LinearGradient(
                colors: [colors.accent.opacity(0.35), colors.accent.opacity(0.02)],
                startPoint: .top, endPoint: .bottom))
          LineMark(x: .value("Time", sample.at), y: .value("Value", sample.value))
            .interpolationMethod(.monotone)
            .foregroundStyle(colors.accent)
            .lineStyle(StrokeStyle(lineWidth: max(1, 1.5 * scale)))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 44 * scale)
      }
      Spacer(minLength: 0)
    }
  }
}

private struct WidgetSeriesView: View {
  let kind: WidgetViewKind
  let points: [WidgetSeriesPoint]
  let scale: Double
  let colors: WidgetColors

  private var indexed: [(offset: Int, element: WidgetSeriesPoint)] {
    Array(points.enumerated())
  }

  private var sliceColors: [Color] {
    indexed.map { item in
      Color(
        hue: (0.38 + Double(item.offset) * 0.61).truncatingRemainder(dividingBy: 1),
        saturation: 0.42,
        brightness: 0.82
      )
    }
  }

  var body: some View {
    switch kind {
    case .pie:
      Chart(indexed, id: \.offset) { item in
        SectorMark(
          angle: .value("Value", item.element.value),
          innerRadius: .ratio(0.55),
          angularInset: 1.5
        )
        .foregroundStyle(by: .value("Label", item.element.label))
        .cornerRadius(3)
      }
      .chartForegroundStyleScale(range: sliceColors)
      .chartLegend(position: .trailing, alignment: .center)
    case .bar:
      Chart(indexed, id: \.offset) { item in
        BarMark(
          x: .value("Label", item.element.label),
          y: .value("Value", item.element.value)
        )
        .foregroundStyle(colors.accent.opacity(0.85))
        .cornerRadius(3)
      }
    default:
      Chart(indexed, id: \.offset) { item in
        AreaMark(
          x: .value("Label", item.element.label),
          y: .value("Value", item.element.value)
        )
        .interpolationMethod(.monotone)
        .foregroundStyle(
          LinearGradient(
            colors: [colors.accent.opacity(0.3), colors.accent.opacity(0.02)],
            startPoint: .top, endPoint: .bottom))
        LineMark(
          x: .value("Label", item.element.label),
          y: .value("Value", item.element.value)
        )
        .interpolationMethod(.monotone)
        .foregroundStyle(colors.accent)
        .lineStyle(StrokeStyle(lineWidth: max(1, 2 * scale)))
      }
    }
  }
}

private struct WidgetTableView: View {
  let table: WidgetTablePayload
  let scale: Double
  let colors: WidgetColors

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8 * scale) {
        ForEach(Array(table.columns.enumerated()), id: \.offset) { column in
          Text(column.element.uppercased())
            .font(.ottoMono(max(6, 7 * scale), weight: .black))
            .tracking(1.1)
            .foregroundStyle(colors.muted)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.vertical, 6 * scale)
      Rectangle().fill(colors.text.opacity(0.12)).frame(height: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(table.rows.enumerated()), id: \.offset) { row in
            HStack(spacing: 8 * scale) {
              ForEach(Array(row.element.enumerated()), id: \.offset) { cell in
                Text(cell.element)
                  .font(.ottoMono(max(7, 8.5 * scale)))
                  .foregroundStyle(colors.text)
                  .lineLimit(1)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
            .padding(.vertical, 5 * scale)
            .background(
              row.offset.isMultiple(of: 2) ? Color.clear : colors.text.opacity(0.03))
          }
        }
      }
    }
  }
}

private enum WidgetError: LocalizedError {
  case unsupportedEntry(String)
  var errorDescription: String? {
    switch self {
    case .unsupportedEntry(let entry):
      "Widget entry '\(entry)' is not supported yet. Use index.html."
    }
  }
}

private struct WidgetSourceEditor: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.ottoPalette) private var palette
  @Binding var source: String
  let packagePath: String
  let save: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("WIDGET SOURCE").font(.ottoMono(10, weight: .black)).tracking(1.8)
            .foregroundStyle(palette.signal)
          Text(packagePath).font(.ottoMono(8)).foregroundStyle(palette.muted)
        }
        Spacer()
        Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(palette.muted)
        Button("Save & run", action: save)
          .buttonStyle(.borderedProminent).tint(palette.signal).foregroundStyle(palette.ink)
      }
      TextEditor(text: $source)
        .font(.system(size: 12, design: .monospaced))
        .scrollContentBackground(.hidden)
        .padding(10)
        .background(palette.ink, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.paper.opacity(0.1)))
    }
    .padding(20)
    .frame(minWidth: 760, minHeight: 560)
    .background(palette.raised)
  }
}

private struct WidgetWebView: NSViewRepresentable {
  let nodeID: UUID
  let html: String
  let manifest: WidgetManifest
  let state: String
  let revision: Int
  let saveState: (String) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(saveState: saveState) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(context.coordinator, name: "ottoWidget")
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.setValue(false, forKey: "drawsBackground")
    load(view)
    context.coordinator.startSchedule(for: view, schedule: manifest.schedule)
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    let stateChanged = context.coordinator.state != state
    if context.coordinator.revision != revision {
      context.coordinator.revision = revision
      context.coordinator.state = state
      load(view)
      return
    }
    if stateChanged {
      context.coordinator.state = state
      let update = dataUpdateJavaScript
      Task { @MainActor in _ = try? await view.evaluateJavaScript(update) }
    }
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    coordinator.scheduleTask?.cancel()
    view.configuration.userContentController.removeScriptMessageHandler(forName: "ottoWidget")
  }

  private func load(_ view: WKWebView) {
    let bridge = """
      <script>
        (() => {
          const initialState = \(safeWidgetStateJSON);
          window.__ottoWidgetData = \(safeDataJSON);
          window.otto = Object.freeze({
            widgetId: \(javascriptString(nodeID.uuidString.lowercased())),
            state: initialState,
            get data() { return window.__ottoWidgetData; },
            saveState(next) {
              window.webkit.messageHandlers.ottoWidget.postMessage({type: 'saveState', state: next});
            }
          });
          // Widgets written before the rename use window.muse and muse:* events.
          window.muse = window.otto;
        })();
      </script>
      """
    let policy = contentSecurityPolicy
    // The app's motion tiers ride along as CSS variables so a widget can move at its pace.
    let motionTokens = "<style>\(OttoMotion.cssTokens)</style>"
    let secured = html.replacingOccurrences(
      of: "<head>",
      with:
        "<head><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">\(motionTokens)\(bridge)",
      options: [.caseInsensitive]
    )
    view.loadHTMLString(secured, baseURL: nil)
  }

  private var runtimeState: WidgetRuntimeState {
    let decoded = WidgetRuntimeState.decode(from: state)
    if manifest.job != nil || decoded.lastRunAt != nil {
      return decoded
    }
    return WidgetRuntimeState(widgetState: state)
  }

  private var safeWidgetStateJSON: String {
    let source =
      runtimeState.widgetState
      ?? (manifest.job == nil && runtimeState.lastRunAt == nil ? state : "{}")
    return safeJSON(source, fallback: "{}")
  }

  private var safeDataJSON: String {
    safeJSON(runtimeState.payload ?? "null", fallback: "null")
  }

  private var dataUpdateJavaScript: String {
    "window.__ottoWidgetData = \(safeDataJSON); "
      + "for (const name of ['otto:data', 'muse:data']) "
      + "window.dispatchEvent(new CustomEvent(name, {detail: window.__ottoWidgetData}));"
  }

  private func safeJSON(_ value: String, fallback: String) -> String {
    guard let data = value.data(using: .utf8),
      (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    else { return fallback }
    return value.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
  }

  private var contentSecurityPolicy: String {
    let allowed = manifest.permissions.network.compactMap { value -> String? in
      guard let url = URL(string: value), let scheme = url.scheme,
        ["https", "http"].contains(scheme), let host = url.host
      else { return nil }
      return "\(scheme)://\(host)"
    }
    let connect = allowed.isEmpty ? "'none'" : allowed.joined(separator: " ")
    return
      "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob: \(allowed.joined(separator: " ")); connect-src \(connect); font-src data:;"
  }

  private func javascriptString(_ value: String) -> String {
    let data = try? JSONEncoder().encode(value)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
  }

  final class Coordinator: NSObject, WKScriptMessageHandler {
    var revision = 0
    var state = ""
    var scheduleTask: Task<Void, Never>?
    let saveState: (String) -> Void

    init(saveState: @escaping (String) -> Void) { self.saveState = saveState }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard let body = message.body as? [String: Any], body["type"] as? String == "saveState",
        let value = body["state"], JSONSerialization.isValidJSONObject(value),
        let data = try? JSONSerialization.data(withJSONObject: value),
        let json = String(data: data, encoding: .utf8)
      else { return }
      Task { @MainActor in self.saveState(json) }
    }

    func startSchedule(for webView: WKWebView, schedule: WidgetSchedule?) {
      scheduleTask?.cancel()
      guard let schedule, schedule.enabled else { return }
      let seconds = max(15, schedule.intervalSeconds)
      scheduleTask = Task { @MainActor [weak webView] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(seconds))
          guard !Task.isCancelled else { return }
          _ = try? await webView?.evaluateJavaScript(
            "for (const name of ['otto:schedule', 'muse:schedule']) "
              + "window.dispatchEvent(new CustomEvent(name, {detail:{trigger:'interval'}}))"
          )
        }
      }
    }
  }
}
