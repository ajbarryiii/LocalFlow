import Foundation

/// The capture thread's audio boundary, driven with timestamped fake input and a stateful fake converter
/// that can be paused mid-conversion. Host ticks are nanoseconds.
enum CapturePipelineTests {
    static var tests: [TestCase] {
        [
            ("tokenGuardsAppend", testTokenGuardsAppend),
            ("conversionSpanningCancelAndBeginIsDropped", testConversionSpanningCancelAndBeginIsDropped),
            ("conversionSpanningFinishIsDropped", testConversionSpanningFinishIsDropped),
            ("idleBuffersAreNeverConverted", testIdleBuffersAreNeverConverted),
            ("framesBeforeBeginAreTrimmedBeforeConversion", testFramesBeforeBeginAreTrimmedBeforeConversion),
            ("tailIsCollectedUntilTheEndAndReported", testTailIsCollectedUntilTheEndAndReported),
            ("boundaryResetsTheConverterAtOnce", testBoundaryResetsTheConverterAtOnce),
            ("boundaryDuringConversionResetsWhenItReturns", testBoundaryDuringConversionResetsWhenItReturns),
            ("repeatedConversionFailuresAreReportedOnce", testRepeatedConversionFailuresAreReportedOnce),
            ("eventsAndArrivalTime", testEventsAndArrivalTime),
        ]
    }

    private static func testTokenGuardsAppend() {
        let buffer = DictationSampleBuffer()
        TestSupport.expectEqual(buffer.recordingToken, nil)
        let first = buffer.begin(requestID: Fixture.requestID)
        TestSupport.expectEqual(buffer.recordingToken, first)
        TestSupport.expectEqual(buffer.append([0.1], token: first), .started(generation: first))
        TestSupport.expectEqual(buffer.append([0.2], token: first &+ 1), .dropped)
        TestSupport.expect(buffer.cancel(requestID: Fixture.requestID), "cancel failed")
        TestSupport.expectEqual(buffer.recordingToken, nil)
        TestSupport.expectEqual(buffer.append([0.3], token: first), .dropped)
        let second = buffer.begin(requestID: Fixture.otherRequestID)
        TestSupport.expectEqual(buffer.append([0.4], token: first), .dropped)
        TestSupport.expectEqual(buffer.append([0.5], token: second), .started(generation: second))
        TestSupport.expectEqual(buffer.finish(requestID: Fixture.otherRequestID), [0.5])
    }

    /// P0: R's audio is mid-conversion when R is cancelled and S begins. Those samples must not land in S.
    private static func testConversionSpanningCancelAndBeginIsDropped() {
        let h = PipelineHarness()
        h.buffer.begin(requestID: Fixture.requestID)
        h.converter.pauseNextConversion()
        let done = h.processOnAnotherThread(h.input([0.9, 0.9, 0.9]))   // R's audio
        TestSupport.expect(h.converter.waitUntilPaused(), "conversion never started")
        TestSupport.expect(h.buffer.cancel(requestID: Fixture.requestID), "cancel failed")
        h.advance()
        let second = h.buffer.begin(requestID: Fixture.otherRequestID)
        h.converter.resume()
        TestSupport.expect(done.wait(timeout: .now() + 5) == .success, "conversion did not finish")
        TestSupport.expectEqual(h.buffer.recordedDuration, 0)
        TestSupport.expectEqual(h.events.current, [])
        // S's own audio converts with fresh state and is kept.
        h.advance()
        h.pipeline.process(h.input([0.2, 0.2]))
        TestSupport.expectEqual(h.converter.log.suffix(2), [.reset, .convert])
        TestSupport.expectEqual(h.events.current, [.started(generation: second)])
        TestSupport.expectEqual(h.buffer.finish(requestID: Fixture.otherRequestID), [0.2, 0.2])
    }

    private static func testConversionSpanningFinishIsDropped() {
        let h = PipelineHarness()
        h.buffer.begin(requestID: Fixture.requestID)
        h.advance()
        h.pipeline.process(h.input([0.1]))
        h.converter.pauseNextConversion()
        let done = h.processOnAnotherThread(h.input([0.7, 0.7]))
        TestSupport.expect(h.converter.waitUntilPaused(), "conversion never started")
        TestSupport.expectEqual(h.buffer.finish(requestID: Fixture.requestID), [0.1])
        h.converter.resume()
        TestSupport.expect(done.wait(timeout: .now() + 5) == .success, "conversion did not finish")
        TestSupport.expectEqual(h.buffer.recordedDuration, 0)
        TestSupport.expectEqual(h.buffer.recordingRequestID, nil)
    }

    /// Between dictations nothing is converted and nothing derived from audio is kept.
    private static func testIdleBuffersAreNeverConverted() {
        let h = PipelineHarness()
        for _ in 0..<5 { h.pipeline.process(h.input([0.5])) }
        TestSupport.expectEqual(h.converter.log, [])
        h.buffer.begin(requestID: Fixture.requestID)
        h.advance()
        h.pipeline.process(h.input([0.5]))
        _ = h.buffer.finish(requestID: Fixture.requestID)
        for _ in 0..<5 { h.pipeline.process(h.input([0.5])) }
        // One reset before the first conversion, one at the first idle buffer, none while idle after.
        TestSupport.expectEqual(h.converter.log, [.reset, .convert, .reset])
        TestSupport.expectEqual(h.converter.state, [])
    }

    /// P0: a long buffer captured partly before begin. Only the frames after begin are converted.
    private static func testFramesBeforeBeginAreTrimmedBeforeConversion() {
        let h = PipelineHarness()
        h.buffer.begin(requestID: Fixture.requestID)
        let begin = h.clock.current
        // 0.2 s at 16 kHz captured from 0.05 s before begin: frames 0..<800 are idle audio.
        let samples = (0..<3_200).map { Float($0) }
        h.advance(by: 300_000_000)
        h.pipeline.process(PipelineHarness.Input(samples: samples, hostTime: begin - 50_000_000))
        TestSupport.expectEqual(h.converter.converted.last?.count, 2_400)
        TestSupport.expectEqual(h.converter.converted.last?.first, 800)
        TestSupport.expectEqual(h.buffer.finish(requestID: Fixture.requestID)?.first, 800)
        // A buffer captured entirely before begin is never converted.
        h.buffer.begin(requestID: Fixture.otherRequestID)
        let secondBegin = h.clock.current
        let conversions = h.converter.converted.count
        h.pipeline.process(PipelineHarness.Input(samples: samples, hostTime: secondBegin - 300_000_000))
        TestSupport.expectEqual(h.converter.converted.count, conversions)
        TestSupport.expectEqual(h.buffer.recordedDuration, 0)
    }

    /// After finish (close), frames captured before the end still arrive; the buffer that reaches past the
    /// end is trimmed and reports the tail complete, once.
    private static func testTailIsCollectedUntilTheEndAndReported() {
        let h = PipelineHarness()
        let generation = h.buffer.begin(requestID: Fixture.requestID)
        let begin = h.clock.current
        h.advance(by: 100_000_000)
        h.pipeline.process(PipelineHarness.Input(samples: [Float](repeating: 1, count: 1_600), hostTime: begin))
        h.advance(by: 50_000_000)
        TestSupport.expect(h.buffer.close(requestID: Fixture.requestID), "close failed")
        let end = h.clock.current
        TestSupport.expect(!h.buffer.close(requestID: Fixture.requestID), "closed twice")
        TestSupport.expectEqual(h.buffer.recordingWindow?.end, end)
        // In flight at the finish: captured from 0.1 s to 0.2 s, the end falls at 0.15 s.
        h.advance(by: 100_000_000)
        h.pipeline.process(PipelineHarness.Input(samples: [Float](repeating: 2, count: 1_600), hostTime: begin + 100_000_000))
        TestSupport.expectEqual(h.converter.converted.last?.count, 800)
        TestSupport.expectEqual(h.events.current, [.started(generation: generation), .tailComplete(generation: generation)])
        h.pipeline.process(PipelineHarness.Input(samples: [Float](repeating: 3, count: 1_600), hostTime: begin + 200_000_000))
        TestSupport.expectEqual(h.events.current.count, 2)
        let samples = h.buffer.finish(requestID: Fixture.requestID)
        TestSupport.expectEqual(samples?.count, 2_400)
        TestSupport.expect(samples?.contains(3) == false, "audio after the end was kept")
    }

    /// P1: finish with no further callback still clears the converter at once.
    private static func testBoundaryResetsTheConverterAtOnce() {
        let h = PipelineHarness()
        h.buffer.begin(requestID: Fixture.requestID)
        h.advance()
        h.pipeline.process(h.input([0.4, 0.4]))
        TestSupport.expectEqual(h.converter.state, [0.4, 0.4])
        _ = h.buffer.finish(requestID: Fixture.requestID)
        h.pipeline.boundaryPassed()
        TestSupport.expectEqual(h.converter.state, [])
    }

    /// P1: a boundary during a conversion resets the converter when that conversion returns, with no
    /// further callback.
    private static func testBoundaryDuringConversionResetsWhenItReturns() {
        let h = PipelineHarness()
        h.buffer.begin(requestID: Fixture.requestID)
        h.advance()
        h.converter.pauseNextConversion()
        let done = h.processOnAnotherThread(h.input([0.6, 0.6]))
        TestSupport.expect(h.converter.waitUntilPaused(), "conversion never started")
        _ = h.buffer.finish(requestID: Fixture.requestID)
        h.pipeline.boundaryPassed()
        TestSupport.expectEqual(h.converter.log.last, .convert)   // no reset under a running conversion
        h.converter.resume()
        TestSupport.expect(done.wait(timeout: .now() + 5) == .success, "conversion did not finish")
        TestSupport.expectEqual(h.converter.log.last, .reset)
        TestSupport.expectEqual(h.converter.state, [])
        TestSupport.expectEqual(h.buffer.recordedDuration, 0)
    }

    private static func testRepeatedConversionFailuresAreReportedOnce() {
        let h = PipelineHarness()
        let generation = h.buffer.begin(requestID: Fixture.requestID)
        h.advance()
        h.converter.failing = true
        for _ in 0..<(HostSessionPolicy.maxConsecutiveConversionFailures - 1) { h.pipeline.process(h.input([0.1])) }
        TestSupport.expectEqual(h.events.current, [])
        h.pipeline.process(h.input([0.1]))
        TestSupport.expectEqual(h.events.current, [.conversionFailed(generation: generation)])
        for _ in 0..<10 { h.pipeline.process(h.input([0.1])) }
        TestSupport.expectEqual(h.events.current.count, 1)
        // A success in between restarts the count.
        h.converter.failing = false
        h.pipeline.process(h.input([0.1]))
        h.converter.failing = true
        for _ in 0..<(HostSessionPolicy.maxConsecutiveConversionFailures - 1) { h.pipeline.process(h.input([0.1])) }
        TestSupport.expectEqual(h.events.current.count, 2)   // the success reported `started`
    }

    private static func testEventsAndArrivalTime() {
        let h = PipelineHarness(maxDuration: 4 / DictationSampleBuffer.sampleRate)
        TestSupport.expectEqual(h.pipeline.clock.lastBufferAt, nil)
        h.pipeline.process(h.input([0.1]))
        TestSupport.expect(h.pipeline.clock.lastBufferAt != nil, "an idle buffer did not count as input")
        let generation = h.buffer.begin(requestID: Fixture.requestID)
        h.advance()
        h.pipeline.process(h.input([0.1, 0.1]))
        h.pipeline.process(h.input([0.1]))
        h.pipeline.process(h.input([0.1, 0.1]))
        TestSupport.expectEqual(h.events.current, [.started(generation: generation), .reachedLimit(generation: generation)])
        h.pipeline.resetClock()
        TestSupport.expectEqual(h.pipeline.clock.lastBufferAt, nil)
    }
}

/// A buffer, pipeline and converter sharing a fake host clock in nanoseconds.
private final class PipelineHarness {
    struct Input: CaptureInput, Sendable {
        var samples: [Float]
        var hostTime: UInt64?
        var sampleTime: Int64?
        var sampleRate: Double { DictationSampleBuffer.sampleRate }
        var frameCount: Int { samples.count }

        init(samples: [Float], hostTime: UInt64?, sampleTime: Int64? = nil) {
            self.samples = samples
            self.hostTime = hostTime
            self.sampleTime = sampleTime
        }

        func slice(_ frames: Range<Int>) -> Input? {
            frames.isEmpty ? nil : Input(samples: Array(samples[frames]), hostTime: nil)
        }
    }

    let clock = Locked<UInt64>(1_000_000_000)
    let events = Locked<[CaptureEvent]>([])
    let buffer: DictationSampleBuffer
    let converter = FakeConverter()
    let pipeline: CapturePipeline<FakeConverter>

    init(maxDuration: TimeInterval = DictationProtocol.maxDictationDuration) {
        let clock = self.clock
        let events = self.events
        buffer = DictationSampleBuffer(maxDuration: maxDuration, hostClock: { clock.current })
        pipeline = CapturePipeline(buffer: buffer, converter: converter, ticksPerSecond: 1_000_000_000,
                                   hostClock: { clock.current }) { event in events.update { $0.append(event) } }
    }

    func advance(by nanoseconds: UInt64 = 10_000_000) { clock.update { $0 += nanoseconds } }

    /// Samples captured just now, after any begin recorded before this call.
    func input(_ samples: [Float]) -> Input {
        Input(samples: samples, hostTime: clock.current)
    }

    func processOnAnotherThread(_ input: Input) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        let pipeline = self.pipeline
        Thread {
            pipeline.process(input)
            done.signal()
        }.start()
        return done
    }
}

/// Identity "conversion" that keeps the last input as its state, with a log, a failure switch and a gate
/// that holds one conversion open.
private final class FakeConverter: SampleConverter, @unchecked Sendable {
    enum Call: Equatable { case convert, reset }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var history: [[Float]] = []
    private var current: [Float] = []
    private var shouldFail = false
    private var pauseNext = false
    private let paused = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)

    var log: [Call] { withLock { calls } }
    /// What a resampler would carry into the next conversion.
    var state: [Float] { withLock { current } }
    var converted: [[Float]] { withLock { history } }
    var failing: Bool {
        get { withLock { shouldFail } }
        set { withLock { shouldFail = newValue } }
    }

    func pauseNextConversion() { withLock { pauseNext = true } }
    func waitUntilPaused() -> Bool { paused.wait(timeout: .now() + 5) == .success }
    func resume() { gate.signal() }

    func convert(_ input: PipelineHarness.Input) -> [Float]? {
        let (pause, fail) = withLock { () -> (Bool, Bool) in
            calls.append(.convert)
            defer { pauseNext = false }
            return (pauseNext, shouldFail)
        }
        if pause {
            paused.signal()
            gate.wait()
        }
        return withLock {
            current = input.samples
            if fail { return nil }
            history.append(input.samples)
            return input.samples
        }
    }

    func reset() {
        withLock {
            calls.append(.reset)
            current = []
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
