import AVFoundation
import CoreMedia
import ListenerCore
import ScreenCaptureKit
import Synchronization

/// The "Them" channel through ScreenCaptureKit, kept as the fallback for the Core Audio
/// tap. SCK cannot capture audio without also running a video stream, so we ask for a
/// 2x2 pixel frame once a second and ignore it.
///
/// SCK stops sending audio while the Mac is silent, so the channel's gaps are filled
/// with silence (ContinuousAudioFeed). A stream that dies with an error is reopened.
///
/// The converter is only touched on `sampleQueue` and everything else sits behind
/// `state`, hence @unchecked Sendable.
public final class ScreenCaptureAudio: NSObject, AudioCaptureSource, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    private struct State {
        var feed: ContinuousAudioFeed?
        var stream: StreamHandle?
        var pacer = RestartPacer()
        var restartPending = false
        var lastFailure: String?
    }

    private let onEvent: (@Sendable (CaptureEvent) -> Void)?
    private let sampleQueue = DispatchQueue(label: "listener.capture.screencapturekit", qos: .userInitiated)
    private let state = Mutex(State())
    private var converter: PCMConverter?

    public init(onEvent: (@Sendable (CaptureEvent) -> Void)? = nil) {
        self.onEvent = onEvent
        super.init()
    }

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo {
        try CapturePermissions.requireScreenRecording()
        let feed = ContinuousAudioFeed(speaker: .them, onChunk: onChunk)
        let claimed = state.withLock { state in
            if state.feed != nil {
                return false
            }
            state.feed = feed
            return true
        }
        if !claimed {
            throw CaptureError.alreadyRunning
        }
        feed.start()

        do {
            let stream = try await openStream()
            keepOrStop(stream, for: feed)
        } catch {
            state.withLock { $0.feed = nil }
            feed.stop()
            throw error
        }
        return ChannelInfo(
            speaker: .them,
            backend: "ScreenCaptureKit",
            device: "all system audio",
            nativeFormat: "48 kHz, 2 ch, float32 planar (requested)"
        )
    }

    /// Returns at once. The consumer gets no audio after this returns.
    public func stop() {
        let (feed, stream) = state.withLock { state in
            defer {
                state.feed = nil
                state.stream = nil
            }
            return (state.feed, state.stream)
        }
        feed?.stop()
        stream?.stop()
    }

    private func openStream() async throws -> StreamHandle {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        // Without a screen output SCK logs an error for every dropped video frame.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        return StreamHandle(stream)
    }

    /// Keeps a freshly opened stream, unless `stop()` ran while it was opening.
    @discardableResult
    private func keepOrStop(_ stream: StreamHandle, for feed: ContinuousAudioFeed) -> Bool {
        let kept = state.withLock { state in
            if state.feed !== feed {
                return false
            }
            state.stream = stream
            return true
        }
        if !kept {
            stream.stop()
        }
        return kept
    }

    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid, let feed = state.withLock({ $0.feed }) else {
            return
        }
        let capturedAt = ContinuousClock.now
        guard var description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
            let format = AVAudioFormat(streamDescription: &description)
        else {
            return
        }

        if converter == nil || converter?.inputFormat != format {
            converter = try? PCMConverter(inputFormat: format)
        }
        guard let converter else {
            return
        }

        let samples: [Int16]? = try? sampleBuffer.withAudioBufferList { bufferList, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList.unsafePointer) else {
                return nil
            }
            return try converter.convert(buffer)
        }
        if let samples, !samples.isEmpty {
            feed.accept(AudioChunk(speaker: .them, samples: samples, capturedAt: capturedAt))
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let isCurrent = state.withLock { $0.stream?.stream === stream }
        guard isCurrent else {
            return
        }
        if (error as? SCStreamError)?.code == .userStopped {
            state.withLock { $0.stream = nil }
            CaptureSupport.report(.stoppedByUser(.them), to: onEvent)
            return
        }
        Log.capture.error(
            "ScreenCaptureKit stream stopped: \(String(describing: error), privacy: .public)")
        scheduleRestart()
    }

    /// Returns the delay, or nil when stopped or when a restart is already scheduled.
    @discardableResult
    private func scheduleRestart() -> Duration? {
        let delay: Duration? = state.withLock { state in
            if state.feed == nil || state.restartPending {
                return nil
            }
            state.restartPending = true
            state.stream = nil
            return state.pacer.delay(at: .now)
        }
        if let delay {
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                await self?.restart()
            }
        }
        return delay
    }

    private func restart() async {
        let feed = state.withLock { state in
            state.restartPending = false
            state.pacer.restarted(at: .now)
            return state.feed
        }
        guard let feed else {
            return
        }
        feed.realign()
        do {
            if keepOrStop(try await openStream(), for: feed) {
                state.withLock { $0.lastFailure = nil }
                CaptureSupport.report(.restarted(.them, reason: .streamStopped), to: onEvent)
            }
        } catch {
            // Retries repeat the same failure every few seconds; say it once.
            let message = String(describing: error)
            let isNewFailure = state.withLock { state in
                defer { state.lastFailure = message }
                return state.lastFailure != message
            }
            if let retryIn = scheduleRestart(), isNewFailure {
                CaptureSupport.report(
                    .restartFailed(.them, reason: .streamStopped, error: message, retryIn: retryIn), to: onEvent)
            }
        }
    }
}

/// SCStream is not marked Sendable, but ScreenCaptureKit's own async API starts and
/// stops it from whatever thread the caller is on, which is all this wrapper does.
private final class StreamHandle: @unchecked Sendable {
    let stream: SCStream

    init(_ stream: SCStream) {
        self.stream = stream
    }

    /// Stops without waiting. The completion handler holds on to the handle so the
    /// stream stays alive until ScreenCaptureKit has finished stopping it.
    func stop() {
        stream.stopCapture { _ in
            withExtendedLifetime(self) {}
        }
    }
}
