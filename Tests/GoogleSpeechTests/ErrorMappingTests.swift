import Foundation
import GRPCCore
import GRPCProtobuf
import Testing

@testable import GoogleSpeech

struct ErrorMappingTests {
    private let setup = try! RecognitionSetup(settings: .forTests(), quotaProjectID: nil)

    private func failure(_ error: any Error) -> GoogleSpeechError? {
        if case .fail(let failure) = setup.response(to: error) { failure } else { nil }
    }

    private func permissionDenied(_ message: String, details: ErrorDetails...) -> RPCError {
        RPCError(GoogleRPCStatus(code: .permissionDenied, message: message, details: details))
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
        let error = failure(permissionDenied("API has not been used", details: .serviceDisabled))
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
        let details = ErrorDetails.errorInfo(reason: "BILLING_DISABLED", domain: "googleapis.com")
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
}
