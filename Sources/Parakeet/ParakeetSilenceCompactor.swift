import Foundation

/// Shortens silence in 16 kHz mono audio before chunking, so pauses cost no
/// encoder time and a recording fits a smaller encoder function. Leading
/// silence keeps its last `margin` and trailing silence its first. A pause
/// between speech longer than `interiorPause` is cut to exactly that: its
/// first half after speech and its last half before the next. Speech and
/// shorter pauses, which cue phrasing and punctuation, pass through unchanged:
/// the output is the input's own runs in order, spliced without resampling,
/// gain or fades. A stream with no speech is emitted unchanged by `finish`, so
/// audio is held until speech starts; after that at most `interiorPause` is
/// held. The output depends only on the samples, not on how they are split
/// across calls.
struct ParakeetSilenceCompactor {
    static let defaultMargin = 4800  // 0.3 s
    // A pause between speech, such as searching for a word, keeps up to 0.8 s;
    // chosen on synthetic hesitations (see the pull request).
    static let defaultInteriorPause = 12_800  // 0.8 s
    /// Output is emitted in pieces of at most 1 s, so appending a whole
    /// recording at once never builds a second full-size copy.
    static let maxPieceSamples = 16_000
    /// 10 ms, the front end's hop. Speech is decided per frame.
    static let frameSamples = 160
    // Levels are a frame's mean square in dB relative to full scale. The noise
    // floor follows the quietest recent frames: it drops at once and, outside
    // speech, rises 3 dB/s, so steady noise is learned within seconds while
    // speech, however long, is not. It stays within -70...-40 dB, so speech
    // never starts below -60 dB, and frames above -30 dB are always speech.
    private static let floorRange = -70.0 ... -40.0
    private static let floorRise = 0.03
    // A frame starts speech 10 dB over the floor and continues it 6 dB over.
    private static let onset = 10.0, release = 6.0

    let margin: Int
    let interiorPause: Int
    private var floor = floorRange.upperBound
    private var speaking = false
    private var heardSpeech = false
    private var frame: [Float] = []
    // Before speech, everything so far; in a later pause, its first and last
    // half of `interiorPause`.
    private var held: [Float] = []

    init(margin: Int = defaultMargin, interiorPause: Int = defaultInteriorPause) {
        // Trailing silence keeps its first margin from the pause's first half.
        precondition(margin >= 0 && interiorPause >= 2 * margin, "A kept pause must hold both edge margins")
        self.margin = margin
        self.interiorPause = interiorPause
    }

    mutating func append(_ samples: [Float], emit: ([Float]) throws -> Void) rethrows {
        var output: [Float] = [], rest = samples[...]
        if !frame.isEmpty {
            let take = min(Self.frameSamples - frame.count, rest.count)
            frame += rest.prefix(take)
            rest = rest.dropFirst(take)
            if frame.count == Self.frameSamples {
                process(frame[...], into: &output)
                frame = []
            }
        }
        while rest.count >= Self.frameSamples {
            process(rest.prefix(Self.frameSamples), into: &output)
            rest = rest.dropFirst(Self.frameSamples)
            try Self.flush(&output, whole: false, emit: emit)
        }
        frame += rest
        try Self.flush(&output, whole: true, emit: emit)
    }

    mutating func finish(emit: ([Float]) throws -> Void) rethrows {
        var output: [Float] = []
        if !frame.isEmpty { process(frame[...], into: &output) }
        // Trailing silence keeps its first margin. With no speech at all, the
        // model hears the recording unchanged; output is empty then, so the
        // held recording moves rather than copies.
        if heardSpeech { output += held.prefix(margin) } else { swap(&output, &held) }
        self = Self(margin: margin, interiorPause: interiorPause)
        try Self.flush(&output, whole: true, emit: emit)
    }

    /// Emits full pieces of `output`, and with `whole` the rest too, keeping order.
    private static func flush(_ output: inout [Float], whole: Bool, emit: ([Float]) throws -> Void) rethrows {
        var start = 0
        while output.count - start >= maxPieceSamples || (whole && start < output.count) {
            let end = min(start + maxPieceSamples, output.count)
            try emit(Array(output[start..<end]))
            start = end
        }
        output.removeFirst(start)
    }

    private mutating func process(_ samples: ArraySlice<Float>, into output: inout [Float]) {
        if isSpeech(samples) {
            output += heardSpeech ? held[...] : held.suffix(margin)
            output += samples
            heardSpeech = true
            held = []
        } else {
            held += samples
            // After speech, a pause keeps only what speech resuming or the
            // stream ending could need: the first and last half of the kept pause.
            let head = interiorPause / 2, tail = interiorPause - head
            if heardSpeech, held.count > interiorPause { held.removeSubrange(head..<(held.count - tail)) }
        }
    }

    private mutating func isSpeech(_ samples: ArraySlice<Float>) -> Bool {
        var energy = 0.0
        for sample in samples { energy += Double(sample) * Double(sample) }
        // Invalid samples are kept, so the model rejects them.
        guard energy.isFinite else { speaking = true; return true }
        // Digital silence is silence and says nothing about the room's noise.
        guard energy > 0 else { speaking = false; return false }
        let level = 10 * log10(energy / Double(samples.count))
        speaking = level > floor + (speaking ? Self.release : Self.onset)
        let next = level < floor ? level : speaking ? floor : floor + Self.floorRise
        floor = min(max(next, Self.floorRange.lowerBound), Self.floorRange.upperBound)
        return speaking
    }
}
