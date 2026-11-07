import Foundation
import Testing
@testable import SieveSciCore

/// Naive AI: Anthropic format, token auth, one X-Session-Id per task, 1M context, text only.
@Suite struct NaiveAITests {
    let preset = ProviderPresets.profile(id: "naive-ai")!

    func provider(_ p: ProviderProfile? = nil) -> AnthropicProvider {
        AnthropicProvider(profile: p ?? preset, apiKey: "test-token", http: RoutedHTTP([]))
    }

    func request(lineage: String = "task1-main") -> LLMRequest {
        LLMRequest(model: "naive-n0.5-flash", system: "sys", tools: [], messages: [Message.user("hi")], maxTokens: 100,
                   cache: CacheHints(lineageKey: lineage, retention: .short))
    }

    @Test func presetMatchesTheVendorConfig() {
        #expect(preset.family == .anthropic)
        #expect(preset.baseURL == "https://api.naive.ai")
        #expect(preset.endpoint("/v1/messages")?.absoluteString == "https://api.naive.ai/v1/messages")
        #expect(preset.defaultModel == "naive-n0.5-flash")
        let h = provider().headers()
        #expect(h["authorization"] == "Bearer test-token" && h["x-api-key"] == nil)
    }

    @Test func eachTaskSendsItsOwnStableSessionId() throws {
        let a = provider().headers(lineage: "task1-main")["X-Session-Id"]
        let again = provider().headers(lineage: "task1-main")["X-Session-Id"]
        let b = provider().headers(lineage: "task2-main")["X-Session-Id"]
        let id = try #require(a)
        #expect(a == again && a != b)
        #expect(UUID(uuidString: id) != nil, "UUID format, as uuidgen gives")
        #expect(id.count == 36 && Array(id)[14] == "5")
    }

    @Test func requestUsesThePublishedSamplingAndNoClaudeThinking() {
        let body = provider().body(for: request())
        #expect(body["temperature"]?.doubleValue == 1.0)
        #expect(body["top_p"]?.doubleValue == 0.95)
        #expect(body["thinking"] == nil && body["output_config"] == nil)
    }

    @Test func modelIsOneMillionTokensAndTextOnly() {
        let s = ModelDiscovery.effectiveSettings(model: "naive-n0.5-flash", profile: preset, discovered: nil)
        #expect(s.contextWindow == 1_000_000)
        #expect(!s.supportsImages)
        #expect(KnownModels.spec(for: "naive-n0.5-flash")?.contextBudget == 1_000_000)
        #expect(KnownModels.spec(for: "claude-opus-5-5") == nil)
    }

    @Test func spendUsesNaivePrices() throws {
        var u = Usage()
        u.input = 1_000_000; u.cacheRead = 1_000_000; u.output = 1_000_000
        let usd = try #require(KnownModels.cost(u, model: "naive-n0.5-flash"))
        #expect(abs(usd - 0.51) < 1e-9)
    }

    @Test func handAddedNaiveProvidersGetTheSessionHeader() {
        #expect(ProviderOptions.detected(family: .anthropic, baseURL: "https://api.naive.ai").sessionAffinity == "x-session-id")
        var config = AppConfig()
        var mine = ProviderProfile(id: "my-naive", displayName: "Naive", family: .anthropic, baseURL: "https://api.naive.ai",
                                   auth: .xApiKey, apiKeyRef: "NAIVE_AI_API_KEY", models: ["naive-n0.5-flash"])
        mine.options.sessionAffinity = ""
        config.providers = [mine]
        config.addPresets()
        #expect(config.providers.first { $0.id == "my-naive" }?.options.sessionAffinity == "x-session-id")
        #expect(config.providers.first { $0.id == "my-naive" }?.auth == .xApiKey, "the user's auth stays")
        #expect(config.providers.contains { $0.id == "naive-ai" })
    }

    @Test func longToolLoopsRestateTheRequest() throws {
        let (services, _) = try makeServices()
        let note = TurnContext.refresh(services: services, request: "Find binders for PD-L1", steps: 20)
        #expect(note.hasPrefix("<state_refresh>") && note.hasSuffix("</state_refresh>"))
        #expect(note.contains("the user asked: Find binders for PD-L1") && note.contains("tool rounds this turn: 20"))
        #expect(KnownModels.spec(for: "naive-n0.5-flash")?.stateRefreshEvery == 10)
    }
}
