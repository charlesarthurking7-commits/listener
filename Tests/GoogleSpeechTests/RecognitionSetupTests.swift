import Foundation
import GRPCCore
import GRPCInProcessTransport
import ListenerCore
import Testing

@testable import GoogleSpeech

struct RecognitionSetupTests {
    @Test func configMatchesTheSettings() throws {
        var settings = SpeechSettings.forTests()
        settings.model = "long"
        settings.languageCode = "en-US"
        settings.endpointingSensitivity = "SuperShort"
        let request = try RecognitionSetup(settings: settings, quotaProjectID: nil).configRequest

        #expect(request.recognizer == "projects/test-project/locations/eu/recognizers/_")
        guard case .streamingConfig(let streaming) = request.streamingRequest else {
            Issue.record("No streaming config")
            return
        }
        #expect(streaming.config.explicitDecodingConfig.encoding == .linear16)
        #expect(streaming.config.explicitDecodingConfig.sampleRateHertz == 16_000)
        #expect(streaming.config.explicitDecodingConfig.audioChannelCount == 1)
        #expect(streaming.config.model == "long")
        #expect(streaming.config.languageCodes == ["en-US"])
        #expect(streaming.config.features.enableAutomaticPunctuation)
        #expect(streaming.streamingFeatures.interimResults)
        #expect(streaming.streamingFeatures.enableVoiceActivityEvents)
        #expect(streaming.streamingFeatures.endpointingSensitivity == .supershort)
    }

    @Test func takesTheProjectFromTheQuotaProjectWhenSettingsHaveNone() throws {
        var settings = SpeechSettings.forTests()
        settings.googleProjectID = " "
        let setup = try RecognitionSetup(settings: settings, quotaProjectID: "adc-project")
        #expect(setup.recognizer == "projects/adc-project/locations/eu/recognizers/_")
    }

    @Test func refusesSettingsWithoutAProject() {
        var settings = SpeechSettings.forTests()
        settings.googleProjectID = nil
        let error = #expect(throws: GoogleSpeechError.self) {
            try RecognitionSetup(settings: settings, quotaProjectID: nil)
        }
        #expect(error?.kind == .configuration)
        #expect(error?.message.contains("speech.googleProjectID") == true)
    }

    @Test(arguments: ["standard", "SHORT", "supershort"])
    func acceptsTheThreeSensitivities(_ name: String) {
        #expect(RecognitionSetup.sensitivity(named: name) != nil)
    }

    @Test func refusesAnUnknownSensitivity() {
        var settings = SpeechSettings.forTests()
        settings.endpointingSensitivity = "fast"
        let error = #expect(throws: GoogleSpeechError.self) {
            try RecognitionSetup(settings: settings, quotaProjectID: nil)
        }
        #expect(error?.message.contains("standard, short or supershort") == true)
    }

    @Test func splitsAudioIntoLittleEndianFrames() {
        let samples: [Int16] = Array(repeating: 0x0102, count: 3_500)
        let requests = RecognitionSetup.audioRequests(samples[...], frameBytes: 3_200)
        let frames = requests.compactMap { request -> Data? in
            if case .audio(let audio) = request.streamingRequest { audio } else { nil }
        }

        #expect(frames.map(\.count) == [3_200, 3_200, 600])
        #expect(Array(frames[0].prefix(4)) == [0x02, 0x01, 0x02, 0x01])
    }

    @Test func framesASliceFromItsOwnStart() {
        let samples = Audio.samples(from: 0, to: 0.1)
        let requests = RecognitionSetup.audioRequests(samples[1_000...], frameBytes: 3_200)
        guard case .audio(let audio) = requests.first?.streamingRequest else {
            Issue.record("No audio")
            return
        }
        #expect(requests.count == 1)
        #expect(audio.count == 1_200)
        #expect(audio.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } == Array(samples[1_000...]))
    }

    @Test func parsesTheEndpoint() throws {
        let regional = try Endpoint("eu-speech.googleapis.com", location: "eu")
        #expect(regional.host == "eu-speech.googleapis.com" && regional.port == 443)
        #expect(try Endpoint("speech.googleapis.com", location: "global").host == "speech.googleapis.com")
        let local = try Endpoint("localhost:8443", location: "eu")
        #expect(local.host == "localhost" && local.port == 8443)
        #expect(throws: GoogleSpeechError.self) { try Endpoint("host:port", location: "eu") }
        #expect(throws: GoogleSpeechError.self) { try Endpoint(":443", location: "eu") }
    }

    @Test func refusesAnEndpointForAnotherLocation() {
        let error = #expect(throws: GoogleSpeechError.self) {
            try Endpoint("us-speech.googleapis.com", location: "eu")
        }
        #expect(error?.message.contains("eu-speech.googleapis.com") == true)
    }

    @Test func namesTheModelAndLocation() throws {
        let client = GRPCClient(transport: InProcessTransport().client)
        let provider = try GoogleSpeechProvider(
            settings: .forTests(),
            tokenProvider: FakeTokens(),
            client: Google_Cloud_Speech_V2_Speech.Client(wrapping: client),
            tuning: .forTests())
        #expect(provider.displayName == "Google chirp_3 (eu)")
    }

    @Test func publicInitialiserRefusesBadSettingsBeforeConnecting() {
        var settings = SpeechSettings.forTests()
        settings.googleEndpoint = "us-speech.googleapis.com"
        #expect(throws: GoogleSpeechError.self) {
            try GoogleSpeechProvider(settings: settings, turns: TurnSettings(), tokenProvider: FakeTokens())
        }
    }

    @Test func rotationIntervalComesFromSettings() {
        #expect(StreamTuning.forTests(settings: .forTests(rotateAfterSeconds: 120)).rotateAfter == .seconds(120))
    }

    @Test func aPauseInsideAnUtteranceIsOneThatWouldNotEndATurn() {
        var turns = TurnSettings()
        turns.silenceMs = 900
        #expect(StreamTuning(settings: .forTests(), turns: turns).utterancePause == .milliseconds(900))
    }
}
