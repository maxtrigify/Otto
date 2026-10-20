import AppKit
import SwiftUI

/// Paper's Email draft artifact: opaque reading surface, editable fields and real local actions.
struct ChatEmailCard: View {
  let draft: ChatEmailDraft
  let scale: Double
  let palette: OttoPalette
  @State private var editing = false
  @State private var working: ChatEmailDraft
  @State private var feedback: String?
  @AppStorage private var savedDraft: String

  init(draft: ChatEmailDraft, scale: Double, palette: OttoPalette, storageScope: String = "") {
    self.draft = draft
    self.scale = scale
    self.palette = palette
    _working = State(initialValue: draft)
    _savedDraft = AppStorage(wrappedValue: "", draft.storageKey + "." + storageScope)
  }

  private var current: ChatEmailDraft {
    (try? JSONDecoder().decode(ChatEmailDraft.self, from: Data(savedDraft.utf8))) ?? draft
  }
  private var size: Double { max(12, 15 * scale) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ViewThatFits(in: .horizontal) {
        HStack {
          Label("Email draft", systemImage: "envelope").fontWeight(.semibold)
          Spacer()
          Text("Draft · not sent").foregroundStyle(palette.muted)
        }
        VStack(alignment: .leading, spacing: 6) {
          Label("Email draft", systemImage: "envelope").fontWeight(.semibold)
          Text("Draft · not sent").foregroundStyle(palette.muted)
        }
      }
      .font(.ottoDisplay(max(11, 14 * scale)))
      .padding(20 * scale)
      Divider()
      VStack(alignment: .leading, spacing: 12 * scale) {
        if editing {
          TextField("To", text: $working.to).accessibilityLabel("Email recipient")
          TextField("Subject", text: $working.subject).accessibilityLabel("Email subject")
        } else {
          field("To", value: current.to.isEmpty ? "Add recipient in your mail app" : current.to)
          field("Subject", value: current.subject)
        }
      }
      .font(.ottoDisplay(size))
      .textFieldStyle(.roundedBorder)
      .padding(24 * scale)
      Divider()
      if editing {
        TextEditor(text: $working.body)
          .font(.ottoDisplay(size))
          .scrollContentBackground(.hidden)
          .frame(minHeight: 220 * scale)
          .padding(20 * scale)
          .accessibilityLabel("Email body")
      } else {
        Text(current.body)
          .font(.ottoDisplay(size))
          .lineSpacing(7 * scale)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .padding(24 * scale)
      }
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 16 * scale) { actions }
          VStack(alignment: .leading, spacing: 12 * scale) { actions }
        }
        if let feedback {
          Text(feedback).font(.ottoDisplay(max(11, 12 * scale))).foregroundStyle(palette.muted)
        }
      }
      .font(.ottoDisplay(max(12, 14 * scale)))
      .padding(20 * scale)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(palette.surface)
    }
    .foregroundStyle(palette.paper)
    .background(palette.raised)
    .clipShape(RoundedRectangle(cornerRadius: 14 * scale))
    .overlay(RoundedRectangle(cornerRadius: 14 * scale).stroke(palette.paper.opacity(0.10)))
    .textSelection(.disabled)
  }

  private func field(_ label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 18 * scale) {
      Text(label).foregroundStyle(palette.muted).frame(width: 56 * scale, alignment: .leading)
      Text(value).fontWeight(label == "Subject" ? .semibold : .regular)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
  }

  @ViewBuilder private var actions: some View {
    if editing {
      Button("Save draft") {
        if let data = try? JSONEncoder().encode(working),
          let text = String(data: data, encoding: .utf8)
        {
          savedDraft = text
          editing = false
          feedback = "Draft saved on this Mac."
        }
      }.buttonStyle(.borderedProminent).tint(palette.signal)
      Button("Cancel") {
        editing = false
        feedback = nil
      }.buttonStyle(.borderless)
    } else {
      Button {
        NSPasteboard.general.clearContents()
        feedback =
          NSPasteboard.general.setString(current.copyText, forType: .string)
          ? "Email copied." : "Could not copy email."
      } label: {
        Label("Copy email", systemImage: "doc.on.doc")
      }
      .buttonStyle(.borderedProminent).tint(palette.signal)
      Button("Edit draft") {
        working = current
        editing = true
        feedback = nil
      }.buttonStyle(.borderless)
      Button("Open in mail app ↗") {
        guard let url = current.mailURL else {
          feedback = "Check the recipient and subject before opening."
          return
        }
        feedback =
          NSWorkspace.shared.open(url)
          ? "Opened in your mail app. Nothing sent by Otto."
          : "No mail app could open this draft. Copy the email instead."
      }.buttonStyle(.borderless)
    }
  }
}

/// A snapshot of connector results. Opening and composing do not silently mutate the mailbox.
struct ChatInboxCard: View {
  var storageScope: String = ""
  let inbox: ChatInbox
  let scale: Double
  let palette: OttoPalette
  @State private var unreadOnly = false
  @State private var selected: Int?
  @State private var replying: Int?
  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ViewThatFits(in: .horizontal) {
        HStack {
          header
          Spacer()
          filter
        }
        VStack(alignment: .leading, spacing: 10) {
          header
          filter
        }
      }.padding(20 * scale)
      Divider()
      let entries = inbox.messages.enumerated().filter { !unreadOnly || $0.element.unread == true }
      if entries.isEmpty {
        Text("No messages in this view.").foregroundStyle(palette.muted).padding(20 * scale)
      }
      ForEach(Array(entries), id: \.offset) { index, message in
        VStack(alignment: .leading, spacing: 12 * scale) {
          Button {
            selected = selected == index ? nil : index
          } label: {
            HStack(alignment: .top, spacing: 14 * scale) {
              Text(String(message.sender.prefix(1)))
                .font(.ottoDisplay(max(12, 14 * scale)).weight(.semibold))
                .frame(width: 36 * scale, height: 36 * scale)
                .background(palette.surface, in: Circle())
              VStack(alignment: .leading, spacing: 7 * scale) {
                Text(message.sender).font(.ottoDisplay(max(12, 13 * scale))).foregroundStyle(
                  palette.muted)
                Text(message.subject).font(.ottoDisplay(max(13, 17 * scale)).weight(.semibold))
                  .fixedSize(horizontal: false, vertical: true)
                Text(message.body).font(.ottoDisplay(max(12, 14 * scale)))
                  .lineLimit(selected == index ? nil : 2)
                  .fixedSize(horizontal: false, vertical: true)
                  .foregroundStyle(palette.muted)
                if let time = message.receivedAt {
                  Text(time).font(.ottoDisplay(max(11, 12 * scale))).foregroundStyle(palette.muted)
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
              Circle().fill(message.unread == true ? palette.signal : .clear).frame(
                width: 7, height: 7)
            }.contentShape(Rectangle())
          }.buttonStyle(.plain)
            .accessibilityLabel(
              "\(message.sender): \(message.subject). \(selected == index ? "Collapse" : "Expand") message"
            )
          HStack(spacing: 20 * scale) {
            Button(replying == index ? "Cancel reply" : "Reply") {
              replying = replying == index ? nil : index
            }
            if let url = message.originalURL {
              Button("Open original ↗") { openURL(url) }
            }
          }.buttonStyle(.borderless).foregroundStyle(palette.signal)
          if replying == index {
            ChatEmailCard(
              draft: message.reply, scale: scale, palette: palette,
              storageScope: storageScope + ".reply.\(index)")
          }
        }.padding(20 * scale)
        Divider()
      }
      Text("Mailbox snapshot · replies open as drafts")
        .font(.ottoDisplay(max(11, 12 * scale))).foregroundStyle(palette.muted).padding(16 * scale)
    }
    .font(.ottoDisplay(max(12, 13 * scale)))
    .foregroundStyle(palette.paper)
    .background(palette.raised)
    .clipShape(RoundedRectangle(cornerRadius: 14 * scale))
    .overlay(RoundedRectangle(cornerRadius: 14 * scale).stroke(palette.paper.opacity(0.10)))
    .textSelection(.disabled)
  }

  private var header: some View {
    Text("\(inbox.title) · \(inbox.messages.count)").fontWeight(.semibold)
  }

  private var filter: some View {
    Toggle("Unread only", isOn: $unreadOnly).toggleStyle(.checkbox)
  }
}
