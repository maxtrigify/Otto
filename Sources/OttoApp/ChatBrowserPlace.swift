import OttoModels
import OttoServices
import SwiftUI

/// Chat's Browser place: your own tabs at full width, with the same AI panel Documents uses.
/// The page and every browser beside a conversation share one website data store, so a site
/// you are signed in to here is signed in for your agents too.
struct ChatBrowserPlace<Page: View, Conversation: View>: View {
  @ObservedObject var services: ApplicationServices
  let browser: OttoNode?
  let ensureBrowser: () -> Void
  let start: AssistantStarter
  @ViewBuilder let page: (OttoNode, BrowserChromeStyle) -> Page
  @ViewBuilder let conversation: (UUID) -> Conversation
  @AppStorage(AssistantTarget.defaultsKey) private var targetRaw = ""
  @AppStorage("otto.browser.aiVisible") private var aiVisible = false
  @State private var status: OttoStatusToast?
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    Group {
      if let browser {
        HStack(spacing: 0) {
          page(
            browser,
            .place(
              aiVisible: aiVisible,
              toggleAI: { withAnimation(.easeOut(duration: 0.18)) { aiVisible.toggle() } },
              askOtto: { request in
                withAnimation(.easeOut(duration: 0.18)) { aiVisible = true }
                Task { await send(request, browser: browser) }
              })
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          if aiVisible {
            sidePanel(browser)
              .frame(width: 400)
              .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
      } else {
        ProgressView("Opening Browser…")
          .font(.ottoDisplay(12))
          .foregroundStyle(palette.muted)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear { if browser == nil { ensureBrowser() } }
    .ottoStatusToast($status)
  }

  private var target: Binding<AssistantTarget> {
    Binding(
      get: { AssistantTarget(storageValue: targetRaw) ?? .provider(.claudeCode) },
      set: { targetRaw = $0.storageValue })
  }

  /// One helper chat per browser; changing who helps starts a fresh one, as in Documents.
  private func helperTarget(_ key: String) -> Binding<AssistantTarget> {
    Binding(
      get: { target.wrappedValue },
      set: { next in
        if next != target.wrappedValue { services.office.setSession(nil, path: key) }
        target.wrappedValue = next
      })
  }

  private func sidePanel(_ browser: OttoNode) -> some View {
    let key = Self.sessionKey(browser.id)
    return WorkAssistantPanel(
      services: services, target: helperTarget(key),
      sessionID: services.office.session(path: key),
      actions: AssistantPanelActions(
        newChat: { services.office.setSession(nil, path: key) },
        close: { withAnimation(.easeOut(duration: 0.18)) { aiVisible = false } }),
      named: .otto
    ) {
      EmptyView()
    } empty: {
      VStack(alignment: .leading, spacing: 0) {
        AssistantPromptBar(
          services: services, placeholder: "Ask Otto about this page…", target: target,
          showsPicker: false
        ) { request in
          await send(request, browser: browser)
        }
        .padding(14)
        AssistantIdeas(title: "Ideas", ideas: Self.ideas) { idea in
          Task { await send(idea, browser: browser) }
        }
      }
    } conversation: { nodeID in
      conversation(nodeID)
    }
  }

  static var ideas: [String] {
    [
      "Summarise this page in five bullets",
      "Compare the pages in my open tabs",
      "Save the key points from this page as a document",
    ]
  }

  nonisolated static func sessionKey(_ browserID: UUID) -> String {
    "browser:\(browserID.uuidString)"
  }

  /// The helper is told which page is open and which Otto browser holds it, so it can read
  /// the page with the browser tools instead of fetching a signed-out copy. The page details
  /// travel in Otto's context envelope, so the conversation shows only what the person typed.
  nonisolated static func message(_ request: String, browser: OttoNode) -> String {
    let session = browser.browserSession
    let tab = session?.activeTab
    let tabs = session?.tabs ?? []
    var lines = ["The person is looking at a page in Otto Browser."]
    if let tab {
      lines.append("Active tab: \(tab.title) — \(tab.url)")
    }
    if let tab, tab.url == BrowserDefaults.blankURL || BrowserDefaults.isStartURL(tab.url) {
      lines.append(
        "They asked from a new tab. Act as their web research assistant: answer in chat, using "
          + "web search where it helps, and cite links to your sources. Only open a site in this "
          + "browser when the request needs it, for example their signed-in account, something "
          + "to do on a page, or they asked to go there.")
    }
    let others = tabs.filter { $0.id != tab?.id && $0.url.hasPrefix("http") }
    if !others.isEmpty {
      lines.append("Other open tabs:")
      lines += others.prefix(12).map { "- \($0.title) — \($0.url)" }
    }
    lines.append(
      "Browser node ID: \(browser.id.uuidString). Read it with browser.inspect; it is signed in "
        + "as the person. Ask before submitting, posting, buying or sending anything. Don't "
        + "navigate away from their page just to look something up; answer from search instead.")
    return PromptSubmission.contextualPrompt(request, context: lines.joined(separator: "\n"))
  }

  private func send(_ request: String, browser: OttoNode) async {
    do {
      _ = try await start(
        target.wrappedValue, Self.message(request, browser: browser), Self.sessionKey(browser.id))
    } catch {
      status = OttoStatusToast(
        kind: .error, title: "Couldn’t reach the agent", detail: error.localizedDescription)
    }
  }
}
