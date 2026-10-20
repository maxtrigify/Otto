import Foundation
import OttoModels
import Testing

@testable import OttoApp

@Suite("Bot and team avatar presentation")
struct BotAvatarViewTests {
  @Test("Initials prefer a stored value and otherwise derive stably from the name")
  func stableInitials() {
    let profileID = UUID()
    #expect(
      BotAvatarPresentation(
        id: profileID,
        name: "Research Scout",
        appearance: BotAppearance(profileID: profileID, initials: " RS ")
      ).initials == "RS")
    #expect(BotAvatarPresentation(id: profileID, name: "Research Scout").initials == "RS")
    #expect(BotAvatarPresentation(id: profileID, name: "Bowie").initials == "B")
  }

  @Test("Every derived state has distinct non-colour accessibility semantics")
  func accessibleStates() {
    let labels = BotAvatarState.allCases.map(\.accessibilityLabel)
    #expect(Set(labels).count == BotAvatarState.allCases.count)
    #expect(BotAvatarState.needsUser.accessibilityLabel == "Needs you")
    #expect(BotAvatarState.failed.accessibilityLabel == "Failed")
  }

  @Test("Team composition shows one, overlaps two, triangles three, and caps overflow")
  func teamComposition() {
    #expect(TeamAvatarComposition(count: 1).visibleCount == 1)
    #expect(TeamAvatarComposition(count: 2).visibleCount == 2)
    #expect(TeamAvatarComposition(count: 3).visibleCount == 3)
    #expect(TeamAvatarComposition(count: 7).visibleCount == 3)
    #expect(TeamAvatarComposition(count: 7).overflowCount == 4)

    let two = TeamAvatarComposition(count: 2)
    #expect(two.offset(for: 0, containerSize: 40).width < 0)
    #expect(two.offset(for: 1, containerSize: 40).width > 0)
    let three = TeamAvatarComposition(count: 3)
    #expect(three.offset(for: 2, containerSize: 40).height > 0)
  }
}
