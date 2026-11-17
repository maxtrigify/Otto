import Foundation
import OttoTools

/// Stops voice starting a session on a model that does not exist.
///
/// A voice model that hears "Sol 6.2" and finds no such model will happily pass along a
/// plausible-looking identifier of its own invention, and the session then fails or runs on
/// something the person never asked for. Otto knows each harness's real models, so the name is
/// checked here, for every voice engine, before the session is created.
public enum VoiceModelCheck {
  public static func checked(spawnArguments: JSONValue, context: VoiceContext?) throws -> JSONValue
  {
    guard case .object(var input) = spawnArguments,
      let harness = input["provider"]?.stringValue,
      let asked = input["model"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
      !asked.isEmpty,
      let known = context?.models?.first(where: {
        $0.harness.caseInsensitiveCompare(harness) == .orderedSame
      })?.models, !known.isEmpty
    else { return spawnArguments }
    if known.contains(where: { $0.id == asked }) { return spawnArguments }

    if let match = match(for: asked, among: known) {
      input["model"] = .string(match.id)
      return .object(input)
    }
    let offered = known.map(\.name).joined(separator: ", ")
    throw ToolRegistryError.invalidInput(
      "\(harness) has no model called \(asked). It offers: \(offered). Ask which one they want, or leave the model out to use the default."
    )
  }

  /// The one real model a spoken name can only mean: the same name written differently, or
  /// every part of what was said found in exactly one model ("Sol 6.1" in "GPT-6.1-Sol").
  static func match(for asked: String, among known: [VoiceModelName]) -> VoiceModelName? {
    let squashed = parts(of: asked).joined()
    if let same = known.first(where: {
      parts(of: $0.id).joined() == squashed || parts(of: $0.name).joined() == squashed
    }) {
      return same
    }
    let wanted = Set(parts(of: asked))
    guard !wanted.isEmpty else { return nil }
    let candidates = known.filter { model in
      wanted.isSubset(of: Set(parts(of: model.name)).union(parts(of: model.id)))
    }
    return candidates.count == 1 ? candidates[0] : nil
  }

  /// "GPT-6.1-Sol" as ["gpt", "6.1", "sol"]: lower-cased words, with a version kept whole.
  static func parts(of name: String) -> [String] {
    name.lowercased()
      .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == ".") })
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
      .filter { !$0.isEmpty }
  }
}
