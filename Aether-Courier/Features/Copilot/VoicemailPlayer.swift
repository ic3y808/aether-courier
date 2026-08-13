import AppKit

/// Plays a voicemail audio attachment (e.g. the .mp3 Google Voice attaches).
/// Thin NSObject wrapper around NSSound so `CourierStore` (a plain @Observable
/// class, not an NSObject) can still receive the finish callback and flip its
/// `isPlayingVoicemail` flag back off.
final class VoicemailPlayer: NSObject, NSSoundDelegate {
    private var sound: NSSound?
    /// Called on the main thread when playback ends (naturally or via `stop()`).
    var onFinish: (() -> Void)?

    var isPlaying: Bool { sound?.isPlaying ?? false }

    /// Starts playing `data`; returns false if the bytes couldn't be decoded.
    @discardableResult
    func play(_ data: Data) -> Bool {
        stop()
        guard let s = NSSound(data: data) else { return false }
        s.delegate = self
        sound = s
        return s.play()
    }

    func stop() {
        sound?.stop()
        sound = nil
    }

    func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
        self.sound = nil
        onFinish?()
    }
}
