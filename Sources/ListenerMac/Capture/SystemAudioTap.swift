import AVFoundation
import CoreAudio
import ListenerCore
import Synchronization

/// The "Them" channel: a Core Audio process tap on everything the Mac plays except this
/// app, read through a private aggregate device, because a tap cannot be read directly,
/// only as an input of a device.
///
/// Taps fail quietly, so this class keeps the channel alive itself:
/// - It rebuilds when the default output device or its sample rate changes: a headset
///   plugged in, or a Bluetooth headset switching to its call profile. It also rebuilds
///   when the Mac wakes from sleep.
/// - It reads the audio at the rate the device clock runs at, not the one the tap's
///   format reports, and keeps checking the rate it arrives at, as AirPods switch to a
///   lower rate when a call app opens their mic (see DeliveredRateMonitor).
/// - It rebuilds after SilenceWatchdog's timeout of exact digital zeros while another
///   app is playing audio. A tap without the System Audio Recording permission, and some
///   taps on macOS 26 after a while, keep running but deliver only zeros. When a rebuild
///   does not bring the audio back, the next one waits twice as long.
///
/// Rebuilds run on a private serial queue and teardown on another, because stopping or
/// destroying a device can block inside a broken audio path. While the tap is rebuilt
/// the channel carries silence, so the consumer sees one stream with continuous timing.
///
/// Mutable state is only touched on `controlQueue` (and in deinit), hence @unchecked Sendable.
public final class SystemAudioTap: AudioCaptureSource, @unchecked Sendable {
    private let onEvent: (@Sendable (CaptureEvent) -> Void)?
    private let controlQueue = DispatchQueue(label: "listener.capture.tap.control", qos: .userInitiated)
    // Core Audio runs the IO block on this queue synchronously from its audio thread, so
    // nothing else may run here: stopping the device from this queue would deadlock.
    private let ioQueue = DispatchQueue(label: "listener.capture.tap.io", qos: .userInitiated)
    private let teardownQueue = DispatchQueue(label: "listener.capture.tap.teardown", qos: .utility)
    private let watchdog = Mutex(SilenceWatchdog())
    private let delivery = Mutex<ContinuousAudioFeed?>(nil)

    private var feed: ContinuousAudioFeed?
    private var pipeline: TapPipeline?
    private var outputListener: PropertyListener?
    private var sleepListener: SleepWakeListener?
    private var pacer = RestartPacer()
    private var restartPending = false
    private var lastFailure: String?

    public init(onEvent: (@Sendable (CaptureEvent) -> Void)? = nil) {
        self.onEvent = onEvent
    }

    deinit {
        shutDown()
    }

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo {
        try await withCheckedThrowingContinuation { continuation in
            controlQueue.async {
                continuation.resume(with: Result { try self.startCapture(onChunk: onChunk) })
            }
        }
    }

    /// Returns at once. The consumer gets no audio after this returns; the hardware is
    /// released in the background.
    public func stop() {
        delivery.withLock { $0 }?.stop()
        controlQueue.async { self.shutDown() }
    }

    private func startCapture(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws -> ChannelInfo {
        if feed != nil {
            throw CaptureError.alreadyRunning
        }
        let deliverAndWatch: @Sendable (AudioChunk) -> Void = { [weak self] chunk in
            onChunk(chunk)
            self?.watch(chunk)
        }
        let feed = ContinuousAudioFeed(
            speaker: .them, threshold: CaptureSupport.deviceGapThreshold, onChunk: deliverAndWatch)
        feed.start()
        let info: ChannelInfo
        do {
            (pipeline, info) = try buildPipeline(feeding: feed)
        } catch {
            feed.stop()
            throw error
        }
        self.feed = feed
        delivery.withLock { $0 = feed }

        do {
            outputListener = try PropertyListener(
                object: systemAudioObject, selector: kAudioHardwarePropertyDefaultOutputDevice
            ) { [weak self] in
                self?.requestRestart(.outputDeviceChanged)
            }
        } catch {
            Log.capture.error(
                "Cannot follow output device changes: \(String(describing: error), privacy: .public)")
        }
        sleepListener = SleepWakeListener(speaker: .them) { [weak self] in
            self?.requestRestart(.wokeFromSleep)
        }
        return info
    }

    private func shutDown() {
        feed?.stop()
        feed = nil
        delivery.withLock { $0 = nil }
        outputListener?.remove()
        outputListener = nil
        sleepListener?.remove()
        sleepListener = nil
        retire(pipeline)
        pipeline = nil
    }

    private func buildPipeline(feeding feed: ContinuousAudioFeed) throws -> (TapPipeline, ChannelInfo) {
        let pipeline = TapPipeline()
        do {
            let info = try pipeline.start(
                feeding: feed, ioQueue: ioQueue,
                onRouteChange: { [weak self] in self?.requestRestart(.sampleRateChanged) },
                onRateChecked: { [weak self] outcome in
                    guard let self else {
                        return
                    }
                    controlQueue.async { self.rateChecked(outcome) }
                })
            return (pipeline, info)
        } catch {
            retire(pipeline)
            throw error
        }
    }

    private func retire(_ pipeline: TapPipeline?) {
        guard let pipeline else {
            return
        }
        pipeline.close()
        teardownQueue.async { pipeline.destroy() }
    }

    // MARK: Recovery, all on controlQueue

    private func watch(_ chunk: AudioChunk) {
        if watchdog.withLock({ $0.observe(chunk) }) {
            controlQueue.async { self.silenceIsDue() }
        }
    }

    private func silenceIsDue() {
        // Nothing to rebuild while stopped or while a retry is already scheduled, and
        // zeros are expected when no other app is playing anything. This process is left
        // out because voice processing on the mic runs output of its own.
        let ownProcess = try? CoreAudioObjects.processObject(pid: getpid())
        guard pipeline != nil, CoreAudioObjects.isAnotherProcessPlaying(excluding: ownProcess) else {
            watchdog.withLock { $0.silenceExplained() }
            return
        }
        let seconds = watchdog.withLock { $0.silence.components.seconds }
        rebuild(.digitalSilence(seconds: Int(seconds)))
        watchdog.withLock { $0.rebuilt() }
    }

    private func rateChecked(_ outcome: DeliveredRateMonitor.Outcome) {
        guard feed != nil else {
            return
        }
        switch outcome {
        case .matches(let measured):
            Log.capture.info("Them audio arrives at \(Int(measured), privacy: .public) Hz, the rate it is read at")
        case .corrected(let from, let to, _):
            CaptureSupport.report(.rateCorrected(.them, from: from, to: to), to: onEvent)
        case .unexplained(let measured):
            Log.capture.notice(
                "Them audio arrives at \(Int(measured), privacy: .public) Hz, no standard rate, so the rate stands")
        }
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
            self.restartIfNeeded(reason)
        }
        return delay
    }

    private func restartIfNeeded(_ reason: CaptureRestartReason) {
        guard feed != nil else {
            return
        }
        // Sleep can leave the tap broken on a route that looks the same, so a wake always rebuilds.
        guard let pipeline, reason != .wokeFromSleep else {
            rebuild(reason)
            return
        }
        // Notifications also arrive for changes that do not matter, and for our own
        // rebuilds, so only a real difference triggers one.
        if let change = pipeline.route.restartReason(movingTo: currentRoute(capturingFrom: pipeline)) {
            rebuild(change)
        }
    }

    private func rebuild(_ reason: CaptureRestartReason) {
        guard let feed else {
            return
        }
        retire(pipeline)
        pipeline = nil
        feed.realign()
        pacer.restarted(at: .now)
        do {
            let info: ChannelInfo
            (pipeline, info) = try buildPipeline(feeding: feed)
            lastFailure = nil
            CaptureSupport.report(.restarted(.them, reason: reason), to: onEvent)
            Log.capture.notice(
                "Them now \(info.device, privacy: .private), \(info.nativeFormat, privacy: .public)")
        } catch {
            // Retries repeat the same failure every few seconds; say it once.
            let message = String(describing: error)
            let isNewFailure = message != lastFailure
            lastFailure = message
            if let retryIn = scheduleRestart(reason), isNewFailure {
                CaptureSupport.report(
                    .restartFailed(.them, reason: reason, error: message, retryIn: retryIn),
                    to: onEvent)
            }
        }
    }

    private func currentRoute(capturingFrom pipeline: TapPipeline) -> AudioRoute {
        let output = try? CoreAudioObjects.defaultOutputDevice()
        return AudioRoute(
            outputDeviceUID: output.flatMap { try? CoreAudioObjects.deviceUID($0) },
            outputSampleRate: output.flatMap { try? CoreAudioObjects.nominalSampleRate($0) },
            captureSampleRate: try? CoreAudioObjects.nominalSampleRate(pipeline.aggregateID)
        )
    }
}

/// One tap with its aggregate device and IO proc. Built on the control queue, then
/// handed to the teardown queue when retired; a rebuild always makes a new one.
private final class TapPipeline: @unchecked Sendable {
    private(set) var aggregateID = unknownAudioObject
    private(set) var route = AudioRoute(outputDeviceUID: nil, outputSampleRate: nil, captureSampleRate: nil)
    private var tapID = unknownAudioObject
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false
    private var input: TapInput?
    private var listeners: [PropertyListener] = []

    func start(
        feeding feed: ContinuousAudioFeed, ioQueue: DispatchQueue, onRouteChange: @escaping @Sendable () -> Void,
        onRateChecked: @escaping @Sendable (DeliveredRateMonitor.Outcome) -> Void
    ) throws -> ChannelInfo {
        // Looked up on every build: the process only gets an audio object once it has
        // touched audio, for example after the mic started.
        let ownProcess = try? CoreAudioObjects.processObject(pid: getpid())
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        tapDescription.uuid = UUID()
        tapDescription.name = "Listener system audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        try CoreAudioObjects.check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "Create process tap")

        guard let outputDevice = try CoreAudioObjects.defaultOutputDevice() else {
            throw CaptureError.noOutputDevice
        }
        let outputUID = try CoreAudioObjects.deviceUID(outputDevice)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Listener system audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ]
            ],
        ]
        try CoreAudioObjects.check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
            "Create aggregate device"
        )

        // The tap is the aggregate's last input stream, and that stream's virtual format is
        // by definition what the IO proc receives. Right after creation the stream list can
        // lag behind; the tap's own format, documented as what aggregates expose, stands in.
        let tapFormat = try CoreAudioObjects.tapFormat(tapID)
        let delivered = try? CoreAudioObjects.lastInputStreamFormat(aggregateID)
        var streamDescription = tapFormat
        if let delivered, delivered.mChannelsPerFrame == tapFormat.mChannelsPerFrame, delivered.mSampleRate > 0 {
            streamDescription = delivered
        }
        // With AirPods in call mode both of those still say 48 kHz, while the aggregate,
        // clocked by the AirPods, runs at 24 kHz: the rate the audio really arrives at.
        let clockRate = try? CoreAudioObjects.nominalSampleRate(aggregateID)
        if let clockRate, clockRate > 0 {
            streamDescription.mSampleRate = clockRate
        }
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CaptureError.unsupportedFormat("tap format with \(streamDescription.mChannelsPerFrame) channels")
        }
        let input = try TapInput(format: format, feed: feed, onRateChecked: onRateChecked)
        self.input = input

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            _, inputData, inputTime, _, _ in
            input.process(inputData, at: inputTime)
        }
        try CoreAudioObjects.check(status, "Create IO proc")
        try CoreAudioObjects.check(AudioDeviceStart(aggregateID, ioProcID), "Start aggregate device")
        isStarted = true

        route = AudioRoute(
            outputDeviceUID: outputUID,
            outputSampleRate: try? CoreAudioObjects.nominalSampleRate(outputDevice),
            captureSampleRate: try? CoreAudioObjects.nominalSampleRate(aggregateID)
        )
        // Core Audio has reported a rate the audio did not arrive at, so every source of
        // it goes in the log for comparison with what the rate check measures.
        let formats = [
            "tap \(AudioFormatText.describe(tapFormat))",
            "aggregate input \(delivered.map(AudioFormatText.describe) ?? "unreadable")",
            "aggregate \(clockRate.map { "\(Int($0)) Hz" } ?? "unreadable")",
            "output \(route.outputSampleRate.map { "\(Int($0)) Hz" } ?? "unreadable")",
            "reading \(AudioFormatText.describe(format))",
        ]
        Log.capture.notice("Them formats: \(formats.joined(separator: ", "), privacy: .public)")
        for device in [outputDevice, aggregateID] {
            do {
                listeners.append(
                    try PropertyListener(
                        object: device, selector: kAudioDevicePropertyNominalSampleRate, handler: onRouteChange))
            } catch {
                Log.capture.error(
                    "Cannot follow sample rate changes: \(String(describing: error), privacy: .public)")
            }
        }
        let outputName = CoreAudioObjects.name(outputDevice) ?? "default output"
        return ChannelInfo(
            speaker: .them,
            backend: "Core Audio process tap",
            device: "all system audio, clocked by \(outputName)",
            nativeFormat: AudioFormatText.describe(format)
        )
    }

    /// Stops delivering audio at once; the hardware goes in `destroy()`.
    func close() {
        input?.close()
    }

    /// Releases everything in the order Core Audio needs. Can block on a broken device,
    /// so it only ever runs on the teardown queue.
    func destroy() {
        for listener in listeners {
            listener.remove()
        }
        if aggregateID != unknownAudioObject {
            if let ioProcID {
                if isStarted {
                    logFailure(AudioDeviceStop(aggregateID, ioProcID), "Stop aggregate device")
                }
                logFailure(AudioDeviceDestroyIOProcID(aggregateID, ioProcID), "Destroy IO proc")
            }
            logFailure(AudioHardwareDestroyAggregateDevice(aggregateID), "Destroy aggregate device")
        }
        if tapID != unknownAudioObject {
            logFailure(AudioHardwareDestroyProcessTap(tapID), "Destroy process tap")
        }
    }

    private func logFailure(_ status: OSStatus, _ operation: String) {
        if status != noErr {
            Log.capture.error(
                "\(operation, privacy: .public) failed with OSStatus \(status, privacy: .public)")
        }
    }
}

/// What the IO block runs every cycle: picks out the tap's buffers, converts them and
/// hands them to the feed. It also watches the rate the audio arrives at, and reads it at
/// that rate whenever it differs from the one in use. Only used on the IO queue, apart
/// from the atomic `close()`.
private final class TapInput: @unchecked Sendable {
    private var buffers: TapBufferSelector
    private var converter: PCMConverter
    private var rateMonitor: DeliveredRateMonitor
    private let feed: ContinuousAudioFeed
    private let onRateChecked: @Sendable (DeliveredRateMonitor.Outcome) -> Void
    private let origin = ContinuousClock.now
    private let isOpen = Atomic<Bool>(true)

    init(
        format: AVAudioFormat, feed: ContinuousAudioFeed,
        onRateChecked: @escaping @Sendable (DeliveredRateMonitor.Outcome) -> Void
    ) throws {
        buffers = TapBufferSelector(format: format)
        converter = try PCMConverter(inputFormat: format)
        rateMonitor = DeliveredRateMonitor(rate: format.sampleRate)
        self.feed = feed
        self.onRateChecked = onRateChecked
    }

    func process(_ inputData: UnsafePointer<AudioBufferList>, at inputTime: UnsafePointer<AudioTimeStamp>) {
        guard isOpen.load(ordering: .acquiring) else {
            return
        }
        let capturedAt = ContinuousClock.now
        guard var buffer = buffers.buffer(from: inputData) else {
            return
        }
        let time = seconds(of: inputTime.pointee, arrivedAt: capturedAt)
        if let outcome = rateMonitor.record(frames: Int(buffer.frameLength), at: time) {
            if case .corrected(_, let rate, _) = outcome, read(at: rate), let reread = buffers.buffer(from: inputData) {
                buffer = reread
            }
            onRateChecked(outcome)
        }
        guard let samples = try? converter.convert(buffer), !samples.isEmpty else {
            return
        }
        feed.accept(AudioChunk(speaker: .them, samples: samples, capturedAt: capturedAt))
    }

    /// Reads the audio at `rate` from now on, with the format otherwise unchanged. The
    /// stream has fallen behind the wall clock until now, so the feed catches it up.
    private func read(at rate: Double) -> Bool {
        var description = converter.inputFormat.streamDescription.pointee
        description.mSampleRate = rate
        guard let format = AVAudioFormat(streamDescription: &description),
            let converter = try? PCMConverter(inputFormat: format)
        else {
            return false
        }
        buffers = TapBufferSelector(format: format)
        self.converter = converter
        feed.realign()
        return true
    }

    /// The host time of the buffer's first frame when Core Audio gives one, otherwise
    /// when the buffer reached us.
    private func seconds(of time: AudioTimeStamp, arrivedAt arrival: ContinuousClock.Instant) -> Double {
        if time.mFlags.contains(.hostTimeValid) {
            return Double(AudioConvertHostTimeToNanos(time.mHostTime)) / 1_000_000_000
        }
        return (arrival - origin).inSeconds
    }

    func close() {
        isOpen.store(false, ordering: .releasing)
    }
}

/// Picks the tap's audio out of the aggregate device's input.
///
/// The aggregate also contains the output device, and if that device has inputs of
/// its own (a headset mic, say) their buffers come first in the list, followed by the
/// tap's. Reading the whole list as tap audio would put your own voice on the "Them"
/// channel, so we take only the trailing buffers that belong to the tap.
///
/// Only used from the tap's IO queue, hence @unchecked Sendable.
private final class TapBufferSelector: @unchecked Sendable {
    private let format: AVAudioFormat
    private let tapBufferCount: Int
    private let channelsPerBuffer: UInt32
    private let list: UnsafeMutableAudioBufferListPointer

    init(format: AVAudioFormat) {
        self.format = format
        tapBufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        channelsPerBuffer = format.isInterleaved ? format.channelCount : 1
        list = AudioBufferList.allocate(maximumBuffers: tapBufferCount)
    }

    deinit {
        free(list.unsafeMutablePointer)
    }

    func buffer(from inputData: UnsafePointer<AudioBufferList>) -> AVAudioPCMBuffer? {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        if input.count < tapBufferCount {
            return nil
        }
        let firstTapBuffer = input.count - tapBufferCount
        for index in 0..<tapBufferCount {
            // A buffer of another shape means the format was misread and this may be a
            // headset mic's buffer. Silence beats your voice on "Them"; the silence
            // watchdog then rebuilds and reads the format again.
            if input[firstTapBuffer + index].mNumberChannels != channelsPerBuffer {
                return nil
            }
            list[index] = input[firstTapBuffer + index]
        }
        return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer, deallocator: nil)
    }
}
