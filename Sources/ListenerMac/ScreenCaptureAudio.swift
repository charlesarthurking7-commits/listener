import AVFoundation
import CoreGraphics
import CoreMedia
import ListenerCore
import ScreenCaptureKit

/// The "Them" channel through ScreenCaptureKit. Kept as the fallback for the Core
/// Audio tap. SCK cannot capture audio without also running a video stream, so we
/// ask for a 2x2 pixel frame once a second and ignore it.
///
/// Converter state is only touched on `queue`, hence @unchecked Sendable.
public final class ScreenCaptureAudio: NSObject, AudioCaptureSource, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    private let queue = DispatchQueue(label: "listener.capture.screencapturekit", qos: .userInitiated)
    private var stream: SCStream?
    private var converter: PCMConverter?
    private var onChunk: (@Sendable (AudioChunk) -> Void)?

    override public init() {
        super.init()
    }

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo {
        if !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
            throw CaptureError.screenRecordingPermissionDenied
        }

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

        self.onChunk = onChunk
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Without a screen output SCK logs an error for every dropped video frame.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream

        return ChannelInfo(
            speaker: .them,
            backend: "ScreenCaptureKit",
            device: "all system audio",
            nativeFormat: "48 kHz, 2 ch, float32 planar (requested)"
        )
    }

    public func stop() {
        guard let stream else {
            return
        }
        self.stream = nil
        let finished = DispatchSemaphore(value: 0)
        stream.stopCapture { _ in finished.signal() }
        _ = finished.wait(timeout: .now() + 2)
    }

    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid, let onChunk else {
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
            onChunk(AudioChunk(speaker: .them, samples: samples, capturedAt: capturedAt))
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        FileHandle.standardError.write(Data("ScreenCaptureKit stream stopped: \(error)\n".utf8))
    }
}
