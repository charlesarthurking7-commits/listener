import Testing

@testable import ListenerCore

struct WordErrorRateTests {
    @Test func identicalTextHasNoErrors() {
        let score = WordErrorRate(
            reference: "the quarterly numbers look fine", hypothesis: "the quarterly numbers look fine")
        #expect(score.errors == 0)
        #expect(score.rate == 0)
    }

    @Test func countsEachKindOfError() {
        let substituted = WordErrorRate(reference: "send me the report", hypothesis: "send me a report")
        #expect(substituted.substitutions == 1)
        #expect(substituted.rate == 0.25)

        let deleted = WordErrorRate(reference: "send me the report", hypothesis: "send the report")
        #expect(deleted.deletions == 1)

        let inserted = WordErrorRate(reference: "send me the report", hypothesis: "send me the the report")
        #expect(inserted.insertions == 1)
    }

    @Test func ignoresCaseAndPunctuation() {
        let score = WordErrorRate(reference: "Don't follow-up, OK?", hypothesis: "don\u{2019}t follow up ok")
        #expect(score.errors == 0)
        #expect(score.referenceWords == 4)
    }

    @Test func rateCanExceedOneWhenWordsAreInvented() {
        let score = WordErrorRate(reference: "yes", hypothesis: "to to to to")
        #expect(score.substitutions == 1)
        #expect(score.insertions == 3)
        #expect(score.rate == 4)
    }

    @Test func emptySidesAreAllDeletionsOrInsertions() {
        #expect(WordErrorRate(reference: "one two", hypothesis: "").deletions == 2)
        #expect(WordErrorRate(reference: "", hypothesis: "one").insertions == 1)
        #expect(WordErrorRate(reference: "", hypothesis: "").rate == 0)
    }
}
