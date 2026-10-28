import Foundation
import OttoModels
import OttoRuntime
import Testing

@Suite("Local OpenAI-compatible model configuration")
struct LocalModelConfigurationTests {
  @Test("API bases normalize and build expected OpenAI-compatible endpoints")
  func localEndpoints() throws {
    let ollama = try LocalModelConfiguration(
      baseURL: "http://127.0.0.1:11434/v1/", modelID: "qwen3:8b")
    #expect(ollama.apiBaseURL.absoluteString == "http://127.0.0.1:11434/v1")
    #expect(ollama.modelsURL.absoluteString == "http://127.0.0.1:11434/v1/models")
    #expect(ollama.completionsURL.absoluteString == "http://127.0.0.1:11434/v1/chat/completions")

    let lmStudio = try LocalModelConfiguration(
      baseURL: "http://localhost:1234", modelID: "local/large-model")
    #expect(lmStudio.completionsURL.absoluteString == "http://localhost:1234/v1/chat/completions")
    let lan = try LocalModelConfiguration(
      baseURL: "http://192.168.1.20:8000/v1", modelID: "test")
    #expect(lan.baseURL.host == "192.168.1.20")
    let tailnet = try LocalModelConfiguration(
      baseURL: "100.101.102.103:4000/v1", modelID: "proxy-alias")
    #expect(tailnet.baseURL.absoluteString == "http://100.101.102.103:4000/v1")
    #expect(
      tailnet.completionsURL.absoluteString == "http://100.101.102.103:4000/v1/chat/completions")
    #expect(tailnet.modelID == "proxy-alias")
    let upperTailnet = try LocalModelConfiguration(
      baseURL: "http://100.127.0.1:4000/v1", modelID: "test")
    #expect(upperTailnet.baseURL.host == "100.127.0.1")
    let lowerTailnet = try LocalModelConfiguration(
      baseURL: "http://100.64.0.1:4000/v1", modelID: "test")
    #expect(lowerTailnet.baseURL.host == "100.64.0.1")
  }

  @Test("HTTP public internet and embedded credentials cannot receive local API keys")
  func rejectUnsafeEndpoint() {
    for address in [
      "http://example.com/v1", "http://8.8.8.8/v1",
      "http://user:password@localhost:11434/v1",
      "http://localhost:11434/v1?key=secret",
      "ftp://localhost/v1", "http://192.0.2.1/v1",
      "100.63.255.255:4000/v1", "100.128.0.1:4000/v1",
      "8.8.8.8:4000/v1", "example.com:4000/v1",
      "http://127.0.0.1:11434/v1/chat/completions",
    ] {
      #expect(throws: LocalModelConfigurationError.self) {
        _ = try LocalModelConfiguration(baseURL: address, modelID: "local-test")
      }
    }
    #expect(throws: LocalModelConfigurationError.self) {
      _ = try LocalModelConfiguration(baseURL: "http://localhost:1234/v1", modelID: "")
    }
  }

  @Test("Config persists without putting an API key in preferences")
  func preferenceRoundTrip() throws {
    let name = "OttoLocalModelTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let expected = try LocalModelConfiguration(
      baseURL: "http://10.0.0.2:8000/v1", modelID: "deepseek-local")
    expected.save(defaults: defaults)
    #expect(LocalModelConfiguration.load(defaults: defaults) == expected)
    #expect(
      defaults.dictionaryRepresentation().keys.allSatisfy {
        !$0.localizedCaseInsensitiveContains("api-key")
      })
    #expect(
      OttoHarnessModelSelection.resolve("local/deepseek-local")
        == OttoHarnessModelSelection(provider: .local, modelID: "deepseek-local"))
    #expect(AgentModelCatalog.effortLevels(for: .openAI, modelID: "local/deepseek-local").isEmpty)
  }

  @Test("Gateway model aliases stay distinct from the underlying provider model")
  func proxyModelAlias() throws {
    let response = Data(
      #"{"data":[{"id":"my-coder"},{"id":"another-model"}]}"#.utf8)
    let models = OpenAIDirectAdapter.parseDirectModels(response, provider: .local)
    #expect(models.map(\.id) == ["local/my-coder", "local/another-model"])
    let selected = OttoHarnessModelSelection.resolve("local/my-coder")
    #expect(selected.provider == .local)
    #expect(selected.modelID == "my-coder")
  }
}
