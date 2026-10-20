import Foundation

public enum LocalhostURLDetector {
  public static func urls(in text: String, limit: Int = 8) -> [URL] {
    guard limit > 0 else { return [] }
    let pattern =
      #"https?://(?:localhost|127\.0\.0\.1|\[::1\])(?![A-Za-z0-9.-])(?::[0-9]{1,5}(?![0-9]))?(?:/[^\s<>\"']*)?"#
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    var seen = Set<String>()
    var results: [URL] = []
    for match in expression.matches(in: text, range: range) {
      guard let matchRange = Range(match.range, in: text) else { continue }
      var candidate = String(text[matchRange])
      while let last = candidate.last, ".,;:!?)]}".contains(last) {
        candidate.removeLast()
      }
      guard
        let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased()),
        ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased()),
        url.user == nil, url.password == nil,
        url.port.map({ (1...65_535).contains($0) }) ?? true
      else { continue }
      let normalized = url.absoluteString
      guard seen.insert(normalized).inserted else { continue }
      results.append(url)
      if results.count == limit { break }
    }
    return results
  }
}
