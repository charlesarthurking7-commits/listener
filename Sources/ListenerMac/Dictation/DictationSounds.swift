import AVFoundation

/// The soft sounds when dictation starts and stops, played off the main thread. Starting
/// speakers that have gone idle, such as a Studio Display's, holds up the thread that
/// plays for nearly half a second, and the capsule and the microphone must not wait.
///
/// The players are only touched on `queue`, hence @unchecked Sendable.
final class DictationSounds: @unchecked Sendable {
    enum Sound: String {
        case start = "Tink"
        case stop = "Pop"
    }

    private static let volume: Float = 0.25

    private let queue = DispatchQueue(label: "listener.dictation.sounds", qos: .userInitiated)
    private var players: [Sound: AVAudioPlayer] = [:]

    func play(_ sound: Sound) {
        queue.async {
            guard let player = self.player(for: sound) else {
                return
            }
            player.currentTime = 0
            player.play()
        }
    }

    private func player(for sound: Sound) -> AVAudioPlayer? {
        if let player = players[sound] {
            return player
        }
        let file = URL(fileURLWithPath: "/System/Library/Sounds/\(sound.rawValue).aiff")
        guard let player = try? AVAudioPlayer(contentsOf: file) else {
            Log.dictation.error("Could not load the \(sound.rawValue, privacy: .public) sound")
            return nil
        }
        player.volume = Self.volume
        players[sound] = player
        return player
    }
}
