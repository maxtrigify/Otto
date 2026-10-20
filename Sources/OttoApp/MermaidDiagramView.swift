import AppKit
import Foundation
import SwiftUI
import WebKit

enum MermaidRenderPolicy {
  static let maximumSourceBytes = 65_536
  static let minimumHeight: CGFloat = 88
  static let maximumHeight: CGFloat = 1_200
  static func previewHeightLimit(viewportHeight: CGFloat) -> CGFloat {
    guard viewportHeight.isFinite, viewportHeight > 0 else { return 320 }
    return max(44, viewportHeight * 0.4 - 36)
  }

  static let renderTimeout: Duration = .seconds(4)

  static func accepts(_ source: String) -> Bool {
    !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && source.utf8.count <= maximumSourceBytes
  }

  static func clampedHeight(_ value: Double) -> CGFloat? {
    guard value.isFinite, value > 0 else { return nil }
    return min(maximumHeight, max(minimumHeight, CGFloat(value)))
  }
}

enum MermaidBridgeMessage: Equatable {
  case ready
  case rendered
  case height(CGFloat)
  case error(String)

  init?(body: Any) {
    guard let payload = body as? [String: Any], let type = payload["type"] as? String else {
      return nil
    }
    switch type {
    case "ready":
      self = .ready
    case "rendered":
      self = .rendered
    case "height":
      let rawValue = (payload["value"] as? NSNumber)?.doubleValue
      guard let rawValue, let height = MermaidRenderPolicy.clampedHeight(rawValue) else {
        return nil
      }
      self = .height(height)
    case "error":
      let message = (payload["message"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let detail = message.flatMap { $0.isEmpty ? nil : $0 } ?? "The diagram could not be rendered."
      self = .error(String(detail.prefix(300)))
    default:
      return nil
    }
  }
}

struct MermaidDiagramView: View {
  @Environment(\.ottoPalette) private var palette
  let source: String
  let scale: Double
  var allowsExpansion = true

  @State private var renderedHeight: CGFloat = 180
  @State private var renderError: String?
  @State private var showingSource = false
  @State private var rendered = false
  @State private var copied = false
  @State private var expanded = false
  @State private var previewHeightLimit: CGFloat = 320
  @State private var zoom: Double = 1

  private var sourceIsValid: Bool { MermaidRenderPolicy.accepts(source) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider().overlay(palette.paper.opacity(0.08))
      if showingSource || renderError != nil || !sourceIsValid {
        sourceFallback
      } else {
        MermaidDiagramWebView(
          source: source,
          theme: MermaidDiagramTheme(palette: palette),
          interactive: !allowsExpansion,
          zoom: zoom,
          viewportChanged: {
            previewHeightLimit = MermaidRenderPolicy.previewHeightLimit(viewportHeight: $0)
          },
          heightChanged: { renderedHeight = $0 },
          rendered: {
            rendered = true
            renderError = nil
          },
          failed: { message in
            renderError = message
            rendered = false
          }
        )
        .frame(height: allowsExpansion ? min(renderedHeight, previewHeightLimit) : nil)
        .frame(maxHeight: allowsExpansion ? nil : .infinity)
        .opacity(rendered ? 1 : 0.35)
        .overlay {
          if !rendered {
            ProgressView()
              .controlSize(.small)
              .tint(palette.muted)
          }
        }
        .accessibilityLabel("Mermaid diagram")
      }
    }
    .background(palette.ink.opacity(0.6), in: RoundedRectangle(cornerRadius: 9 * scale))
    .overlay(
      RoundedRectangle(cornerRadius: 9 * scale)
        .stroke(palette.paper.opacity(0.08), lineWidth: 1)
    )
    .onChange(of: source) { _, _ in resetRenderer() }
    .sheet(isPresented: $expanded) {
      VStack(alignment: .trailing, spacing: 12) {
        Button("Done") { expanded = false }
          .keyboardShortcut(.cancelAction)
        MermaidDiagramView(source: source, scale: 1.25, allowsExpansion: false)
      }
      .padding(20)
      .frame(minWidth: 720, idealWidth: 960, minHeight: 540, idealHeight: 720)
      .background(palette.workspaceSurface)
      .environment(\.ottoPalette, palette)
    }
  }

  private var header: some View {
    HStack(spacing: 8 * scale) {
      Text("DIAGRAM")
        .font(.ottoMono(max(5.5, 6.5 * scale), weight: .black))
        .tracking(0.8 * scale)
        .foregroundStyle(palette.muted)
      Spacer()
      if allowsExpansion {
        Button {
          expanded = true
        } label: {
          Label("Expand diagram", systemImage: "arrow.up.left.and.arrow.down.right")
            .font(.ottoDisplay(max(10, 10 * scale)))
        }
        .buttonStyle(.plain)
        .help("Expand diagram")
        .accessibilityLabel("Expand diagram")
      }
      if !allowsExpansion {
        Button("Zoom out", systemImage: "minus.magnifyingglass") { zoom = max(0.25, zoom / 1.25) }
          .labelStyle(.iconOnly)
          .disabled(zoom <= 0.25)
        Button("Fit") { zoom = 1 }
        Button("Zoom in", systemImage: "plus.magnifyingglass") { zoom = min(8, zoom * 1.25) }
          .labelStyle(.iconOnly)
          .disabled(zoom >= 8)
      }
      Button {
        showingSource.toggle()
      } label: {
        Image(
          systemName: showingSource
            ? "rectangle.on.rectangle.slash" : "chevron.left.forwardslash.chevron.right"
        )
        .font(.system(size: max(7, 8 * scale), weight: .medium))
        .foregroundStyle(showingSource ? palette.signal : palette.muted)
      }
      .buttonStyle(.plain)
      .help(showingSource ? "Show diagram" : "Show diagram source")
      .accessibilityLabel(showingSource ? "Show diagram" : "Show diagram source")
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
        copied = true
        Task {
          try? await Task.sleep(for: .seconds(1.4))
          copied = false
        }
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .font(.system(size: max(7, 8 * scale), weight: .medium))
          .foregroundStyle(copied ? palette.signal : palette.muted)
      }
      .buttonStyle(.plain)
      .help("Copy diagram source")
      .accessibilityLabel("Copy diagram source")
    }
    .padding(.horizontal, 11 * scale)
    .padding(.vertical, 6 * scale)
    .background(palette.paper.opacity(0.045))
  }

  private var sourceFallback: some View {
    VStack(alignment: .leading, spacing: 7 * scale) {
      if let message = fallbackMessage {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.ottoDisplay(max(8, 9.5 * scale)))
          .foregroundStyle(palette.amber)
          .fixedSize(horizontal: false, vertical: true)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        Text(source)
          .font(.ottoMono(max(8, 9.5 * scale)))
          .foregroundStyle(palette.paper.opacity(0.92))
          .lineSpacing(2.5 * scale)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(11 * scale)
  }

  private var fallbackMessage: String? {
    if !sourceIsValid {
      return source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "The diagram source is empty."
        : "The diagram is too large to render safely."
    }
    return renderError.map { "Couldn’t render this diagram: \($0)" }
  }

  private func resetRenderer() {
    renderedHeight = 180
    renderError = nil
    rendered = false
  }
}

private struct MermaidDiagramTheme: Codable, Equatable, Hashable {
  let background: String
  let foreground: String
  let surface: String
  let raised: String
  let muted: String
  let border: String

  init(palette: OttoPalette) {
    background = Self.cssColor(palette.ink)
    foreground = Self.cssColor(palette.paper)
    surface = Self.cssColor(palette.raised)
    raised = Self.cssColor(palette.surface)
    muted = Self.cssColor(palette.muted)
    border = Self.cssColor(palette.muted.opacity(0.55))
  }

  private static func cssColor(_ color: Color) -> String {
    let native = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    return String(
      format: "rgba(%d,%d,%d,%.3f)",
      Int((native.redComponent * 255).rounded()),
      Int((native.greenComponent * 255).rounded()),
      Int((native.blueComponent * 255).rounded()),
      native.alphaComponent
    )
  }
}

private struct MermaidDiagramWebView: NSViewRepresentable {
  let source: String
  let theme: MermaidDiagramTheme
  let interactive: Bool
  let zoom: Double
  let viewportChanged: (CGFloat) -> Void
  let heightChanged: (CGFloat) -> Void
  let rendered: () -> Void
  let failed: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> WKWebView {
    let controller = WKUserContentController()
    controller.add(context.coordinator, name: Coordinator.messageHandlerName)

    let configuration = WKWebViewConfiguration()
    configuration.userContentController = controller
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    if let assetHandler = context.coordinator.assetHandler {
      configuration.setURLSchemeHandler(
        assetHandler, forURLScheme: MermaidAssetSchemeHandler.scheme)
    }

    let webView = MermaidNativeWebView(frame: .zero, configuration: configuration)
    webView.isInteractive = interactive
    webView.viewportChanged = viewportChanged
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")
    webView.allowsMagnification = false

    if context.coordinator.assetHandler != nil,
      let pageURL = URL(string: "\(MermaidAssetSchemeHandler.scheme)://app/index.html")
    {
      context.coordinator.beginLoading()
      webView.load(URLRequest(url: pageURL))
    } else {
      DispatchQueue.main.async {
        context.coordinator.parent.failed("The bundled diagram renderer is missing.")
      }
    }
    return webView
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    coordinator.cancelTimeout()
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: Coordinator.messageHandlerName)
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.parent = self
    if let preview = webView as? MermaidNativeWebView {
      preview.isInteractive = interactive
      preview.viewportChanged = viewportChanged
    }
    context.coordinator.synchronize(webView)
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let messageHandlerName = "ottoDiagram"
    var parent: MermaidDiagramWebView
    let assetHandler: MermaidAssetSchemeHandler?
    private var isReady = false
    private var renderedSignature: Int?
    private var renderGeneration = 0
    private var timeoutTask: Task<Void, Never>?

    init(parent: MermaidDiagramWebView) {
      self.parent = parent
      assetHandler = MermaidAssetSchemeHandler.bundled()
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard message.name == Self.messageHandlerName,
        let bridgeMessage = MermaidBridgeMessage(body: message.body)
      else { return }

      switch bridgeMessage {
      case .ready:
        isReady = true
        if let webView = message.webView { synchronize(webView) }
      case .rendered:
        cancelTimeout()
        parent.rendered()
      case .height(let height):
        parent.heightChanged(height)
      case .error(let detail):
        cancelTimeout()
        parent.failed(detail)
      }
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      let allowed = navigationAction.request.url?.scheme == MermaidAssetSchemeHandler.scheme
      decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation?,
      withError error: any Error
    ) {
      parent.failed(error.localizedDescription)
    }

    func webView(
      _ webView: WKWebView,
      didFail navigation: WKNavigation?,
      withError error: any Error
    ) {
      parent.failed(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      cancelTimeout()
      parent.failed("The diagram rendering process stopped unexpectedly.")
    }

    func synchronize(_ webView: WKWebView) {
      guard isReady, MermaidRenderPolicy.accepts(parent.source) else { return }
      webView.evaluateJavaScript(
        "window.ottoDiagram?.setPresentation(\(parent.interactive), \(parent.zoom))",
        completionHandler: nil)
      let signature = parent.source.hashValue ^ parent.theme.hashValue
      guard signature != renderedSignature,
        let themeData = try? JSONEncoder().encode(parent.theme)
      else { return }

      renderedSignature = signature
      renderGeneration += 1
      let generation = renderGeneration
      let source = Data(parent.source.utf8).base64EncodedString()
      let theme = themeData.base64EncodedString()
      let script = "void window.ottoDiagram?.renderBase64('\(source)', '\(theme)')"
      webView.evaluateJavaScript(script) { [weak self] _, error in
        guard let self, let error else { return }
        self.cancelTimeout()
        self.parent.failed(error.localizedDescription)
      }
      beginTimeout(generation: generation)
    }

    func beginLoading() {
      beginTimeout(generation: renderGeneration)
    }

    func cancelTimeout() {
      timeoutTask?.cancel()
      timeoutTask = nil
    }

    private func beginTimeout(generation: Int) {
      cancelTimeout()
      timeoutTask = Task { [weak self] in
        do {
          try await Task.sleep(for: MermaidRenderPolicy.renderTimeout)
        } catch {
          return
        }
        guard let self, generation == self.renderGeneration else { return }
        self.parent.failed("Rendering timed out.")
      }
    }
  }
}

/// Inline previews never become the event target: AppKit keeps wheel, momentum and
/// pinch gestures in the enclosing conversation instead of WebKit's nested scroll view.
@MainActor
final class MermaidNativeWebView: WKWebView {
  var isInteractive = false
  var viewportChanged: ((CGFloat) -> Void)?
  private var lastViewportHeight: CGFloat = 0

  override func hitTest(_ point: NSPoint) -> NSView? {
    isInteractive ? super.hitTest(point) : nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(
      self, name: NSView.frameDidChangeNotification, object: nil)
    guard window != nil, let clipView = enclosingScrollView?.contentView else { return }
    clipView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(reportViewportHeight),
      name: NSView.frameDidChangeNotification, object: clipView)
    reportViewportHeight()
  }

  override func layout() {
    super.layout()
    reportViewportHeight()
  }

  @objc private func reportViewportHeight() {
    guard !isInteractive, let height = enclosingScrollView?.contentView.bounds.height,
      height > 0, height != lastViewportHeight
    else { return }
    lastViewportHeight = height
    DispatchQueue.main.async { [weak self] in self?.viewportChanged?(height) }
  }

}

@MainActor
private final class MermaidAssetSchemeHandler: NSObject, WKURLSchemeHandler {
  static let scheme = "otto-diagram"
  private let rootURL: URL

  static func bundled() -> MermaidAssetSchemeHandler? {
    guard let indexURL = MermaidRendererResources.indexURL else { return nil }
    return MermaidAssetSchemeHandler(rootURL: indexURL.deletingLastPathComponent())
  }

  private init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard let requestURL = urlSchemeTask.request.url else {
      urlSchemeTask.didFailWithError(URLError(.badURL))
      return
    }
    let relativePath =
      requestURL.path == "/"
      ? "index.html"
      : String(requestURL.path.drop(while: { $0 == "/" }))
    let fileURL = rootURL.appending(path: relativePath).standardizedFileURL
    guard fileURL.path.hasPrefix(rootURL.path + "/"), Self.isAllowed(fileURL.pathExtension) else {
      urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
      return
    }

    do {
      let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
      let response = URLResponse(
        url: requestURL,
        mimeType: Self.mimeType(fileURL.pathExtension),
        expectedContentLength: data.count,
        textEncodingName: Self.isText(fileURL.pathExtension) ? "utf-8" : nil
      )
      urlSchemeTask.didReceive(response)
      urlSchemeTask.didReceive(data)
      urlSchemeTask.didFinish()
    } catch {
      urlSchemeTask.didFailWithError(error)
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

  private static func isAllowed(_ pathExtension: String) -> Bool {
    ["html", "js", "css"].contains(pathExtension.lowercased())
  }

  private static func isText(_ pathExtension: String) -> Bool {
    ["html", "js", "css"].contains(pathExtension.lowercased())
  }

  private static func mimeType(_ pathExtension: String) -> String {
    switch pathExtension.lowercased() {
    case "html": "text/html"
    case "js": "application/javascript"
    case "css": "text/css"
    default: "application/octet-stream"
    }
  }
}

enum MermaidRendererResources {
  static var indexURL: URL? {
    OttoAppResources.url(
      forResource: "index", withExtension: "html", subdirectory: "DiagramRenderer")
  }
}
