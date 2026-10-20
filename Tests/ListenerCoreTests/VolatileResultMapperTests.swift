import Testing

@testable import ListenerCore

struct VolatileResultMapperTests {
    @Test func volatileBecomesInterimAndFinalSettlesIt() {
        var mapper = VolatileResultMapper()
        let interim = mapper.map(volatileResult(("Hello", 0.2, 0.6), (" there", 0.7, 1.0)))
        #expect(interim == [SpeechEvent(kind: .interim, text: "Hello there", audioStart: 0.2, audioEnd: 1.0)])

        let settled = mapper.map(finalResult(("Hello", 0.2, 0.6), (" there.", 0.7, 1.0)))
        #expect(settled == [SpeechEvent(kind: .final, text: "Hello there.", audioStart: 0.2, audioEnd: 1.0)])
        #expect(mapper.finalizedThrough == 1.0)
    }

    @Test func timesAreShiftedOntoTheChannelTimeline() {
        var mapper = VolatileResultMapper()
        mapper.beginSession(at: 12.5)
        let events = mapper.map(finalResult(("Yes.", 0.25, 0.5)))
        #expect(events == [SpeechEvent(kind: .final, text: "Yes.", audioStart: 12.75, audioEnd: 13.0)])
        #expect(mapper.finalizedThrough == 13.0)
    }

    @Test func wordsAfterAPartialFinalStayAsTheInterim() {
        var mapper = VolatileResultMapper()
        _ = mapper.map(
            volatileResult(("Hello", 0.0, 0.4), (" there", 0.5, 0.9), (" how", 1.4, 1.6), (" are", 1.6, 1.8)))

        let events = mapper.map(finalResult(("Hello", 0.0, 0.4), (" there.", 0.5, 0.9)))
        #expect(
            events == [
                SpeechEvent(kind: .final, text: "Hello there.", audioStart: 0.0, audioEnd: 0.9),
                SpeechEvent(kind: .interim, text: "how are", audioStart: 1.4, audioEnd: 1.8),
            ])
    }

    @Test func volatileTextSettledWithoutAFinalIsPromoted() {
        var mapper = VolatileResultMapper()
        _ = mapper.map(volatileResult(("Send", 0.0, 0.3), (" it", 0.3, 0.5)))

        // The recognizer moved past "Send it" without resending it as final.
        let next = volatileResult(("Today", 1.2, 1.6))
        let events = mapper.map(withFinalizedThrough(1.2, next))
        #expect(
            events == [
                SpeechEvent(kind: .final, text: "Send it", audioStart: 0.0, audioEnd: 0.5),
                SpeechEvent(kind: .interim, text: "Today", audioStart: 1.2, audioEnd: 1.6),
            ])
    }

    @Test func onlyTheSettledPartOfTheVolatileTextIsPromoted() {
        var mapper = VolatileResultMapper()
        _ = mapper.map(volatileResult(("One", 0.0, 0.3), (" two", 0.4, 0.7), (" three", 0.8, 1.1)))

        let events = mapper.map(withFinalizedThrough(0.75, volatileResult((" three", 0.8, 1.1), (" four", 1.2, 1.5))))
        #expect(
            events == [
                SpeechEvent(kind: .final, text: "One two", audioStart: 0.0, audioEnd: 0.7),
                SpeechEvent(kind: .interim, text: "three four", audioStart: 0.8, audioEnd: 1.5),
            ])
    }

    @Test func aRevisedVolatileReplacesTheOldOneWithoutFinals() {
        var mapper = VolatileResultMapper()
        _ = mapper.map(volatileResult(("I sink", 0.0, 0.6)))
        let events = mapper.map(withFinalizedThrough(0.0, volatileResult(("I think so", 0.0, 0.9))))
        #expect(events == [SpeechEvent(kind: .interim, text: "I think so", audioStart: 0.0, audioEnd: 0.9)])
    }

    @Test func wordsBeforeAFinalThatNeverGotTheirOwnFinalAreSettledFirst() {
        var mapper = VolatileResultMapper()
        _ = mapper.map(volatileResult(("Right", 0.0, 0.4), (" so", 1.0, 1.2)))

        let events = mapper.map(finalResult((" so", 1.0, 1.2)))
        #expect(
            events == [
                SpeechEvent(kind: .final, text: "Right", audioStart: 0.0, audioEnd: 0.4),
                SpeechEvent(kind: .final, text: "so", audioStart: 1.0, audioEnd: 1.2),
            ])
    }

    @Test func endingTheSessionPromotesWhatIsStillVolatile() {
        var mapper = VolatileResultMapper()
        mapper.beginSession(at: 3.0)
        _ = mapper.map(volatileResult(("Thanks", 0.1, 0.5)))
        #expect(mapper.endSession() == [SpeechEvent(kind: .final, text: "Thanks", audioStart: 3.1, audioEnd: 3.5)])
        #expect(mapper.finalizedThrough == 3.5)
        #expect(mapper.endSession().isEmpty)
    }

    @Test func punctuationOnlyFinalsAreDroppedAndClearTheInterim() {
        var mapper = VolatileResultMapper()
        _ = mapper.map(volatileResult(("uh", 0.0, 0.2)))
        let events = mapper.map(finalResult((".......", 0.0, 0.3)))
        #expect(events == [SpeechEvent(kind: .interim, text: "", audioStart: nil, audioEnd: nil)])
    }

    @Test func anEmptyVolatileResultRevokesTheInterim() {
        var mapper = VolatileResultMapper()
        _ = mapper.map(volatileResult(("hmm", 0.0, 0.3)))
        let revoked = RecognizerResult(isFinal: false, start: 0.0, end: 0.5, finalizedThrough: 0.0, pieces: [])
        #expect(mapper.map(revoked) == [SpeechEvent(kind: .interim, text: "", audioStart: nil, audioEnd: nil)])
        #expect(mapper.endSession().isEmpty)
    }

    @Test func anUnchangedInterimIsNotRepeated() {
        var mapper = VolatileResultMapper()
        _ = mapper.map(volatileResult(("Okay", 0.0, 0.3)))
        #expect(mapper.map(withFinalizedThrough(0.0, volatileResult(("Okay", 0.0, 0.3)))).isEmpty)
    }

    @Test func untimedPunctuationAndSpacesJoinTheirNeighbours() {
        var mapper = VolatileResultMapper()
        let result = RecognizerResult(
            isFinal: true, start: 0.0, end: 1.0,
            pieces: [
                .init(text: " "),
                .init(text: "Hello", start: 0.1, end: 0.4),
                .init(text: ","),
                .init(text: " world", start: 0.5, end: 0.9),
                .init(text: "."),
            ])
        #expect(
            mapper.map(result) == [SpeechEvent(kind: .final, text: "Hello, world.", audioStart: 0.1, audioEnd: 0.9)])
    }

    @Test func textWithoutWordTimesUsesTheResultRange() {
        var mapper = VolatileResultMapper()
        mapper.beginSession(at: 1.0)
        let result = RecognizerResult(isFinal: true, start: 0.5, end: 2.0, pieces: [.init(text: "No timings here.")])
        #expect(
            mapper.map(result) == [SpeechEvent(kind: .final, text: "No timings here.", audioStart: 1.5, audioEnd: 3.0)])
    }

    @Test func invalidTimesFallBackToWhatIsKnown() {
        var mapper = VolatileResultMapper()
        _ = mapper.map(finalResult(("First.", 0.0, 2.0)))
        let result = RecognizerResult(
            isFinal: true, start: .nan, end: .infinity, pieces: [.init(text: "Second.", start: .nan, end: .nan)])
        #expect(mapper.map(result) == [SpeechEvent(kind: .final, text: "Second.", audioStart: 2.0, audioEnd: 2.0)])
    }

    @Test func aFinalCanSettleVolatileWordsAfterItsOwnRange() {
        var mapper = VolatileResultMapper()
        _ = mapper.map(
            volatileResult(("Buy", 0.0, 0.3), (" now", 0.4, 0.7), (" please", 1.0, 1.4), (" thanks", 2.0, 2.4)))

        var settledFurther = finalResult(("Buy", 0.0, 0.3), (" now", 0.4, 0.7))
        settledFurther.finalizedThrough = 1.5
        #expect(
            mapper.map(settledFurther) == [
                SpeechEvent(kind: .final, text: "Buy now", audioStart: 0.0, audioEnd: 0.7),
                SpeechEvent(kind: .final, text: "please", audioStart: 1.0, audioEnd: 1.4),
                SpeechEvent(kind: .interim, text: "thanks", audioStart: 2.0, audioEnd: 2.4),
            ])
        #expect(mapper.finalizedThrough == 1.5)
    }
}

private func volatileResult(_ words: (String, Double, Double)...) -> RecognizerResult {
    result(isFinal: false, words)
}

private func finalResult(_ words: (String, Double, Double)...) -> RecognizerResult {
    result(isFinal: true, words)
}

private func result(isFinal: Bool, _ words: [(String, Double, Double)]) -> RecognizerResult {
    RecognizerResult(
        isFinal: isFinal,
        start: words.first?.1,
        end: words.last?.2,
        finalizedThrough: isFinal ? words.last?.2 : words.first?.1,
        pieces: words.map { RecognizerResult.Piece(text: $0.0, start: $0.1, end: $0.2) }
    )
}

private func withFinalizedThrough(_ time: Double, _ result: RecognizerResult) -> RecognizerResult {
    var result = result
    result.finalizedThrough = time
    return result
}
