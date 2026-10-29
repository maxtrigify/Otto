import OttoModels
import OttoRuntime
import Testing

@Suite("Provider compatibility policy")
struct ProviderCompatibilityTests {
  @Test("Current provider fixtures are supported")
  func currentVersions() {
    let claude = ProviderCompatibilityPolicy.evaluate(
      provider: .claudeCode,
      reportedVersion: "2.1.187 (Claude Code)"
    )
    #expect(claude.state == .supported)
    #expect(claude.detail == "Tested with Claude Code 2.1.0–<3.0.0.")
    let codex = ProviderCompatibilityPolicy.evaluate(
      provider: .codex,
      reportedVersion: "codex-cli 0.144.3"
    )
    #expect(codex.state == .supported)
    #expect(codex.detail == "Tested with Codex 0.100.0–<1.0.0.")
    let kimi = ProviderCompatibilityPolicy.evaluate(
      provider: .kimi,
      reportedVersion: "kimi-code 0.34.0"
    )
    #expect(kimi.state == .supported)
    #expect(kimi.detail == "Tested with Kimi 0.34.0–<1.0.0.")
    let grok = ProviderCompatibilityPolicy.evaluate(
      provider: .grok,
      reportedVersion: "grok 1.0.3 (1a29d5bc12d4) [stable]"
    )
    #expect(grok.state == .supported)
    #expect(grok.detail == "Tested with Grok 1.0.0–<2.0.0.")
    let pi = ProviderCompatibilityPolicy.evaluate(provider: .pi, reportedVersion: "1.4.0")
    #expect(pi.state == .supported)
    #expect(pi.detail == "Tested with Pi 1.0.0–<2.0.0.")
    #expect(
      ProviderCompatibilityPolicy.evaluate(
        provider: .shell,
        reportedVersion: "system"
      ).state == .supported
    )
  }

  @Test("Old, future-major, and unparsable versions are classified safely")
  func boundaries() {
    let oldClaude = ProviderCompatibilityPolicy.evaluate(
      provider: .claudeCode, reportedVersion: "2.0.99")
    #expect(oldClaude.state == .unsupported)
    #expect(oldClaude.detail.contains("Update Claude Code to 2.1.0"))
    let futureCodex = ProviderCompatibilityPolicy.evaluate(
      provider: .codex, reportedVersion: "codex 1.0.0")
    #expect(futureCodex.state == .untested)
    #expect(futureCodex.detail.contains("newer Codex version"))
    #expect(
      ProviderCompatibilityPolicy.evaluate(provider: .codex, reportedVersion: "development")
        .state == .untested
    )
    let oldKimi = ProviderCompatibilityPolicy.evaluate(provider: .kimi, reportedVersion: "0.33.9")
    #expect(oldKimi.state == .unsupported)
    #expect(oldKimi.detail.contains("Update Kimi to 0.34.0"))
    let oldGrok = ProviderCompatibilityPolicy.evaluate(provider: .grok, reportedVersion: "0.9.9")
    #expect(oldGrok.state == .unsupported)
    #expect(oldGrok.detail.contains("Update Grok to 1.0.0"))
    // The deprecated @mariozechner package tops out at 0.73 and lacks the flags Otto drives.
    let oldPi = ProviderCompatibilityPolicy.evaluate(provider: .pi, reportedVersion: "0.73.1")
    #expect(oldPi.state == .unsupported)
    #expect(oldPi.detail.contains("Update Pi to 1.0.0"))
  }
}
