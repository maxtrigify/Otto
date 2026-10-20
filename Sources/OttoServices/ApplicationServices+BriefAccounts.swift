import Foundation
import OttoModels

extension ApplicationServices {
  /// Gives the morning brief one run per signed-in AI account, so calendars, inboxes and tasks
  /// from every account land in the same brief. Extra runs copy the main brief's schedule, who
  /// runs it and whether it is on; only the account differs. Deleting one of them leaves that
  /// account out from then on.
  @discardableResult
  public func syncMorningBriefAccounts(profileID: UUID) async throws -> [Routine] {
    guard var profile = dailyBrief.profile(id: profileID) else { return [] }
    var links = profile.briefAccountRoutines ?? [:]
    var skipped = Set(profile.briefSkippedAccountIDs ?? [])
    let main = profile.briefRoutineID.flatMap { routines.routine(id: $0) }
    for (key, routineID) in links where routines.routine(id: routineID) == nil {
      if main != nil, let accountID = UUID(uuidString: key) { skipped.insert(accountID) }
      links[key] = nil
    }

    var wanted: [ProviderAccount] = []
    if let main, let provider = briefProvider(for: main.target), provider.supportsProviderAccounts {
      let mainAccount = briefAccountID(main)
      for account in providerAccounts.accounts
      where account.id != mainAccount && !skipped.contains(account.id) {
        if await briefCanUse(account, provider: provider) { wanted.append(account) }
      }
    }

    let wantedKeys = Set(wanted.map(\.id.uuidString))
    for (key, routineID) in links where !wantedKeys.contains(key) {
      try routines.delete(id: routineID)
      links[key] = nil
    }
    var extras: [Routine] = []
    if let main {
      for account in wanted {
        let existing = links[account.id.uuidString].flatMap { routines.routine(id: $0) }
        var routine =
          existing
          ?? Routine(name: "", instruction: "", trigger: main.trigger, target: main.target)
        routine.name = "\(main.name) · \(account.name)"
        routine.instruction = main.instruction
        routine.trigger = main.trigger
        routine.target = main.target
        routine.enabled = main.enabled
        routine.delivery = main.delivery
        routine.permissionMode = main.permissionMode
        routine.quietWhenUnchanged = main.quietWhenUnchanged
        routine.timeZoneIdentifier = main.timeZoneIdentifier
        routine.accountID = account.id
        let saved = routine == existing ? routine : try routines.save(routine)
        links[account.id.uuidString] = saved.id
        extras.append(saved)
      }
    }

    profile.briefAccountRoutines = links.isEmpty ? nil : links
    profile.briefSkippedAccountIDs =
      skipped.isEmpty ? nil : skipped.sorted { $0.uuidString < $1.uuidString }
    if profile != dailyBrief.profile(id: profileID) { try dailyBrief.updateProfile(profile) }
    return extras
  }

  /// Every run behind a profile's morning brief: the main one first, then one per extra account.
  public func morningBriefRoutines(profileID: UUID) -> [Routine] {
    guard let profile = dailyBrief.profile(id: profileID),
      let main = profile.briefRoutineID.flatMap({ routines.routine(id: $0) })
    else { return [] }
    let extras = (profile.briefAccountRoutines ?? [:]).values.compactMap {
      routines.routine(id: $0)
    }
    return [main] + extras.sorted { $0.name < $1.name }
  }

  /// The account name to show beside a brief item when the brief reads several accounts.
  func briefAccountLabel(for routine: Routine, profileID: UUID?) -> String? {
    guard let profile = profileID.flatMap({ dailyBrief.profile(id: $0) }),
      !(profile.briefAccountRoutines ?? [:]).isEmpty,
      profile.briefRoutineID == routine.id
        || (profile.briefAccountRoutines ?? [:]).values.contains(routine.id)
    else { return nil }
    return briefAccountID(routine).flatMap { providerAccounts.account(id: $0)?.name }
      ?? "This Mac"
  }

  /// The provider the brief runs on, when Otto chooses the account. A running agent keeps the
  /// account it was started with, so it gets no extra runs.
  private func briefProvider(for target: RoutineTarget) -> AgentProvider? {
    switch target {
    case .spawnProvider(let provider): AgentProvider(rawValue: provider)
    case .spawnProfile(let id): agentProfiles.profile(id: id)?.provider
    case .existingAgent: nil
    }
  }

  /// The account a brief run uses; nil is this Mac's own login.
  private func briefAccountID(_ routine: Routine) -> UUID? {
    var botAccount: UUID?
    if case .spawnProfile(let id) = routine.target {
      botAccount = agentProfiles.profile(id: id)?.accountID
    }
    return providerAccounts.effectiveAccountID(
      agentAccountID: routine.accountID ?? botAccount, projectDefaultAccountID: nil)
  }

  /// Only accounts that are actually signed in to the brief's provider get a run. An account
  /// that just uses the Mac's own login adds nothing new.
  private func briefCanUse(_ account: ProviderAccount, provider: AgentProvider) async -> Bool {
    switch account.credentialMode(for: provider) {
    case .login: providerAccounts.hasProviderLogin(accountID: account.id, provider: provider)
    case .apiKey: await providerAccounts.hasAPIKey(accountID: account.id, provider: provider)
    case .systemDefault: false
    }
  }
}
