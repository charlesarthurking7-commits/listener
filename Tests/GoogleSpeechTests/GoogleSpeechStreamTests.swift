import Foundation
import GRPCCore
import GRPCProtobuf
import ListenerCore
import Testing

@testable import GoogleSpeech

struct GoogleSpeechStreamTests {
    @Test func sendsTheConfigFirstThenAudioInFramesOfAtMost100Milliseconds() async throws {
        try await withFakeSpeech(scripts: []) { provider, recorder in
            let stream = try await provider.openStream(for: .them)
            await recorder.waitForCalls(1)
            let audio = Audio.samples(from: 0, to: 0.4)
            try await stream.send(AudioChunk(speaker: .them, samples: Array(audio[..<5_600]), capturedAt: .now))
            try await stream.send(AudioChunk(speaker: .them, samples: Array(audio[5_600...]), capturedAt: .now))
            await stream.finish()
            #expect(try await stream.events.collect() == [])

            let calls = await recorder.calls
            try #require(calls.count == 1)
            let setup = try RecognitionSetup(settings: .forTests(), quotaProjectID: "quota-project")
            #expect(calls[0].config == setup.configRequest)
            #expect(calls[0].audioRequests.map(\.count) == [3_200, 3_200, 3_200, 1_600, 1_600])
            #expect(calls[0].samples == audio)
            #expect(calls[0].metadata[stringValues: "authorization"].map { $0 } == ["Bearer token-1"])
            #expect(calls[0].metadata[stringValues: "x-goog-user-project"].map { $0 } == ["quota-project"])
        }
    }

    @Test func leavesOutTheQuotaHeaderWhenTheCredentialsHaveNoQuotaProject() async throws {
        try await withFakeSpeech(scripts: [], tokens: FakeTokens(quotaProjectID: nil)) { provider, recorder in
            let stream = try await provider.openStream(for: .me)
            try await Audio.send(stream, from: 0, to: 0.1)
            await stream.finish()

            let calls = await recorder.calls
            #expect(calls.first?.metadata[stringValues: "x-goog-user-project"].map { $0 } == [])
        }
    }

    @Test func mapsInterimsAndFinalsToChannelTime() async throws {
        let script: CallScript = { call in
            try await call.waitForAudio(seconds: 1)
            try await call.respond(Response.speechBegin(at: 0.2))
            try await call.respond(Response.interim("hello", end: 0.5))
            try await call.respond(Response.results([("Hello there.", true, 0.9), (" how", false, 1.0)]))
            await call.drain()
        }
        try await withFakeSpeech(scripts: [script]) { provider, _ in
            let stream = try await provider.openStream(for: .them)
            try await Audio.send(stream, from: 0, to: 1.2)
            await stream.finish()

            #expect(
                try await stream.events.collect() == [
                    .interim("hello", 0.2, 0.5),
                    .final("Hello there.", 0.2, 0.9),
                    .interim("how", 0.9, 1.0),
                ])
        }
    }

    @Test func rotatesAtTheFirstFinalAfterRotateAfterAndReplaysWhatFollowsIt() async throws {
        let first: CallScript = { call in
            try await call.waitForAudio(seconds: 1)
            try await call.respond(Response.final("One.", end: 0.6))
            await call.drain()
        }
        // Answers after the half-close, so the second stream is not old enough to
        // rotate again when its final arrives.
        let second: CallScript = { call in
            await call.drain()
            try await call.respond(Response.final("Two.", end: 0.8))
        }
        let settings = SpeechSettings.forTests(rotateAfterSeconds: 0.5)
        try await withFakeSpeech(scripts: [first, second], settings: settings) { provider, recorder in
            let stream = try await provider.openStream(for: .them)
            var events = stream.events.makeAsyncIterator()
            try await Audio.send(stream, from: 0, to: 1)
            #expect(try await events.next() == .final("One.", 0, 0.6))

            try await Audio.send(stream, from: 1, to: 1.5)
            await stream.finish()
            #expect(try await events.next() == .final("Two.", 0.6, 1.4))
            #expect(try await events.next() == nil)

            let calls = await recorder.calls
            try #require(calls.count == 2)
            #expect(calls[0].samples == Audio.samples(from: 0, to: 1))
            #expect(calls[1].config?.recognizer == "projects/test-project/locations/eu/recognizers/_")
            #expect(calls[1].samples == Audio.samples(from: 0.6, to: 1.5))
        }
    }

    @Test func forcedRotationWhileSpeechIsInProgressReplaysUpToTheReplayLimit() async throws {
        let first: CallScript = { call in
            try await call.waitForAudio(seconds: 0.5)
            try await call.respond(Response.interim("still talking", end: 0.5))
            await call.drain()
        }
        let second: CallScript = { call in
            await call.drain()
            try await call.respond(Response.final("Still talking.", end: 0.5))
        }
        let tuning = StreamTuning.forTests().with {
            $0.hardLimit = .seconds(1)
            $0.replayLimit = .milliseconds(600)
        }
        try await withFakeSpeech(scripts: [first, second], tuning: tuning) { provider, recorder in
            let stream = try await provider.openStream(for: .them)
            var events = stream.events.makeAsyncIterator()
            try await Audio.send(stream, from: 0, to: 0.5)
            #expect(try await events.next() == .interim("still talking", 0, 0.5))

            // The last chunk reaches the hard limit. Sending no more keeps the replay
            // window where it was at that moment.
            try await Audio.send(stream, from: 0.5, to: 1)
            await stream.finish()
            #expect(try await events.next() == .final("Still talking.", 0.4, 0.9))

            let calls = await recorder.calls
            try #require(calls.count == 2)
            #expect(calls[1].samples == Audio.samples(from: 0.4, to: 1))
        }
    }

    @Test func forcedRotationDuringSilenceReplaysOnlyTheRecentPast() async throws {
        let second: CallScript = { call in
            await call.drain()
            try await call.respond(Response.final("Hi.", end: 0.4))
        }
        // The limit also counts time since the stream started. It is long enough that
        // the audio, sent at once, reaches it first even on a busy machine.
        let tuning = StreamTuning.forTests().with {
            $0.hardLimit = .seconds(5)
            $0.idleReplay = .milliseconds(250)
        }
        try await withFakeSpeech(scripts: [{ await $0.drain() }, second], tuning: tuning) { provider, recorder in
            let stream = try await provider.openStream(for: .them)
            await recorder.waitForCalls(1)
            try await Audio.send(stream, from: 0, to: 5.2)
            await stream.finish()

            #expect(try await stream.events.collect() == [.final("Hi.", 4.75, 5.15)])
            let calls = await recorder.calls
            try #require(calls.count == 2)
            #expect(calls[1].samples == Audio.samples(from: 4.75, to: 5.2))
        }
    }

    @Test func reconnectsAfterATransientErrorAndReplaysAudioAfterTheLastFinal() async throws {
        let first: CallScript = { call in
            try await call.waitForAudio(seconds: 1)
            try await call.respond(Response.final("First.", end: 0.4))
            throw RPCError(code: .unavailable, message: "connection reset")
        }
        let second: CallScript = { call in
            try await call.waitForAudio(seconds: 0.9)
            try await call.respond(Response.final("Second.", end: 0.85))
            await call.drain()
        }
        try await withFakeSpeech(scripts: [first, second]) { provider, recorder in
            let stream = try await provider.openStream(for: .me)
            var events = stream.events.makeAsyncIterator()
            try await Audio.send(stream, from: 0, to: 1)
            #expect(try await events.next() == .final("First.", 0, 0.4))

            try await Audio.send(stream, from: 1, to: 1.3)
            await stream.finish()
            #expect(try await events.next() == .final("Second.", 0.4, 1.25))
            #expect(try await events.next() == nil)

            let calls = await recorder.calls
            try #require(calls.count == 2)
            #expect(calls[1].config?.recognizer.isEmpty == false)
            #expect(calls[1].samples == Audio.samples(from: 0.4, to: 1.3))
        }
    }

    @Test func reconnectsWhenGoogleClosesTheStreamUnasked() async throws {
        let first: CallScript = { call in
            try await call.waitForAudio(seconds: 0.3)
        }
        let second: CallScript = { call in
            try await call.waitForAudio(seconds: 0.3)
            try await call.respond(Response.interim("Back", end: 0.3))
            await call.drain()
            try await call.respond(Response.final("Back.", end: 0.5))
        }
        try await withFakeSpeech(scripts: [first, second]) { provider, recorder in
            let stream = try await provider.openStream(for: .me)
            var events = stream.events.makeAsyncIterator()
            try await Audio.send(stream, from: 0, to: 0.3)
            #expect(try await events.next() == .interim("Back", 0, 0.3))

            try await Audio.send(stream, from: 0.3, to: 0.5)
            await stream.finish()
            #expect(try await events.next() == .final("Back.", 0, 0.5))
            #expect(try await events.next() == nil)
            #expect(await recorder.calls.count == 2)
        }
    }

    @Test func whenGoogleHangsUpForLackOfAudioItWaitsForMoreAndKeepsTheLastGuess() async throws {
        let first: CallScript = { call in
            try await call.waitForAudio(seconds: 0.5)
            try await call.respond(Response.interim("half a", end: 0.4))
            throw RPCError(
                code: .outOfRange,
                message: "Long duration elapsed without audio. Audio should be sent close to real time.")
        }
        let second: CallScript = { call in
            await call.drain()
            try await call.respond(Response.final("More.", end: 0.3))
        }
        try await withFakeSpeech(scripts: [first, second]) { provider, recorder in
            let stream = try await provider.openStream(for: .me)
            var events = stream.events.makeAsyncIterator()
            try await Audio.send(stream, from: 0, to: 0.5)
            #expect(try await events.next() == .interim("half a", 0, 0.4))
            #expect(try await events.next() == .final("half a", 0, 0.4))
            #expect(await recorder.calls.count == 1)

            try await Audio.send(stream, from: 0.5, to: 0.8)
            await stream.finish()
            #expect(try await events.next() == .final("More.", 0.5, 0.8))

            let calls = await recorder.calls
            try #require(calls.count == 2)
            #expect(calls[1].samples == Audio.samples(from: 0.5, to: 0.8))
        }
    }

    @Test func refreshesTheTokenOnceWhenGoogleRejectsIt() async throws {
        let rejecting: CallScript = { call in
            throw RPCError(code: .unauthenticated, message: "Request had invalid authentication credentials.")
        }
        let tokens = FakeTokens(token: "stale", refreshed: "fresh")
        try await withFakeSpeech(scripts: [rejecting], tokens: tokens) { provider, recorder in
            let stream = try await provider.openStream(for: .me)
            try await Audio.send(stream, from: 0, to: 0.3)
            await stream.finish()
            #expect(try await stream.events.collect() == [])

            let calls = await recorder.calls
            #expect(
                calls.map { $0.metadata[stringValues: "authorization"].map { $0 } } == [
                    ["Bearer stale"], ["Bearer fresh"],
                ])
            #expect(calls.last?.samples == Audio.samples(from: 0, to: 0.3))
            #expect(await tokens.refreshes == 1)
        }
    }

    @Test func givesUpWhenTheRefreshedTokenIsRejectedToo() async throws {
        let rejecting: CallScript = { _ in
            throw RPCError(code: .unauthenticated, message: "Request had invalid authentication credentials.")
        }
        try await withFakeSpeech(scripts: [], fallback: rejecting) { provider, recorder in
            let stream = try await provider.openStream(for: .me)
            // After the first rejection the stream waits for audio before it retries.
            try await stream.send(AudioChunk(speaker: .me, samples: Audio.samples(from: 0, to: 0.1), capturedAt: .now))
            let error = await #expect(throws: GoogleSpeechError.self) { try await stream.events.collect() }
            #expect(error?.kind == .credentials)
            #expect(error?.message.contains("gcloud auth application-default login") == true)
            #expect(await recorder.calls.count == 2)
        }
    }

    @Test func surfacesAPermanentErrorOnEventsAndRefusesMoreAudio() async throws {
        let disabled: CallScript = { _ in
            throw GoogleRPCStatus(
                code: .permissionDenied,
                message: "Cloud Speech-to-Text API has not been used in project 123 before or it is disabled.",
                details: .serviceDisabled)
        }
        try await withFakeSpeech(scripts: [disabled]) { provider, recorder in
            let stream = try await provider.openStream(for: .them)
            let error = await #expect(throws: GoogleSpeechError.self) { try await stream.events.collect() }
            #expect(error?.kind == .apiDisabled)
            #expect(error?.message.contains("not enabled in project test-project") == true)
            #expect(
                error?.message.contains("https://console.developers.google.com/apis/api/speech.googleapis.com") == true)

            await #expect(throws: GoogleSpeechError.self) {
                try await stream.send(AudioChunk(speaker: .them, samples: [0], capturedAt: .now))
            }
            #expect(await recorder.calls.count == 1)
        }
    }

    @Test func givesUpAfterTooManyFailedReconnects() async throws {
        let failing: CallScript = { _ in throw RPCError(code: .unavailable, message: "no route to host") }
        let tuning = StreamTuning.forTests().with { $0.maxAttempts = 3 }
        try await withFakeSpeech(scripts: [], fallback: failing, tuning: tuning) { provider, recorder in
            let stream = try await provider.openStream(for: .them)
            try await stream.send(
                AudioChunk(speaker: .them, samples: Audio.samples(from: 0, to: 0.1), capturedAt: .now))
            let error = await #expect(throws: GoogleSpeechError.self) { try await stream.events.collect() }
            #expect(error?.kind == .connectionLost)
            #expect(error?.message.contains("no route to host") == true)
            #expect(await recorder.calls.count == 4)
        }
    }

    @Test func finishStopsWaitingAfterTheTimeout() async throws {
        let silent: CallScript = { call in
            await call.drain()
            try await Task.sleep(for: .seconds(1))
        }
        let tuning = StreamTuning.forTests().with { $0.finishTimeout = .milliseconds(200) }
        try await withFakeSpeech(scripts: [silent], tuning: tuning) { provider, _ in
            let stream = try await provider.openStream(for: .them)
            try await Audio.send(stream, from: 0, to: 0.2)
            let started = ContinuousClock.now
            await stream.finish()
            #expect(started.duration(to: .now) < .milliseconds(900))
            #expect(try await stream.events.collect() == [])
        }
    }

    @Test func finishWithoutAudioClosesAtOnce() async throws {
        try await withFakeSpeech(scripts: []) { provider, _ in
            let stream = try await provider.openStream(for: .them)
            await stream.finish()
            #expect(try await stream.events.collect() == [])
        }
    }

    @Test func openStreamThrowsWhenNoTokenCanBeHad() async throws {
        try await withFakeSpeech(scripts: [], tokens: BrokenTokens()) { provider, recorder in
            await #expect(throws: GoogleAuthError.self) { try await provider.openStream(for: .me) }
            #expect(await recorder.calls.isEmpty)
        }
    }
}

private struct BrokenTokens: AccessTokenProvider {
    func accessToken() async throws -> String {
        throw GoogleAuthError(.missingCredentials, "No Google credentials")
    }
}
