import Foundation

/// The power log summary (ARCHITECTURE.md, "Power log"): per-state totals, the background
/// microphone drain and the inactive-gap baseline as two observed rates (never a projection), CPU per
/// transcription, charging exclusion and the confidence threshold. All samples are invented.
enum PowerLogSummaryTests {
    static var tests: [TestCase] {
        [
            ("emptyLog", testEmptyLog),
            ("perStateTimeCPUAndBattery", testPerStateTimeCPUAndBattery),
            ("observedRatesStayApart", testObservedRatesStayApart),
            ("labelsSayWhatTheRatesAreNot", testLabelsSayWhatTheRatesAreNot),
            ("lockedAlwaysOnRateIsSeparate", testLockedAlwaysOnRateIsSeparate),
            ("confidenceThreshold", testConfidenceThreshold),
            ("chargingIsExcludedFromDrain", testChargingIsExcludedFromDrain),
            ("unknownBatteryLevelIsExcludedFromDrain", testUnknownBatteryLevelIsExcludedFromDrain),
            ("uptimeWithinARunWallTimeAcrossGaps", testUptimeWithinARunWallTimeAcrossGaps),
            ("processRestartResetsCPU", testProcessRestartResetsCPU),
            ("cpuPerTranscription", testCPUPerTranscription),
            ("suspendedWhileBackgroundIdleIsInactive", testSuspendedWhileBackgroundIdleIsInactive),
            ("unexplainedSilenceIsUnknown", testUnexplainedSilenceIsUnknown),
            ("truncatedLastLineIsIgnored", testTruncatedLastLineIsIgnored),
        ]
    }

    private typealias S = PowerSynthetic

    private static func expectClose(_ actual: Double?, _ expected: Double, _ what: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else {
            TestSupport.expect(false, "\(what): expected \(expected), got nil", file: file, line: line)
            return
        }
        TestSupport.expect(abs(actual - expected) < 1e-6, "\(what): expected \(expected), got \(actual)",
                           file: file, line: line)
    }

    /// A background micOpen stretch sampled every 60 s from `start` for `minutes`, with the battery level
    /// dropping linearly by `points` percentage points, quantized to whole percent as iOS reports it.
    private static func micOpenStretch(from start: TimeInterval, minutes: Int, startLevel: Double, points: Double,
                                       cpuStart: Double = 0, cpuPerMinute: Double = 0.01) -> [PowerSample] {
        (0 ... minutes).map { minute in
            let dropped = (points * Double(minute) / Double(minutes)).rounded(.down)
            let level = ((startLevel * 100 - dropped).rounded()) / 100
            return S.sample(start + Double(minute) * 60, minute == 0 ? .state : .periodic, host: .micOpen,
                            app: .background, level: level, cpu: cpuStart + Double(minute) * cpuPerMinute)
        }
    }

    private static func testEmptyLog() {
        for samples in [[], [S.sample(0, .launch)]] {
            let summary = PowerLogSummary(samples: samples)
            TestSupport.expectEqual(summary.sampleCount, samples.count)
            TestSupport.expectEqual(summary.states, [:])
            TestSupport.expectEqual(summary.inactive, PowerLogSummary.Totals())
            TestSupport.expectEqual(summary.micOpenBackground.percentPerHour, nil)
            TestSupport.expectEqual(summary.baseline.percentPerHour, nil)
            TestSupport.expectEqual(summary.transcriptions, 0)
            TestSupport.expectEqual(summary.cpuSecondsPerTranscription, nil)
        }
        TestSupport.expectEqual(PowerLogSummary(samples: []).span, nil)
        TestSupport.expectEqual(PowerLogSummary(samples: [S.sample(0, .launch)]).span,
                                DateInterval(start: S.wallBase, duration: 0))
    }

    /// Each interval between consecutive samples belongs to the state of its first sample.
    private static func testPerStateTimeCPUAndBattery() {
        let samples = [
            S.sample(0, .launch, level: 0.80, cpu: 0.5),
            S.sample(60, .state, host: .preparing, level: 0.80, cpu: 1.0),
            S.sample(65, .state, host: .micOpen, level: 0.80, cpu: 5.0),
            S.sample(125, .periodic, host: .micOpen, level: 0.79, cpu: 5.5),
            S.sample(130, .state, host: .recording, level: 0.79, cpu: 5.7),
            S.sample(140, .state, host: .transcribing, level: 0.79, cpu: 6.7),
            S.sample(141, .state, host: .micOpen, level: 0.78, cpu: 7.7),
            S.sample(200, .background, host: .micOpen, app: .background, level: 0.78, cpu: 7.8),
            S.sample(260, .periodic, host: .micOpen, app: .background, level: 0.77, cpu: 8.0),
        ]
        let summary = PowerLogSummary(samples: samples)
        let expected: [PowerHostState: PowerLogSummary.Totals] = [
            .idle: .init(seconds: 60, cpuSeconds: 0.5, drainSeconds: 60, drainPercent: 0),
            .preparing: .init(seconds: 5, cpuSeconds: 4, drainSeconds: 5, drainPercent: 0),
            .micOpen: .init(seconds: 60 + 5 + 59 + 60, cpuSeconds: 0.5 + 0.2 + 0.1 + 0.2,
                            drainSeconds: 184, drainPercent: 1 + 0 + 0 + 1),
            .recording: .init(seconds: 10, cpuSeconds: 1, drainSeconds: 10, drainPercent: 0),
            .transcribing: .init(seconds: 1, cpuSeconds: 1, drainSeconds: 1, drainPercent: 1),
        ]
        TestSupport.expectEqual(Set(summary.states.keys), Set(expected.keys))
        for (state, totals) in expected {
            let actual = summary.states[state] ?? .init()
            expectClose(actual.seconds, totals.seconds, "\(state) seconds")
            expectClose(actual.cpuSeconds, totals.cpuSeconds, "\(state) CPU")
            expectClose(actual.drainSeconds, totals.drainSeconds, "\(state) drain seconds")
            expectClose(actual.drainPercent, totals.drainPercent, "\(state) drain percent")
        }
        // Only the background micOpen stretch feeds the always-open figure.
        expectClose(summary.micOpenBackground.seconds, 60, "background micOpen seconds")
        expectClose(summary.micOpenBackground.percent, 1, "background micOpen drop")
        TestSupport.expectEqual(summary.span, DateInterval(start: S.wallBase, duration: 260))
        TestSupport.expectEqual(summary.sampleCount, samples.count)
    }

    /// 2 h of background micOpen losing 10 points, then 4 h suspended losing 4 points: two observed rates,
    /// 5 %/h and 1 %/h. Their difference is not the microphone's cost (the screen differs), so the summary
    /// offers no projection; only matched runs measure it.
    private static func testObservedRatesStayApart() {
        var samples = [S.sample(0, .launch, level: 0.90)]
        samples += micOpenStretch(from: 10, minutes: 120, startLevel: 0.90, points: 10)
        let end = 10 + 120 * 60.0
        // The session expires in the background: the app is suspended until the user opens it 4 h later.
        samples.append(S.sample(end, .state, host: .idle, app: .background, level: 0.80, cpu: 1.2))
        samples.append(S.sample(end + 4 * 3600, .foreground, host: .idle, app: .foreground, level: 0.76, cpu: 1.2))
        let summary = PowerLogSummary(samples: samples)
        expectClose(summary.micOpenBackground.seconds, 7200, "micOpen seconds")
        expectClose(summary.micOpenBackground.percent, 10, "micOpen drop")
        expectClose(summary.micOpenBackground.percentPerHour, 5, "micOpen rate")
        expectClose(summary.inactive.seconds, 4 * 3600, "inactive seconds")
        expectClose(summary.baseline.seconds, 4 * 3600, "baseline seconds")
        expectClose(summary.baseline.percent, 4, "baseline drop")
        expectClose(summary.baseline.percentPerHour, 1, "baseline rate")
        // Suspended time is never charged to a host state.
        expectClose(summary.states[.idle]?.seconds, 10, "foreground idle seconds")
    }

    /// A drain figure needs at least 1 h of qualifying time and at least 3 points of drop.
    private static func testConfidenceThreshold() {
        func figure(minutes: Int, points: Double) -> PowerLogSummary.Drain {
            PowerLogSummary(samples: micOpenStretch(from: 0, minutes: minutes, startLevel: 0.9, points: points)).micOpenBackground
        }
        let short = figure(minutes: 59, points: 10)
        TestSupport.expect(!short.isConfident && short.percentPerHour == nil, "59 min is not enough")
        expectClose(short.percent, 10, "the raw drop is still reported")
        let shallow = figure(minutes: 180, points: 2)
        TestSupport.expect(!shallow.isConfident && shallow.percentPerHour == nil, "2 points are not enough")
        let enough = figure(minutes: 60, points: 3)
        TestSupport.expect(enough.isConfident, "exactly 1 h and 3 points is enough")
        expectClose(enough.percentPerHour, 3, "rate")
        TestSupport.expectEqual(PowerLogSummary.Drain.minimumSeconds, 3600)
        TestSupport.expectEqual(PowerLogSummary.Drain.minimumPercent, 3)
    }

    /// The exact wording the Diagnostics section shows (ARCHITECTURE.md, "No automatic projection" and
    /// "Gaps").
    private static func testLabelsSayWhatTheRatesAreNot() {
        TestSupport.expectEqual(PowerLogSummary.observedDrainNote,
                                "Observed whole-device drain; screen conditions differ. Microphone cost requires matched runs.")
        TestSupport.expectEqual(PowerLogSummary.gapNote,
                                "Gaps are uncontrolled: the phone may have charged in between, so this is not a measurement.")
    }

    /// Always-on, locked, with the microphone open: its own observed rate. Locked time never counts toward
    /// the unlocked background figure, and locked micOpen without the mode (a lock just ending a session)
    /// counts toward neither.
    private static func testLockedAlwaysOnRateIsSeparate() {
        var samples = [S.sample(0, .state, host: .micOpen, app: .background, level: 0.90, alwaysOn: true)]
        // Locked for 2 h, losing 6 points, sampled each minute.
        samples += (0 ... 120).map { minute in
            let level = ((90 - (6 * Double(minute) / 120).rounded(.down)).rounded()) / 100
            return S.sample(60 + Double(minute) * 60, minute == 0 ? .protectedData : .periodic, host: .micOpen,
                            app: .background, level: level, alwaysOn: true, protected: .unavailable)
        }
        let unlock = 60 + 120 * 60.0
        samples.append(S.sample(unlock, .protectedData, host: .micOpen, app: .background, level: 0.84, alwaysOn: true))
        samples.append(S.sample(unlock + 60, .periodic, host: .micOpen, app: .background, level: 0.84,
                                alwaysOn: false, protected: .unavailable))
        samples.append(S.sample(unlock + 120, .state, host: .idle, app: .background, level: 0.84,
                                protected: .unavailable))
        let summary = PowerLogSummary(samples: samples)
        expectClose(summary.micOpenLockedAlwaysOn.seconds, 7_200, "locked always-on seconds")
        expectClose(summary.micOpenLockedAlwaysOn.percent, 6, "locked always-on drop")
        expectClose(summary.micOpenLockedAlwaysOn.percentPerHour, 3, "locked always-on rate")
        expectClose(summary.micOpenBackground.seconds, 60 + 60, "unlocked background micOpen only")
        expectClose(summary.states[.micOpen]?.seconds, 60 + 7_200 + 60 + 60, "all micOpen time still counts")
    }

    private static func testChargingIsExcludedFromDrain() {
        let samples = [
            S.sample(0, .state, host: .micOpen, app: .background, level: 0.50),
            S.sample(60, .battery, host: .micOpen, app: .background, level: 0.49, battery: .charging),
            S.sample(120, .periodic, host: .micOpen, app: .background, level: 0.55, battery: .charging),
            S.sample(180, .battery, host: .micOpen, app: .background, level: 0.60, battery: .full),
            S.sample(240, .battery, host: .micOpen, app: .background, level: 0.60, battery: .unplugged),
            // Suspended, charged and unplugged again in between: the level rose although both ends are
            // unplugged, so the gap cannot be a drain measurement.
            S.sample(300, .state, host: .idle, app: .background, level: 0.59),
            S.sample(300 + 7200, .foreground, level: 0.95),
        ]
        let summary = PowerLogSummary(samples: samples)
        expectClose(summary.states[.micOpen]?.seconds, 300, "time still counts while charging")
        expectClose(summary.micOpenBackground.seconds, 60, "only unplugged-to-unplugged intervals qualify")
        expectClose(summary.micOpenBackground.percent, 1, "drop")
        expectClose(summary.inactive.seconds, 7200, "the gap is inactive time")
        expectClose(summary.baseline.seconds, 0, "but not a drain measurement")
        expectClose(summary.pluggedInSeconds, 240 + 7200, "excluded time is reported")
    }

    private static func testUnknownBatteryLevelIsExcludedFromDrain() {
        let samples = [
            S.sample(0, .state, host: .micOpen, app: .background, level: 0.70),
            S.sample(600, .periodic, host: .micOpen, app: .background, level: -1, battery: .unknown),
            S.sample(1200, .periodic, host: .micOpen, app: .background, level: -1, battery: .unplugged),
            S.sample(1800, .periodic, host: .micOpen, app: .background, level: 0.68),
            S.sample(2400, .periodic, host: .micOpen, app: .background, level: 0.67),
        ]
        let summary = PowerLogSummary(samples: samples, maxAwakeInterval: 900)
        expectClose(summary.states[.micOpen]?.seconds, 2400, "time counts")
        expectClose(summary.micOpenBackground.seconds, 600, "only known-to-known levels qualify")
        expectClose(summary.micOpenBackground.percent, 1, "drop")
    }

    /// Within a run, durations come from monotonic uptime, so a wall-clock change does not distort them.
    /// Across a gap (a new run), only wall time exists; a negative gap is unusable.
    private static func testUptimeWithinARunWallTimeAcrossGaps() {
        let samples = [
            S.sample(0, .launch, host: .idle, level: 0.8),
            S.sample(60, .periodic, wall: 60 - 3600),          // the clock was set back an hour
            S.sample(120, .periodic, wall: 120 + 86_400),      // then forward a day
            S.sample(180, .background, app: .background, wall: 180 + 86_400),
            // Relaunch: wall time continues from the last change; uptime restarted (a reboot).
            S.sample(0, .launch, level: 0.78, wall: 180 + 86_400 + 3600, uptime: 50),
            S.sample(60, .background, app: .background, level: 0.78, wall: 240 + 86_400 + 3600, uptime: 110),
            // The clock went backwards across a gap: the gap has no usable duration.
            S.sample(0, .launch, level: 0.75, wall: 0, uptime: 20),
        ]
        let summary = PowerLogSummary(samples: samples)
        expectClose(summary.states[.idle]?.seconds, 180 + 60, "foreground idle by uptime")
        expectClose(summary.inactive.seconds, 3600, "the first gap by wall time")
        expectClose(summary.inactive.drainPercent, 2, "drop over the gap")
        expectClose(summary.unknownSeconds, 0, "a negative gap adds no time anywhere")
        TestSupport.expectEqual(summary.runs, 3)
    }

    /// Cumulative CPU time restarts with the process; a drop never becomes negative CPU, even when the
    /// launch row was lost.
    private static func testProcessRestartResetsCPU() {
        let samples = [
            S.sample(0, .launch, host: .micOpen, cpu: 0.2),
            S.sample(60, .periodic, host: .micOpen, cpu: 30.2),
            S.sample(120, .terminate, host: .micOpen, app: .background, cpu: 31.0),
            S.sample(0, .launch, host: .micOpen, cpu: 0.1, wall: 600, uptime: 1_600),
            S.sample(60, .periodic, host: .micOpen, cpu: 0.6, wall: 660, uptime: 1_660),
            // No launch row (lost with the buffer of a killed process), but uptime moved on and CPU fell.
            S.sample(0, .periodic, host: .micOpen, cpu: 0.3, wall: 900, uptime: 1_900),
            S.sample(60, .periodic, host: .micOpen, cpu: 0.4, wall: 960, uptime: 1_960),
        ]
        let summary = PowerLogSummary(samples: samples)
        expectClose(summary.states[.micOpen]?.cpuSeconds, 30 + 0.8 + 0.5 + 0.1, "CPU within runs only")
        expectClose(summary.states[.micOpen]?.seconds, 60 + 60 + 60 + 60, "time within runs only")
        expectClose(summary.inactive.seconds, 600 - 120, "after a terminate row the gap is inactive")
        expectClose(summary.unknownSeconds, 900 - 660, "a run that ended unannounced while active is unknown")
        TestSupport.expectEqual(summary.runs, 3)
    }

    private static func testCPUPerTranscription() {
        let samples = [
            S.sample(0, .launch, host: .micOpen, cpu: 0),
            S.sample(10, .state, host: .recording, cpu: 0.1),
            S.sample(15, .state, host: .transcribing, cpu: 0.2),
            S.sample(16, .state, host: .micOpen, cpu: 1.2),
            S.sample(30, .state, host: .recording, cpu: 1.3),
            S.sample(40, .state, host: .transcribing, app: .background, cpu: 1.4),
            S.sample(100, .periodic, host: .transcribing, app: .background, cpu: 3.0),   // one long transcription
            S.sample(101, .state, host: .micOpen, app: .background, cpu: 4.4),
        ]
        let summary = PowerLogSummary(samples: samples)
        TestSupport.expectEqual(summary.transcriptions, 2)
        expectClose(summary.states[.transcribing]?.cpuSeconds, 4, "transcribing CPU")
        expectClose(summary.cpuSecondsPerTranscription, 2, "CPU per transcription")
    }

    /// Background with no session means nothing keeps LocalFlow running: iOS suspends it, so the time
    /// until the next sample is the inactive baseline even within one process run.
    private static func testSuspendedWhileBackgroundIdleIsInactive() {
        let samples = [
            S.sample(0, .launch, level: 0.9),
            S.sample(30, .background, app: .background, level: 0.9),
            S.sample(30 + 3 * 3600, .foreground, level: 0.87),
            S.sample(30 + 3 * 3600 + 60, .periodic, level: 0.87),
        ]
        let summary = PowerLogSummary(samples: samples)
        expectClose(summary.inactive.seconds, 3 * 3600, "suspended time")
        expectClose(summary.baseline.percentPerHour, 1, "baseline rate")
        expectClose(summary.states[.idle]?.seconds, 90, "foreground idle")
        TestSupport.expectEqual(summary.runs, 1)
    }

    /// An awake state with no sample for far longer than the 60 s cadence was not really awake (or lost
    /// its rows); it is neither charged to the state nor used as a baseline.
    private static func testUnexplainedSilenceIsUnknown() {
        let samples = [
            S.sample(0, .state, host: .micOpen, app: .background, level: 0.9),
            S.sample(60, .periodic, host: .micOpen, app: .background, level: 0.9),
            S.sample(60 + 7200, .periodic, host: .micOpen, app: .background, level: 0.8),
            // Active when the process died: the gap to the relaunch is unknown too.
            S.sample(0, .launch, level: 0.7, wall: 60 + 7200 + 3600, uptime: 10),
        ]
        let summary = PowerLogSummary(samples: samples)
        expectClose(summary.states[.micOpen]?.seconds, 60, "only the sampled minute")
        expectClose(summary.micOpenBackground.seconds, 60, "drain seconds")
        expectClose(summary.unknownSeconds, 7200 + 3600, "unknown time")
        expectClose(summary.inactive.seconds, 0, "no baseline")
        TestSupport.expectEqual(PowerLogSummary.defaultMaxAwakeInterval, 600)
    }

    private static func testTruncatedLastLineIsIgnored() {
        let samples = micOpenStretch(from: 0, minutes: 120, startLevel: 0.9, points: 10)
        var text = PowerLogCSV.preamble + samples.map { PowerLogCSV.line($0) + "\n" }.joined()
        // A crash mid-write left half a row that would otherwise read as a level of 0.0.
        let extra = PowerLogCSV.line(S.sample(7300, .periodic, host: .micOpen, app: .background, level: 0.0))
        text += String(extra.prefix(extra.count - 20))
        let summary = PowerLogSummary(samples: PowerLogCSV.parse(text))
        TestSupport.expectEqual(summary.sampleCount, samples.count)
        expectClose(summary.micOpenBackground.percentPerHour, 5, "rate unaffected")
    }
}
