import Foundation

enum DictationSampleBufferTests {
    static var tests: [TestCase] {
        [
            ("dropsWhenIdle", testDropsWhenIdle),
            ("collectsOnlyBetweenBeginAndFinish", testCollectsOnlyBetweenBeginAndFinish),
            ("finishIsForTheRecordingRequestOnly", testFinishIsForTheRecordingRequestOnly),
            ("beginSupersedesAndAdvancesGeneration", testBeginSupersedesAndAdvancesGeneration),
            ("cancelPaths", testCancelPaths),
            ("capsAtMaxDuration", testCapsAtMaxDuration),
            ("defaultCapIsFiveMinutes", testDefaultCapIsFiveMinutes),
            ("levelTracksSpeechAndStaysInRange", testLevelTracksSpeechAndStaysInRange),
            ("levelFollowsSyllables", testLevelFollowsSyllables),
            ("softNormalAndLoudVoicesAllLookActive", testSoftNormalAndLoudVoicesAllLookActive),
            ("roomNoiseAndPausesRestFlat", testRoomNoiseAndPausesRestFlat),
            ("aLoudMomentDoesNotSilenceTheNextWords", testALoudMomentDoesNotSilenceTheNextWords),
            ("finishDrainsAtomicallyUnderConcurrentAppends", testFinishDrainsAtomicallyUnderConcurrentAppends),
            ("streamReceivesExactlyTheRecording", testStreamReceivesExactlyTheRecording),
            ("staleRecordingNeverFeedsANewerStream", testStaleRecordingNeverFeedsANewerStream),
            ("discardedRecordingCancelsItsStream", testDiscardedRecordingCancelsItsStream),
            ("streamMatchesTheDrainUnderConcurrentAppends", testStreamMatchesTheDrainUnderConcurrentAppends),
        ]
    }

    private static func tone(_ count: Int, amplitude: Float) -> [Float] {
        (0..<count).map { amplitude * sinf(Float($0) * 0.2) }
    }

    private static func testDropsWhenIdle() {
        let buffer = DictationSampleBuffer()
        TestSupport.expectEqual(buffer.append(tone(1_600, amplitude: 0.5)), .dropped)
        TestSupport.expectEqual(buffer.recordedDuration, 0)
        TestSupport.expectEqual(buffer.level, 0)
        TestSupport.expectEqual(buffer.recordingRequestID, nil)
        TestSupport.expectEqual(buffer.generation, 0)
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID), nil)
    }

    private static func testCollectsOnlyBetweenBeginAndFinish() {
        let buffer = DictationSampleBuffer()
        let generation = buffer.begin(requestID: Fixture.requestID)
        TestSupport.expectEqual(generation, 1)
        TestSupport.expectEqual(buffer.recordingRequestID, Fixture.requestID)
        TestSupport.expectEqual(buffer.append([Float]()), .dropped)
        TestSupport.expectEqual(buffer.append([0.1, 0.2]), .started(generation: 1))
        TestSupport.expectEqual(buffer.append([0.3]), .accepted)
        [Float](repeating: 0.4, count: 2).withUnsafeBufferPointer { pointer in
            TestSupport.expectEqual(buffer.append(pointer), .accepted)
        }
        TestSupport.expectEqual(buffer.recordedDuration, 5 / DictationSampleBuffer.sampleRate)
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID), [0.1, 0.2, 0.3, 0.4, 0.4])
        TestSupport.expectEqual(buffer.recordingRequestID, nil)
        TestSupport.expectEqual(buffer.append([0.5]), .dropped)
        TestSupport.expectEqual(buffer.recordedDuration, 0)
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID), nil)
    }

    private static func testFinishIsForTheRecordingRequestOnly() {
        let buffer = DictationSampleBuffer()
        buffer.begin(requestID: Fixture.requestID)
        buffer.append([0.1])
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.otherRequestID), nil)
        TestSupport.expectEqual(buffer.recordingRequestID, Fixture.requestID)
        TestSupport.expectEqual(buffer.append([0.2]), .accepted)
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID), [0.1, 0.2])
    }

    private static func testBeginSupersedesAndAdvancesGeneration() {
        let buffer = DictationSampleBuffer()
        TestSupport.expectEqual(buffer.begin(requestID: Fixture.requestID), 1)
        buffer.append([0.9, 0.9])
        TestSupport.expectEqual(buffer.begin(requestID: Fixture.otherRequestID), 2)
        TestSupport.expectEqual(buffer.generation, 2)
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID), nil)
        TestSupport.expectEqual(buffer.append([0.1]), .started(generation: 2))
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.otherRequestID), [0.1])
        // The generation identifies recordings; finishing does not reset it.
        TestSupport.expectEqual(buffer.generation, 2)
        TestSupport.expectEqual(buffer.begin(requestID: Fixture.requestID), 3)
    }

    private static func testCancelPaths() {
        let buffer = DictationSampleBuffer()
        buffer.begin(requestID: Fixture.requestID)
        buffer.append([0.1])
        TestSupport.expect(!buffer.cancel(requestID: Fixture.otherRequestID), "cancelled another request")
        TestSupport.expectEqual(buffer.recordingRequestID, Fixture.requestID)
        TestSupport.expect(buffer.cancel(requestID: Fixture.requestID), "did not cancel the recording")
        TestSupport.expectEqual(buffer.append([0.2]), .dropped)
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID), nil)
        buffer.begin(requestID: Fixture.otherRequestID)
        buffer.append([0.3])
        buffer.cancelAll()
        TestSupport.expectEqual(buffer.recordingRequestID, nil)
        TestSupport.expectEqual(buffer.recordedDuration, 0)
        TestSupport.expectEqual(buffer.level, 0)
    }

    private static func testCapsAtMaxDuration() {
        let buffer = DictationSampleBuffer(maxDuration: 10 / DictationSampleBuffer.sampleRate)
        TestSupport.expectEqual(buffer.maxSampleCount, 10)
        let generation = buffer.begin(requestID: Fixture.requestID)
        TestSupport.expectEqual(buffer.append([Float](repeating: 0.1, count: 6)), .started(generation: generation))
        TestSupport.expect(!buffer.hasReachedLimit, "limit reached early")
        TestSupport.expectEqual(buffer.append([Float](repeating: 0.2, count: 6)), .reachedLimit(generation: generation))
        TestSupport.expect(buffer.hasReachedLimit, "limit not reported")
        TestSupport.expectEqual(buffer.append([0.3]), .dropped)
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID),
                                [Float](repeating: 0.1, count: 6) + [Float](repeating: 0.2, count: 4))
        TestSupport.expect(!buffer.hasReachedLimit, "limit outlived the recording")

        // A first buffer that fills the cap reports the limit.
        buffer.begin(requestID: Fixture.otherRequestID)
        TestSupport.expectEqual(buffer.append([Float](repeating: 0.1, count: 20)), .reachedLimit(generation: 2))
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.otherRequestID)?.count, 10)
    }

    /// The stream is fed exactly what the drain returns, cap included, and is handed over with it.
    private static func testStreamReceivesExactlyTheRecording() {
        let buffer = DictationSampleBuffer(maxDuration: 10 / DictationSampleBuffer.sampleRate)
        let stream = FakeSpeechStream()
        buffer.append([0.9])   // idle: dropped
        let generation = buffer.begin(requestID: Fixture.requestID, stream: stream)
        buffer.append([0.1, 0.2, 0.3])
        buffer.append([], token: generation)
        buffer.append([0.4, 0.5], token: generation)
        TestSupport.expectEqual(buffer.append([Float](repeating: 0.6, count: 8)), .reachedLimit(generation: generation))
        buffer.append([0.7])   // past the cap: dropped
        let audio = buffer.finishRecording(requestID: Fixture.requestID)
        TestSupport.expectEqual(audio?.samples, [0.1, 0.2, 0.3, 0.4, 0.5] + [Float](repeating: 0.6, count: 5))
        TestSupport.expect(audio?.stream === stream, "stream not handed over")
        TestSupport.expectEqual(stream.samples, audio?.samples)
        TestSupport.expect(!stream.isCancelled, "a finished recording cancelled its stream")
        buffer.append([0.8], token: generation)
        TestSupport.expectEqual(stream.samples.count, 10)
        TestSupport.expect(buffer.finishRecording(requestID: Fixture.requestID) == nil, "finished twice")
        TestSupport.expect(!stream.isCancelled, "a later boundary cancelled a handed-over stream")

        // Without a stream nothing changes.
        buffer.begin(requestID: Fixture.otherRequestID)
        buffer.append([0.1])
        let plain = buffer.finishRecording(requestID: Fixture.otherRequestID)
        TestSupport.expectEqual(plain?.samples, [0.1])
        TestSupport.expect(plain?.stream == nil, "a stream appeared")
    }

    /// Audio converted for an earlier recording is dropped before any stream sees it.
    private static func testStaleRecordingNeverFeedsANewerStream() {
        let buffer = DictationSampleBuffer()
        let first = FakeSpeechStream(), second = FakeSpeechStream()
        let stale = buffer.begin(requestID: Fixture.requestID, stream: first)
        buffer.append([0.1], token: stale)
        let current = buffer.begin(requestID: Fixture.otherRequestID, stream: second)
        TestSupport.expect(first.isCancelled, "a superseded recording kept its stream")
        buffer.append([0.2], token: stale)
        buffer.append([0.3], token: current)
        TestSupport.expectEqual(first.samples, [0.1])
        TestSupport.expectEqual(second.samples, [0.3])
        TestSupport.expect(buffer.finishRecording(requestID: Fixture.requestID) == nil, "stale request finished")
        let audio = buffer.finishRecording(requestID: Fixture.otherRequestID)
        TestSupport.expect(audio?.stream === second, "wrong stream handed over")
        TestSupport.expectEqual(audio?.samples, [0.3])
        TestSupport.expect(!second.isCancelled, "current stream cancelled")
    }

    /// Every way a recording is discarded cancels its stream; `finish` without a taker does too.
    private static func testDiscardedRecordingCancelsItsStream() {
        let buffer = DictationSampleBuffer()
        let cancelled = FakeSpeechStream(), other = FakeSpeechStream()
        buffer.begin(requestID: Fixture.requestID, stream: cancelled)
        TestSupport.expect(!buffer.cancel(requestID: Fixture.otherRequestID), "cancelled another request")
        TestSupport.expect(!cancelled.isCancelled, "another request's cancel reached the stream")
        buffer.cancel(requestID: Fixture.requestID)
        TestSupport.expect(cancelled.isCancelled, "cancel kept the stream")

        let ended = FakeSpeechStream()
        buffer.begin(requestID: Fixture.requestID, stream: ended)
        buffer.cancelAll()
        TestSupport.expect(ended.isCancelled, "cancelAll kept the stream")

        let drained = FakeSpeechStream()
        buffer.begin(requestID: Fixture.requestID, stream: drained)
        buffer.append([0.1])
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.requestID), [0.1])
        TestSupport.expect(drained.isCancelled, "an unclaimed stream outlived its recording")
        TestSupport.expect(!other.isCancelled, "an unrelated stream was cancelled")
    }

    /// Appends racing the drain: the stream holds exactly the drained samples, in order.
    private static func testStreamMatchesTheDrainUnderConcurrentAppends() {
        let buffer = DictationSampleBuffer()
        let stream = FakeSpeechStream()
        let generation = buffer.begin(requestID: Fixture.requestID, stream: stream)
        let drained = Locked<RecordedAudio?>(nil)
        Concurrently.run(4) { index in
            if index == 0 {
                Thread.sleep(forTimeInterval: 0.002)
                drained.update { $0 = buffer.finishRecording(requestID: Fixture.requestID) }
            } else {
                for step in 0..<500 { buffer.append([Float(index * 1_000 + step)], token: generation) }
            }
        }
        let audio = drained.current
        TestSupport.expect(audio != nil, "not drained")
        TestSupport.expectEqual(stream.samples, audio?.samples)
    }

    private static func testDefaultCapIsFiveMinutes() {
        TestSupport.expectEqual(DictationSampleBuffer().maxSampleCount, 300 * 16_000)
    }

    private static func testLevelTracksSpeechAndStaysInRange() {
        let buffer = DictationSampleBuffer()
        buffer.begin(requestID: Fixture.requestID)
        buffer.append([Float](repeating: 0, count: 1_600))
        TestSupport.expectEqual(buffer.level, 0)
        var previous: Float = 0
        for _ in 0..<6 {
            buffer.append(tone(1_600, amplitude: 0.3))
            TestSupport.expect(buffer.level > previous && buffer.level <= 1, "level did not rise toward speech")
            previous = buffer.level
        }
        TestSupport.expect(previous > 0.8, "loud speech reads low: \(previous)")
        buffer.append(tone(1_600, amplitude: 0.001))
        TestSupport.expect(buffer.level < previous && buffer.level > 0, "level did not release smoothly")
        buffer.append([Float](repeating: .nan, count: 160))
        TestSupport.expect(buffer.level.isFinite, "NaN input produced a NaN level")
        buffer.append([Float](repeating: 10, count: 160))
        TestSupport.expect(buffer.level <= 1, "clipped input exceeded 1")
        _ = buffer.finish(requestID: Fixture.requestID)
        TestSupport.expectEqual(buffer.level, 0)
    }

    /// Round 10 (owner: the keyboard's wave "kind of slow, consistent"): the level falls with a syllable's end, within two
    /// buffers (about 0.2 s; round 9's release kept 70% then, a 0.6 s fall), so the keyboard sees a gap between words;
    /// and ordinary speech (-17 dBFS, the synthetic voice's level) sits clearly below the top, so a louder word still
    /// shows louder.
    private static func testLevelFollowsSyllables() {
        let buffer = DictationSampleBuffer()
        buffer.begin(requestID: Fixture.requestID)
        for _ in 0..<8 { buffer.append(tone(1_600, amplitude: 0.3)) }
        let speaking = buffer.level
        buffer.append(tone(1_600, amplitude: 0.001))
        buffer.append(tone(1_600, amplitude: 0.001))
        TestSupport.expect(buffer.level <= 0.25 * speaking, "the level lingers after a syllable: \(buffer.level) of \(speaking)")
        for _ in 0..<8 { buffer.append(tone(1_600, amplitude: 0.2)) }
        let ordinary = buffer.level
        TestSupport.expect(ordinary < 0.92, "ordinary speech is at the top: \(ordinary)")
        for _ in 0..<8 { buffer.append(tone(1_600, amplitude: 0.5)) }
        TestSupport.expect(buffer.level > ordinary + 0.05, "a louder word reads the same: \(buffer.level) vs \(ordinary)")
        _ = buffer.finish(requestID: Fixture.requestID)
    }

    // MARK: Real voices (round 11)

    /// 100 ms of a tone whose RMS is `dBFS`.
    private static func buffer(at dBFS: Double) -> [Float] {
        tone(1_600, amplitude: Float(2.0.squareRoot() * pow(10, dBFS / 20)))
    }

    /// 100 ms of invented room noise (a fixed pseudo-random hiss) whose RMS is `dBFS`.
    private static func noise(at dBFS: Double, seed: inout UInt64) -> [Float] {
        let amplitude = Float(3.0.squareRoot() * pow(10, dBFS / 20))
        return (0..<1_600).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return amplitude * (Float(seed >> 40) / Float(1 << 24) * 2 - 1)
        }
    }

    /// A phrase of invented speech at `dBFS` (its RMS): syllables a little above it with 100 ms gaps 18 dB down between, 100 ms a
    /// buffer, for `seconds`. Returns the level after each buffer.
    private static func speak(_ buffer: DictationSampleBuffer, at dBFS: Double, seconds: Double) -> [Float] {
        let pattern = [dBFS + 3, dBFS + 1, dBFS - 18]
        return (0..<Int(seconds * 10)).map { index in
            buffer.append(Self.buffer(at: pattern[index % pattern.count]))
            return buffer.level
        }
    }

    /// Round 11 (Opus, round 10: the wave was tuned on `say`'s loud voice, and a quiet phrase at about -32 dBFS left the
    /// row flat; a real voice at arm's length often sits around -35 to -25 dBFS): a soft, a normal and a loud speaker
    /// (-32, -22 and -12 dBFS) all look clearly active. Each one's syllables reach near the top of the level, where the
    /// keyboard's wave swells (`DotWave.voice`), and dip clearly between syllables, from the first second of speech.
    private static func testSoftNormalAndLoudVoicesAllLookActive() {
        var peaks: [Float] = []
        for dBFS in [-32.0, -22, -12] {
            let buffer = DictationSampleBuffer()
            buffer.begin(requestID: Fixture.requestID)
            let levels = speak(buffer, at: dBFS, seconds: 3)
            let first = levels.prefix(10), all = levels.dropFirst(3)
            TestSupport.expect(first.max()! >= 0.85, "a voice at \(dBFS) dBFS starts flat: \(levels)")
            TestSupport.expect(all.max()! >= 0.85, "a voice at \(dBFS) dBFS reads quiet: \(levels)")
            TestSupport.expect(all.max()! - all.min()! >= 0.35, "syllables at \(dBFS) dBFS blur together: \(levels)")
            TestSupport.expect(DotWave.voice(Double(all.max()!)) >= 0.75, "the wave barely swells at \(dBFS) dBFS")
            peaks.append(all.max()!)
            _ = buffer.finish(requestID: Fixture.requestID)
        }
        TestSupport.expect(peaks.min()! >= 0.85 * peaks.max()!, "soft and loud speakers look different: \(peaks)")
    }

    /// Silence and a quiet room (invented hiss at -55 and -50 dBFS) rest flat: before anyone speaks, in a pause after a
    /// soft speaker (within 0.3 s), and long after a loud one. The wave draws nothing below its dead zone.
    private static func testRoomNoiseAndPausesRestFlat() {
        var seed: UInt64 = 7
        for room in [-55.0, -50] {
            for speaker in [nil, -32.0, -12] {
                let buffer = DictationSampleBuffer()
                buffer.begin(requestID: Fixture.requestID)
                for _ in 0..<20 {
                    buffer.append(noise(at: room, seed: &seed))
                    if speaker == nil { TestSupport.expect(buffer.level <= 0.03, "a \(room) dBFS room moves the level: \(buffer.level)") }
                }
                guard let speaker else { continue }
                _ = speak(buffer, at: speaker, seconds: 2)
                var pause: [Float] = []
                for _ in 0..<60 {
                    buffer.append(noise(at: room, seed: &seed))
                    pause.append(buffer.level)
                }
                TestSupport.expect(pause.dropFirst(3).allSatisfy { DotWave.voice(Double($0)) == 0 },
                                   "a pause after \(speaker) dBFS in a \(room) dBFS room swells the wave: \(pause)")
                TestSupport.expect(pause.dropFirst(3).allSatisfy { $0 <= 0.08 }, "the pause is not flat: \(pause)")
                TestSupport.expect(pause.suffix(20).allSatisfy { $0 <= 0.03 }, "the room creeps up after \(speaker) dBFS: \(pause)")
                _ = buffer.finish(requestID: Fixture.requestID)
            }
        }
    }

    /// The level follows the speaker's recent loudest, so one loud moment (a laugh, a bump, at -6 dBFS) shrinks what
    /// follows for a moment, as a louder word should, but ordinary words at -22 dBFS look active again within 3 s.
    private static func testALoudMomentDoesNotSilenceTheNextWords() {
        let buffer = DictationSampleBuffer()
        buffer.begin(requestID: Fixture.requestID)
        _ = speak(buffer, at: -22, seconds: 1)
        buffer.append(Self.buffer(at: -6))
        buffer.append(Self.buffer(at: -6))
        let next = speak(buffer, at: -22, seconds: 3.6)
        TestSupport.expect(next.prefix(4).max()! < 0.95, "the loud moment changes nothing: \(next)")
        TestSupport.expect(next.suffix(6).max()! >= 0.85, "ordinary words stay small after a loud moment: \(next)")
        _ = buffer.finish(requestID: Fixture.requestID)
    }

    /// The audio tap appends from its own thread while the main thread finishes the request. Every
    /// chunk lands either in the drained snapshot or is dropped; none is lost or retained.
    private static func testFinishDrainsAtomicallyUnderConcurrentAppends() {
        let buffer = DictationSampleBuffer()
        buffer.begin(requestID: Fixture.requestID)
        let chunk = [Float](repeating: 0.25, count: 160)
        let accepted = LockedCounter()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<2_000 {
                switch buffer.append(chunk) {
                case .dropped: break
                default: accepted.increment()
                }
            }
            done.signal()
        }
        while buffer.recordedDuration < 0.05 { _ = buffer.level }
        let drained = buffer.finish(requestID: Fixture.requestID)!
        done.wait()
        TestSupport.expectEqual(drained.count, accepted.value * chunk.count)
        TestSupport.expectEqual(buffer.recordedDuration, 0)
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
}
