import Testing

@testable import ListenerCore

struct TranscriptWindowTests {
    /// A deterministic conversation of `count` turns between 3 and 40 words long.
    static func conversation(_ count: Int, seed: UInt64 = 7) -> [Turn] {
        var state = seed
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        let words = ["the", "margin", "call", "account", "we", "can", "check", "position", "broker", "copy", "trade"]
        var turns: [Turn] = []
        var clock = 0.0
        for id in 0..<count {
            let wordCount = 3 + next() % 38
            let text = (0..<wordCount).map { _ in words[next() % words.count] }.joined(separator: " ")
            let duration = Double(wordCount) * 0.4
            turns.append(
                Turn(id: id, speaker: next() % 3 == 0 ? .me : .them, text: text, start: clock, end: clock + duration))
            clock += duration + 0.6
        }
        return turns
    }

    static func tokens(_ turns: ArraySlice<Turn>) -> Int {
        turns.reduce(0) { $0 + TokenEstimate.tokens(in: TranscriptWindow.line(for: $1)) }
    }

    @Test func rendersTimestampedSpeakerLines() {
        let turns = [
            Turn(id: 0, speaker: .them, text: "Can you hear me?", start: 3.2, end: 3.9),
            Turn(id: 1, speaker: .me, text: "Yes,\nloud and clear.", start: 65.9, end: 67),
        ]
        let window = TranscriptWindow(turns: turns, budgetTokens: 8_000, hardCapTokens: 60_000)
        #expect(window.blocks == ["[00:03] Them: Can you hear me?\n[01:05-01:07] Me: Yes, loud and clear.\n"])
        #expect(window.firstTurnIndex == 0)
        #expect(!window.omitsEarlierTurns)
        #expect(window.estimatedTokens == Self.tokens(turns[...]))
    }

    @Test func timestampsKeepCountingMinutesPastAnHour() {
        #expect(TranscriptWindow.timestamp(0) == "[00:00]")
        #expect(TranscriptWindow.timestamp(599.99) == "[09:59]")
        #expect(TranscriptWindow.timestamp(3_725) == "[62:05]")
        #expect(TranscriptWindow.timestamp(-4) == "[00:00]")
    }

    @Test func noTurnsGiveAnEmptyWindow() {
        let window = TranscriptWindow(turns: [], budgetTokens: 8_000, hardCapTokens: 60_000)
        #expect(window.blocks.isEmpty)
        #expect(window.estimatedTokens == 0)
    }

    @Test func consecutiveWindowsShareEveryCompleteBlock() {
        let turns = Self.conversation(400)
        var previous = TranscriptWindow(turns: Array(turns.prefix(1)), budgetTokens: 2_000, hardCapTokens: 60_000)
        var moves = 0
        for count in 2...turns.count {
            let window = TranscriptWindow(turns: Array(turns.prefix(count)), budgetTokens: 2_000, hardCapTokens: 60_000)
            if window.firstTurnIndex == previous.firstTurnIndex {
                #expect(Array(window.blocks.prefix(previous.blocks.count - 1)) == Array(previous.blocks.dropLast()))
                #expect(window.blocks.joined().hasPrefix(previous.blocks.joined()))
            } else {
                #expect(window.firstTurnIndex > previous.firstTurnIndex)
                moves += 1
            }
            previous = window
        }
        // A window that slid turn by turn would move about 300 times here.
        #expect(moves > 0)
        #expect(moves <= Self.tokens(turns[...]) / 500 + 1)
    }

    @Test func windowStartsOnlyAtQuarterBudgetCheckpoints() {
        let turns = Self.conversation(300)
        let step = 2_000 / 4
        var offsets: [Int] = []
        var total = 0
        for turn in turns {
            offsets.append(total)
            total += TranscriptWindow.estimatedTokens(for: turn)
        }
        for count in 1...turns.count {
            let start = TranscriptWindow(
                turns: Array(turns.prefix(count)), budgetTokens: 2_000, hardCapTokens: 60_000
            ).firstTurnIndex
            #expect(start == 0 || offsets[start - 1] / step != offsets[start] / step)
        }
    }

    @Test func windowStaysWithinBudgetAndUsesMostOfIt() {
        let turns = Self.conversation(400)
        let budget = 2_000
        let sizes = turns.map { TokenEstimate.tokens(in: TranscriptWindow.line(for: $0)) }
        let longestTurn = sizes.max() ?? 0
        for count in 1...turns.count {
            let window = TranscriptWindow(
                turns: Array(turns.prefix(count)), budgetTokens: budget, hardCapTokens: 60_000)
            #expect(window.estimatedTokens == sizes[window.firstTurnIndex..<count].reduce(0, +))
            #expect(window.blocks.joined() == turns[window.firstTurnIndex..<count].map(TranscriptWindow.line).joined())
            #expect(window.estimatedTokens <= budget)
            if window.omitsEarlierTurns {
                #expect(window.estimatedTokens > budget - budget / 4 - longestTurn)
            }
        }
    }

    @Test func blocksBreakAtAboutFiveHundredTokens() {
        let turns = Self.conversation(600)
        let longestTurn = turns.map { TokenEstimate.tokens(in: TranscriptWindow.line(for: $0)) }.max() ?? 0
        let window = TranscriptWindow(turns: turns, budgetTokens: 8_000, hardCapTokens: 60_000)
        #expect(window.omitsEarlierTurns)
        #expect(window.blocks.count >= 10)
        for block in window.blocks.dropLast() {
            #expect(TokenEstimate.tokens(in: block) < 500 + longestTurn)
        }
    }

    @Test func growingLastTurnOnlyChangesTheLastBlock() {
        var turns = Self.conversation(120)
        let before = TranscriptWindow(turns: turns, budgetTokens: 4_000, hardCapTokens: 60_000)
        turns[turns.count - 1].text += " and one more thing"
        let after = TranscriptWindow(turns: turns, budgetTokens: 4_000, hardCapTokens: 60_000)
        #expect(after.firstTurnIndex == before.firstTurnIndex)
        #expect(Array(after.blocks.dropLast()) == Array(before.blocks.dropLast()))
        #expect(after.blocks.last?.hasSuffix("and one more thing\n") == true)
    }

    @Test func singleTurnLongerThanTheHardCapKeepsItsEnd() {
        let monologue = String(repeating: "blah ", count: 20_000) + "so what is the margin?"
        let turns = Self.conversation(10) + [Turn(id: 10, speaker: .them, text: monologue, start: 200, end: 900)]
        let window = TranscriptWindow(turns: turns, budgetTokens: 8_000, hardCapTokens: 1_000)
        #expect(window.firstTurnIndex == 10)
        #expect(window.estimatedTokens <= 1_000)
        #expect(window.estimatedTokens == TokenEstimate.tokens(in: window.blocks.joined()))
        #expect(window.blocks.joined().hasPrefix("[03:20-15:00] Them: ... "))
        #expect(window.blocks.joined().hasSuffix("so what is the margin?\n"))
    }

    @Test func turnLongerThanTheBudgetButUnderTheCapIsSentWhole() {
        let speech = String(repeating: "word ", count: 3_000)
        let turns = Self.conversation(5) + [Turn(id: 5, speaker: .them, text: speech, start: 100, end: 400)]
        let window = TranscriptWindow(turns: turns, budgetTokens: 1_000, hardCapTokens: 60_000)
        #expect(window.firstTurnIndex == 5)
        #expect(window.blocks.joined() == TranscriptWindow.line(for: turns[5]))
    }

    @Test func hardCapWinsOverALargerBudget() {
        let window = TranscriptWindow(turns: Self.conversation(400), budgetTokens: 50_000, hardCapTokens: 1_000)
        #expect(window.omitsEarlierTurns)
        #expect(window.estimatedTokens <= 1_000)
    }

    @Test func longTurnIsNotDroppedToReachACheckpoint() {
        // Budget 100, so checkpoints every 25 tokens. The long question starts between
        // checkpoints and the next checkpoint is the short reply after it; starting
        // there would leave the question out although both fit.
        let filler = String(repeating: "x", count: 15)
        let question = String(repeating: "q", count: 255)
        let turns = [
            Turn(id: 0, speaker: .them, text: filler, start: 0, end: 1),
            Turn(id: 1, speaker: .me, text: filler, start: 1, end: 2),
            Turn(id: 2, speaker: .them, text: question, start: 2, end: 30),
            Turn(id: 3, speaker: .me, text: "", start: 30, end: 31),
        ]
        let window = TranscriptWindow(turns: turns, budgetTokens: 100, hardCapTokens: 60_000)
        #expect(window.firstTurnIndex == 2)
        #expect(window.estimatedTokens == 99)
    }
}
