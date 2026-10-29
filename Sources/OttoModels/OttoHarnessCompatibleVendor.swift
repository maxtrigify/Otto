import Foundation

/// Model vendors Otto Harness reaches through an OpenAI-compatible chat-completions API. One table
/// feeds both the runtime (where turns are sent) and model discovery (where pickers list models),
/// so adding a vendor never means keeping two endpoint lists in step.
public enum OttoHarnessCompatibleVendor: String, CaseIterable, Sendable {
  case moonshot
  case deepSeek = "deepseek"
  case mistral
  case groq
  case gemini
  case openRouter = "openrouter"

  public var displayName: String {
    switch self {
    case .moonshot: "Moonshot"
    case .deepSeek: "DeepSeek"
    case .mistral: "Mistral"
    case .groq: "Groq"
    case .gemini: "Google Gemini"
    case .openRouter: "OpenRouter"
    }
  }

  private var baseURL: String {
    switch self {
    case .moonshot: "https://api.moonshot.ai/v1"
    case .deepSeek: "https://api.deepseek.com"
    case .mistral: "https://api.mistral.ai/v1"
    case .groq: "https://api.groq.com/openai/v1"
    case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
    case .openRouter: "https://openrouter.ai/api/v1"
    }
  }

  public var chatCompletionsURL: URL { URL(string: baseURL + "/chat/completions")! }
  public var modelsURL: URL { URL(string: baseURL + "/models")! }

  /// Gemini lists models as `models/<id>` but takes the bare id in chat requests.
  public func modelID(fromListedID id: String) -> String {
    id.hasPrefix("models/") ? String(id.dropFirst("models/".count)) : id
  }

  /// Keeps chat models and drops embeddings, speech, moderation and image endpoints that the
  /// vendors list alongside them.
  public func isConversationalModel(_ id: String) -> Bool {
    guard !id.isEmpty, id.count <= 200, !id.contains("\n") else { return false }
    let lowered = id.lowercased()
    let nonChat = ["embed", "whisper", "tts", "moderation", "guard", "ocr", "imagen", "veo", "aqa"]
    if nonChat.contains(where: lowered.contains) { return false }
    switch self {
    case .moonshot: return lowered.hasPrefix("kimi-")
    case .deepSeek: return lowered.hasPrefix("deepseek-")
    case .gemini: return lowered.hasPrefix("gemini-")
    case .mistral, .groq, .openRouter: return true
    }
  }
}
