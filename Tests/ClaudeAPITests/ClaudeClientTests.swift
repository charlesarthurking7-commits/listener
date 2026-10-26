import Foundation
import ListenerCore
import Testing

@testable import ClaudeAPI

struct ClaudeClientTests {
    static let fastTiming = ClaudeClient.Timing(
        responseTimeout: .seconds(10), retryDelay: .zero, maxRetryAfter: .seconds(2), warmUpInterval: .seconds(60))

    let request = ModelRequest(
        settings: ModelSettings(model: "claude-haiku-5-5", effort: "low", thinking: .off, maxTokens: 600),
        system: "Be brief.", user: [PromptBlock("What now?")])

    func client(_ transport: FakeTransport, timing: ClaudeClient.Timing = fastTiming) -> ClaudeClient {
        ClaudeClient(apiKey: "test-key", transport: transport, timing: timing)
    }

    /// Everything the stream produced, and the error it ended with, if any.
    func run(_ client: ClaudeClient) async -> (events: [ModelEvent], error: (any Error)?) {
        var events: [ModelEvent] = []
        do {
            for try await event in client.stream(request) {
                events.append(event)
            }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    func errorResponse(_ status: Int, type: String, message: String, headers: [String: String] = [:])
        -> FakeTransport.Reply
    {
        .response(
            status: status, headers: headers,
            lines: [#"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"},"request_id":"req_1"}"#])
    }

    @Test func streamsTextThenUsage() async {
        let transport = FakeTransport([.response(status: 200, lines: SSE.answer(["Tell them ", "yes."], output: 7))])
        let (events, error) = await run(client(transport))
        #expect(error == nil)
        #expect(
            events == [
                .accepted, .text("Tell them "), .text("yes."),
                .finished(TokenUsage(inputTokens: 10, outputTokens: 7), stopReason: "end_turn"),
            ])
        #expect(transport.requests.count == 1)
        #expect(transport.requests.first?.headers["x-api-key"] == "test-key")
    }

    @Test func authenticationFailureIsNotRetried() async {
        let transport = FakeTransport([errorResponse(401, type: "authentication_error", message: "invalid x-api-key")])
        let (_, error) = await run(client(transport))
        #expect(error as? ClaudeError == .authentication)
        #expect(transport.requests.count == 1)
    }

    @Test func invalidRequestCarriesTheAPIMessage() async {
        let transport = FakeTransport([
            errorResponse(400, type: "invalid_request_error", message: "max_tokens: too big")
        ])
        let (_, error) = await run(client(transport))
        #expect(error as? ClaudeError == .invalidRequest("max_tokens: too big"))
        #expect((error as? ClaudeError)?.errorDescription?.contains("max_tokens: too big") == true)
    }

    @Test func unknownModelIsAnInvalidRequest() async {
        let transport = FakeTransport([errorResponse(404, type: "not_found_error", message: "model: claude-nope")])
        let (_, error) = await run(client(transport))
        #expect(error as? ClaudeError == .invalidRequest("model: claude-nope"))
    }

    @Test func permissionAndBillingErrorsAreNotRetried() async {
        let transport = FakeTransport([
            errorResponse(403, type: "permission_error", message: "Not allowed"),
            errorResponse(402, type: "billing_error", message: "Add credit"),
        ])
        #expect(await run(client(transport)).error as? ClaudeError == .permission("Not allowed"))
        #expect(await run(client(transport)).error as? ClaudeError == .permission("Add credit"))
        #expect(transport.requests.count == 2)
    }

    @Test func overloadedIsRetriedOnce() async {
        let transport = FakeTransport([
            errorResponse(529, type: "overloaded_error", message: "Overloaded"),
            .response(status: 200, lines: SSE.answer(["Fine."])),
        ])
        let (events, error) = await run(client(transport))
        #expect(error == nil)
        #expect(events.prefix(2) == [.accepted, .text("Fine.")])
        #expect(transport.requests.count == 2)
    }

    @Test func serverErrorsGiveUpAfterOneRetry() async {
        let transport = FakeTransport([
            errorResponse(500, type: "api_error", message: "Internal server error"),
            .response(status: 503, lines: ["<html>Service Unavailable</html>"]),
            .response(status: 200, lines: SSE.answer(["never reached"])),
        ])
        let (_, error) = await run(client(transport))
        #expect(error as? ClaudeError == .server(status: 503, message: nil))
        #expect(transport.requests.count == 2)
    }

    @Test func shortRateLimitWaitIsRetried() async {
        let transport = FakeTransport([
            errorResponse(429, type: "rate_limit_error", message: "Slow down", headers: ["retry-after": "0"]),
            .response(status: 200, lines: SSE.answer(["Ok."])),
        ])
        #expect(await run(client(transport)).error == nil)
        #expect(transport.requests.count == 2)
    }

    @Test func longRateLimitWaitFailsAtOnce() async {
        let transport = FakeTransport([
            errorResponse(429, type: "rate_limit_error", message: "Slow down", headers: ["retry-after": "30"])
        ])
        let (_, error) = await run(client(transport))
        #expect(error as? ClaudeError == .rateLimited(retryAfter: 30))
        #expect((error as? ClaudeError)?.errorDescription == "Rate limited by the Anthropic API. Try again in 30 s.")
        #expect(transport.requests.count == 1)
    }

    @Test func connectionFailureIsRetried() async {
        let transport = FakeTransport([
            .connectionFailure(FakeTransportError.connectionReset),
            .response(status: 200, lines: SSE.answer(["Back."])),
        ])
        #expect(await run(client(transport)).events.prefix(2) == [.accepted, .text("Back.")])
        #expect(transport.requests.count == 2)
    }

    @Test func connectionFailureTwiceIsANetworkError() async {
        let transport = FakeTransport([
            .connectionFailure(FakeTransportError.connectionReset),
            .connectionFailure(FakeTransportError.connectionReset),
        ])
        let (_, error) = await run(client(transport))
        guard case .network = error as? ClaudeError else {
            Issue.record("expected a network error, got \(String(describing: error))")
            return
        }
    }

    @Test func midStreamErrorBeforeAnyTextIsRetried() async {
        let transport = FakeTransport([
            .response(
                status: 200, lines: SSE.messageStart() + SSE.error(type: "overloaded_error", message: "Overloaded")),
            .response(status: 200, lines: SSE.answer(["Second try."])),
        ])
        let (events, error) = await run(client(transport))
        #expect(error == nil)
        // Each attempt was accepted; the session times the one that answered.
        #expect(events.prefix(3) == [.accepted, .accepted, .text("Second try.")])
    }

    @Test func errorAfterTextIsNeverRetried() async {
        let transport = FakeTransport([
            .response(
                status: 200, lines: SSE.messageStart() + SSE.textBlockStart() + SSE.text("Half an"),
                failure: FakeTransportError.connectionReset),
            .response(status: 200, lines: SSE.answer(["Should not be sent."])),
        ])
        let (events, error) = await run(client(transport))
        #expect(events == [.accepted, .text("Half an")])
        guard case .network = error as? ClaudeError else {
            Issue.record("expected a network error, got \(String(describing: error))")
            return
        }
        #expect(transport.requests.count == 1)
    }

    @Test func refusalIsReportedAndNotRetried() async {
        let transport = FakeTransport([
            .response(
                status: 200, lines: SSE.messageStart() + SSE.messageDelta(stopReason: "refusal") + SSE.messageStop)
        ])
        let (_, error) = await run(client(transport))
        #expect(error as? ClaudeError == .refused(category: nil))
        #expect(transport.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func missingHeadersTimeOutAndRetryOnce() async {
        var timing = Self.fastTiming
        timing.responseTimeout = .milliseconds(50)
        let transport = FakeTransport([.hang, .hang])
        let (_, error) = await run(client(transport, timing: timing))
        #expect(error as? ClaudeError == .network("timed out waiting for a response"))
        #expect(transport.requests.count == 2)
        #expect(transport.cancelledSends == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheConsumerCancelsTheRequest() async throws {
        let transport = FakeTransport([
            .openStream(lines: SSE.messageStart() + SSE.textBlockStart() + SSE.text("Start"))
        ])
        let stream = client(transport).stream(request)
        let (firstText, firstTextContinuation) = AsyncStream.makeStream(of: Void.self)
        let consumer = Task {
            for try await event in stream {
                if case .text = event {
                    firstTextContinuation.yield()
                }
            }
        }
        for await _ in firstText {
            break
        }
        consumer.cancel()
        for await _ in transport.streamTerminations {
            break
        }
        #expect(transport.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingWhileWaitingForHeadersCancelsTheSend() async {
        let transport = FakeTransport([.hang])
        let stream = client(transport).stream(request)
        let consumer = Task {
            for try await _ in stream {}
        }
        while transport.requests.isEmpty {
            await Task.yield()
        }
        consumer.cancel()
        _ = await consumer.result
        while transport.cancelledSends == 0 {
            await Task.yield()
        }
        #expect(transport.requests.count == 1)
    }

    @Test func warmUpSendsOneCheapRequestPerInterval() async {
        let transport = FakeTransport([.response(status: 200, lines: [#"{"data":[]}"#])])
        let client = client(transport)
        await client.warmUp()
        await client.warmUp()

        #expect(transport.requests.count == 1)
        let warm = transport.requests[0]
        #expect(warm.method == "GET")
        #expect(warm.url.absoluteString == "https://api.anthropic.com/v1/models?limit=1")
        #expect(warm.headers == ["x-api-key": "test-key", "anthropic-version": "2023-06-01"])
        #expect(warm.body == nil)
    }

    @Test func warmUpRunsAgainOnceTheIntervalHasPassed() async {
        var timing = Self.fastTiming
        timing.warmUpInterval = .zero
        let transport = FakeTransport([
            .response(status: 200, lines: []), .connectionFailure(FakeTransportError.connectionReset),
        ])
        let client = client(transport, timing: timing)
        await client.warmUp()
        await client.warmUp()
        #expect(transport.requests.count == 2)
    }

    @Test func aCacheWarmUpIsAPlainRequestThatReturnsItsUsage() async throws {
        let body =
            #"{"id":"msg_1","type":"message","content":[],"usage":{"input_tokens":3,"cache_creation_input_tokens":4100,"output_tokens":0}}"#
        let transport = FakeTransport([.response(status: 200, lines: [body])])
        var warmUp = request
        warmUp.settings.maxTokens = 0
        let usage = try await client(transport).prewarm(warmUp)
        #expect(usage == TokenUsage(inputTokens: 3, cacheCreationInputTokens: 4100))
        let sent =
            try JSONSerialization.jsonObject(with: try #require(transport.requests.first?.body)) as? [String: Any]
        #expect(sent?["stream"] as? Bool == false && sent?["max_tokens"] as? Int == 0)
    }

    @Test func anAdaptiveWarmUpIsTheRealRequestStoppedOnceThePromptIsRead() async throws {
        // max_tokens is part of what such a model caches, so the warm-up keeps it.
        let transport = FakeTransport([.openStream(lines: SSE.messageStart(input: 3, cacheWrite: 4100))])
        let deep = ModelRequest(
            settings: ModelSettings(model: "claude-sonnet-5-5", effort: "medium", thinking: .adaptive, maxTokens: 4000),
            system: "Be thorough.", cacheSystem: true, user: [PromptBlock("Warm.")])
        let usage = try await client(transport).prewarm(deep)
        #expect(usage == TokenUsage(inputTokens: 3, outputTokens: 1, cacheCreationInputTokens: 4100))
        let sent =
            try JSONSerialization.jsonObject(with: try #require(transport.requests.first?.body)) as? [String: Any]
        #expect(sent?["stream"] as? Bool == true && sent?["max_tokens"] as? Int == 4000)
        // Stopping reading cancels the request before the model writes an answer.
        var terminations = transport.streamTerminations.makeAsyncIterator()
        #expect(await terminations.next() != nil)
    }

    @Test func checkingLooksUpEachModelOnce() async {
        let transport = FakeTransport([.response(status: 200, lines: ["{}"]), .response(status: 200, lines: ["{}"])])
        let problem = await client(transport).check(models: [
            "claude-sonnet-5-5", "claude-haiku-5-5", "claude-sonnet-5-5",
        ])
        #expect(problem == nil)
        #expect(
            transport.requests.map(\.url.absoluteString) == [
                "https://api.anthropic.com/v1/models/claude-haiku-5-5",
                "https://api.anthropic.com/v1/models/claude-sonnet-5-5",
            ])
    }

    @Test func checkingSaysWhenTheKeyOrAModelIsWrong() async {
        let rejected = FakeTransport([errorResponse(401, type: "authentication_error", message: "invalid x-api-key")])
        #expect(await client(rejected).check(models: ["claude-haiku-5-5"])?.contains("key was rejected") == true)

        let mistyped = FakeTransport([
            .response(status: 200, lines: ["{}"]),
            errorResponse(404, type: "not_found_error", message: "model: claude-sonet-5-5"),
        ])
        let problem = await client(mistyped).check(models: ["claude-haiku-5-5", "claude-sonet-5-5"])
        #expect(problem == "There is no Anthropic model called claude-sonet-5-5. Check the model IDs in settings.json.")
    }

    @Test func checkingOfflineSaysNothing() async {
        let transport = FakeTransport([.connectionFailure(FakeTransportError.connectionReset)])
        #expect(await client(transport).check(models: ["claude-haiku-5-5"]) == nil)
    }
}
