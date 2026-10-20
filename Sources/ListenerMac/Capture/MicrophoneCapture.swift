import AVFoundation
import CoreAudio
import ListenerCore
import Synchronization

/// The "Me" channel: the default input device through AVAudioEngine.
///
/// AVAudioEngine stops itself when the audio hardware changes channel count or sample
/// rate and posts AVAudioEngineConfigurationChange. Whenever that happens, or the default
/// input device changes, this class throws the engine away and starts a new one on the
/// current default device, with a converter for its format. The channel carries silence
/// in between, and while no microphone is present.
///
/// Mutable state is only touched on `controlQueue`, hence @unchecked Sendable.
public final class MicrophoneCapture: AudioCaptureSource, @unchecked Sendable {
    private let wantsVoiceProcessing: Bool
    private let onEvent: (@Sendable (CaptureEvent) -> Void)?
    private let controlQueue = DispatchQueue(label: "listener.capture.microphone", qos: .userInitiated)
    private let delivery = Mutex<ContinuousAudioFeed?>(nil)

    private var feed: ContinuousAudioFeed?
    private var engine: AVAudioEngine?
    private var configurationObserver: (any NSObjectProtocol)?
    private var inputListener: PropertyListener?
    private var pacer = RestartPacer()
    private var restartPending = false
    private var lastFailure: String?

    /// - Parameter voiceProcessing: turn on Apple's echo cancellation. Only useful when
    ///   the call plays through speakers instead of headphones. If it cannot run with the
    ///   current devices the mic runs without it and `onEvent` says so.
    public init(voiceProcessing: Bool, onEvent: (@Sendable (CaptureEvent) -> Void)? = nil) {
        wantsVoiceProcessing = voiceProcessing
        self.onEvent = onEvent
    }

    deinit {
        shutDown()
    }

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo {
        try await CapturePermissions.requireMicrophone()
        return try await withCheckedThrowingContinuation { continuation in
            controlQueue.async {
                continuation.resume(with: Result { try self.startCapture(onChunk: onChunk) })
            }
        }
    }

    /// Returns at once. The consumer gets no audio after this returns.
    public func stop() {
        delivery.withLock { $0 }?.stop()
        controlQueue.async { self.shutDown() }
    }

    private func startCapture(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws -> ChannelInfo {
        if feed != nil {
            throw CaptureError.alreadyRunning
        }
        let feed = ContinuousAudioFeed(speaker: .me, onChunk: onChunk)
        feed.start()
        let info: ChannelInfo
        do {
            info = try startEngine(feeding: feed)
        } catch {
            feed.stop()
            throw error
        }
        self.feed = feed
        delivery.withLock { $0 = feed }

        do {
            inputListener = try PropertyListener(
                object: systemAudioObject, selector: kAudioHardwarePropertyDefaultInputDevice
            ) { [weak self] in
                self?.requestRestart(.inputDeviceChanged)
            }
        } catch {
            CaptureSupport.logger.error(
                "Cannot follow input device changes: \(String(describing: error), privacy: .public)")
        }
        return info
    }

    private func shutDown() {
        feed?.stop()
        feed = nil
        delivery.withLock { $0 = nil }
        inputListener?.remove()
        inputListener = nil
        stopEngine()
    }

    // MARK: Engine, all on controlQueue

    /// Starts an engine on the current default input, with voice processing if asked for
    /// and possible.
    private func startEngine(feeding feed: ContinuousAudioFeed) throws -> ChannelInfo {
        if wantsVoiceProcessing {
            do {
                return try startEngine(feeding: feed, voiceProcessing: true)
            } catch CaptureError.noInputDevice {
                throw CaptureError.noInputDevice
            } catch {
                // Typically the input and output are different devices that voice
                // processing cannot pair up. A mic without echo cancellation beats none.
                CaptureSupport.report(.voiceProcessingUnavailable(error: String(describing: error)), to: onEvent)
            }
        }
        return try startEngine(feeding: feed, voiceProcessing: false)
    }

    private func startEngine(feeding feed: ContinuousAudioFeed, voiceProcessing: Bool) throws -> ChannelInfo {
        // With no input device at all, touching the input node can raise an
        // Objective-C exception rather than an error, so check first.
        guard let device = try CoreAudioObjects.defaultInputDevice() else {
            throw CaptureError.noInputDevice
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Voice processing ducks all other audio by default, which would turn the
            // call down. Minimum is the lowest setting macOS offers; there is no "off".
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min)
        }
        // Read after enabling voice processing, which changes the channel count.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        let converter = try PCMConverter(inputFormat: format, mixAllChannels: !voiceProcessing)
        // Ask for 100 ms buffers. macOS treats this as a hint, the spike measures what we really get.
        let bufferSize = AVAudioFrameCount(format.sampleRate / 10)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            let capturedAt = ContinuousClock.now
            guard let samples = try? converter.convert(buffer), !samples.isEmpty else {
                return
            }
            feed.accept(AudioChunk(speaker: .me, samples: samples, capturedAt: capturedAt))
        }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Only hand off: the engine must not be released inside this handler.
            self?.requestRestart(.audioConfigurationChanged)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            NotificationCenter.default.removeObserver(observer)
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
        self.engine = engine
        configurationObserver = observer

        return ChannelInfo(
            speaker: .me,
            backend: voiceProcessing ? "AVAudioEngine with voice processing" : "AVAudioEngine",
            device: CoreAudioObjects.name(device) ?? "default input",
            nativeFormat: AudioFormatText.describe(format)
        )
    }

    private func stopEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        guard let engine else {
            return
        }
        self.engine = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func requestRestart(_ reason: CaptureRestartReason) {
        controlQueue.async { self.scheduleRestart(reason) }
    }

    /// Returns the delay, or nil when stopped or when a restart is already scheduled.
    @discardableResult
    private func scheduleRestart(_ reason: CaptureRestartReason) -> Duration? {
        if feed == nil || restartPending {
            return nil
        }
        restartPending = true
        let delay = pacer.delay(at: .now)
        controlQueue.asyncAfter(deadline: .now() + CaptureSupport.dispatchInterval(delay)) {
            self.restartPending = false
            self.restart(reason)
        }
        return delay
    }

    private func restart(_ reason: CaptureRestartReason) {
        guard let feed else {
            return
        }
        // The engine stops itself before posting a configuration change. One that is
        // still running was not affected, for example by a change it caused itself.
        if reason == .audioConfigurationChanged, engine?.isRunning == true {
            return
        }
        stopEngine()
        feed.realign()
        pacer.restarted(at: .now)
        do {
            let info = try startEngine(feeding: feed)
            lastFailure = nil
            CaptureSupport.report(.restarted(.me, reason: reason), to: onEvent)
            CaptureSupport.logger.notice(
                "Me now on \(info.device, privacy: .public), \(info.nativeFormat, privacy: .public)")
        } catch {
            // Retries repeat the same failure every few seconds, for example while no
            // microphone is plugged in; say it once.
            let message = String(describing: error)
            let isNewFailure = message != lastFailure
            lastFailure = message
            if let retryIn = scheduleRestart(reason), isNewFailure {
                CaptureSupport.report(
                    .restartFailed(.me, reason: reason, error: message, retryIn: retryIn),
                    to: onEvent)
            }
        }
    }
}
