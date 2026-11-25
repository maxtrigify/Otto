import OttoModels
import SwiftUI

/// What Otto's checker found before the work reached its reviewer (#127): what it couldn't
/// judge first, then what failed and was fixed, then everything that passed folded into a line.
struct TicketCheckView: View {
  let ticket: Ticket
  @Environment(\.ottoPalette) private var palette
  @State private var showingAllPassed = false

  var body: some View {
    if let check = ticket.latestCheck {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Image(systemName: "checkmark.seal")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(palette.cyan)
          Text("Checked before handing back").font(.ottoDisplay(15).weight(.semibold))
          Spacer(minLength: 8)
          Text(byline(check)).font(.ottoDisplay(12)).foregroundStyle(palette.muted)
            .lineLimit(1)
        }
        Text(caption(check)).font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
          .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 0) {
          let rows = orderedRows(check)
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, verdict in
            verdictRow(verdict, fixedEarlier: wasFixed(verdict))
              .overlay(alignment: .top) {
                if index > 0 { Divider().overlay(palette.paper.opacity(0.06)) }
              }
          }
          let passed = check.passed.filter { !wasFixed($0) }
          if !passed.isEmpty {
            if showingAllPassed {
              ForEach(passed) { verdict in
                verdictRow(verdict, fixedEarlier: false)
                  .overlay(alignment: .top) { Divider().overlay(palette.paper.opacity(0.06)) }
              }
            } else {
              passedSummary(passed, divided: !rows.isEmpty)
            }
          }
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(
          palette.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
      .frame(maxWidth: .infinity, alignment: .leading)
      .ottoGlass(cornerRadius: 12)
      .accessibilityIdentifier("tickets.checked")
    }
  }

  private func byline(_ check: StandardsCheck) -> String {
    // The check's own count, so an earlier round's check still reads right after a send-back.
    "\(check.checker) · \(check.attempt) \(check.attempt == 1 ? "try" : "tries")"
  }

  private func caption(_ check: StandardsCheck) -> String {
    var text = check.summary + "."
    if !check.unsure.isEmpty {
      text += " What it couldn't judge is yours to look at."
    } else if !check.failures.isEmpty {
      text += " It still fails after the bot's tries, so it's with you as it is."
    }
    return text
      + " The checker saw the brief and the work, not the bot's chat."
  }

  /// Unsure first, then failures, then standards that failed earlier and now pass.
  private func orderedRows(_ check: StandardsCheck) -> [StandardsCheck.Verdict] {
    check.unsure + check.failures + check.passed.filter(wasFixed)
  }

  /// Failed on an earlier try of this round and passes now.
  private func wasFixed(_ verdict: StandardsCheck.Verdict) -> Bool {
    guard verdict.outcome == .pass, let checks = ticket.checks, checks.count > 1 else {
      return false
    }
    let round = checks.suffix(ticket.checksThisRound).dropLast()
    return round.contains { earlier in
      earlier.verdicts.contains { $0.standard == verdict.standard && $0.outcome == .fail }
    }
  }

  private func verdictRow(_ verdict: StandardsCheck.Verdict, fixedEarlier: Bool) -> some View {
    HStack(alignment: .top, spacing: 10) {
      mark(verdict.outcome)
        .frame(width: 16, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(verdict.standard).font(.ottoDisplay(13)).foregroundStyle(palette.paper)
            .fixedSize(horizontal: false, vertical: true)
          if verdict.ticketOnly {
            Text("· this ticket only").font(.ottoDisplay(12)).foregroundStyle(palette.muted)
          }
        }
        Group {
          if fixedEarlier {
            Text("Failed on an earlier try, fixed by the bot. ").foregroundStyle(palette.red)
              + Text(verdict.evidence)
          } else {
            Text(verdict.evidence)
          }
        }
        .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 10)
    .accessibilityIdentifier("tickets.checked.\(verdict.outcome.rawValue)")
  }

  private func passedSummary(_ passed: [StandardsCheck.Verdict], divided: Bool) -> some View {
    HStack(alignment: .center, spacing: 10) {
      mark(.pass).frame(width: 16, alignment: .leading)
      Text(
        "\(passed.count) passed: " + passed.map(\.standard).joined(separator: " · ")
      )
      .font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
      .lineLimit(2)
      Spacer(minLength: 8)
      Button("Show all") { showingAllPassed = true }
        .buttonStyle(.plain)
        .font(.ottoDisplay(12)).foregroundStyle(palette.cyan)
    }
    .padding(.vertical, 10)
    .overlay(alignment: .top) {
      if divided { Divider().overlay(palette.paper.opacity(0.06)) }
    }
  }

  @ViewBuilder private func mark(_ outcome: StandardsCheck.Outcome) -> some View {
    switch outcome {
    case .pass:
      Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
        .foregroundStyle(palette.cyan)
    case .fail:
      Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
        .foregroundStyle(palette.red)
    case .unsure:
      Text("?").font(.ottoDisplay(13).weight(.semibold)).foregroundStyle(palette.amber)
    }
  }
}

/// "Keep this for next time?" under a send-back note: Otto turns the note into standards,
/// tries each on the work being sent back, and ticks the ones that would have caught it.
struct StandardProposalsView: View {
  let proposals: [StandardProposal]
  @Binding var selected: Set<UUID>
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Keep this for next time?").font(.ottoDisplay(13).weight(.semibold))
        Text(
          "Otto turned your note into checks and tried them on this work. Only ones it fails "
            + "would have caught the problem."
        )
        .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.bottom, 6)
      ForEach(proposals) { proposal in
        Button {
          if selected.contains(proposal.id) {
            selected.remove(proposal.id)
          } else {
            selected.insert(proposal.id)
          }
        } label: {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected.contains(proposal.id) ? "checkmark.square.fill" : "square")
              .font(.system(size: 14))
              .foregroundStyle(selected.contains(proposal.id) ? palette.signal : palette.muted)
            VStack(alignment: .leading, spacing: 2) {
              Text(proposal.text).font(.ottoDisplay(13))
                .foregroundStyle(palette.paper.opacity(proposal.catchesIt ? 1 : 0.7))
                .fixedSize(horizontal: false, vertical: true)
              (Text(proposal.catchesIt ? "Catches it: " : "Doesn't catch it: ")
                .foregroundStyle(proposal.catchesIt ? palette.cyan : palette.amber)
                + Text(proposal.evidence))
                .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
          .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Divider().overlay(palette.paper.opacity(0.06)) }
        .accessibilityIdentifier("tickets.proposal")
      }
    }
  }
}
