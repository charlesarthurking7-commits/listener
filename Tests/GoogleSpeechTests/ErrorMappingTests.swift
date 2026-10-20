import Foundation
import GRPCCore
import Testing

@testable import GoogleSpeech

struct ErrorMappingTests {
    private let setup = try! RecognitionSetup(settings: .forTests(), quotaProjectID: nil)

    private func failure(_ error: any Error) -> GoogleSpeechError? {
        if case .fail(let failure) = setup.response(to: error) { failure } else { nil }
    }

    private func permissionDenied(_ message: String, details: [UInt8]? = nil) -> RPCError {
        var metadata = Metadata()
        if let details {
            metadata.addBinary(details, forKey: "grpc-status-details-bin")
        }
        return RPCError(code: .permissionDenied, message: message, metadata: metadata)
    }

    @Test(arguments: [
        RPCError.Code.unavailable, .internalError, .deadlineExceeded, .aborted, .unknown, .cancelled, .outOfRange,
    ])
    func retriesTransientCodes(_ code: RPCError.Code) {
        #expect(setup.response(to: RPCError(code: code, message: "")) == .retry)
    }

    @Test func retriesConnectionErrors() {
        #expect(setup.response(to: URLError(.networkConnectionLost)) == .retry)
        #expect(setup.response(to: GoogleAuthError(.unavailable, "offline")) == .retry)
    }

    @Test func waitsForAudioAfterAnIdleHangUp() {
        let error = RPCError(code: .outOfRange, message: "Long duration elapsed without audio.")
        #expect(setup.response(to: error) == .reconnectWhenAudioArrives)
    }

    @Test func refreshesTheTokenWhenUnauthenticated() {
        #expect(setup.response(to: RPCError(code: .unauthenticated, message: "")) == .refreshToken)
    }

    @Test func rejectedCredentialsAreFinal() {
        let error = failure(GoogleAuthError(.rejected, "Google rejected the stored credentials"))
        #expect(error == GoogleSpeechError(.credentials, "Google rejected the stored credentials"))
    }

    @Test func serviceDisabledPointsAtTheActivationPage() {
        let error = failure(permissionDenied("API has not been used", details: StatusDetails.serviceDisabled))
        #expect(error?.kind == .apiDisabled)
        #expect(error?.message.contains("not enabled in project test-project") == true)
        #expect(
            error?.message.contains(
                "https://console.developers.google.com/apis/api/speech.googleapis.com/overview?project=123") == true)
    }

    @Test func serviceDisabledIsRecognisedFromTheMessageAlone() {
        let message = "Cloud Speech-to-Text API has not been used in project 123 before or it is disabled."
        #expect(failure(permissionDenied(message))?.kind == .apiDisabled)
    }

    @Test func billingDisabledSaysSo() {
        let details = StatusDetails.status(code: 7, message: "Billing", reason: "BILLING_DISABLED", metadata: [:])
        let error = failure(permissionDenied("This API method requires billing to be enabled.", details: details))
        #expect(error?.kind == .apiDisabled)
        #expect(error?.message.contains("Billing is not enabled for project test-project") == true)
    }

    @Test func otherPermissionErrorsNameTheRole() {
        let error = failure(permissionDenied("Permission 'speech.recognizers.recognize' denied"))
        #expect(error?.kind == .permissionDenied)
        #expect(error?.message.contains("speech.recognizers.recognize") == true)
        #expect(error?.message.contains("roles/speech.client") == true)
    }

    @Test func invalidArgumentNamesTheSettings() {
        let error = failure(RPCError(code: .invalidArgument, message: "The model \"chirp_3\" does not exist"))
        #expect(error?.kind == .invalidRequest)
        #expect(error?.message.contains("model chirp_3, language en-GB, location eu") == true)
    }

    @Test func notFoundNamesTheRecognizer() {
        let error = failure(RPCError(code: .notFound, message: "Project not found"))
        #expect(error?.kind == .notFound)
        #expect(error?.message.contains("projects/test-project/locations/eu/recognizers/_") == true)
    }

    @Test func resourceExhaustedIsAQuotaError() {
        let error = failure(RPCError(code: .resourceExhausted, message: "Quota exceeded"))
        #expect(error?.kind == .quotaExceeded)
        #expect(error?.message.contains("Quota exceeded") == true)
    }

    @Test func otherCodesFailWithTheServerMessage() {
        let error = failure(RPCError(code: .failedPrecondition, message: "Something is off"))
        #expect(error?.kind == .other)
        #expect(error?.message.contains("Something is off") == true)
    }

    /// Google's real answer to a call without credentials, captured from
    /// eu-speech.googleapis.com. Checks the hand-written fixtures above have the
    /// same shape as what Google sends.
    @Test func statusDetailsFixturesMatchGooglesEncoding() throws {
        let recorded = try #require(
            Data(
                base64Encoded:
                    "CBAS1wFSZXF1ZXN0IGlzIG1pc3NpbmcgcmVxdWlyZWQgYXV0aGVudGljYXRpb24gY3JlZGVudGlhbC4gRXhwZWN0ZWQgT0F1dGggMiBhY2Nlc3MgdG9rZW4sIGxvZ2luIGNvb2tpZSBvciBvdGhlciB2YWxpZCBhdXRoZW50aWNhdGlvbiBjcmVkZW50aWFsLiBTZWUgaHR0cHM6Ly9kZXZlbG9wZXJzLmdvb2dsZS5jb20vaWRlbnRpdHkvc2lnbi1pbi93ZWIvZGV2Y29uc29sZS1wcm9qZWN0LhqwAQoodHlwZS5nb29nbGVhcGlzLmNvbS9nb29nbGUucnBjLkVycm9ySW5mbxKDAQoTQ1JFREVOVElBTFNfTUlTU0lORxIOZ29vZ2xlYXBpcy5jb20aOgoGbWV0aG9kEjBnb29nbGUuY2xvdWQuc3BlZWNoLnYyLlNwZWVjaC5TdHJlYW1pbmdSZWNvZ25pemUaIAoHc2VydmljZRIVc3BlZWNoLmdvb2dsZWFwaXMuY29t"
            ))
        let rebuilt = StatusDetails.status(
            code: 16,
            message: "Request is missing required authentication credential. Expected OAuth 2 access token, login "
                + "cookie or other valid authentication credential. See "
                + "https://developers.google.com/identity/sign-in/web/devconsole-project.",
            reason: "CREDENTIALS_MISSING",
            metadata: [
                "method": "google.cloud.speech.v2.Speech.StreamingRecognize",
                "service": "speech.googleapis.com",
            ])
        #expect(rebuilt == Array(recorded))
    }
}
