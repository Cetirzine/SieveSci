import Foundation

/// Built-in endpoint presets. Model lists are starting points; the settings UI refreshes them from
/// each vendor's models endpoint, so a new model never requires an app update.
///
/// Subscription plans (Claude Pro/Max, ChatGPT plans, Google AI Ultra) are reached **only** through
/// the vendor's own CLI, which the user signs into themselves. SieveSci never reads, copies or
/// replays subscription OAuth tokens: Anthropic's terms restrict Pro/Max OAuth to Claude Code and
/// Claude.ai, and Google has suspended accounts whose Gemini CLI OAuth credentials were used by
/// third-party clients. The GLM Coding Plan is different: Z.ai issues an API key for use in
/// third-party coding tools, so it is a normal HTTP preset.
public enum ProviderPresets {
    public static let all: [ProviderProfile] = [
        // MARK: Anthropic
        ProviderProfile(
            id: "anthropic", displayName: "Anthropic API", family: .anthropic,
            baseURL: "https://api.anthropic.com", auth: .xApiKey, apiKeyRef: "ANTHROPIC_API_KEY",
            models: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"],
            notes: "Native Messages API: explicit cache_control breakpoints, 5m/1h TTL tiers."),
        ProviderProfile(
            id: "claude-code", displayName: "Claude Code (Pro/Max plan)", family: .cliAgent, flavor: .claudeCode,
            baseURL: "", auth: .none, apiKeyRef: "", models: ["opus", "sonnet"], billing: "plan",
            notes: "Runs your locally installed, signed-in `claude` CLI headless. Claude Code manages its own caching.",
            executable: "claude"),

        // MARK: OpenAI
        ProviderProfile(
            id: "openai", displayName: "OpenAI API", family: .openaiResponses,
            baseURL: "https://api.openai.com/v1", auth: .bearer, apiKeyRef: "OPENAI_API_KEY",
            models: ["gpt-6-astra", "gpt-6.1-sol", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"],
            notes: "Native Responses API: prompt_cache_key routing, optional 24h retention, encrypted reasoning replay."),
        ProviderProfile(
            id: "codex", displayName: "Codex CLI (ChatGPT plan)", family: .cliAgent, flavor: .codex,
            baseURL: "", auth: .none, apiKeyRef: "", models: ["default"], billing: "plan",
            notes: "Runs your locally installed, signed-in `codex` CLI (`codex exec --json`). \"default\" uses the model in Codex's own config; the list is fetched from `codex debug models` (what your account may use).",
            executable: "codex"),

        // MARK: Google
        ProviderProfile(
            id: "gemini", displayName: "Gemini API", family: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta", auth: .googApiKey, apiKeyRef: "GEMINI_API_KEY",
            models: ["gemini-4-argon", "gemini-3.8-flash", "gemini-3.7-flash"],
            notes: "Native generateContent: implicit caching plus explicit cachedContents for large static prefixes; thoughtSignature replay."),
        ProviderProfile(
            id: "antigravity", displayName: "Antigravity CLI (Google account)", family: .cliAgent, flavor: .antigravity,
            baseURL: "", auth: .none, apiKeyRef: "", models: ["default"], billing: "plan",
            notes: "Runs your locally installed, signed-in `agy` (Antigravity CLI) in its official headless mode (`agy -p --output-format json`). Google replaced Gemini CLI with it for personal accounts. Model slugs: run `agy models`. Check Google's terms for driving it from other tools; with a Gemini API key (`modelProvider: gemini` in its settings) usage is billed to the key instead.",
            executable: "agy"),
        ProviderProfile(
            id: "gemini-cli", displayName: "Gemini CLI (Code Assist Standard/Enterprise)", family: .cliAgent, flavor: .geminiCLI,
            baseURL: "", auth: .none, apiKeyRef: "", models: ["gemini-4-argon", "gemini-3.8-flash"], billing: "plan",
            notes: "Runs your locally installed `gemini` CLI headless. Since 2026 Google serves Gemini CLI only to paid API keys and Code Assist Standard/Enterprise licences; personal Google accounts (free, AI Pro, AI Ultra) should use Antigravity CLI.",
            executable: "gemini"),

        // MARK: DeepSeek
        ProviderProfile(
            id: "deepseek", displayName: "DeepSeek API", family: .openaiChat, flavor: .deepseek,
            baseURL: "https://api.deepseek.com", auth: .bearer, apiKeyRef: "DEEPSEEK_API_KEY",
            models: ["deepseek-flash", "deepseek-v4-pro"],
            notes: "Automatic disk prefix cache (64-token units); usage reports prompt_cache_hit_tokens. Model list is refreshed from /models."),

        // MARK: Zhipu GLM
        ProviderProfile(
            id: "glm-coding-cn", displayName: "GLM Coding Plan (bigmodel.cn)", family: .openaiChat, flavor: .zhipu,
            baseURL: "https://open.bigmodel.cn/api/coding/paas/v4", auth: .bearer, apiKeyRef: "ZHIPU_API_KEY",
            models: ["glm-5.3", "glm-5.2", "glm-5.3-flash"], billing: "plan",
            notes: "Coding Plan endpoint (mainland). Automatic context caching."),
        ProviderProfile(
            id: "glm-coding-intl", displayName: "GLM Coding Plan (z.ai)", family: .openaiChat, flavor: .zhipu,
            baseURL: "https://api.z.ai/api/coding/paas/v4", auth: .bearer, apiKeyRef: "ZAI_API_KEY",
            models: ["glm-5.3", "glm-5.2", "glm-5.3-flash"], billing: "plan",
            notes: "Coding Plan endpoint (international)."),
        ProviderProfile(
            id: "glm-api", displayName: "GLM API (bigmodel.cn)", family: .openaiChat, flavor: .zhipu,
            baseURL: "https://open.bigmodel.cn/api/paas/v4", auth: .bearer, apiKeyRef: "ZHIPU_API_KEY",
            models: ["glm-5.3", "glm-5.2"],
            notes: "Pay-as-you-go endpoint."),

        // MARK: Relays (中转站)
        ProviderProfile(
            id: "openrouter", displayName: "OpenRouter", family: .openaiChat,
            baseURL: "https://openrouter.ai/api/v1", auth: .bearer, apiKeyRef: "OPENROUTER_API_KEY",
            models: ["anthropic/claude-opus-5-5", "openai/gpt-6-astra", "google/gemini-4-argon", "deepseek/deepseek-v4-pro", "z-ai/glm-5.3"],
            billing: "relay",
            notes: "Chat format; cache_control is placed on content parts for Claude/Gemini upstreams.",
            extraBody: ["usage": ["include": true]],
            options: { var o = ProviderOptions(); o.cacheControlInChatParts = true; o.sendPromptCacheKey = false; return o }()),
        ProviderProfile(
            id: "closeai", displayName: "CloseAI · OpenAI format", family: .openaiChat,
            baseURL: "https://api.openai-proxy.org/v1", auth: .bearer, apiKeyRef: "CLOSEAI_API_KEY",
            models: ["gpt-6-astra", "claude-opus-5-5", "gemini-4-argon", "deepseek-v4-pro"], billing: "relay",
            notes: "CloseAI (closeai-asia.com) Chat Completions endpoint; also routes Claude and Gemini models. Balance needs a management key (sk-admin-…, enterprise accounts) saved as CLOSEAI_ADMIN_KEY.",
            options: { var o = ProviderOptions(); o.sendPromptCacheKey = false; return o }()),
        ProviderProfile(
            id: "closeai-anthropic", displayName: "CloseAI · Anthropic format", family: .anthropic,
            baseURL: "https://api.openai-proxy.org/anthropic", auth: .xApiKey, apiKeyRef: "CLOSEAI_API_KEY",
            models: ["claude-opus-5-5", "claude-sonnet-5-5"], billing: "relay",
            notes: "CloseAI native Messages endpoint (same key as the OpenAI format), so cache_control reaches Claude."),
        ProviderProfile(
            id: "relay-anthropic", displayName: "Relay · Anthropic format", family: .anthropic,
            baseURL: "https://your-relay.example.com", auth: .xApiKey, apiKeyRef: "RELAY_ANTHROPIC_KEY",
            models: ["claude-opus-5-5", "claude-sonnet-5-5"], billing: "relay",
            notes: "new-api / one-api / Claude Code relays. Base URL without /v1; SieveSci appends /v1/messages. Use the cache probe to confirm cache_control is forwarded."),
        ProviderProfile(
            id: "relay-openai", displayName: "Relay · OpenAI format", family: .openaiChat,
            baseURL: "https://your-relay.example.com/v1", auth: .bearer, apiKeyRef: "RELAY_OPENAI_KEY",
            models: ["gpt-6-astra", "deepseek-v4-pro", "glm-5.3"], billing: "relay",
            notes: "Chat Completions relays. Turn off prompt_cache_key if the relay rejects unknown fields.",
            options: { var o = ProviderOptions(); o.sendPromptCacheKey = false; return o }()),
        ProviderProfile(
            id: "relay-responses", displayName: "Relay · OpenAI Responses format", family: .openaiResponses,
            baseURL: "https://your-relay.example.com/v1", auth: .bearer, apiKeyRef: "RELAY_RESPONSES_KEY",
            models: ["gpt-6-astra"], billing: "relay", notes: "Codex-style relays that expose /v1/responses."),
        ProviderProfile(
            id: "relay-gemini", displayName: "Relay · Gemini format", family: .gemini,
            baseURL: "https://your-relay.example.com/v1beta", auth: .googApiKey, apiKeyRef: "RELAY_GEMINI_KEY",
            models: ["gemini-4-argon"], billing: "relay", notes: "Relays that expose native generateContent."),

        // MARK: Local / generic
        ProviderProfile(
            id: "openai-compatible", displayName: "OpenAI-compatible (custom)", family: .openaiChat,
            baseURL: "http://localhost:8000/v1", auth: .bearer, apiKeyRef: "CUSTOM_API_KEY", models: ["local-model"],
            notes: "vLLM, SGLang, Ollama, LM Studio, Kimi, Qwen, MiniMax, Doubao…",
            options: { var o = ProviderOptions(); o.sendPromptCacheKey = false; return o }()),
    ]

    public static func profile(id: String) -> ProviderProfile? { all.first { $0.id == id } }
}
