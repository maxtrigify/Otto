import AppKit
import OttoModels
import PDFKit
import SwiftUI
import WebKit

/// Builds the web page for a deck: Otto's deck engine (deck.css + deck.js), the theme's
/// tokens, and the slides. Used for editing, thumbnails, presenting and exports alike, so
/// everything looks the same everywhere.
@MainActor
enum DeckRenderer {
  enum Mode: String { case present, edit, `static` }

  /// Slides are designed at 1280×720 and scaled to fit.
  static let size = CGSize(width: 1280, height: 720)

  private static func resource(_ name: String, _ ext: String) -> String {
    guard
      let url = OttoAppResources.url(forResource: name, withExtension: ext, subdirectory: "Deck"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return "" }
    return text
  }

  /// The engine's stylesheet with Inter embedded, so pages work offline and as one file.
  static let css: String = {
    var css = resource("deck", "css")
    if let font = OttoAppResources.url(
      forResource: "InterVariable", withExtension: "ttf", subdirectory: "Fonts"),
      let data = try? Data(contentsOf: font)
    {
      css = css.replacingOccurrences(
        of: #"url("InterVariable.ttf")"#,
        with: "url(data:font/ttf;base64,\(data.base64EncodedString()))")
    }
    return css
  }()

  static let js: String = resource("deck", "js")

  static func tokenCSS(_ tokens: DeckTokens) -> String {
    func font(_ name: String?) -> String? {
      name.map {
        "\"\($0.replacingOccurrences(of: "\"", with: ""))\", \"Inter Otto\", -apple-system, sans-serif"
      }
    }
    let pairs: [(String, String?)] = [
      ("--bg", tokens.background), ("--bg2", tokens.background2), ("--surface", tokens.surface),
      ("--text", tokens.text), ("--muted", tokens.muted), ("--accent", tokens.accent),
      ("--accent2", tokens.accent2), ("--font-display", font(tokens.fontDisplay)),
      ("--font-body", font(tokens.fontBody)),
    ]
    let body = pairs.compactMap { name, value in
      value.map {
        "\(name): \($0.replacingOccurrences(of: ";", with: "").replacingOccurrences(of: "}", with: ""));"
      }
    }.joined(separator: " ")
    return ":root { \(body) }"
  }

  /// One page with the given slides. `indices` nil means every slide.
  static func page(
    _ deck: Presentation, indices: [Int]? = nil, mode: Mode, start: Int = 0, title: String = ""
  ) -> String {
    let tokens = deck.tokens
    let chosen = (indices ?? Array(deck.slides.indices)).filter { deck.slides.indices.contains($0) }
    let logo = tokens.logoURL.map { #"<img class="logo" src="\#(DeckHTML.escape($0))" alt="">"# }
    let sections = chosen.map { index -> String in
      let slide = deck.slides[index]
      var html = slide.renderedHTML
      if let logo, !html.contains("class=\"logo\"") { html = logo + html }
      return "<section class=\"slide\" data-index=\"\(index)\">\(html)</section>"
    }.joined(separator: "\n")
    let fontLink =
      tokens.fontURL.map {
        #"<link rel="stylesheet" href="\#(DeckHTML.escape($0))">"#
      } ?? ""
    let chrome =
      mode == .present
      ? #"<div class="progressbar" style="width:0"></div><div class="counter"></div>"# : ""
    let config = #"{"mode":"\#(mode.rawValue)","index":\#(max(0, start))}"#
    return """
      <!doctype html><html><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>\(DeckHTML.escape(title))</title>\(fontLink)
      <style>\(css)</style><style>\(tokenCSS(tokens))</style>
      </head><body><div class="viewport"><div class="stage">
      \(sections)
      </div></div>\(chrome)
      <script>window.OTTO_DECK = \(config);</script><script>\(js)</script>
      </body></html>
      """
  }
}

/// A live deck page. `token` decides when to reload: edits made inside the page are reported
/// through `onEdit` without reloading, so the caret stays put while typing.
struct DeckWebView: NSViewRepresentable {
  let html: String
  let token: Int
  var onEdit: (String) -> Void = { _ in }
  var onSelection: (String) -> Void = { _ in }
  var onExit: () -> Void = {}
  var onEditingText: (Bool) -> Void = { _ in }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(context.coordinator, name: "otto")
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.setValue(false, forKey: "drawsBackground")
    view.navigationDelegate = context.coordinator
    context.coordinator.parent = self
    view.loadHTMLString(html, baseURL: nil)
    context.coordinator.loadedToken = token
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    context.coordinator.parent = self
    guard context.coordinator.loadedToken != token else { return }
    context.coordinator.loadedToken = token
    view.loadHTMLString(html, baseURL: nil)
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    view.configuration.userContentController.removeScriptMessageHandler(forName: "otto")
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var parent: DeckWebView
    var loadedToken = Int.min
    init(parent: DeckWebView) { self.parent = parent }

    func userContentController(
      _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
        return
      }
      switch type {
      case "edit": if let html = body["html"] as? String { parent.onEdit(html) }
      case "selection": parent.onSelection(body["text"] as? String ?? "")
      case "editing": parent.onEditingText(body["active"] as? Bool ?? false)
      case "exit": parent.onExit()
      default: break
      }
    }

    /// Links in slides open in the browser, never inside the deck.
    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      if action.navigationType == .linkActivated, let url = action.request.url {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
      } else {
        decisionHandler(.allow)
      }
    }
  }
}

/// Renders slides off screen for thumbnails and exports, one at a time, and remembers results.
@MainActor
final class DeckSnapshotter: NSObject, WKNavigationDelegate {
  static let shared = DeckSnapshotter()

  private let window: NSWindow
  private let webView: WKWebView
  private var cache: [String: NSImage] = [:]
  private var loading: CheckedContinuation<Void, Never>?

  override init() {
    webView = WKWebView(frame: CGRect(origin: .zero, size: DeckRenderer.size))
    window = NSWindow(
      contentRect: CGRect(
        x: -10_000, y: -10_000, width: DeckRenderer.size.width,
        height: DeckRenderer.size.height),
      styleMask: [.borderless], backing: .buffered, defer: false)
    super.init()
    window.isReleasedWhenClosed = false
    window.contentView = webView
    window.alphaValue = 0.01
    window.orderBack(nil)
    webView.navigationDelegate = self
  }

  static func key(_ deck: Presentation, _ index: Int) -> String {
    guard deck.slides.indices.contains(index) else { return "" }
    let tokens = (try? JSONEncoder().encode(deck.tokens)).map {
      String(decoding: $0, as: UTF8.self)
    }
    return "\(deck.slides[index].renderedHTML.hashValue)-\(tokens?.hashValue ?? 0)"
  }

  func cached(_ deck: Presentation, _ index: Int) -> NSImage? { cache[Self.key(deck, index)] }

  /// A picture of one slide at `width` pixels wide.
  func image(_ deck: Presentation, index: Int, width: CGFloat = 480) async -> NSImage? {
    let key = Self.key(deck, index) + "@\(Int(width))"
    if let hit = cache[key] { return hit }
    let image: NSImage? = await serial {
      await self.load(DeckRenderer.page(deck, indices: [index], mode: .static))
      let config = WKSnapshotConfiguration()
      config.rect = CGRect(origin: .zero, size: DeckRenderer.size)
      config.snapshotWidth = NSNumber(value: Double(width))
      return try? await self.webView.takeSnapshot(configuration: config)
    }
    if let image { cache[key] = image }
    if cache.count > 400 { cache.removeAll() }
    return image
  }

  /// A vector PDF, one page per slide.
  func pdf(_ deck: Presentation) async -> Data {
    let document = PDFDocument()
    for index in deck.slides.indices {
      let data: Data? = await serial {
        await self.load(DeckRenderer.page(deck, indices: [index], mode: .static))
        let config = WKPDFConfiguration()
        config.rect = CGRect(origin: .zero, size: DeckRenderer.size)
        return try? await self.webView.pdf(configuration: config)
      }
      if let data, let page = PDFDocument(data: data)?.page(at: 0) {
        document.insert(page, at: document.pageCount)
      }
    }
    return document.dataRepresentation() ?? Data()
  }

  /// Reads a rendered slide into native parts: text blocks with their fonts and colours, card
  /// shapes, and regions (charts, the cube, images) that travel as pictures.
  private static let extractor = #"""
    const slide = document.querySelector('.slide');
    const base = slide.getBoundingClientRect();
    const ctx = document.createElement('canvas').getContext('2d');
    const rgba = (c) => { ctx.clearRect(0,0,1,1); ctx.fillStyle = '#000'; ctx.fillStyle = c;
      ctx.fillRect(0,0,1,1); const d = ctx.getImageData(0,0,1,1).data;
      return [d[0], d[1], d[2], +(d[3] / 255).toFixed(3)]; };
    const root = getComputedStyle(document.documentElement);
    const textSel = 'h1,h2,h3,p,li,.kicker,.label,.value,.pill,.badge,td,th,.cite,.icon,.brandmark,.lead,.small';
    const boxSel = '.card,.pill,.badge,.icon,.steps > li';
    const picSel = '.chart,.cube,img,.progress,.legend';
    const items = [];
    const rect = (el) => { const r = el.getBoundingClientRect();
      return { x: r.left - base.left, y: r.top - base.top, w: r.width, h: r.height }; };
    const visible = (el) => { const cs = getComputedStyle(el);
      return cs.visibility !== 'hidden' && cs.display !== 'none' && +cs.opacity > 0.05; };
    const colorOf = (el) => { const cs = getComputedStyle(el); let c = rgba(cs.color);
      if (c[3] < 0.05) { c = rgba(el.closest('.stat') || el.classList.contains('gradient-text')
        ? root.getPropertyValue('--accent') : root.getPropertyValue('--text')); }
      return c; };
    for (const el of slide.querySelectorAll('*')) {
      if (!visible(el) || el.closest('.backdrop')) continue;
      if (el.parentElement && el.parentElement.closest(picSel)) continue;
      const r = rect(el);
      if (r.w < 2 || r.h < 2) continue;
      if (el.matches(picSel)) { items.push({ k: 'pic', ...r }); continue; }
      const cs = getComputedStyle(el);
      if (el.matches(boxSel)) {
        const fill = rgba(cs.backgroundColor), line = rgba(cs.borderTopColor);
        const lw = parseFloat(cs.borderTopWidth) || 0;
        if (fill[3] > 0.01 || (lw > 0 && line[3] > 0.01)) {
          items.push({ k: 'box', ...r, fill, line: lw > 0 ? line : null,
            radius: parseFloat(cs.borderTopLeftRadius) || 0 });
        }
      }
      if (!el.matches(textSel)) continue;
      if (el.querySelector(textSel)) continue;
      const text = el.innerText.replace(/ /g, ' ').trim();
      if (!text) continue;
      const upper = cs.textTransform === 'uppercase';
      const runs = [];
      const bulletColor = rgba(root.getPropertyValue('--accent'));
      if (el.tagName === 'LI' && el.closest('.list')) runs.push({ t: '•  ', b: false, i: false, c: bulletColor });
      if (el.tagName === 'LI' && el.closest('.steps')) {
        const n = Array.prototype.indexOf.call(el.parentElement.children, el) + 1;
        runs.push({ t: String(n).padStart(2, '0') + '\n', b: true, i: false, c: bulletColor });
      }
      const walk = (node, bold, italic) => {
        for (const child of node.childNodes) {
          if (child.nodeType === 3) {
            let t = child.textContent.replace(/\s+/g, ' ');
            if (upper) t = t.toUpperCase();
            if (t.trim() || t === ' ') runs.push({ t, b: bold, i: italic, c: colorOf(node.nodeType === 1 ? node : el) });
          } else if (child.nodeType === 1) {
            if (child.tagName === 'BR') { runs.push({ t: '\n', b: bold, i: italic, c: colorOf(el) }); continue; }
            const ccs = getComputedStyle(child);
            walk(child, parseInt(ccs.fontWeight) >= 600, ccs.fontStyle === 'italic');
          }
        }
      };
      walk(el, parseInt(cs.fontWeight) >= 600, cs.fontStyle === 'italic');
      if (runs.length) runs[runs.length - 1].t = runs[runs.length - 1].t.replace(/\s+$/, '');
      if (runs.length) runs[0].t = runs[0].t.replace(/^\s+/, '');
      const size = parseFloat(cs.fontSize);
      const lh = parseFloat(cs.lineHeight) || size * 1.25;
      const family = (cs.fontFamily.split(',')[0] || '').replace(/["']/g, '').trim();
      items.push({ k: 'text', ...r, size, lh, ls: parseFloat(cs.letterSpacing) || 0,
        align: cs.textAlign, font: family === 'Inter Otto' ? 'Inter' : family,
        single: r.h < lh * 1.6, runs });
    }
    return JSON.stringify(items);
    """#

  /// PowerPoint with native, editable text and shapes on top of a picture of each slide's
  /// background; charts, the cube and images come across as pictures so they keep their look.
  /// Imports into Google Slides with editable text.
  /// `forGoogle` keeps Inter, which Google Slides has; plain PowerPoint files use Arial in its
  /// place because many machines don't have Inter installed.
  func editablePPTX(_ deck: Presentation, title: String, forGoogle: Bool = false) async -> Data {
    var slides: [PPTXSlide] = []
    for index in deck.slides.indices {
      let slide: PPTXSlide? = await serial {
        await self.load(DeckRenderer.page(deck, indices: [index], mode: .static))
        guard
          let json = try? await self.webView.callAsyncJavaScript(
            Self.extractor, contentWorld: .page) as? String,
          let items = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        else { return nil }
        let scale: CGFloat = 2
        let full = await self.snapshot(width: DeckRenderer.size.width * scale)
        // The background is the slide with everything but its backdrop hidden.
        _ = try? await self.webView.callAsyncJavaScript(
          """
          const s = document.createElement('style');
          s.textContent = '.slide * { visibility: hidden !important; } .slide .backdrop, .slide .backdrop * { visibility: visible !important; } .logo { visibility: visible !important; }';
          document.head.appendChild(s); await new Promise(r => setTimeout(r, 60));
          return true;
          """, contentWorld: .page)
        let background = await self.snapshot(width: DeckRenderer.size.width * scale)
        guard let background = background.flatMap(Self.jpeg) else { return nil }
        var shapes: [PPTXShape] = []
        for item in items {
          let x = item["x"] as? Double ?? 0
          let y = item["y"] as? Double ?? 0
          let w = item["w"] as? Double ?? 0
          let h = item["h"] as? Double ?? 0
          switch item["k"] as? String {
          case "pic":
            if let full, let crop = Self.crop(full, x: x, y: y, w: w, h: h, scale: scale) {
              shapes.append(.picture(x: x, y: y, w: w, h: h, image: crop))
            }
          case "box":
            shapes.append(
              .box(
                x: x, y: y, w: w, h: h, fill: Self.color(item["fill"]),
                line: Self.color(item["line"]), radius: item["radius"] as? Double ?? 0))
          case "text":
            let runs = (item["runs"] as? [[String: Any]] ?? []).compactMap { run -> PPTXText.Run? in
              guard let text = run["t"] as? String, !text.isEmpty else { return nil }
              return PPTXText.Run(
                text: text, bold: run["b"] as? Bool ?? false, italic: run["i"] as? Bool ?? false,
                color: Self.color(run["c"]) ?? PPTXColor(hex: "FFFFFF"))
            }
            guard !runs.isEmpty else { continue }
            shapes.append(
              .text(
                PPTXText(
                  x: x, y: y, w: w, h: h, fontSize: item["size"] as? Double ?? 24,
                  font: Self.font(item["font"] as? String, forGoogle: forGoogle),
                  align: item["align"] as? String ?? "left",
                  lineHeight: item["lh"] as? Double ?? 30,
                  letterSpacing: item["ls"] as? Double ?? 0,
                  singleLine: item["single"] as? Bool ?? false, runs: runs)))
          default:
            break
          }
        }
        return PPTXSlide(background: background, shapes: shapes, notes: deck.slides[index].notes)
      }
      if let slide { slides.append(slide) }
    }
    return PPTXWriter.data(slides: slides, title: title)
  }

  private static func font(_ family: String?, forGoogle: Bool) -> String {
    let name = family?.isEmpty == false ? family! : "Inter"
    if forGoogle { return name }
    return ["Inter", "-apple-system", "system-ui", "sans-serif"].contains(name) ? "Arial" : name
  }

  private func snapshot(width: CGFloat) async -> NSImage? {
    let config = WKSnapshotConfiguration()
    config.rect = CGRect(origin: .zero, size: DeckRenderer.size)
    config.snapshotWidth = NSNumber(value: Double(width))
    return try? await webView.takeSnapshot(configuration: config)
  }

  private static func cgImage(_ image: NSImage) -> CGImage? {
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }

  static func jpeg(_ image: NSImage) -> Data? {
    guard let cg = cgImage(image) else { return nil }
    return NSBitmapImageRep(cgImage: cg).representation(
      using: .jpeg, properties: [.compressionFactor: 0.9])
  }

  private static func crop(
    _ image: NSImage, x: Double, y: Double, w: Double, h: Double, scale: CGFloat
  ) -> Data? {
    guard let cg = cgImage(image) else { return nil }
    let pixels = CGFloat(cg.width) / DeckRenderer.size.width
    let area = CGRect(x: x * pixels, y: y * pixels, width: w * pixels, height: h * pixels)
      .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    guard !area.isEmpty, let piece = cg.cropping(to: area) else { return nil }
    return NSBitmapImageRep(cgImage: piece).representation(using: .png, properties: [:])
  }

  private static func color(_ value: Any?) -> PPTXColor? {
    guard let parts = value as? [Double], parts.count == 4, parts[3] > 0.01 else { return nil }
    let hex = String(
      format: "%02X%02X%02X", Int(parts[0]), Int(parts[1]), Int(parts[2]))
    return PPTXColor(hex: hex, alpha: parts[3])
  }

  /// High-quality JPEGs of every slide at 1920 px wide, for PowerPoint.
  func pngs(_ deck: Presentation) async -> [Data] {
    var result: [Data] = []
    for index in deck.slides.indices {
      guard let image = await image(deck, index: index, width: 1920),
        let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
      else { continue }
      result.append(png)
    }
    return result
  }

  private var busy = false

  /// Runs jobs one after another on the single off-screen page.
  private func serial<T>(_ job: @MainActor () async -> T) async -> T {
    while busy { try? await Task.sleep(for: .milliseconds(15)) }
    busy = true
    defer { busy = false }
    return await job()
  }

  private func load(_ html: String) async {
    await withCheckedContinuation { continuation in
      loading = continuation
      webView.loadHTMLString(html, baseURL: nil)
    }
    // Let fonts, images and the static chart frame settle.
    _ = try? await webView.callAsyncJavaScript(
      "await document.fonts.ready; return true;", contentWorld: .page)
    try? await Task.sleep(for: .milliseconds(120))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    loading?.resume()
    loading = nil
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    loading?.resume()
    loading = nil
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    loading?.resume()
    loading = nil
  }
}
