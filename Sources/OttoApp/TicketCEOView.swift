import OttoModels
import OttoServices
import SwiftUI

/// The CEO bot's own page in Tickets: who reports to it, and what it may do without asking,
/// what it asks first, and what it never does. Each power is a rule Otto enforces.
struct TicketCEOView: View {
  @ObservedObject var services: ApplicationServices
  let chief: AgentProfile
  let roster: [BotRosterEntry]
  let avatar: (BotRosterEntry) -> BotAvatarPresentation
  let close: () -> Void
  let newTicket: () -> Void
  let report: (OttoStatusToast) -> Void
  /// Shown as a tab on the CEO's own chat, where the tabs above already say whose page it is.
  var embedded = false
  @Environment(\.ottoPalette) private var palette
  /// A rule being typed, per column.
  @State private var drafts: [CEORules.Custom.Level: String] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(EdgeInsets(top: 26, leading: 32, bottom: 22, trailing: 32))
      ScrollView {
        VStack(alignment: .leading, spacing: 26) {
          team
          VStack(alignment: .leading, spacing: 10) {
            Text(
              "WHAT \(chief.name.uppercased()) MAY DO · USE THE MENUS, OR ADD A RULE OF YOUR OWN"
            )
            .font(.ottoMono(9.5)).tracking(1.9).foregroundStyle(palette.muted)
            powers
          }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
      }
    }
    .accessibilityIdentifier("tickets.ceo")
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      if let entry = roster.first(where: { $0.profile.id == chief.id }) {
        BotAvatarView(presentation: avatar(entry), size: 44, showsStateBadge: false)
      }
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(chief.name).font(.ottoDisplay(24).weight(.semibold))
          Text("CEO").font(.ottoMono(8.5, weight: .bold)).tracking(1.2)
            .foregroundStyle(palette.signal)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(palette.signal.opacity(0.35)))
        }
        HStack(spacing: 6) {
          if !embedded {
            Button("Tickets", action: close)
              .buttonStyle(.plain).foregroundStyle(palette.cyan)
              .accessibilityIdentifier("tickets.ceo.back")
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
              .foregroundStyle(palette.muted)
          }
          Text("Splits tickets up, hands them to its team and checks what comes back")
            .foregroundStyle(palette.muted)
        }
        .font(.ottoDisplay(12.5))
      }
      Spacer(minLength: 12)
      Button {
        newTicket()
      } label: {
        Label("Give \(chief.name) a goal", systemImage: "plus")
          .font(.ottoDisplay(12.5).weight(.semibold))
          .padding(.horizontal, 12).padding(.vertical, 6)
      }
      .buttonStyle(OttoPrimaryButtonStyle())
      .fixedSize()
      TicketChoice(
        options: roster.filter { $0.profile.id != chief.id }.map { entry in
          TicketChoice.Option(
            id: entry.profile.id.uuidString, title: "Make \(entry.profile.name) the CEO"
          ) {
            change(to: entry.profile.id)
          }
        } + [
          TicketChoice.Option(id: "none", title: "Nobody is CEO") { change(to: nil) }
        ]
      ) {
        Text("Change").font(.ottoDisplay(12.5).weight(.medium))
          .padding(.horizontal, 12).padding(.vertical, 6)
          .background(palette.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      }
      .accessibilityIdentifier("tickets.ceo.change")
    }
  }

  private func change(to profileID: UUID?) {
    do {
      try services.setCEO(profileID: profileID)
      if profileID == nil { close() }
    } catch {
      report(OttoStatusToast(kind: .error, title: error.localizedDescription))
    }
  }

  // MARK: Team

  private var team: some View {
    let others = roster.filter { $0.profile.id != chief.id }
    let reporting = others.filter { services.reportsToCEO($0.profile.id) }
    return VStack(alignment: .leading, spacing: 0) {
      sectionLabel("Reports to \(chief.name) · \(reporting.count) of \(others.count)")
      if others.isEmpty {
        Text("There are no other bots yet. Hire one and it joins \(chief.name)’s team.")
          .font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
          .padding(.vertical, 12)
      }
      ForEach(others) { entry in
        teamRow(entry)
      }
      Text("\(chief.name) can only give tickets to the bots switched on here.")
        .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
        .padding(.top, 10)
    }
    .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
    .ottoGlass(cornerRadius: 12)
  }

  private func teamRow(_ entry: BotRosterEntry) -> some View {
    let job = (entry.profile.jobTitle ?? entry.profile.role)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return HStack(spacing: 12) {
      BotAvatarView(presentation: avatar(entry), size: 24, showsStateBadge: false)
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.profile.name).font(.ottoDisplay(13).weight(.medium))
        if !job.isEmpty {
          Text(job).font(.ottoDisplay(11.5)).foregroundStyle(palette.muted).lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      Toggle(
        "",
        isOn: Binding(
          get: { services.reportsToCEO(entry.profile.id) },
          set: { on in
            do {
              try services.setReportsToCEO(entry.profile.id, on)
            } catch {
              report(OttoStatusToast(kind: .error, title: error.localizedDescription))
            }
          })
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
      .accessibilityLabel("\(entry.profile.name) reports to \(chief.name)")
    }
    .frame(height: 46)
    .overlay(alignment: .top) {
      Rectangle().fill(palette.paper.opacity(0.07)).frame(height: 1)
    }
  }

  // MARK: Powers

  private var powers: some View {
    let all = services.ceoPowers()
    return HStack(alignment: .top, spacing: 14) {
      column(
        "Does without asking", tint: palette.cyan,
        caption: "\(chief.name) just does these. Each one shows on the ticket.",
        rules: all.filter { $0.level == .does }, level: .does,
        prompt: "Add something it may just do")
      column(
        "Asks you first", tint: palette.signal,
        caption: "These stop and wait for you, on the ticket or in its chat.",
        rules: all.filter { $0.level == .asks }, level: .asks,
        prompt: "Add something it must ask you about")
      column(
        "Never", tint: palette.red,
        caption: "Otto refuses the built-in ones. Rules you add are ones \(chief.name) is told.",
        rules: all.filter { $0.level == .never }, level: .never,
        prompt: "Add something it must never do")
    }
  }

  private func column(
    _ title: String, tint: Color, caption: String, rules: [CEOPower],
    level: CEORules.Custom.Level, prompt: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Circle().fill(tint).frame(width: 8, height: 8)
        Text("\(rules.count) RULES").font(.ottoMono(9.5)).tracking(1.9)
          .foregroundStyle(palette.muted)
      }
      Text(title).font(.ottoDisplay(17).weight(.semibold))
        .padding(.top, 6)
      Text(caption).font(.ottoDisplay(12)).foregroundStyle(palette.muted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 4)
        .padding(.bottom, 12)
      ForEach(rules) { rule in
        ruleRow(rule)
      }
      addRule(level: level, prompt: prompt)
    }
    .padding(EdgeInsets(top: 18, leading: 20, bottom: 14, trailing: 20))
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .ottoGlass(cornerRadius: 12)
  }

  /// One rule. A rule you can change shows its current choice as a menu; a built-in one shows
  /// a lock, so it is plain which is which.
  private func ruleRow(_ rule: CEOPower) -> some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(rule.text).font(.ottoDisplay(13))
          .foregroundStyle(palette.paper.opacity(0.92))
          .fixedSize(horizontal: false, vertical: true)
        if let detail = rule.detail {
          Text(detail).font(.ottoDisplay(11.5)).foregroundStyle(palette.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        if rule.customID != nil {
          Text("YOUR RULE · \(chief.name.uppercased()) IS TOLD THIS EVERY TURN")
            .font(.ottoMono(8.5)).tracking(1.2).foregroundStyle(palette.muted)
            .padding(.top, 1)
        }
      }
      Spacer(minLength: 6)
      if let customID = rule.customID {
        Button {
          do {
            try services.removeCEORule(id: customID)
          } catch {
            report(OttoStatusToast(kind: .error, title: error.localizedDescription))
          }
        } label: {
          Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            .foregroundStyle(palette.muted)
            .frame(width: 22, height: 22)
            .background(palette.raised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Remove this rule")
        .accessibilityLabel("Remove rule: \(rule.text)")
      } else if let control = rule.control {
        TicketChoice(
          options: rule.choices.map { choice in
            TicketChoice.Option(
              id: choice.id, title: choice.selected ? "\(choice.title)  ✓" : choice.title
            ) {
              change(control, to: choice.id)
            }
          }
        ) {
          HStack(spacing: 5) {
            Text(rule.choices.first { $0.selected }?.title ?? "Change")
              .font(.ottoDisplay(12).weight(.medium)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
          }
          .fixedSize()
          .padding(.horizontal, 9).padding(.vertical, 5)
          .background(palette.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .help("Change this rule")
        .accessibilityIdentifier("tickets.ceo.rule.\(control.rawValue)")
      } else {
        Image(systemName: "lock.fill").font(.system(size: 9))
          .foregroundStyle(palette.muted.opacity(0.6))
          .padding(.top, 4)
          .help("Built in. Otto enforces this one itself.")
      }
    }
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .top) {
      Rectangle().fill(palette.paper.opacity(0.07)).frame(height: 1)
    }
  }

  /// A rule in the person's own words. Otto passes it to the CEO; it can't check free text.
  private func addRule(level: CEORules.Custom.Level, prompt: String) -> some View {
    let text = Binding(
      get: { drafts[level] ?? "" },
      set: { drafts[level] = $0 })
    return HStack(spacing: 8) {
      TextField(prompt, text: text)
        .textFieldStyle(.plain)
        .font(.ottoDisplay(12.5))
        .onSubmit { submitRule(level) }
        .accessibilityIdentifier("tickets.ceo.addRule.\(level.rawValue)")
      if !(drafts[level] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Button("Add") { submitRule(level) }
          .buttonStyle(.plain)
          .font(.ottoDisplay(12.5).weight(.semibold)).foregroundStyle(palette.cyan)
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(
      palette.ink.opacity(0.48), in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .padding(.top, 10)
  }

  private func submitRule(_ level: CEORules.Custom.Level) {
    do {
      try services.addCEORule(level: level, text: drafts[level] ?? "")
      drafts[level] = ""
    } catch {
      report(OttoStatusToast(kind: .error, title: error.localizedDescription))
    }
  }

  private func change(_ control: CEOPower.Control, to choice: String) {
    do {
      try services.setCEOPower(control, choice: choice)
    } catch {
      report(OttoStatusToast(kind: .error, title: error.localizedDescription))
    }
  }

  private func sectionLabel(_ text: String) -> some View {
    Text(text.uppercased()).font(.ottoMono(9.5)).tracking(1.9).foregroundStyle(palette.muted)
      .padding(.bottom, 8)
  }
}

/// The tabs on the CEO bot's own chat.
enum CEOChatTab: String, CaseIterable {
  case chat
  case tickets
  case powers

  var title: String {
    switch self {
    case .chat: "Chat"
    case .tickets: "Tickets"
    case .powers: "Powers & team"
    }
  }
}

/// A quiet strip under the CEO's chat header: its chat, the tickets it owns or handed out, and
/// what it is allowed to do. Only the CEO bot has it; every other bot's chat is unchanged.
struct CEOChatTabs: View {
  let name: String
  let selection: CEOChatTab
  let openTickets: Int
  let select: (CEOChatTab) -> Void
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    HStack(spacing: 4) {
      Text("CEO").font(.ottoMono(8.5, weight: .bold)).tracking(1.2)
        .foregroundStyle(palette.signal)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(palette.signal.opacity(0.35)))
        .padding(.trailing, 8)
      ForEach(CEOChatTab.allCases, id: \.self) { tab in
        Button {
          select(tab)
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(tab.title)
              .font(.ottoDisplay(12.5).weight(selection == tab ? .medium : .regular))
              .foregroundStyle(selection == tab ? palette.paper : palette.muted)
            if tab == .tickets, openTickets > 0 {
              Text("\(openTickets)").font(.ottoMono(9.5)).foregroundStyle(palette.muted)
            }
          }
          .padding(.horizontal, 12).padding(.vertical, 6)
          .background(
            palette.paper.opacity(selection == tab ? 0.09 : 0),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ceo.tab.\(tab.rawValue)")
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 8)
    .background(palette.workspaceSurface)
    .overlay(alignment: .bottom) {
      Rectangle().fill(palette.paper.opacity(0.06)).frame(height: 1)
    }
    .accessibilityIdentifier("ceo.tabs")
  }
}
