import Foundation
import Testing

@testable import OttoServices

struct PrivatePhoneLinkTests {
  @Test func messagesRecognizesEntireCompactLink() throws {
    for value in [UInt8(0), 127, 255] {
      let fragment = PrivatePhoneLink.fragment(
        installationID: UUID(), sessionID: UUID(), expiresAt: 1_800_000_000,
        hostPublicKey: Data(repeating: value, count: 65),
        capability: Data(repeating: value, count: 32))
      let url = "https://muse-private-sign-in.muse-private.workers.dev/#" + fragment
      #expect(url.count < 250)
      let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
      let matches = detector.matches(in: url, range: NSRange(url.startIndex..., in: url))
      #expect(matches.count == 1)
      #expect(matches.first?.range.length == url.utf16.count)
      #expect(URL(string: url)?.query == nil)
    }
  }
}
