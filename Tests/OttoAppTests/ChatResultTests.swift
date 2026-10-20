import AppKit
import OttoModels
import SwiftUI
import Testing

@testable import OttoApp

@Suite("Chat result cards")
struct ChatResultTests {
  let email = ChatEmailDraft(
    to: "Hugo", subject: "What Otto is",
    body: """
      Hey Hugo,

      Otto is a shared visual workspace where you and AI agents work together on the same canvas.

      Instead of keeping everything inside separate chat threads, Otto brings conversations, websites, documents, apps and agent outputs into one place. You can ask an agent to research something, build a prototype or work inside an app, then see and interact with the results alongside the conversation.

      The key idea is shared context: you and the agents can work with the same material. You can also hand work between agents—for example, having one research a problem and another turn the findings into a working prototype.

      Think of it as a workspace for collaborating with AI, where the conversation and the actual work live together.

      Max
      """)

  private func fence<T: Encodable>(_ language: String, _ value: T) throws -> String {
    "```\(language)\n" + String(decoding: try JSONEncoder().encode(value), as: UTF8.self) + "\n```"
  }

  @Test func savedSubjectOnlyRegression() {
    let source = "**Subject: What Otto is**\n\n" + email.body
    #expect(source.count > 700)
    let result = AssistantResponsePresentation(source)
    #expect(result.fullText == source)
    #expect(!result.hasDetails)
    #expect(result.preview.count == 1)
    guard case .email(let parsed) = result.preview.first?.content else {
      Issue.record("Saved email must render as a draft card")
      return
    }
    #expect(parsed.subject == email.subject)
    #expect(parsed.body == email.body)
    #expect(parsed.to.isEmpty)
  }

  @Test func legacyDividerCannotHideTheEmailBody() {
    let response = AssistantResponsePresentation(
      "**Subject: What Otto is**\n\n<!-- otto:details -->\n\n" + email.body)
    #expect(!response.hasDetails)
    #expect(response.preview.count == 1)
    guard case .email(let parsed) = response.preview.first?.content else {
      Issue.record("Divider must not split a legacy email")
      return
    }
    #expect(parsed.body == email.body)
  }

  @Test func legacySupportingNotesStayOutsideTheDraft() {
    let response = AssistantResponsePresentation(
      "**Subject: What Otto is**\n\n" + email.body
        + "\n\n<!-- otto:details -->\n\nOptional writing notes.")
    #expect(response.hasDetails)
    guard case .email(let parsed) = response.preview.first?.content else {
      Issue.record("Expected complete legacy draft")
      return
    }
    #expect(parsed.body == email.body)
    #expect(response.supportingBlocks.map(\.content) == [.paragraph("Optional writing notes.")])
  }

  @Test func longRequestedWritingStaysVisible() {
    let source = "Here is your speech.\n\n" + String(repeating: "A complete paragraph. ", count: 60)
    let result = AssistantResponsePresentation(source)
    #expect(!result.hasDetails)
    #expect(result.preview == MarkdownBlockParser.parse(source))
  }

  @Test func composedCardsAndMisplacedDetailsStayVisible() throws {
    let card = try fence("muse-email", email)
    let source = "Here is the draft.\n\n" + card + "\n\n<!-- otto:details -->\n\n" + card
    let response = AssistantResponsePresentation(source)
    #expect(
      response.preview.filter { if case .email = $0.content { true } else { false } }.count == 2)
    let explicit = AssistantResponsePresentation(
      card + "\n\n<!-- otto:details -->\n\nOptional rationale.")
    #expect(explicit.hasDetails)
    #expect(explicit.supportingBlocks.map(\.content) == [.paragraph("Optional rationale.")])
  }

  @Test func invalidAndStreamingCardsRemainReadable() throws {
    for source in [
      "```muse-email\n{invalid}\n```", "```muse-email\n{\"subject\":\"No body\"}\n```",
      String(try fence("muse-email", email).dropLast(3)),
    ] {
      guard case .code = MarkdownBlockParser.parse(source).first?.content else {
        Issue.record("Invalid or unfinished result must fall back to code")
        continue
      }
    }
    #expect(
      ChatResult.block(language: "muse-inbox", source: "{\"title\":\"Inbox\",\"messages\":[]}")
        == .inbox(ChatInbox(title: "Inbox", messages: [])))
  }

  @Test func draftActionsPreserveContentAndEncodeHeaders() throws {
    let draft = ChatEmailDraft(
      to: "hugo@example.com", subject: "Otto & co? #1", body: "Hi Hugo,\nA + B & C\nMax")
    let url = try #require(draft.mailURL)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "mailto")
    #expect(components.queryItems?.first(where: { $0.name == "body" })?.value == draft.body)
    #expect(components.queryItems?.first(where: { $0.name == "subject" })?.value == draft.subject)
    #expect(draft.copyText.hasSuffix(draft.body))
    #expect(draft.storageKey == draft.storageKey)
    #expect(draft.storageKey != email.storageKey)
    #expect(ChatEmailDraft(to: "x\nbcc: y", subject: "x", body: "y").mailURL == nil)
  }

  @Test func inboxUsesOnlySafeOriginalLinksAndKnownRecipients() {
    var message = ChatInbox.Message(
      sender: "Hugo", subject: "Otto", body: "Hello", url: "javascript:alert(1)")
    #expect(message.originalURL == nil)
    #expect(message.reply.to == "")
    #expect(message.reply.subject == "Re: Otto")
    message.url = "https://mail.example.com/message/1"
    #expect(message.originalURL != nil)
    message.subject = "Re: Otto"
    #expect(message.reply.subject == "Re: Otto")
  }

  @Test @MainActor func renderResultCards() async throws {
    guard let directory = ProcessInfo.processInfo.environment["OTTO_RESULT_SNAPSHOTS"] else {
      return
    }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared
    for theme in OttoThemeCatalog.all
    where ["field-notes", "nightspire", "glasswing"].contains(theme.id) {
      for width in [390, 900] {
        let palette = OttoPalette(theme: theme)
        let inbox = ChatInbox(
          title: "Inbox",
          messages: [
            .init(
              sender: "Hugo", subject: "Can you show me Otto this week?",
              body: "Would be good to see the agent workflow live. Does Thursday work?",
              unread: true),
            .init(
              sender: "Maya", subject: "Latest onboarding notes",
              body: "The three friction points we discussed, with screenshots."),
          ])
        let view = VStack(spacing: 24) {
          ChatEmailCard(draft: email, scale: 1, palette: palette)
          ChatInboxCard(inbox: inbox, scale: 1, palette: palette)
        }.padding(16).frame(width: CGFloat(width)).background(palette.surface)
          .environment(\.colorScheme, theme.isLightAppearance ? .light : .dark)
        let host = NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1500)
        let window = NSWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: width, height: 1500),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: theme.isLightAppearance ? .aqua : .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        #expect(height > 500)
        window.setContentSize(NSSize(width: CGFloat(width), height: height))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(
          to: URL(fileURLWithPath: directory).appendingPathComponent("\(theme.id)-\(width).png"))
      }
    }
  }
}
