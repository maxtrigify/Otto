import OttoModels
import SwiftUI

/// The Browser's new tab: Otto sits above one box that either asks Otto, searches Google, or
/// opens an address. It guesses which from what is typed and lists the alternatives underneath,
/// so the person can pick another with the arrow keys before pressing Return.
struct OttoStartSurface: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var focused: Bool
  @Binding var query: String
  let focusRequest: Int
  /// Loads a resolved URL in the current tab.
  let navigate: (String) -> Void
  /// Opens the Otto panel and sends the request there.
  let askOtto: (String) -> Void

  @State private var highlighted = 0
  @State private var floating = false
  @State private var hop = false

  enum Choice: Equatable {
    case ask
    case search
    case open(String)
  }

  var body: some View {
    let choices = Self.choices(for: query)
    ZStack {
      palette.ink
      RadialGradient(
        colors: [Color(red: 0.30, green: 0.55, blue: 1.0).opacity(0.10), .clear],
        center: UnitPoint(x: 0.5, y: 0.36), startRadius: 0, endRadius: 420)

      VStack(spacing: 18) {
        OttoMark(size: 92)
          .offset(y: floating ? -5 : 3)
          .scaleEffect(hop ? 1.08 : 1, anchor: .bottom)
          .animation(
            reduceMotion ? nil : .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
            value: floating)
          .onAppear { floating = true }

        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 10) {
            Image(systemName: icon(for: choices.first ?? .ask))
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(palette.muted)
              .frame(width: 16)
            TextField(
              "", text: $query,
              prompt: Text("Ask Otto, search, or enter an address…")
                .foregroundStyle(palette.muted)
            )
              .textFieldStyle(.plain)
              .font(.ottoDisplay(16))
              .foregroundStyle(palette.paper)
              .focused($focused)
              .onSubmit { run(choices) }
              .onKeyPress(.downArrow) {
                guard !choices.isEmpty else { return .ignored }
                highlighted = min(highlighted + 1, choices.count - 1)
                return .handled
              }
              .onKeyPress(.upArrow) {
                guard !choices.isEmpty else { return .ignored }
                highlighted = max(highlighted - 1, 0)
                return .handled
              }
          }
          .padding(.horizontal, 16)
          .frame(height: 52)

          if !choices.isEmpty {
            VStack(spacing: 2) {
              ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                row(choice, isHighlighted: index == highlighted)
                  .onTapGesture { perform(choice) }
                  .onHover { if $0 { highlighted = index } }
              }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
          }

          HStack(spacing: 8) {
            Text("Otto can search, open and read pages for you")
              .font(.ottoDisplay(11))
              .foregroundStyle(palette.muted.opacity(0.8))
            Spacer(minLength: 8)
            Button { run(choices) } label: {
              HStack(spacing: 6) {
                Text(primaryLabel(choices))
                Image(systemName: "return")
              }
              .font(.ottoDisplay(12).weight(.semibold))
              .foregroundStyle(Color(red: 0.11, green: 0.12, blue: 0.16))
              .padding(.horizontal, 12)
              .frame(height: 30)
              .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty)
            .opacity(trimmed.isEmpty ? 0.5 : 1)
          }
          .padding(.horizontal, 14)
          .padding(.bottom, 12)
          .padding(.top, choices.isEmpty ? 0 : 6)
        }
        .frame(maxWidth: 620)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(palette.paper.opacity(0.1)))
        .shadow(color: .black.opacity(0.14), radius: 22, y: 10)
      }
      .padding(32)
      .offset(y: -40)
    }
    .onChange(of: query) { old, new in
      highlighted = 0
      // Otto perks up when the person starts typing.
      if old.isEmpty, !new.isEmpty, !reduceMotion {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { hop = true }
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(180))
          withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { hop = false }
        }
      }
    }
    .task(id: focusRequest) {
      // A new tab button keeps keyboard focus; wait a turn so typing lands in the box.
      await Task.yield()
      focused = true
    }
  }

  private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  private func row(_ choice: Choice, isHighlighted: Bool) -> some View {
    HStack(spacing: 10) {
      Group {
        if choice == .ask {
          OttoMark(size: 16)
        } else {
          Image(systemName: icon(for: choice)).font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.muted)
        }
      }
      .frame(width: 16)
      Text(trimmed).font(.ottoDisplay(13).weight(.semibold)).foregroundStyle(palette.paper)
        .lineLimit(1)
      Text("— \(label(for: choice))").font(.ottoDisplay(13)).foregroundStyle(palette.muted)
      Spacer(minLength: 8)
      if isHighlighted {
        Image(systemName: "return").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(palette.muted)
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 36)
    .background(
      isHighlighted ? palette.paper.opacity(0.1) : .clear,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .contentShape(Rectangle())
  }

  private func icon(for choice: Choice) -> String {
    switch choice {
    case .ask: "bubble.left"
    case .search: "magnifyingglass"
    case .open: "globe"
    }
  }

  private func label(for choice: Choice) -> String {
    switch choice {
    case .ask: "Ask Otto"
    case .search: "Google"
    case .open(let url): "Open \(URL(string: url)?.host ?? url)"
    }
  }

  private func primaryLabel(_ choices: [Choice]) -> String {
    guard choices.indices.contains(highlighted) else { return "Ask Otto" }
    switch choices[highlighted] {
    case .ask: return "Ask Otto"
    case .search: return "Search"
    case .open: return "Open"
    }
  }

  private func run(_ choices: [Choice]) {
    guard choices.indices.contains(highlighted) else { return }
    perform(choices[highlighted])
  }

  private func perform(_ choice: Choice) {
    let text = trimmed
    guard !text.isEmpty else { return }
    switch choice {
    case .ask:
      query = ""
      askOtto(text)
    case .search:
      navigate(Self.searchURL(text))
    case .open(let url):
      navigate(url)
    }
  }

  // MARK: - Deciding what the person meant

  /// Addresses open directly; questions and longer requests go to Otto; short keyword lookups
  /// search Google. Every option stays available underneath.
  nonisolated static func choices(for text: String) -> [Choice] {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return [] }
    if let url = address(from: text) { return [.open(url), .ask, .search] }
    return isQuestion(text) ? [.ask, .search] : [.search, .ask]
  }

  nonisolated static func address(from text: String) -> String? {
    guard !text.contains(" ") else { return nil }
    let lowered = text.lowercased()
    if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
      return URL(string: text)?.host == nil ? nil : text
    }
    if lowered.hasPrefix("localhost") || lowered.hasPrefix("127.0.0.1") {
      return "http://\(text)"
    }
    // A dot followed by a plausible top-level domain: "clay.com", "news.ycombinator.com/item".
    let host = lowered.split(separator: "/", maxSplits: 1).first.map(String.init) ?? lowered
    guard let tld = host.split(separator: ".").last, host.contains("."),
      (2...24).contains(tld.count), tld.allSatisfy(\.isLetter)
    else { return nil }
    return "https://\(text)"
  }

  nonisolated static func isQuestion(_ text: String) -> Bool {
    if text.hasSuffix("?") { return true }
    let words = text.lowercased().split(whereSeparator: \.isWhitespace)
    if words.count >= 5 { return true }
    let starters: Set<String> = [
      "what", "why", "how", "who", "when", "where", "which", "should", "can", "could", "would",
      "is", "are", "does", "do", "compare", "find", "summarise", "summarize", "explain", "help",
      "research", "tell", "give", "show", "write", "draft", "list",
    ]
    return words.first.map { starters.contains(String($0)) } ?? false
  }

  nonisolated static func searchURL(_ text: String) -> String {
    var components = URLComponents(string: "https://www.google.com/search")
    components?.queryItems = [URLQueryItem(name: "q", value: text)]
    return components?.url?.absoluteString ?? "https://www.google.com"
  }
}
