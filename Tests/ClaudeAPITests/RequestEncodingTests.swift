import Foundation
import ListenerCore
import Testing

@testable import ClaudeAPI

struct RequestEncodingTests {
    let client = ClaudeClient(apiKey: "test-key", transport: FakeTransport([]))

    func request(
        model: String, effort: String = "low", thinking: ThinkingMode = .off, maxTokens: Int = 600,
        cacheSystem: Bool = false, user: [PromptBlock] = [PromptBlock("Hello")]
    ) -> ModelRequest {
        ModelRequest(
            settings: ModelSettings(model: model, effort: effort, thinking: thinking, maxTokens: maxTokens),
            system: "Be brief.", cacheSystem: cacheSystem, user: user)
    }

    func body(_ request: ModelRequest) throws -> [String: Any] {
        let data = try #require(try client.httpRequest(for: request).body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func thinkingType(_ body: [String: Any]) -> String? {
        (body["thinking"] as? [String: Any])?["type"] as? String
    }

    @Test func haikuQuickAnswerHasTheExactWireShape() throws {
        let http = try client.httpRequest(
            for: request(
                model: "claude-haiku-5-5",
                user: [PromptBlock("<transcript>\n[00:01] Them: Hi\n", cacheBreakpoint: true), PromptBlock("Answer.")]))

        #expect(http.method == "POST")
        #expect(http.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(
            http.headers == [
                "x-api-key": "test-key", "anthropic-version": "2023-06-01", "content-type": "application/json",
            ])
        let json = String(decoding: try #require(http.body), as: UTF8.self)
        #expect(
            json == """
                {"max_tokens":600,"messages":[{"content":[{"cache_control":{"type":"ephemeral"},"text":"<transcript>\\n[00:01] Them: Hi\\n","type":"text"},{"text":"Answer.","type":"text"}],"role":"user"}],"model":"claude-haiku-5-5","output_config":{"effort":"low"},"stream":true,"system":[{"text":"Be brief.","type":"text"}],"thinking":{"type":"disabled"}}
                """)
    }

    @Test func systemPromptIsCachedOnlyWhenAsked() throws {
        let cached = try body(request(model: "claude-haiku-5-5", cacheSystem: true))
        let system = try #require(cached["system"] as? [[String: Any]])
        #expect((system[0]["cache_control"] as? [String: String]) == ["type": "ephemeral"])

        let empty = ModelRequest(
            settings: ModelSettings(model: "claude-haiku-5-5", effort: "low", thinking: .off, maxTokens: 10),
            system: "", user: [PromptBlock("Hi")])
        #expect(try body(empty)["system"] == nil)
    }

    @Test func emptyAndWhitespaceBlocksAreDropped() throws {
        let sent = try body(
            request(model: "claude-haiku-5-5", user: [PromptBlock(""), PromptBlock(" \n"), PromptBlock("Real")]))
        let messages = try #require(sent["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["text"] as? String == "Real")
    }

    @Test func sonnetTurnsThinkingOffWithBetweenToolsAndKeepsItsFallback() throws {
        // A between_tools request that falls back runs there with thinking disabled.
        let http = try client.httpRequest(for: request(model: "claude-sonnet-5-5", effort: "high", thinking: .off))
        let sent = try body(request(model: "claude-sonnet-5-5", effort: "high", thinking: .off))
        #expect(thinkingType(sent) == "between_tools")
        #expect(sent["fallbacks"] as? String == "default")
        #expect(http.headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
    }

    @Test func aCacheWarmUpIsNotStreamedAndWritesNoAnswer() throws {
        // max_tokens 0 is rejected with stream true.
        let sent = try body(request(model: "claude-sonnet-5-5", effort: "medium", thinking: .adaptive, maxTokens: 0))
        #expect(sent["max_tokens"] as? Int == 0)
        #expect(sent["stream"] as? Bool == false)
        #expect(thinkingType(sent) == "adaptive")
        #expect(try body(request(model: "claude-haiku-5-5"))["stream"] as? Bool == true)
    }

    @Test func sonnetAdaptiveSendsServerSideFallback() throws {
        let model = request(model: "claude-sonnet-5-5", effort: "medium", thinking: .adaptive)
        let sent = try body(model)
        #expect(thinkingType(sent) == "adaptive")
        #expect(sent["fallbacks"] as? String == "default")
        #expect((sent["output_config"] as? [String: String]) == ["effort": "medium"])
        #expect(try client.httpRequest(for: model).headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
    }

    @Test func opusNeverSendsDisabledThinking() throws {
        let off = try body(request(model: "claude-opus-5-5", thinking: .off))
        #expect(off["thinking"] == nil)
        #expect(off["fallbacks"] as? String == "default")

        let adaptive = try body(request(model: "claude-opus-5-5", thinking: .adaptive))
        #expect(thinkingType(adaptive) == "adaptive")
        #expect(adaptive["fallbacks"] as? String == "default")
    }

    @Test func haikuNeverSendsFallback() throws {
        let model = request(model: "claude-haiku-5-5", thinking: .adaptive)
        let sent = try body(model)
        #expect(thinkingType(sent) == "adaptive")
        #expect(sent["fallbacks"] == nil)
        #expect(try client.httpRequest(for: model).headers["anthropic-beta"] == nil)
    }

    @Test(arguments: ["xhigh", "max"])
    func thinkingStaysOnAboveHighEffort(effort: String) throws {
        #expect(thinkingType(try body(request(model: "claude-haiku-5-5", effort: effort))) == "adaptive")
        let sonnet = try body(request(model: "claude-sonnet-5-5", effort: effort))
        #expect(thinkingType(sonnet) == "adaptive")
        #expect(sonnet["fallbacks"] as? String == "default")
    }

    @Test func noSamplingParametersOrPrefillAreEverSent() throws {
        for model in ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"] {
            let sent = try body(request(model: model))
            #expect(sent["temperature"] == nil && sent["top_p"] == nil && sent["top_k"] == nil)
            let messages = try #require(sent["messages"] as? [[String: Any]])
            #expect(messages.map { $0["role"] as? String } == ["user"])
        }
    }

    @Test func unknownModelsGetTheGenericMapping() throws {
        let sent = try body(request(model: "claude-future-9", effort: "medium"))
        #expect(thinkingType(sent) == "disabled")
        #expect(sent["fallbacks"] == nil)
    }
}
