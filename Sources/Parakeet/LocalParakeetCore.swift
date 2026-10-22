import CryptoKit
import Foundation

enum LocalParakeetError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }

    /// Core ML exceptions may carry input details; expose only our
    /// content-free errors or cancellation.
    static func contentFree(_ error: Error) -> Error {
        if error is CancellationError || error is LocalParakeetError { return error }
        return LocalParakeetError.invalid("Local transcription failed while loading the model or processing audio.")
    }
}

enum LocalParakeetCore {
    static let modelID = "localflow"
    static let sampleRate = 16_000
    /// The one encoder function LocalFlow runs (`b15`). Bundles also hold 4, 8
    /// and 30 s functions; they are never loaded, because the Neural Engine
    /// holds memory for every loaded function.
    static let encoderSeconds = 15
    /// Recordings are split into windows of at most this many samples, each
    /// one pass of the 15 s function.
    static let chunkSamples = encoderSeconds * sampleRate
    // 10 ms features, subsampled 8x by the encoder.
    static let samplesPerEncoderFrame = 1280
    // Consecutive chunks share this much audio, so the seam between them can
    // be placed where both chunks heard the speech with context on each side.
    static let chunkOverlapSamples = 2 * sampleRate

    static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    // Bounded reads keep a 330 MB encoder out of memory while verifying it.
    static func sha256(fileURL: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        // Drain each chunk's autoreleased buffer before reading the next.
        while try autoreleasepool(invoking: {
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The encoder function, in seconds, that runs a chunk of `samples`:
    /// always the 15 s one, with shorter chunks zero-padded.
    static func bucket(samples: Int) throws -> Int {
        guard samples > 0, samples <= chunkSamples else {
            throw LocalParakeetError.invalid("Local transcription chunk must contain 1–240000 samples.")
        }
        return encoderSeconds
    }

    /// Whitespace-separated words, each starting at the recording sample where
    /// its first token was emitted. `offset` is the chunk's first sample.
    static func words(_ tokens: [ParakeetToken], vocabulary: [String], offset: Int) throws -> [ParakeetWord] {
        guard tokens.allSatisfy({ vocabulary.indices.contains($0.id) }) else {
            throw LocalParakeetError.invalid("Local model returned an invalid token.")
        }
        var words: [ParakeetWord] = [], text = "", start = 0
        for token in tokens {
            for character in vocabulary[token.id].replacingOccurrences(of: "▁", with: " ") {
                if character.isWhitespace {
                    if !text.isEmpty { words.append(ParakeetWord(text: text, start: start)) }
                    text = ""
                } else {
                    if text.isEmpty { start = offset + token.frame * samplesPerEncoderFrame }
                    text.append(character)
                }
            }
        }
        if !text.isEmpty { words.append(ParakeetWord(text: text, start: start)) }
        return words
    }

    /// NeMo TDT semantics, including terminal emissions and the per-frame symbol cap.
    static func decode(length: Int, predict: (Int) throws -> Void,
                       joint: (Int) throws -> (Int, Int), check: () throws -> Void) throws -> [ParakeetToken] {
        let blank = 1024
        var tokens: [ParakeetToken] = [], frame = 0, lastFrame = -1, symbols = 0
        try predict(blank)
        while frame < length {
            try check()
            let (token, duration) = try joint(frame)
            guard (0...blank).contains(token), (0...4).contains(duration) else {
                throw LocalParakeetError.invalid("Invalid local model decision.")
            }
            var advance = token == blank && duration == 0 ? 1 : duration
            if token != blank {
                symbols = lastFrame == frame ? symbols + 1 : 1
                lastFrame = frame
                tokens.append(ParakeetToken(id: token, frame: frame))
                try predict(token)
                if advance == 0 && symbols >= 10 { advance = 1 }
            }
            frame += advance
        }
        return tokens
    }
}

struct ParakeetToken: Equatable {
    let id: Int
    let frame: Int
}

struct ParakeetWord: Equatable {
    let text: String
    /// Sample of the model input (the recording with silence compacted)
    /// where the word's first token was emitted.
    let start: Int
}

/// A window of the recording, starting at sample `start`.
struct ParakeetChunk: Equatable {
    let samples: [Float]
    let start: Int
    var range: Range<Int> { start..<(start + samples.count) }
}

/// Windows of exactly `size` samples that start `size - overlap` apart. Only
/// the final one may be shorter, and it is emitted only when it holds audio no
/// earlier window covered. Streamed files and in-memory recordings share it,
/// so both split the same audio at the same boundaries.
struct ParakeetChunker {
    let size: Int
    let overlap: Int
    private var pending: [Float] = []
    private var carried = 0
    private var start = 0

    init(size: Int, overlap: Int) {
        precondition(size > 0, "Chunk size must be positive")
        // Each overlap then ends before the next begins, so a seam only ever
        // involves two chunks.
        precondition(overlap >= 0 && 2 * overlap <= size, "Chunk overlap must be at most half the chunk size")
        self.size = size
        self.overlap = overlap
    }

    mutating func append(_ samples: [Float], emit: (ParakeetChunk) throws -> Void) rethrows {
        var rest = samples[...]
        while pending.count + rest.count >= size {
            let take = size - pending.count
            let chunk = ParakeetChunk(samples: pending + rest.prefix(take), start: start)
            pending = Array(chunk.samples.suffix(overlap))
            carried = pending.count
            start += size - overlap
            rest = rest.dropFirst(take)
            try emit(chunk)
        }
        pending.append(contentsOf: rest)
    }

    mutating func finish(emit: (ParakeetChunk) throws -> Void) rethrows {
        let chunk = ParakeetChunk(samples: pending, start: start)
        let fresh = pending.count > carried
        pending = []
        carried = 0
        if fresh { try emit(chunk) }
    }
}

/// One recording split into chunks, each transcribed as soon as it is complete,
/// and joined. Batch and streaming transcription both run it, so however the
/// samples arrive they give the same chunks, seams and text. With a compactor,
/// silence is shortened before chunking, so chunk ranges are positions in the
/// compacted audio.
struct ParakeetChunkedTranscription {
    private var compactor: ParakeetSilenceCompactor?
    private var chunker: ParakeetChunker
    private var transcript = ParakeetTranscriptAssembler()

    init(size: Int, overlap: Int, compactor: ParakeetSilenceCompactor? = nil) {
        self.compactor = compactor
        chunker = ParakeetChunker(size: size, overlap: overlap)
    }

    /// How every dictation is split, whatever its length: silence compacted,
    /// then 15 s windows that overlap by 2 s.
    static func recording() -> ParakeetChunkedTranscription {
        ParakeetChunkedTranscription(size: LocalParakeetCore.chunkSamples, overlap: LocalParakeetCore.chunkOverlapSamples,
                                     compactor: ParakeetSilenceCompactor())
    }

    mutating func append(_ samples: [Float], transcribe: (ParakeetChunk) throws -> [ParakeetWord]) rethrows {
        try Self.append(samples, &compactor, &chunker, &transcript, transcribe)
    }

    /// Transcribes the remaining partial chunk, if it holds new audio, and returns the text.
    mutating func finish(transcribe: (ParakeetChunk) throws -> [ParakeetWord]) rethrows -> String {
        try Self.finish(&compactor, &chunker, &transcript, transcribe)
        return transcript.text
    }

    // Separate inout properties: a closure capturing self would overlap the chunker's access.
    private static func append(_ samples: [Float], _ compactor: inout ParakeetSilenceCompactor?, _ chunker: inout ParakeetChunker,
                               _ transcript: inout ParakeetTranscriptAssembler,
                               _ transcribe: (ParakeetChunk) throws -> [ParakeetWord]) rethrows {
        guard compactor != nil else { return try chunk(samples, &chunker, &transcript, transcribe) }
        try compactor!.append(samples) { try chunk($0, &chunker, &transcript, transcribe) }
    }

    private static func finish(_ compactor: inout ParakeetSilenceCompactor?, _ chunker: inout ParakeetChunker,
                               _ transcript: inout ParakeetTranscriptAssembler,
                               _ transcribe: (ParakeetChunk) throws -> [ParakeetWord]) rethrows {
        if compactor != nil { try compactor!.finish { try chunk($0, &chunker, &transcript, transcribe) } }
        try chunker.finish { transcript.append(try transcribe($0), covering: $0.range) }
    }

    private static func chunk(_ samples: [Float], _ chunker: inout ParakeetChunker, _ transcript: inout ParakeetTranscriptAssembler,
                              _ transcribe: (ParakeetChunk) throws -> [ParakeetWord]) rethrows {
        try chunker.append(samples) { transcript.append(try transcribe($0), covering: $0.range) }
    }
}

/// A transcription fed while the user is still speaking. `append` only hands
/// samples over (it never waits for model work); on `queue` each completed
/// chunk is transcribed at once, in order, so `finish` is left with the final
/// partial chunk. The stage is built on `queue` when the session begins, which
/// fixes readiness for the recording as a batch call fixes it for its own.
/// Audio stays in memory. The session holds the audio `queue` has not yet
/// processed (normally a moment's worth; all of it if `queue` is blocked), the
/// chunker's pending window, and whatever the stage retains.
final class ParakeetStreamingTranscription<Output: Sendable>: @unchecked Sendable {
    struct Stage {
        var transcription: ParakeetChunkedTranscription
        /// One chunk's words. `check` throws `CancellationError` once cancelled.
        let transcribe: (ParakeetChunk, _ check: () throws -> Void) throws -> [ParakeetWord]
        /// The joined text to the result, after the last chunk.
        let complete: (String, _ check: () throws -> Void) throws -> Output
        /// Undoes what `complete` published when a cancel landed during it.
        var abandon: (Output) -> Void = { _ in }
    }

    private let queue: DispatchQueue
    private let onEnd: (@Sendable () -> Void)?
    // Shared with the capture thread; every access holds lock.
    private let lock = NSLock()
    private var inbox: [Float] = []
    private var drainScheduled = false
    private var cancelled = false
    private var finishing = false
    // Queue only.
    private var transcription: ParakeetChunkedTranscription?
    private var stage: Stage?
    private var failure: Error?
    private var ended = false

    /// `onEnd` runs once, on `queue`, when the session's model work has drained
    /// after `finish` or `cancel`, so its owner can tell when nothing uses the model.
    init(queue: DispatchQueue, onEnd: (@Sendable () -> Void)? = nil, begin: @escaping @Sendable () throws -> Stage) {
        self.queue = queue
        self.onEnd = onEnd
        queue.async {
            guard !self.isCancelled else { return }
            do {
                let stage = try begin()
                self.transcription = stage.transcription
                self.stage = stage
            } catch {
                self.failure = error
            }
        }
    }

    /// Any thread, in recording order. Ignored after `finish` or `cancel`.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        guard !cancelled, !finishing else { lock.unlock(); return }
        inbox.append(contentsOf: samples)
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule { queue.async { self.drain() } }
    }

    /// Transcribes what is left and returns the result, which equals a batch
    /// transcription of every appended sample. An error from any chunk, with
    /// the batch path's content-free mapping, is thrown here. Call it once;
    /// after `cancel`, or cancelling the calling task, it throws `CancellationError`
    /// and what completion published is abandoned. A cancel after the result
    /// is returned leaves it to the caller.
    func finish() async throws -> Output {
        guard beginFinishing() else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.drain()
                    let result: Result<Output, Error>
                    do {
                        result = .success(try self.complete())
                    } catch {
                        result = .failure(LocalParakeetError.contentFree(error))
                    }
                    self.transcription = nil
                    self.stage = nil
                    self.end()
                    continuation.resume(with: result)
                }
            }
        } onCancel: { self.cancel() }
    }

    /// Stops further work and drops pending audio and partial results. Idempotent.
    func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        inbox = []
        lock.unlock()
        if first {
            queue.async {
                self.transcription = nil
                self.stage = nil
                self.end()
            }
        }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// True for the first finish of a session that was not cancelled.
    private func beginFinishing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let accepted = !cancelled && !finishing
        finishing = true
        return accepted
    }

    private func check() throws {
        if isCancelled { throw CancellationError() }
    }

    // Queue only: the tail, then the result. A cancel that landed during
    // completion abandons what it published.
    private func complete() throws -> Output {
        try check()
        if let failure { throw failure }
        guard var transcription, let stage else { throw CancellationError() }
        self.transcription = nil
        let text = try transcription.finish { try stage.transcribe($0, check) }
        let output = try stage.complete(text, check)
        if isCancelled {
            stage.abandon(output)
            throw CancellationError()
        }
        return output
    }

    // Queue only.
    private func end() {
        guard !ended else { return }
        ended = true
        onEnd?()
    }

    // Queue only. After a failure no chunk work runs and samples are dropped.
    private func drain() {
        lock.lock()
        let samples = inbox
        inbox = []
        drainScheduled = false
        lock.unlock()
        guard !samples.isEmpty, failure == nil, let stage, transcription != nil else { return }
        do {
            try check()
            try transcription!.append(samples) { try stage.transcribe($0, check) }
        } catch {
            failure = error
            transcription = nil
        }
    }
}

/// Joins chunk transcripts in recording order. A chunk's model treats its
/// edges as the start and end of speech, so it may capitalize, punctuate, or
/// cut off words there. Where two chunks overlap, the seam is placed on a word
/// both heard, near the middle of the shared audio: earlier words come from
/// the earlier chunk and later words from the later one.
struct ParakeetTranscriptAssembler {
    // Starts of the same word in two chunks differ by a few encoder frames.
    static let alignmentTolerance = 6400
    private var words: [ParakeetWord] = []
    private var end: Int?

    var text: String { words.map(\.text).joined(separator: " ") }

    mutating func append(_ chunkWords: [ParakeetWord], covering range: Range<Int>) {
        if let end, range.lowerBound < end {
            words = Self.merge(words, chunkWords, overlap: range.lowerBound..<end)
        } else {
            words += chunkWords
        }
        end = range.upperBound
    }

    private static func merge(_ left: [ParakeetWord], _ right: [ParakeetWord], overlap: Range<Int>) -> [ParakeetWord] {
        let tolerance = alignmentTolerance
        let l = left.indices.filter { left[$0].start >= overlap.lowerBound - tolerance }
        let r = right.indices.filter { right[$0].start < overlap.upperBound + tolerance }
        let leftKeys = l.map { key(left[$0].text) }, rightKeys = r.map { key(right[$0].text) }
        func distance(_ x: Int, _ y: Int) -> Int { abs(left[l[x]].start - right[r[y]].start) }
        func matches(_ x: Int, _ y: Int) -> Bool {
            !leftKeys[x].isEmpty && leftKeys[x] == rightKeys[y] && distance(x, y) <= tolerance
        }
        // Longest common subsequence, so repeated words pair in order. Among
        // equally long alignments, the one whose pairs are closest in time wins.
        typealias Alignment = (count: Int, cost: Int)
        func better(_ a: Alignment, _ b: Alignment) -> Bool { a.count != b.count ? a.count > b.count : a.cost < b.cost }
        var best: [[Alignment]] = Array(repeating: Array(repeating: (count: 0, cost: 0), count: r.count + 1), count: l.count + 1)
        func paired(_ x: Int, _ y: Int) -> Alignment {
            (best[x + 1][y + 1].count + 1, best[x + 1][y + 1].cost + distance(x, y))
        }
        for x in l.indices.reversed() {
            for y in r.indices.reversed() {
                let skip = better(best[x][y + 1], best[x + 1][y]) ? best[x][y + 1] : best[x + 1][y]
                best[x][y] = matches(x, y) && better(paired(x, y), skip) ? paired(x, y) : skip
            }
        }
        var pairs: [(Int, Int)] = [], x = 0, y = 0
        while x < l.count, y < r.count {
            if matches(x, y), paired(x, y) == best[x][y] {
                pairs.append((l[x], r[y]))
                x += 1
                y += 1
            } else if best[x + 1][y] == best[x][y] {
                x += 1
            } else {
                y += 1
            }
        }
        let middle = overlap.lowerBound + overlap.upperBound
        guard let anchor = pairs.min(by: {
            abs(left[$0.0].start + right[$0.1].start - middle) < abs(left[$1.0].start + right[$1.1].start - middle)
        }) else {
            return left.filter { 2 * $0.start < middle } + right.filter { 2 * $0.start >= middle }
        }
        let (i, j) = anchor
        return Array(left[..<i]) + [seam(left[i], right[j])] + right[(j + 1)...]
    }

    /// Casing comes from the earlier chunk, which heard what preceded the word;
    /// trailing punctuation from the later chunk, which heard what follows it.
    private static func seam(_ left: ParakeetWord, _ right: ParakeetWord) -> ParakeetWord {
        let leftScalars = left.text.unicodeScalars, rightScalars = right.text.unicodeScalars
        guard let leftEnd = leftScalars.lastIndex(where: CharacterSet.alphanumerics.contains),
              let rightEnd = rightScalars.lastIndex(where: CharacterSet.alphanumerics.contains) else { return left }
        let text = String(leftScalars[...leftEnd]) + String(rightScalars[rightScalars.index(after: rightEnd)...])
        return ParakeetWord(text: text, start: left.start)
    }

    private static func key(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }
}

/// Used only on the service's serial queue. Holds the 15 s encoder function:
/// loaded once and kept, and prepared once its synthetic warm-up succeeds. A
/// failed load or warm-up is retried by the next preparation.
final class ParakeetModelCache<Model> {
    private var loaded: Model?
    private(set) var isPrepared = false

    /// The 15 s function, loaded on first use.
    func model(load: (Int) throws -> Model) throws -> Model {
        if let loaded { return loaded }
        let model = try load(LocalParakeetCore.encoderSeconds)
        loaded = model
        return model
    }

    /// Loads the function if needed and warms it; does nothing once prepared.
    func prepare(load: (Int) throws -> Model, warm: (Int, Model) throws -> Void) throws {
        guard !isPrepared else { return }
        try warm(LocalParakeetCore.encoderSeconds, try model(load: load))
        isPrepared = true
    }
}

enum LocalParakeetPreparationState {
    case idle, preparing, ready, failed

    var message: String {
        switch self {
        case .idle: return "Local model has not been prepared yet."
        case .preparing: return "Preparing local model… First-time preparation may take several minutes."
        case .ready: return "Local model ready. Kept in memory for this session."
        case .failed: return "Local model preparation failed. Select the model again to retry."
        }
    }
}
