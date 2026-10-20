import OttoModels
import OttoRuntime
import SwiftUI

/// Presentation only: the original option string is always returned to the waiting agent.
struct AgentChoiceOption: Equatable {
  let title: String
  let detail: String?
  let recommended: Bool

  init(_ raw: String) {
    let parts = raw.components(separatedBy: " — ")
    let heading = (parts.first ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
    let marker = " (recommended)"
    recommended = heading.lowercased().hasSuffix(marker)
    title = recommended ? String(heading.dropLast(marker.count)) : heading
    let description = parts.dropFirst().joined(separator: " — ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    detail = description.isEmpty ? nil : description
  }
}

struct AgentChoiceCardState {
  var selected: Set<Int> = []
  var customAnswer = ""
  var showsCustomAnswer = false
  var submittedAnswer: String?

  mutating func choose(_ index: Int, in prompt: AgentChoicePrompt) -> String? {
    guard submittedAnswer == nil, prompt.choices.indices.contains(index) else { return nil }
    if prompt.multiSelect {
      if !selected.insert(index).inserted { selected.remove(index) }
      return nil
    }
    return submit(prompt.choices[index])
  }

  mutating func continueWithSelection(in prompt: AgentChoicePrompt) -> String? {
    guard !selected.isEmpty else { return nil }
    return submit(
      prompt.choices.enumerated().filter { selected.contains($0.offset) }
        .map(\.element).joined(separator: ", "))
  }

  mutating func submit(_ answer: String) -> String? {
    guard submittedAnswer == nil,
      !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    submittedAnswer = answer
    return answer
  }
}

/// Paper: Questions · clear choices. Shared by bot and session conversations.
///
/// Motion follows Fluid Functionalism's AskUserQuestions: one hover fill glides between the
/// options on the fast tier, a picked option keeps its own accent on the moderate tier, the
/// card's height settles on the slow spring when the prompt or the mode changes, and the
/// footer controls scale in and out rather than popping.
struct AgentChoiceCard: View {
  let prompt: AgentChoicePrompt
  let agentName: String
  let scale: CGFloat
  let palette: OttoPalette
  let answer: (String) -> Void
  @State private var state = AgentChoiceCardState()
  @FocusState private var customAnswerFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.ottoMotion) private var motion

  init(
    prompt: AgentChoicePrompt, agentName: String, scale: CGFloat, palette: OttoPalette,
    initialState: AgentChoiceCardState = AgentChoiceCardState(), answer: @escaping (String) -> Void
  ) {
    self.prompt = prompt
    self.agentName = agentName
    self.scale = scale
    self.palette = palette
    self.answer = answer
    _state = State(initialValue: initialState)
  }

  private var unit: CGFloat { max(0.75, min(scale, 1.2)) }

  /// The three shapes the card takes; a change between them animates the card's height.
  private var mode: Int {
    if state.submittedAnswer != nil { return 2 }
    if state.showsCustomAnswer || prompt.choices.isEmpty { return 1 }
    return 0
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20 * unit) {
      VStack(alignment: .leading, spacing: 10 * unit) {
        Text(state.submittedAnswer == nil ? "\(agentName) · NEEDS YOUR INPUT" : "ANSWERED")
          .font(.ottoDisplay(12 * unit).weight(.semibold))
          .foregroundStyle(palette.choiceAccent)
          .contentTransition(.opacity)
        Text(prompt.question)
          .font(.ottoDisplay(22 * unit).weight(.semibold))
          .foregroundStyle(palette.paper)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        if state.submittedAnswer == nil {
          Text(
            state.showsCustomAnswer || prompt.choices.isEmpty
              ? "Write your answer below."
              : (prompt.multiSelect
                ? "Choose one or more, then continue." : "Click a choice to reply.")
          )
          .font(.ottoDisplay(13 * unit))
          .foregroundStyle(palette.muted)
          .transition(.opacity)
        }
      }
      if let submitted = state.submittedAnswer {
        Label(receiptText(submitted), systemImage: "checkmark")
          .font(.ottoDisplay(15 * unit).weight(.medium))
          .foregroundStyle(palette.paper)
          .fixedSize(horizontal: false, vertical: true)
          .transition(.ottoUnfold(reduceMotion: reduceMotion))
      } else if state.showsCustomAnswer || prompt.choices.isEmpty {
        customAnswer
          .transition(.ottoUnfold(reduceMotion: reduceMotion))
      } else {
        OttoFluidHover(
          axis: .vertical,
          style: OttoFluidHoverStyle(
            fill: palette.signal.opacity(0.06), cornerRadius: 10 * unit)
        ) {
          VStack(spacing: 8 * unit) {
            ForEach(Array(prompt.choices.enumerated()), id: \.offset) { index, raw in
              optionRow(raw, index: index)
                .ottoHoverItem(index)
            }
          }
        }
        .transition(.ottoUnfold(reduceMotion: reduceMotion))
        footer
          .transition(.opacity)
      }
    }
    .padding(24 * unit)
    .frame(maxWidth: 760 * unit, alignment: .leading)
    .background(palette.raised, in: RoundedRectangle(cornerRadius: 14 * unit))
    .overlay {
      RoundedRectangle(cornerRadius: 14 * unit)
        .stroke(palette.paper.opacity(0.12), lineWidth: 1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(motion.enter(.slow), value: mode)
    .animation(motion.enter(.slow), value: prompt)
    .onChange(of: prompt) { _, _ in
      state = AgentChoiceCardState()
      customAnswerFocused = false
    }
  }

  private func receiptText(_ submitted: String) -> String {
    if prompt.choices.contains(submitted) { return AgentChoiceOption(submitted).title }
    let selected = prompt.choices.enumerated().filter { state.selected.contains($0.offset) }
      .map(\.element)
    if !selected.isEmpty, selected.joined(separator: ", ") == submitted {
      return selected.map { AgentChoiceOption($0).title }.joined(separator: " · ")
    }
    return submitted
  }

  private func optionRow(_ raw: String, index: Int) -> some View {
    let option = AgentChoiceOption(raw)
    let picked = state.selected.contains(index)
    return Button {
      withAnimation(motion.enter(.fast)) {
        if let response = state.choose(index, in: prompt) { answer(response) }
      }
    } label: {
      HStack(alignment: .center, spacing: 14 * unit) {
        Group {
          if prompt.multiSelect {
            checkbox(picked: picked)
          } else {
            Text("\(index + 1)")
              .font(.ottoMono(12 * unit))
              .foregroundStyle(palette.muted)
              .frame(width: 28 * unit, height: 28 * unit)
              .overlay {
                RoundedRectangle(cornerRadius: 7 * unit)
                  .stroke(palette.paper.opacity(0.12), lineWidth: 1)
              }
          }
        }
        .frame(width: 28 * unit)
        VStack(alignment: .leading, spacing: 5 * unit) {
          optionHeading(option)
          if let detail = option.detail {
            Text(detail)
              .font(.ottoDisplay(13 * unit))
              .foregroundStyle(palette.muted)
              .lineSpacing(3 * unit)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        if !prompt.multiSelect {
          Image(systemName: "arrow.right")
            .font(.system(size: 14 * unit))
            .foregroundStyle(palette.muted)
            .frame(width: 20 * unit)
        }
      }
      .padding(14 * unit)
      .frame(minHeight: 56 * unit)
      // The picked state is its own layer under the travelling hover fill.
      .background(
        palette.signal.opacity(picked ? 0.08 : 0),
        in: RoundedRectangle(cornerRadius: 10 * unit)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 10 * unit)
          .stroke(picked ? palette.choiceAccent : palette.paper.opacity(0.12), lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 10 * unit))
      .animation(motion.enter(.moderate), value: picked)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(raw)
    .accessibilityValue(prompt.multiSelect ? (picked ? "Selected" : "Not selected") : "")
    .accessibilityAddTraits(picked ? .isSelected : [])
  }

  /// A square whose tick draws itself in on pick and undraws on unpick, instead of two
  /// symbols swapping.
  private func checkbox(picked: Bool) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 5 * unit)
        .fill(picked ? palette.choiceAccent : Color.clear)
      RoundedRectangle(cornerRadius: 5 * unit)
        .stroke(picked ? palette.choiceAccent : palette.muted, lineWidth: 1.5)
      OttoCheckmark()
        .trim(from: 0, to: picked ? 1 : 0)
        .stroke(
          palette.onSignal,
          style: StrokeStyle(lineWidth: 2 * unit, lineCap: .round, lineJoin: .round)
        )
        .padding(5 * unit)
        .animation(
          picked ? .easeOut(duration: 0.08) : .easeIn(duration: 0.04), value: picked)
    }
    .frame(width: 20 * unit, height: 20 * unit)
    .animation(motion.tint, value: picked)
  }

  @ViewBuilder
  private func optionHeading(_ option: AgentChoiceOption) -> some View {
    let title = Text(option.title)
      .font(.ottoDisplay(15 * unit).weight(.semibold))
      .foregroundStyle(palette.paper)
    if option.recommended {
      let badge = Text("Recommended")
        .font(.ottoDisplay(11 * unit).weight(.semibold))
        .foregroundStyle(palette.choiceAccent)
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 12 * unit) {
          title.fixedSize()
          badge.fixedSize()
        }
        VStack(alignment: .leading, spacing: 4 * unit) {
          title
          badge
        }
      }
    } else {
      title
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 16 * unit) {
      if prompt.multiSelect {
        HStack {
          Text("\(state.selected.count) selected")
            .font(.ottoDisplay(13 * unit))
            .foregroundStyle(palette.muted)
            .contentTransition(.numericText())
            .animation(motion.fade, value: state.selected.count)
          Spacer(minLength: 8)
          submitButton("Continue", disabled: state.selected.isEmpty) {
            if let response = state.continueWithSelection(in: prompt) { answer(response) }
          }
        }
      }
      Button {
        withAnimation(motion.enter(.slow)) {
          state.showsCustomAnswer = true
        }
        customAnswerFocused = true
      } label: {
        Label("Write my own answer", systemImage: "square.and.pencil")
          .font(.ottoDisplay(14 * unit).weight(.semibold))
          .padding(.horizontal, 8 * unit)
          .padding(.vertical, 6 * unit)
      }
      .buttonStyle(.ottoChrome(cornerRadius: 7 * unit))
      .padding(.horizontal, -8 * unit)
      .foregroundStyle(palette.choiceAccent)
    }
  }

  private var customAnswer: some View {
    VStack(alignment: .leading, spacing: 12 * unit) {
      HStack {
        Text("Your answer").font(.ottoDisplay(13 * unit).weight(.semibold))
          .foregroundStyle(palette.paper)
        Spacer(minLength: 8)
        if !prompt.choices.isEmpty {
          Button("Back to choices") {
            withAnimation(motion.exit(.slow)) { state.showsCustomAnswer = false }
          }
          .buttonStyle(.plain)
          .font(.ottoDisplay(13 * unit))
          .foregroundStyle(palette.choiceAccent)
        }
      }
      TextField(
        "Your answer", text: $state.customAnswer,
        prompt: Text("Type your answer…").foregroundStyle(palette.muted), axis: .vertical
      )
      .textFieldStyle(.plain)
      .font(.ottoDisplay(15 * unit))
      .foregroundStyle(palette.paper)
      .lineLimit(3...8)
      .focused($customAnswerFocused)
      .onAppear { customAnswerFocused = true }
      .accessibilityLabel("Your answer")
      HStack {
        Spacer()
        submitButton(
          "Send answer",
          disabled: state.customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ) {
          if let response = state.submit(state.customAnswer) { answer(response) }
        }
      }
    }
    .padding(16 * unit)
    .overlay {
      RoundedRectangle(cornerRadius: 10 * unit).stroke(palette.choiceAccent, lineWidth: 1)
    }
  }

  private func submitButton(_ title: String, disabled: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack(spacing: 12 * unit) {
        Text(title)
        Image(systemName: "arrow.right")
      }
      .font(.ottoDisplay(14 * unit).weight(.semibold))
      .padding(.horizontal, 18 * unit)
      .padding(.vertical, 12 * unit)
    }
    .buttonStyle(.ottoPrimary(cornerRadius: 8 * unit))
    .disabled(disabled)
  }
}

/// The tick inside a checkbox, drawn as a path so it can trim in and out.
struct OttoCheckmark: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
    path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.08))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
    return path
  }
}
