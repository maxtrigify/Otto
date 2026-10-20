import Foundation

public enum VoiceProviderKind: String, Codable, CaseIterable, Sendable {
  case xai
  case openai
}

public struct VoiceOption: Identifiable, Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var summary: String
  public var recommended: Bool

  public init(id: String, name: String, summary: String, recommended: Bool = false) {
    self.id = id
    self.name = name
    self.summary = summary
    self.recommended = recommended
  }
}

public enum VoiceCatalog {
  public static func defaultVoiceID(for provider: VoiceProviderKind) -> String {
    switch provider {
    case .xai: "eve"
    case .openai: "marin"
    }
  }

  public static func options(for provider: VoiceProviderKind) -> [VoiceOption] {
    switch provider {
    case .xai: xai
    case .openai: openAI
    }
  }

  public static func validatedVoiceID(_ id: String?, for provider: VoiceProviderKind) -> String {
    let options = options(for: provider)
    guard let id, options.contains(where: { $0.id == id }) else {
      return defaultVoiceID(for: provider)
    }
    return id
  }

  public static let xai: [VoiceOption] = [
    VoiceOption(id: "eve", name: "Eve", summary: "Energetic and upbeat", recommended: true),
    VoiceOption(id: "ara", name: "Ara", summary: "Warm and friendly"),
    VoiceOption(id: "sal", name: "Sal", summary: "Smooth and balanced"),
    VoiceOption(id: "carina", name: "Carina", summary: "Soft, empathetic and soothing"),
    VoiceOption(id: "zagan", name: "Zagan", summary: "Powerful and dramatic"),
    VoiceOption(id: "helix", name: "Helix", summary: "Bold, dynamic and energetic"),
    VoiceOption(id: "orion", name: "Orion", summary: "Rich, cinematic and resonant"),
    VoiceOption(id: "luna", name: "Luna", summary: "Gentle, patient and nurturing"),
    VoiceOption(id: "iris", name: "Iris", summary: "Friendly, upbeat and charming"),
    VoiceOption(id: "altair", name: "Altair", summary: "Elegant, refined and premium"),
    VoiceOption(id: "zenith", name: "Zenith", summary: "Sharp, focused and driven"),
    VoiceOption(id: "perseus", name: "Perseus", summary: "Strong, confident and trustworthy"),
    VoiceOption(id: "helios", name: "Helios", summary: "Upbeat, energetic and versatile"),
    VoiceOption(id: "lux", name: "Lux", summary: "Grounded, calm and quietly wise"),
    VoiceOption(id: "kepler", name: "Kepler", summary: "Inventive and charismatic"),
    VoiceOption(id: "rigel", name: "Rigel", summary: "Precise, professional and calm"),
    VoiceOption(id: "cosmo", name: "Cosmo", summary: "Bright, curious and clear"),
    VoiceOption(id: "celeste", name: "Celeste", summary: "Compassionate and reassuring"),
    VoiceOption(id: "ursa", name: "Ursa", summary: "Friendly, warm and steadfast"),
    VoiceOption(id: "sirius", name: "Sirius", summary: "Quick-witted and playful"),
    VoiceOption(id: "lumen", name: "Lumen", summary: "Warm, articulate and engaging"),
    VoiceOption(id: "castor", name: "Castor", summary: "Charismatic and easygoing"),
    VoiceOption(id: "naksh", name: "Naksh", summary: "Warm, thoughtful and wise"),
    VoiceOption(id: "atlas", name: "Atlas", summary: "Confident, commanding and reassuring"),
    VoiceOption(id: "leo", name: "Leo", summary: "Authoritative and strong"),
    VoiceOption(id: "rex", name: "Rex", summary: "Confident and clear"),
  ]

  public static let openAI: [VoiceOption] = [
    VoiceOption(
      id: "marin", name: "Marin", summary: "Best-quality OpenAI voice", recommended: true),
    VoiceOption(
      id: "cedar", name: "Cedar", summary: "Best-quality OpenAI voice", recommended: true),
    VoiceOption(id: "alloy", name: "Alloy", summary: "Built-in OpenAI voice"),
    VoiceOption(id: "ash", name: "Ash", summary: "Built-in OpenAI voice"),
    VoiceOption(id: "ballad", name: "Ballad", summary: "Built-in OpenAI voice"),
    VoiceOption(id: "coral", name: "Coral", summary: "Built-in OpenAI voice"),
    VoiceOption(id: "echo", name: "Echo", summary: "Built-in OpenAI voice"),
    VoiceOption(id: "sage", name: "Sage", summary: "Built-in OpenAI voice"),
    VoiceOption(id: "shimmer", name: "Shimmer", summary: "Built-in OpenAI voice"),
    VoiceOption(id: "verse", name: "Verse", summary: "Built-in OpenAI voice"),
  ]
}
