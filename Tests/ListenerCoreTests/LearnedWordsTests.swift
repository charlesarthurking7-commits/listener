import Testing

@testable import ListenerCore

struct CorrectionFinderTests {
    /// A small stand-in for the Mac's spell checker.
    private static let common: Set<String> = [
        "hi", "thanks", "for", "the", "update", "can", "you", "send", "it", "to", "by", "wednesday", "friday",
        "thursday", "check", "fix", "logs", "fills", "from", "today", "we", "need", "and", "i", "will", "call",
        "affect", "effect", "this", "bursts", "brush", "cheers", "bridge", "on", "team", "meet", "at", "pelican",
        "a", "quick", "one", "she", "is", "bye", "see",
    ]

    private func corrections(_ typed: String, _ field: String) -> [CorrectionFinder.Correction] {
        CorrectionFinder.corrections(typed: typed, field: field) { Self.common.contains($0.lowercased()) }
    }

    private func fix(_ heard: String, _ term: String) -> CorrectionFinder.Correction {
        CorrectionFinder.Correction(heard: heard, term: term)
    }

    @Test func aMisspeltNameFixedInPlaceIsLearned() {
        #expect(
            corrections(
                "Thanks for the update, Shavani. Can you send it today?",
                "Thanks for the update, Shivani. Can you send it today?")
                == [fix("Shavani", "Shivani")])
    }

    @Test func twoWordsJoinedIntoOneName() {
        #expect(
            corrections("We need the fills from Kestrel Moore today.", "We need the fills from Kestrelmoor today.")
                == [fix("Kestrel Moore", "Kestrelmoor")])
    }

    @Test func aTermPutInCapitalsIsLearned() {
        #expect(corrections("I will check the fix logs.", "I will check the FIX logs.") == [fix("fix", "FIX")])
    }

    @Test func aNameCapitalisedMidSentenceIsLearned() {
        #expect(
            corrections("Send it to pelican by Friday.", "Send it to Pelican by Friday.") == [fix("pelican", "Pelican")]
        )
    }

    @Test func theTextAroundTheDictationDoesNotCount() {
        // The field holds more than was dictated, and the user fixed the first word.
        let field = "Re: the bridge. Hi team,\nShivani can you send it today?\nCheers"
        #expect(corrections("Shavani can you send it today?", field) == [fix("Shavani", "Shivani")])
        #expect(
            corrections("Can you send it to Shavani", "Can you send it to Shivani\nCheers") == [
                fix("Shavani", "Shivani")
            ])
    }

    @Test func fixesToOrdinaryWordsAreEditsNotSpellings() {
        #expect(corrections("This will affect the fills.", "This will effect the fills.").isEmpty)
        #expect(corrections("with brush up to 200", "with bursts up to 200").isEmpty)
        #expect(corrections("She is bye.", "Cheers bye.").isEmpty)
    }

    @Test func changingWhatWasSaidIsNotACorrection() {
        #expect(corrections("Can you send it by Wednesday?", "Can you send it by Friday?").isEmpty)
        #expect(corrections("Meet at the bridge.", "Meet at Canary Wharf.").isEmpty)
    }

    @Test func capitalsAtTheStartOfASentenceAreNotNames() {
        #expect(corrections("Thanks. the fills are in.", "Thanks. The fills are in.").isEmpty)
    }

    @Test func punctuationAloneIsNotACorrection() {
        #expect(corrections("Hi Shivani thanks", "Hi Shivani, thanks.").isEmpty)
    }

    @Test func aRewrittenOrSentMessageTeachesNothing() {
        #expect(corrections("Can you send it to Shavani by Friday?", "").isEmpty)
        #expect(corrections("Can you send it to Shavani by Friday?", "Never mind, I'll call Shivani.").isEmpty)
    }

    @Test func wordsNotInTheDictionaryCountAsTerms() {
        #expect(corrections("Hi Shavanee, thanks.", "Hi Shivani, thanks.") == [fix("Shavanee", "Shivani")])
    }

    @Test func editDistanceGivesUpPastItsLimit() {
        #expect(CorrectionFinder.editDistance("shavani", "shivani", limit: 2) == 1)
        #expect(CorrectionFinder.editDistance("bridge", "canarywharf", limit: 2) == 3)
    }
}

struct LearnedDictionaryTests {
    @Test func readsAndWritesItsFile() {
        let text = """
            # comment
            Shivani (heard as Shavani)

            Kestrelmoor (heard as Kestrel Moore, kestrel moor)
            MT5
            """
        let dictionary = LearnedDictionary(text: text)
        #expect(
            dictionary.entries == [
                .init(term: "Shivani", heardAs: ["Shavani"]),
                .init(term: "Kestrelmoor", heardAs: ["Kestrel Moore", "kestrel moor"]),
                .init(term: "MT5"),
            ])
        #expect(LearnedDictionary(text: dictionary.text) == dictionary)
        #expect(dictionary.text.hasPrefix("# Words Listener's dictation learned"))
        #expect(dictionary.text.hasSuffix("MT5\n"))
    }

    @Test func learningAddsNewWordsAndNewMishearings() {
        var dictionary = LearnedDictionary()
        let new = dictionary.learn(.init(heard: "Shavani", term: "Shivani"))
        let again = dictionary.learn(.init(heard: "Shavani", term: "Shivani"))
        let newMishearing = dictionary.learn(.init(heard: "Shivanee", term: "Shivani"))
        #expect(new && !again && newMishearing)
        #expect(dictionary.entries == [.init(term: "Shivani", heardAs: ["Shavani", "Shivanee"])])
        dictionary.forget("Shivani")
        #expect(dictionary.entries.isEmpty)
    }

    @Test func wordsCanBeAddedByHand() {
        var dictionary = LearnedDictionary(entries: [.init(term: "Shivani", heardAs: ["Shavani"])])
        let added = dictionary.add("  Kestrelmoor \n")
        let refused = ["Kestrelmoor", "Shivani", " ", "a\nb"].filter { !dictionary.add($0) }
        #expect(added && refused.count == 4)
        #expect(dictionary.entries == [.init(term: "Shivani", heardAs: ["Shavani"]), .init(term: "Kestrelmoor")])
        #expect(dictionary.text.hasSuffix("Shivani (heard as Shavani)\nKestrelmoor\n"))
        #expect(LearnedDictionary(text: dictionary.text) == dictionary)
    }

    @Test func theOldestWordsGoPastTheCap() {
        var dictionary = LearnedDictionary()
        for index in 0...LearnedDictionary.maxEntries {
            dictionary.learn(.init(heard: "word\(index)", term: "Term\(index)"))
        }
        #expect(dictionary.entries.count == LearnedDictionary.maxEntries)
        #expect(dictionary.entries.first?.term == "Term1")
    }

    @Test func promptTermsSayHowTheyWereMisheard() {
        let dictionary = LearnedDictionary(entries: [.init(term: "Shivani", heardAs: ["Shavani"]), .init(term: "MT5")])
        #expect(dictionary.promptTerms == ["Shivani (heard as \"Shavani\")", "MT5"])
    }

    @Test func learnedWordsGoInTheCleanUpPrompt() {
        let system = DictationTidier.system(
            settings: DictationSettings(), aboutMe: "", learned: ["Shivani (heard as \"Shavani\")"])
        #expect(system.contains("use the speaker's spelling: Shivani (heard as \"Shavani\")."))
        #expect(
            !DictationTidier.system(settings: DictationSettings(), aboutMe: "").contains("corrected the recognizer"))
    }
}
