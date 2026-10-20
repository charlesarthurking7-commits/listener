import Foundation
import GRPCCore
import GRPCProtobuf

/// A failure retrying will not fix. Delivered by throwing from `events` (or from
/// the provider's initialiser for bad settings), with a message meant for the user.
public struct GoogleSpeechError: Error, LocalizedError, CustomStringConvertible, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Settings that cannot work, e.g. no project or an unknown sensitivity.
        case configuration
        /// No usable access token, or Google rejected it.
        case credentials
        /// The Speech-to-Text API or billing is not enabled in the project.
        case apiDisabled
        case permissionDenied
        /// Google refused the recognition config, e.g. a model the location lacks.
        case invalidRequest
        case notFound
        case quotaExceeded
        /// Reconnecting kept failing.
        case connectionLost
        case other
    }

    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

/// What a stream does after its call to Google ends with an error.
enum FailureResponse: Equatable {
    /// Reconnect after a backoff and replay unsettled audio.
    case retry
    /// Google hung up because no audio came for a few seconds, which is expected
    /// when the caller skips silence. Reconnect when audio arrives.
    case reconnectWhenAudioArrives
    /// Fetch a fresh token and reconnect at once.
    case refreshToken
    case fail(GoogleSpeechError)
}

extension RecognitionSetup {
    func response(to error: any Error) -> FailureResponse {
        switch error {
        case let error as GoogleSpeechError:
            return .fail(error)
        case let error as GoogleAuthError:
            return error.kind == .unavailable ? .retry : .fail(GoogleSpeechError(.credentials, error.message))
        case let error as RPCError:
            return response(to: error)
        default:
            // Transport and connection errors: the network went away or the
            // connection dropped.
            return .retry
        }
    }

    private func response(to error: RPCError) -> FailureResponse {
        let detail = error.message.isEmpty ? "\(error.code)" : error.message
        if detail.contains("elapsed without audio") {
            return .reconnectWhenAudioArrives
        }
        switch error.code {
        case .unavailable, .internalError, .deadlineExceeded, .aborted, .unknown, .cancelled, .dataLoss:
            return .retry
        case .outOfRange:
            // Google ends a stream that ran too long ("Max duration of 5 minutes").
            return .retry
        case .unauthenticated:
            return .refreshToken
        case .permissionDenied:
            return .fail(permissionDenied(error, detail: detail))
        case .invalidArgument:
            return .fail(
                GoogleSpeechError(
                    .invalidRequest,
                    "Google rejected the recognition settings (model \(model), language \(languageCode), "
                        + "location \(location)): \(detail)"))
        case .notFound:
            return .fail(
                GoogleSpeechError(
                    .notFound,
                    "Google could not find \(recognizer): \(detail). "
                        + "Check speech.googleProjectID and speech.googleLocation."))
        case .resourceExhausted:
            return .fail(
                GoogleSpeechError(.quotaExceeded, "Speech-to-Text quota exceeded in project \(project): \(detail)"))
        default:
            return .fail(GoogleSpeechError(.other, "Speech-to-Text failed (\(error.code)): \(detail)"))
        }
    }

    private func permissionDenied(_ error: RPCError, detail: String) -> GoogleSpeechError {
        let info = (try? error.unpackGoogleRPCStatus())?.details.lazy.compactMap(\.errorInfo).first
        switch info?.reason {
        case "SERVICE_DISABLED":
            let link =
                info?.metadata["activationUrl"]
                ?? "https://console.cloud.google.com/apis/library/speech.googleapis.com?project=\(project)"
            return GoogleSpeechError(
                .apiDisabled,
                "The Speech-to-Text API is not enabled in project \(project). Enable it at \(link), "
                    + "wait a few minutes, then start again.")
        case "BILLING_DISABLED":
            return GoogleSpeechError(
                .apiDisabled,
                "Billing is not enabled for project \(project), and Speech-to-Text needs it. "
                    + "Link a billing account at https://console.cloud.google.com/billing/linkedaccount?project=\(project)."
            )
        case nil where detail.contains("has not been used in project") || detail.contains("it is disabled"):
            // Same as SERVICE_DISABLED, for a response without error details.
            return GoogleSpeechError(
                .apiDisabled,
                "The Speech-to-Text API is not enabled in project \(project): \(detail)")
        default:
            return GoogleSpeechError(
                .permissionDenied,
                "Google denied access to Speech-to-Text in project \(project): \(detail). The account needs "
                    + "the Cloud Speech Client role (roles/speech.client) on the project.")
        }
    }
}
