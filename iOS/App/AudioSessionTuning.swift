import AVFoundation
import Foundation

/// How capture is configured, requested against what iOS granted. Content-free; shown in Diagnostics.
struct CaptureConfiguration: Equatable, Sendable {
    /// "microphone" or, in self-test builds, "synthetic".
    var source: String
    var requestedIOBufferDuration: TimeInterval?
    var actualIOBufferDuration: TimeInterval
    var requestedSampleRate: Double?
    var actualSampleRate: Double
    /// The format the tap receives, which the dictation-time converter takes to 16 kHz mono.
    var inputSampleRate: Double
    var inputChannels: Int
    var tapBufferFrames: Int
}

/// Battery: an idle session should wake the app as rarely as possible. Latency does not matter,
/// because a dictation is buffered whole before it is transcribed.
enum AudioSessionTuning {
    /// Tried in order until one is accepted. iOS may still grant less; the actual value is read back.
    static let preferredIOBufferDurations: [TimeInterval] = [0.2, 0.1]
    static let preferredSampleRate: Double = DictationSampleBuffer.sampleRate
    /// The tap's requested buffer, within AVAudioEngine's supported 100–400 ms.
    static let tapBufferDuration: TimeInterval = 0.2

    struct Requested: Equatable, Sendable {
        var ioBufferDuration: TimeInterval?
        var sampleRate: Double?
    }

    /// Call after setting the category and before activating.
    static func requestPreferences(on session: AVAudioSession) -> Requested {
        let ioBuffer = preferredIOBufferDurations.first { (try? session.setPreferredIOBufferDuration($0)) != nil }
        let sampleRate = (try? session.setPreferredSampleRate(preferredSampleRate)) != nil ? preferredSampleRate : nil
        return Requested(ioBufferDuration: ioBuffer, sampleRate: sampleRate)
    }

    /// Call after activating a recording session and before building the engine: mono input where the
    /// route allows it. The tap still reads the actual format.
    static func preferMonoInput(on session: AVAudioSession) {
        guard session.isInputAvailable, session.inputNumberOfChannels != 1 else { return }
        try? session.setPreferredInputNumberOfChannels(1)
    }

    static func tapBufferFrames(sampleRate: Double) -> AVAudioFrameCount {
        AVAudioFrameCount((sampleRate * tapBufferDuration).rounded())
    }
}
