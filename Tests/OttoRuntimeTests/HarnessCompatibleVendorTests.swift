import Foundation
import OttoModels
import Testing

@testable import OttoRuntime

@Suite("Otto Harness compatible vendors")
struct HarnessCompatibleVendorTests {
  @Test("Every compatible vendor is an Otto Harness backend with its own key")
  func vendorsAreBackends() {
    for vendor in OttoHarnessCompatibleVendor.allCases {
      let provider = OttoHarnessProvider(rawValue: vendor.rawValue)
      #expect(provider?.compatibleVendor == vendor, "\(vendor)")
      #expect(provider?.credentialKey == "\(vendor.rawValue).api-key")
      #expect(vendor.chatCompletionsURL.scheme == "https")
      #expect(vendor.chatCompletionsURL.path.hasSuffix("/chat/completions"))
      #expect(vendor.modelsURL.path.hasSuffix("/models"))
    }
    #expect(
      OttoHarnessCompatibleVendor.deepSeek.chatCompletionsURL.absoluteString
        == "https://api.deepseek.com/chat/completions")
    #expect(OttoHarnessProvider.local.compatibleVendor == nil)
  }

  @Test("Provider-prefixed ids resolve, including OpenRouter's nested ids")
  func resolveIDs() {
    let deepSeek = OttoHarnessModelSelection.resolve("deepseek/deepseek-reasoner")
    #expect(deepSeek.provider == .deepSeek && deepSeek.modelID == "deepseek-reasoner")
    let routed = OttoHarnessModelSelection.resolve("openrouter/anthropic/claude-sonnet-5")
    #expect(routed.provider == .openRouter && routed.modelID == "anthropic/claude-sonnet-5")
    #expect(OttoHarnessModelSelection.resolve("mistral/").modelID == "mistral-large-latest")
  }

  @Test("Discovery keeps chat models and strips Gemini's models/ prefix")
  func discoveryParsing() {
    let gemini = Data(
      #"{"data":[{"id":"models/gemini-2.5-flash"},{"id":"models/text-embedding-004"}]}"#.utf8)
    #expect(
      OpenAIDirectAdapter.parseDirectModels(gemini, provider: .gemini).map(\.id)
        == ["gemini/gemini-2.5-flash"])
    let groq = Data(
      #"{"data":[{"id":"llama-3.3-70b-versatile"},{"id":"whisper-large-v3"}]}"#.utf8)
    #expect(
      OpenAIDirectAdapter.parseDirectModels(groq, provider: .groq).map(\.id)
        == ["groq/llama-3.3-70b-versatile"])
  }
}
