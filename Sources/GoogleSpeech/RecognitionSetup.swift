import Foundation
import GRPCCore
import ListenerCore

typealias RecognizeRequest = Google_Cloud_Speech_V2_StreamingRecognizeRequest
typealias RecognizeResponse = Google_Cloud_Speech_V2_StreamingRecognizeResponse
typealias EndpointingSensitivity = Google_Cloud_Speech_V2_StreamingRecognitionFeatures.EndpointingSensitivity

/// Everything that is the same for every stream the provider opens, checked once
/// when the provider is created.
struct RecognitionSetup: Sendable {
    let project: String
    let location: String
    let model: String
    let languageCode: String
    let sensitivity: EndpointingSensitivity
    let quotaProjectID: String?

    init(settings: SpeechSettings, quotaProjectID: String?) throws {
        guard let project = settings.googleProjectID.nilIfBlank ?? quotaProjectID else {
            throw GoogleSpeechError(
                .configuration,
                "No Google Cloud project is set. Set speech.googleProjectID, or run "
                    + "`gcloud auth application-default set-quota-project <project>`.")
        }
        guard let sensitivity = Self.sensitivity(named: settings.endpointingSensitivity) else {
            throw GoogleSpeechError(
                .configuration,
                "speech.endpointingSensitivity is \"\(settings.endpointingSensitivity)\". "
                    + "Use standard, short or supershort.")
        }
        self.project = project
        self.location = settings.googleLocation
        self.model = settings.model
        self.languageCode = settings.languageCode
        self.sensitivity = sensitivity
        self.quotaProjectID = quotaProjectID
    }

    /// `_` is the implicit recognizer: no resource to create, the config travels
    /// with each stream.
    var recognizer: String { "projects/\(project)/locations/\(location)/recognizers/_" }

    /// The first message of every stream. Only audio may follow it.
    var configRequest: RecognizeRequest {
        var decoding = Google_Cloud_Speech_V2_ExplicitDecodingConfig()
        decoding.encoding = .linear16
        decoding.sampleRateHertz = Int32(AudioChunk.sampleRate)
        decoding.audioChannelCount = 1

        var config = Google_Cloud_Speech_V2_RecognitionConfig()
        config.explicitDecodingConfig = decoding
        config.model = model
        config.languageCodes = [languageCode]
        config.features.enableAutomaticPunctuation = true

        var streaming = Google_Cloud_Speech_V2_StreamingRecognitionConfig()
        streaming.config = config
        streaming.streamingFeatures.interimResults = true
        // Gives each utterance a real start time. Harmless on its own: only
        // voice_activity_timeout, which we never set, makes the server hang up.
        streaming.streamingFeatures.enableVoiceActivityEvents = true
        streaming.streamingFeatures.endpointingSensitivity = sensitivity

        var request = RecognizeRequest()
        request.recognizer = recognizer
        request.streamingConfig = streaming
        return request
    }

    func metadata(token: String) -> Metadata {
        var metadata: Metadata = ["authorization": "Bearer \(token)"]
        if let quotaProjectID {
            metadata.addString(quotaProjectID, forKey: "x-goog-user-project")
        }
        return metadata
    }

    /// Splits audio into requests of at most `frameBytes` bytes of 16-bit
    /// little-endian samples.
    static func audioRequests(_ samples: ArraySlice<Int16>, frameBytes: Int) -> [RecognizeRequest] {
        let frameSamples = max(frameBytes / MemoryLayout<Int16>.size, 1)
        return stride(from: samples.startIndex, to: samples.endIndex, by: frameSamples).map { start in
            let frame = samples[start..<min(start + frameSamples, samples.endIndex)]
            var request = RecognizeRequest()
            #if _endian(big)
                request.audio = frame.map(\.littleEndian).withUnsafeBytes { Data($0) }
            #else
                request.audio = frame.withUnsafeBytes { Data($0) }
            #endif
            return request
        }
    }

    static func sensitivity(named name: String) -> EndpointingSensitivity? {
        switch name.lowercased() {
        case "standard": .standard
        case "short": .short
        case "supershort": .supershort
        default: nil
        }
    }
}

/// `host` or `host:port` from `speech.googleEndpoint`.
struct Endpoint: Equatable {
    var host: String
    var port: Int

    init(_ text: String, location: String) throws {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
            let port = parts.count == 2 ? Int(parts[1]) : 443
        else {
            throw GoogleSpeechError(.configuration, "speech.googleEndpoint \"\(text)\" is not a host or host:port")
        }
        host = String(parts[0])
        self.port = port

        // Google serves each location from its own host and rejects a recognizer
        // whose location does not match it. Custom hosts are left alone.
        if host.hasSuffix("speech.googleapis.com") {
            let expected = location == "global" ? "speech.googleapis.com" : "\(location)-speech.googleapis.com"
            guard host == expected else {
                throw GoogleSpeechError(
                    .configuration,
                    "speech.googleLocation \"\(location)\" needs speech.googleEndpoint \"\(expected)\", not \"\(host)\""
                )
            }
        }
    }
}
