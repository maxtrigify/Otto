import Foundation
import OttoMemory
import OttoModels

extension ApplicationServices {
  public func searchWorkspace(_ query: String, limit: Int = 40) async -> [BotSearchResult] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }
    var results: [BotSearchResult] = []

    for profile in agentProfiles.activeProfiles {
      guard Self.matchesSearch(needle, values: [profile.name, profile.jobTitle, profile.role])
      else {
        continue
      }
      let channelID = botChannels.canonicalChannel(for: profile.id)?.id
      results.append(
        BotSearchResult(
          id: "bot:\(profile.id)", kind: .bot, title: profile.name,
          excerpt: profile.jobTitle ?? profile.role,
          deepLink: .bot(profileID: profile.id, channelID: channelID),
          score: Self.searchScore(needle, title: profile.name)))
    }

    let names = Dictionary(uniqueKeysWithValues: agentProfiles.profiles.map { ($0.id, $0.name) })
    for channel in botChannels.channels where !channel.archived {
      let title =
        channel.kind == .group
        ? channel.displayTitle(profileNames: names)
        : names[channel.profileID] ?? "Bot"
      if Self.matchesSearch(needle, values: [title, channel.instructions]) {
        let link: BotActivityDeepLink =
          channel.kind == .group
          ? .team(channelID: channel.id)
          : .bot(profileID: channel.profileID, channelID: channel.id)
        results.append(
          BotSearchResult(
            id: "room:\(channel.id)", kind: .room, title: title,
            excerpt: channel.instructions ?? "Conversation", deepLink: link,
            score: Self.searchScore(needle, title: title)))
      }
    }

    for session in botGroups.allSessions {
      for message in session.messages where Self.matchesSearch(needle, values: [message.text]) {
        results.append(
          BotSearchResult(
            id: "message:\(message.id)", kind: .message, title: "Team message",
            excerpt: String(message.text.prefix(300)),
            deepLink: .team(channelID: session.channelID),
            score: 0.75))
      }
    }
    for projection in botContext.projections {
      let profileID = botChannels.channel(id: projection.channelID)?.profileID
      let link =
        profileID.map {
          BotActivityDeepLink.bot(profileID: $0, channelID: projection.channelID)
        } ?? .team(channelID: projection.channelID)
      for message in projection.recentMessages
      where Self.matchesSearch(needle, values: [message.speaker, message.text]) {
        results.append(
          BotSearchResult(
            id: "context-message:\(message.id)", kind: .message, title: message.speaker,
            excerpt: String(message.text.prefix(300)), deepLink: link, score: 0.7))
      }
      for artifact in projection.artifacts where Self.matchesSearch(needle, values: [artifact]) {
        results.append(
          BotSearchResult(
            id: "artifact:\(projection.channelID):\(Self.stableSearchID(artifact))",
            kind: .artifact,
            title: "Artifact", excerpt: artifact, deepLink: link, score: 0.65))
      }
    }
    for routine in routines.routines
    where Self.matchesSearch(needle, values: [routine.name, routine.instruction]) {
      results.append(
        BotSearchResult(
          id: "routine:\(routine.id)", kind: .routine, title: routine.name,
          excerpt: routine.instruction, deepLink: .routine(routineID: routine.id, runID: nil),
          score: Self.searchScore(needle, title: routine.name)))
    }

    if let brain {
      var seen = Set<String>()
      let shared =
        (try? await brain.search(
          needle, limit: limit, authorisedScopes: [.project, .canvas])) ?? []
      for hit in shared where seen.insert(hit.id).inserted {
        results.append(Self.memoryResult(hit, profileID: nil))
      }
      for profile in agentProfiles.activeProfiles {
        let privateHits =
          (try? await brain.search(
            needle, limit: 8, authorisedScopes: [.agentRole], authorisedProfileID: profile.id))
          ?? []
        for hit in privateHits where seen.insert(hit.id).inserted {
          results.append(Self.memoryResult(hit, profileID: profile.id))
        }
      }
    }
    return Array(
      results.sorted { lhs, rhs in
        lhs.score == rhs.score ? lhs.title < rhs.title : lhs.score > rhs.score
      }.prefix(max(1, limit)))
  }

  private nonisolated static func memoryResult(
    _ hit: BrainSearchHit, profileID: UUID?
  ) -> BotSearchResult {
    BotSearchResult(
      id: "memory:\(hit.id)", kind: .memory, title: hit.title, excerpt: hit.excerpt,
      deepLink: .memory(recordID: hit.id, profileID: profileID),
      score: 0.6 + min(0.3, hit.trustScore * 0.3))
  }

  private nonisolated static func matchesSearch(_ query: String, values: [String?]) -> Bool {
    let needle = query.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    return values.compactMap { $0 }.contains {
      $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .contains(needle)
    }
  }

  private nonisolated static func searchScore(_ query: String, title: String) -> Double {
    let query = query.lowercased()
    let title = title.lowercased()
    if query == title { return 1 }
    if title.hasPrefix(query) { return 0.9 }
    return 0.8
  }

  private nonisolated static func stableSearchID(_ value: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x1000_0000_01b3
    }
    return String(format: "%016llx", hash)
  }
}
