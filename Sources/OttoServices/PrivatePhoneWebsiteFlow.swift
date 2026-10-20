import Foundation
import OttoRPCContracts
import OttoSecurity

extension ApplicationServices {
  func performPrivatePhoneWebsite(
    _ input: WebsiteAccountCommand, nodeID: UUID,
    profileID: UUID, runID: UUID, job: MessagingJob
  ) async throws -> WebsiteAccountResult {
    guard PrivatePhoneConnection.endpoint != nil else {
      throw PrivatePhoneConnection.Failure.unavailable
    }
    let identity = try await privatePhone.installationIdentity()
    let available = try await websiteAccounts.perform(
      WebsiteAccountCommand(action: "list"), botID: profileID, runID: runID
    ).accounts
    let origin: String
    let accountID: UUID
    let created: Bool
    if let id = input.accountID {
      guard let account = available.first(where: { $0.id == id }) else {
        throw WebsiteAccountError.denied
      }
      accountID = id
      origin = account.origin
      created = false
    } else {
      guard input.action == "request_login", let url = input.url else {
        throw WebsiteAccountError.denied
      }
      origin = try WebsiteAccountService.originForLogin(url)
      let matching = available.filter { $0.origin == origin }
      if matching.count == 1 {
        accountID = matching[0].id
        created = false
      } else if matching.isEmpty {
        accountID = try await websiteAccounts.create(origin: origin, bots: .selected([]))
        created = true
      } else {
        throw WebsiteAccountError.denied
      }
    }
    if input.action == "request_login", !created,
      try await websiteAccounts.trySavedLogin(
        accountID: accountID, botID: profileID, runID: runID, url: input.url)
    {
      try Task.checkCancellation()
      guard (try await supervisor.snapshot(agentID: nodeID)).runID == runID,
        messaging.privateJob(for: nodeID)?.id == job.id
      else { throw WebsiteAccountError.denied }
      var result = try await websiteAccounts.perform(
        WebsiteAccountCommand(action: "inspect", accountID: accountID), botID: profileID,
        runID: runID)
      result.accounts = available.filter { $0.id == accountID }
      result.message = "Saved website login restored. Continue the original task."
      return result
    }
    var command = input
    command.accountID = accountID
    let name =
      agentProfiles.activeProfiles.first(where: { $0.id == profileID })?.name ?? "Your agent"
    let deviceID = UUID()
    var request: SecureLoginRequest?
    var completed = false
    var approved = false
    var consented = !created
    let scope = PrivatePhoneSessionLedger.Scope(
      installationID: identity.id,
      workspaceID: websiteAccounts.workspaceID, bindingID: job.binding.id, jobID: job.id,
      botID: profileID, runID: runID, accountID: accountID, origin: origin)
    let detail =
      input.action == "click"
      ? try await websiteAccounts.clickApproval(command, botID: profileID, runID: runID) : ""
    messaging.privatePhoneJobs.insert(job.id)
    defer { messaging.privatePhoneJobs.remove(job.id) }
    do {
      try await privatePhone.run(
        scope: scope,
        sendLink: { [weak self] url in
          guard let self else { throw PrivatePhoneConnection.Failure.unavailable }
          try await self.messaging.sendPrivateLink(url, for: job, nodeID: nodeID)
        },
        isValid: { [weak self] in
          self?.messaging.privateJob(for: nodeID)?.id == job.id
            && self?.agentProfiles.activeProfiles.contains(where: { $0.id == profileID }) == true
        },
        handle: { [weak self] privateInput in
          guard let self else { throw WebsiteAccountError.denied }
          try Task.checkCancellation()
          guard (try await self.supervisor.snapshot(agentID: nodeID)).runID == runID else {
            throw WebsiteAccountError.denied
          }
          let done = { (message: String) in
            PrivatePhoneView(
              mode: "complete", title: "You’re all set.", origin: origin, message: message)
          }
          if ["cancel", "deny"].contains(privateInput.action) {
            return done("Cancelled. You can return to Messages.")
          }
          if input.action == "click" {
            if privateInput.action == "claim" {
              return PrivatePhoneView(
                mode: "approval", title: "Allow this action?", origin: origin, message: detail)
            }
            guard privateInput.action == "approve" else { throw WebsiteAccountError.denied }
            // Recheck the exact revision/element after the human wait. Never switch to a new target.
            _ = try await self.websiteAccounts.clickApproval(
              command, botID: profileID, runID: runID)
            approved = true
            return done("Approved. Your agent is continuing in Messages.")
          }
          if !consented {
            if privateInput.action == "claim" {
              return PrivatePhoneView(
                mode: "consent", title: "Connect this website?", origin: origin,
                message:
                  "Allow \(name) to use this website for your requests? Only this agent gets access. You can revoke it later."
              )
            }
            guard privateInput.action == "consent" else { throw WebsiteAccountError.denied }
            try await self.websiteAccounts.setGrant(
              accountID: accountID, bots: .selected([profileID]))
            consented = true
          }
          if request == nil {
            guard ["claim", "consent"].contains(privateInput.action) else {
              throw WebsiteAccountError.denied
            }
            request = try await self.websiteAccounts.beginLogin(
              accountID: accountID, url: input.url)
          }
          guard let request else { throw WebsiteAccountError.denied }
          if privateInput.action == "finish" {
            _ = try await self.websiteAccounts.secureInput(
              SecureLoginInput(action: .finish, requestID: request.id), deviceID: deviceID)
            completed = true
            return done("Connected. Your agent will reply in Messages.")
          }
          let output: SecureLoginOutput
          if privateInput.action == "input" {
            guard let fields = privateInput.input, fields.action == .click,
              fields.requestID == request.id
            else { throw WebsiteAccountError.denied }
            try await self.websiteAccounts.stageRememberedInput(
              fields, deviceID: deviceID, remember: privateInput.remember == true)
            output = try await self.websiteAccounts.secureInput(fields, deviceID: deviceID)
          } else {
            guard ["claim", "consent"].contains(privateInput.action) else {
              throw WebsiteAccountError.denied
            }
            output = try await self.websiteAccounts.secureInput(
              SecureLoginInput(action: .form, requestID: request.id), deviceID: deviceID)
          }
          return PrivatePhoneView(
            mode: "form", title: "Sign in privately", origin: origin,
            message:
              "Enter your details below. They won’t appear in Messages or your agent’s conversation.",
            form: output)
        })
      try Task.checkCancellation()
      guard (try await supervisor.snapshot(agentID: nodeID)).runID == runID,
        messaging.privateJob(for: nodeID)?.id == job.id
      else { throw WebsiteAccountError.denied }
      if input.action == "click" {
        guard approved else { throw WebsiteAccountError.denied }
        return try await websiteAccounts.perform(command, botID: profileID, runID: runID)
      }
      guard completed else { throw WebsiteAccountError.denied }
      var result = try await websiteAccounts.perform(
        WebsiteAccountCommand(action: "inspect", accountID: accountID), botID: profileID,
        runID: runID)
      result.accounts = try await websiteAccounts.perform(
        WebsiteAccountCommand(action: "list"), botID: profileID, runID: runID
      ).accounts.filter { $0.id == accountID }
      result.message = "Private phone sign-in completed. Continue the original task."
      return result
    } catch {
      if input.action == "request_login", !completed {
        websiteAccounts.cancelLogin(accountID: accountID)
        if created { try? await websiteAccounts.disconnect(accountID: accountID) }
      }
      throw error
    }
  }
}
