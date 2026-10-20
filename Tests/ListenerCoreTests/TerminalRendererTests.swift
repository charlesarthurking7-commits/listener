import Testing

@testable import ListenerCore

struct TerminalRendererTests {
    private let clear = "\r\u{1B}[2K"

    @Test func settledTurnsPrintOnceWithTimeAndSpeaker() {
        var renderer = TerminalRenderer(style: .plain)
        let first = Turn(id: 1, speaker: .them, text: "We saw slippage on the 14:02 fills.", start: 12, end: 15)
        #expect(renderer.render(transcript([first])) == "[0:12] Them  We saw slippage on the 14:02 fills.\n")
        #expect(renderer.render(transcript([first])) == "")

        let second = Turn(id: 2, speaker: .me, text: "Which account?", start: 16, end: 17)
        #expect(renderer.render(transcript([first, second])) == "[0:16] Me    Which account?\n")
    }

    @Test func aGrowingTurnPrintsOnlyTheNewWords() {
        var renderer = TerminalRenderer(style: .plain)
        var turn = Turn(id: 1, speaker: .them, text: "Hi.", start: 61, end: 62)
        _ = renderer.render(transcript([turn]))
        turn.text = "Hi. It's about the rejects."
        #expect(renderer.render(transcript([turn])) == "             It's about the rejects.\n")

        let mine = Turn(id: 2, speaker: .me, text: "Okay.", start: 64, end: 65)
        _ = renderer.render(transcript([turn, mine]))
        turn.text = "Hi. It's about the rejects. Since Monday."
        #expect(renderer.render(transcript([turn, mine])) == "[1:01] Them  Since Monday.\n")

        turn.text = "Hello, it's about the rejects."
        #expect(renderer.render(transcript([turn, mine])) == "[1:01] Them  Hello, it's about the rejects.\n")
    }

    @Test func interimTextLivesOnARewrittenLine() {
        var renderer = TerminalRenderer(style: TerminalStyle(color: false, liveLine: true, width: 80))
        #expect(
            renderer.render(.transcript(TranscriptSnapshot(interim: [.them: "we noticed"]))) == "... Them: we noticed")
        #expect(
            renderer.render(.transcript(TranscriptSnapshot(interim: [.them: "we noticed the"])))
                == clear + "... Them: we noticed the")
        #expect(renderer.render(.transcript(TranscriptSnapshot(interim: [.them: "we noticed the"]))) == "")

        let turn = Turn(id: 1, speaker: .them, text: "We noticed the gap.", start: 5, end: 7)
        #expect(
            renderer.render(.transcript(TranscriptSnapshot(turns: [turn], interim: [.me: "right"])))
                == clear + "[0:05] Them  We noticed the gap.\n... Me: right")
        #expect(renderer.render(.transcript(TranscriptSnapshot(turns: [turn]))) == clear)
    }

    @Test func liveLineIsCutToTheTerminalWidthKeepingTheLatestWords() {
        var renderer = TerminalRenderer(style: TerminalStyle(color: false, liveLine: true, width: 30))
        let output = renderer.render(
            .transcript(TranscriptSnapshot(interim: [.me: "one two three four five six seven"])))
        #expect(output == "... three four five six seven")
        #expect(output.count == 29)
    }

    @Test func typedInputIsClearedAndTheLiveLineRedrawn() {
        var renderer = TerminalRenderer(style: TerminalStyle(color: false, liveLine: true))
        _ = renderer.render(.transcript(TranscriptSnapshot(interim: [.them: "and the"])))
        #expect(renderer.inputEchoed() == "\u{1B}[1A" + clear + "... Them: and the")

        _ = renderer.render(.answerStarted(id: 1, tier: .quick, model: "haiku"))
        #expect(renderer.inputEchoed() == "")
        var plain = TerminalRenderer(style: .plain)
        #expect(plain.inputEchoed() == "")
    }

    @Test func liveLineOffMeansNoInterimText() {
        var renderer = TerminalRenderer(style: .plain)
        #expect(renderer.render(.transcript(TranscriptSnapshot(interim: [.them: "hello"]))) == "")
    }

    @Test func transcriptWaitsWhileAnAnswerStreams() {
        var renderer = TerminalRenderer(style: TerminalStyle(color: false, liveLine: true))
        _ = renderer.render(.transcript(TranscriptSnapshot(interim: [.them: "so what"])))

        #expect(
            renderer.render(.answerStarted(id: 1, tier: .quick, model: "claude-haiku-5-5"))
                == clear + "\nQuick answer (claude-haiku-5-5)\n")
        let turn = Turn(id: 1, speaker: .them, text: "So what happened?", start: 3, end: 4)
        #expect(renderer.render(transcript([turn])) == "")
        #expect(renderer.render(.answerText(id: 1, delta: "Say the feed")) == "Say the feed")
        #expect(renderer.render(.answerText(id: 2, delta: "stale")) == "")
        #expect(renderer.render(.answerText(id: 1, delta: " dropped.")) == " dropped.")

        var record = AnswerRecord(id: 1, tier: .quick, model: "claude-haiku-5-5", askedAt: 4, cost: 0.0005)
        record.latency.hotkeyToFirstToken = 640
        record.latency.hotkeyToDone = 1200
        #expect(
            renderer.render(.answerFinished(record))
                == "\nfirst token 640 ms, done 1.20 s, $0.0005\n\n[0:03] Them  So what happened?\n")
    }

    @Test func failedAnswerReleasesTheTranscript() {
        var renderer = TerminalRenderer(style: .plain)
        _ = renderer.render(.answerStarted(id: 1, tier: .deep, model: "claude-sonnet-5-5"))
        _ = renderer.render(transcript([Turn(id: 1, speaker: .me, text: "Hm.", start: 0, end: 1)]))
        #expect(
            renderer.render(.answerFailed(id: 1, message: "overloaded"))
                == "\nAnswer failed: overloaded\n\n[0:00] Me    Hm.\n")
    }

    @Test func warningsSummaryAndStop() {
        var renderer = TerminalRenderer(style: .plain)
        #expect(renderer.render(.warning("Them has been silent for 30 s")) == "! Them has been silent for 30 s\n")
        _ = renderer.render(.cost(CostSummary(speechCost: 0.12, modelCost: 0.034)))
        #expect(renderer.render(.summaryStarted) == "Writing the summary...\n")
        #expect(renderer.render(.summaryFinished(markdownFile: "/s/summary.md")) == "Summary: /s/summary.md\n")
        #expect(
            renderer.render(.stopped(directory: "/s"))
                == "Saved to /s\nCost $0.15: speech to text $0.12, Claude $0.03\n")
    }

    @Test func colourWrapsLabelsInANSICodes() {
        var renderer = TerminalRenderer(style: TerminalStyle(color: true, liveLine: false))
        let output = renderer.render(transcript([Turn(id: 1, speaker: .me, text: "Yes.", start: 0, end: 1)]))
        #expect(output == "\u{1B}[2m[0:00]\u{1B}[0m \u{1B}[1;36mMe  \u{1B}[0m  Yes.\n")
    }

    @Test func startedListsTheChannels() {
        var renderer = TerminalRenderer(style: .plain)
        let channels = [
            ChannelInfo(speaker: .me, backend: "AVAudioEngine", device: "Headset", nativeFormat: ""),
            ChannelInfo(
                speaker: .them, backend: "Core Audio process tap", device: "all system audio", nativeFormat: ""),
        ]
        #expect(
            renderer.render(.started(channels: channels))
                == "Me   Headset (AVAudioEngine)\nThem all system audio (Core Audio process tap)\n")
    }

    private func transcript(_ turns: [Turn]) -> SessionEvent {
        .transcript(TranscriptSnapshot(turns: turns))
    }
}
