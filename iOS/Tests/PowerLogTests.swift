import Foundation

/// The power log's pure core (ARCHITECTURE.md, "Power log"): the CSV model and encoding, rotation, the
/// file store and the host-state mapping. All samples are invented.
enum PowerLogTests {
    static var tests: [TestCase] {
        [
            ("headerAndSchemaLine", testHeaderAndSchemaLine),
            ("enumSpellings", testEnumSpellings),
            ("encodesAStableLine", testEncodesAStableLine),
            ("roundTrips", testRoundTrips),
            ("decimalPointIsLocaleIndependent", testDecimalPointIsLocaleIndependent),
            ("textFieldsCannotBreakTheRow", testTextFieldsCannotBreakTheRow),
            ("parseSkipsCommentsBlankMalformedAndTruncated", testParseSkipsCommentsBlankMalformedAndTruncated),
            ("rotationDecisionAt4MB", testRotationDecisionAt4MB),
            ("filesRotateKeepingOneOlderFile", testFilesRotateKeepingOneOlderFile),
            ("filesWithAnotherHeaderAreRotated", testFilesWithAnotherHeaderAreRotated),
            ("filesAreExcludedFromBackupAndClear", testFilesAreExcludedFromBackupAndClear),
            ("hostStateFromStatus", testHostStateFromStatus),
            ("readsSchema1Files", testReadsSchema1Files),
        ]
    }

    static let expectedColumns = [
        "wall_time", "uptime_s", "trigger", "host_state", "app_state", "battery_level", "battery_state",
        "low_power_mode", "thermal_state", "cpu_user_s", "cpu_system_s", "memory_mb", "memory_peak_mb",
        "compute_units", "build", "device", "always_on", "protected_data",
    ]

    /// Schema 1, before the always-on mode: still read.
    static let schema1Header = "wall_time,uptime_s,trigger,host_state,app_state,battery_level,battery_state,low_power_mode,thermal_state,cpu_user_s,cpu_system_s,memory_mb,memory_peak_mb,compute_units,build,device"

    private static func testHeaderAndSchemaLine() {
        TestSupport.expectEqual(PowerLogCSV.columns, expectedColumns)
        TestSupport.expectEqual(PowerLogCSV.schema, 2)
        TestSupport.expectEqual(PowerLogCSV.header, expectedColumns.joined(separator: ","))
        TestSupport.expectEqual(PowerLogCSV.schemaLine, "# schema=2")
        TestSupport.expectEqual(PowerLogCSV.preamble, expectedColumns.joined(separator: ",") + "\n# schema=2\n")
    }

    private static func testEnumSpellings() {
        TestSupport.expectEqual(PowerTrigger.allCases.map(\.rawValue),
                                ["periodic", "state", "battery", "thermal", "powerMode", "launch", "foreground",
                                 "background", "terminate", "protectedData"])
        TestSupport.expectEqual(PowerProtectedData.allCases.map(\.rawValue), ["available", "unavailable"])
        TestSupport.expectEqual(PowerHostState.allCases.map(\.rawValue),
                                ["idle", "micOpen", "recording", "transcribing", "preparing"])
        TestSupport.expectEqual(PowerAppState.allCases.map(\.rawValue), ["foreground", "background"])
        TestSupport.expectEqual(PowerBatteryState.allCases.map(\.rawValue), ["unplugged", "charging", "full", "unknown"])
        TestSupport.expectEqual(PowerThermalState.allCases.map(\.rawValue), ["nominal", "fair", "serious", "critical"])
    }

    /// Column order and spellings are the schema: an agent parses these files.
    private static func testEncodesAStableLine() {
        let sample = PowerSample(
            wallTime: Date(timeIntervalSince1970: 1_800_000_000.25), uptime: 12_345.678, trigger: .state,
            hostState: .micOpen, appState: .background, batteryLevel: 0.85, batteryState: .unplugged,
            lowPowerMode: false, thermalState: .fair, cpuUserSeconds: 12.5, cpuSystemSeconds: 3.25,
            memoryMB: 165.43, memoryPeakMB: 170, computeUnits: .cpuAndNeuralEngine, build: "42", device: "iPhone16,1",
            alwaysOn: true, protectedData: .unavailable)
        TestSupport.expectEqual(
            PowerLogCSV.line(sample),
            "2027-01-15T08:00:00.250Z,12345.678,state,micOpen,background,0.850,unplugged,false,fair,12.500,3.250,165.4,170.0,cpuAndNeuralEngine,42,\"iPhone16,1\",true,unavailable")

        var unknown = sample
        unknown.batteryLevel = -1
        unknown.batteryState = .unknown
        unknown.lowPowerMode = true
        unknown.memoryMB = nil
        unknown.memoryPeakMB = nil
        unknown.computeUnits = nil
        unknown.device = "arm64"
        unknown.alwaysOn = false
        unknown.protectedData = nil
        TestSupport.expectEqual(
            PowerLogCSV.line(unknown),
            "2027-01-15T08:00:00.250Z,12345.678,state,micOpen,background,-1,unknown,true,fair,12.500,3.250,,,,42,arm64,false,")
    }

    private static func testRoundTrips() {
        let samples = [
            PowerSynthetic.sample(0, .launch),
            PowerSynthetic.sample(60, .state, host: .recording, level: -1, battery: .unknown, cpu: 1.5),
            PowerSynthetic.sample(61.5, .terminate, host: .transcribing, app: .background, level: 0.42,
                                  battery: .charging, cpu: 2.5, lowPower: true, thermal: .critical, units: .cpuOnly,
                                  alwaysOn: true, protected: .unavailable),
            PowerSynthetic.sample(70, .protectedData, host: .micOpen, app: .background, alwaysOn: true, protected: nil),
        ]
        for sample in samples {
            TestSupport.expectEqual(PowerLogCSV.sample(fromLine: PowerLogCSV.line(sample)), sample)
        }
        let text = PowerLogCSV.preamble + samples.map { PowerLogCSV.line($0) + "\n" }.joined()
        TestSupport.expectEqual(PowerLogCSV.parse(text), samples)
    }

    private static func testDecimalPointIsLocaleIndependent() {
        TestSupport.expectEqual(PowerLogCSV.decimal(1234.5, places: 3), "1234.500")
        TestSupport.expectEqual(PowerLogCSV.decimal(0.05, places: 2), "0.05")
        TestSupport.expectEqual(PowerLogCSV.decimal(-0.0004, places: 3), "0.000")   // never "-0.000"
        let line = PowerLogCSV.line(PowerSynthetic.sample(1, uptime: 1234.5))
        TestSupport.expect(line.contains(",1234.500,"), "decimal point and no grouping in \(line)")
        // A number written with a decimal comma (or grouping) is malformed, not reinterpreted.
        let comma = line.replacingOccurrences(of: ",1234.500,", with: ",\"1234,500\",")
        TestSupport.expectEqual(PowerLogCSV.sample(fromLine: comma), nil)
    }

    /// Build and device are the only text; they can never add a row, a column or content.
    private static func testTextFieldsCannotBreakTheRow() {
        var sample = PowerSynthetic.sample(5)
        sample.build = "4\n2\"x"
        sample.device = "iPhone,\r\n\"Pro\""
        let line = PowerLogCSV.line(sample)
        TestSupport.expect(!line.contains("\n") && !line.contains("\r"), "one physical line: \(line)")
        let decoded = PowerLogCSV.sample(fromLine: line)
        TestSupport.expectEqual(decoded?.build, "42\"x")
        TestSupport.expectEqual(decoded?.device, "iPhone,\"Pro\"")
        TestSupport.expectEqual(PowerLogCSV.parse(PowerLogCSV.preamble + line + "\n").count, 1)
    }

    private static func testParseSkipsCommentsBlankMalformedAndTruncated() {
        let a = PowerSynthetic.sample(0, .launch)
        let b = PowerSynthetic.sample(60, host: .micOpen)
        let c = PowerSynthetic.sample(120, host: .micOpen, app: .background)
        let lineC = PowerLogCSV.line(c)
        var unknownEnum = PowerLogCSV.line(b)
        unknownEnum = unknownEnum.replacingOccurrences(of: ",micOpen,", with: ",dozing,")
        let text = PowerLogCSV.preamble
            + PowerLogCSV.line(a) + "\n"
            + "\n"
            + "# a comment\n"
            + "not,a,sample\n"
            + unknownEnum + "\n"
            + PowerLogCSV.line(b) + "\r\n"
            + String(lineC.prefix(30)) + "\n"   // malformed: too few columns
            + lineC                              // truncated: no final newline, so never trusted
        TestSupport.expectEqual(PowerLogCSV.parse(text), [a, b])
        TestSupport.expectEqual(PowerLogCSV.parse(""), [])
        TestSupport.expectEqual(PowerLogCSV.parse(PowerLogCSV.preamble), [])
        TestSupport.expectEqual(PowerLogCSV.parse(PowerLogCSV.preamble + lineC + "\n"), [c])
    }

    private static func testRotationDecisionAt4MB() {
        let limit = 4 * 1_048_576
        TestSupport.expectEqual(PowerLogRotation.limitBytes, limit)
        TestSupport.expect(!PowerLogRotation.shouldRotate(existingBytes: 0, appendingBytes: limit * 2),
                           "an empty file is written, not rotated")
        TestSupport.expect(!PowerLogRotation.shouldRotate(existingBytes: limit - 100, appendingBytes: 100),
                           "exactly at the limit stays")
        TestSupport.expect(PowerLogRotation.shouldRotate(existingBytes: limit - 100, appendingBytes: 101),
                           "past the limit rotates")
        TestSupport.expect(PowerLogRotation.shouldRotate(existingBytes: limit, appendingBytes: 1), "a full file rotates")
        TestSupport.expect(!PowerLogRotation.shouldRotate(existingBytes: 10, appendingBytes: 10, limit: 20), "custom limit")
        TestSupport.expect(PowerLogRotation.shouldRotate(existingBytes: 11, appendingBytes: 10, limit: 20), "custom limit")
    }

    private static func testFilesRotateKeepingOneOlderFile() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = (0 ..< 12).map { PowerSynthetic.sample(Double($0) * 60) }
        let lineBytes = PowerLogCSV.line(samples[0]).utf8.count + 1
        let preambleBytes = PowerLogCSV.preamble.utf8.count
        // Room for the preamble and three rows per file.
        let files = PowerLogFiles(directory: directory.appendingPathComponent("PowerLog"), fileName: "log.csv",
                                  rotatedFileName: "log.1.csv", limitBytes: preambleBytes + 3 * lineBytes)
        TestSupport.expectEqual(files.existingFiles, [])
        TestSupport.expectEqual(files.totalBytes, 0)
        TestSupport.expectEqual(files.readSamples(), [])

        try! files.append(Array(samples[0 ..< 2]))
        TestSupport.expectEqual(files.existingFiles, [files.currentURL])
        TestSupport.expectEqual(files.readSamples(), Array(samples[0 ..< 2]))
        let first = try! String(contentsOf: files.currentURL, encoding: .utf8)
        TestSupport.expect(first.hasPrefix(PowerLogCSV.preamble), "a new file starts with the header and schema line")

        try! files.append([samples[2]])
        TestSupport.expectEqual(files.existingFiles, [files.currentURL])   // exactly full
        try! files.append([samples[3]])
        TestSupport.expectEqual(files.existingFiles, [files.rotatedURL, files.currentURL])
        TestSupport.expectEqual(files.readSamples(), Array(samples[0 ..< 4]))
        let second = try! String(contentsOf: files.currentURL, encoding: .utf8)
        TestSupport.expectEqual(second, PowerLogCSV.preamble + PowerLogCSV.line(samples[3]) + "\n")

        // A second rotation replaces the older file: one older file is kept.
        try! files.append(Array(samples[4 ..< 6]))
        try! files.append(Array(samples[6 ..< 8]))
        TestSupport.expectEqual(files.readSamples(), Array(samples[3 ..< 8]))
        TestSupport.expectEqual(files.totalBytes, 2 * preambleBytes + 5 * lineBytes)
    }

    private static func testFilesWithAnotherHeaderAreRotated() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = PowerLogFiles(directory: directory, fileName: "log.csv", rotatedFileName: "log.1.csv")
        try! "wall_time,old_column\n# schema=0\n2027-01-15T08:00:00Z,1\n".write(to: files.currentURL, atomically: true,
                                                                                 encoding: .utf8)
        let sample = PowerSynthetic.sample(0, .launch)
        try! files.append([sample])
        TestSupport.expectEqual(files.existingFiles, [files.rotatedURL, files.currentURL])
        TestSupport.expectEqual(try! String(contentsOf: files.currentURL, encoding: .utf8),
                                PowerLogCSV.preamble + PowerLogCSV.line(sample) + "\n")
        TestSupport.expectEqual(files.readSamples(), [sample])   // the old schema's rows are not misread
    }

    private static func testFilesAreExcludedFromBackupAndClear() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logDirectory = directory.appendingPathComponent("PowerLog", isDirectory: true)
        let files = PowerLogFiles(directory: logDirectory, fileName: "log.csv", rotatedFileName: "log.1.csv",
                                  limitBytes: 200)
        try! files.append([PowerSynthetic.sample(0)])
        try! files.append([PowerSynthetic.sample(1)])   // past the 200-byte limit: rotates
        TestSupport.expectEqual(files.existingFiles.count, 2)
        for url in [logDirectory] + files.existingFiles {
            let excluded = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            TestSupport.expect(excluded == true, "\(url.lastPathComponent) is excluded from backup")
        }
        TestSupport.expectEqual(files.clear(), .cleared)
        TestSupport.expectEqual(files.existingFiles, [])
        TestSupport.expectEqual(files.totalBytes, 0)
        TestSupport.expectEqual(files.readSamples(), [])
        TestSupport.expectEqual(files.clear(), .cleared)   // clearing nothing is fine
        try! files.append([PowerSynthetic.sample(9)])
        TestSupport.expectEqual(files.readSamples(), [PowerSynthetic.sample(9)])
    }

    private static func testHostStateFromStatus() {
        func state(_ session: HostStatus.Session, _ phase: DictationStatus.Phase? = nil,
                   model: HostStatus.Model = .ready) -> PowerHostState {
            var status = Fixture.status(session, dictation: phase.map { Fixture.dictation($0) })
            status.model = model
            return PowerHostState(status: status)
        }
        TestSupport.expectEqual(state(.inactive), .idle)
        TestSupport.expectEqual(state(.inactive, model: .notPrepared), .idle)
        TestSupport.expectEqual(state(.starting), .micOpen)
        TestSupport.expectEqual(state(.active), .micOpen)
        TestSupport.expectEqual(state(.active, .starting), .recording)
        TestSupport.expectEqual(state(.active, .recording), .recording)
        TestSupport.expectEqual(state(.active, .transcribing), .transcribing)
        for terminal in [DictationStatus.Phase.completed, .failed, .cancelled] {
            TestSupport.expectEqual(state(.active, terminal), .micOpen)
            TestSupport.expectEqual(state(.inactive, terminal), .idle)
        }
        // Preparation (load or compile) dominates: its CPU must not be charged to a dictation.
        TestSupport.expectEqual(state(.inactive, model: .preparing), .preparing)
        TestSupport.expectEqual(state(.active, model: .preparing), .preparing)
        TestSupport.expectEqual(state(.active, .transcribing, model: .preparing), .preparing)
        TestSupport.expectEqual(state(.active, .recording, model: .preparing), .preparing)
    }
}


extension PowerLogTests {
    /// Files written before schema 2 (no always_on or protected_data) still read: the mode was off, and
    /// protected data was not recorded. Appending to such a file rotates it, and both files read.
    fileprivate static func testReadsSchema1Files() {
        let line = "2027-01-15T08:00:00.250Z,12345.678,state,micOpen,background,0.850,unplugged,false,fair,12.500,3.250,165.4,170.0,cpuAndNeuralEngine,42,\"iPhone16,1\""
        let text = schema1Header + "\n# schema=1\n" + line + "\n"
        let expected = PowerSample(
            wallTime: Date(timeIntervalSince1970: 1_800_000_000.25), uptime: 12_345.678, trigger: .state,
            hostState: .micOpen, appState: .background, batteryLevel: 0.85, batteryState: .unplugged,
            lowPowerMode: false, thermalState: .fair, cpuUserSeconds: 12.5, cpuSystemSeconds: 3.25,
            memoryMB: 165.4, memoryPeakMB: 170, computeUnits: .cpuAndNeuralEngine, build: "42", device: "iPhone16,1",
            alwaysOn: false, protectedData: nil)
        TestSupport.expectEqual(PowerLogCSV.parse(text), [expected])
        // A schema 2 row under a schema 1 header (or the reverse) does not parse.
        let two = PowerLogCSV.line(PowerSynthetic.sample(1))
        TestSupport.expectEqual(PowerLogCSV.parse(schema1Header + "\n# schema=1\n" + two + "\n"), [])
        TestSupport.expectEqual(PowerLogCSV.parse(PowerLogCSV.preamble + line + "\n"), [])

        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = PowerLogFiles(directory: directory, fileName: "log.csv", rotatedFileName: "log.1.csv")
        try! text.write(to: files.currentURL, atomically: true, encoding: .utf8)
        let next = PowerSynthetic.sample(60, alwaysOn: true)
        try! files.append([next])
        TestSupport.expectEqual(files.existingFiles, [files.rotatedURL, files.currentURL])
        TestSupport.expectEqual(files.readSamples(), [expected, next])
    }
}

/// Invented samples. `t` is seconds since the start of a synthetic process run; wall time follows it
/// unless given. CPU is split 3:1 between user and system.
enum PowerSynthetic {
    static let wallBase = Date(timeIntervalSince1970: 1_800_000_000)
    static let uptimeBase: TimeInterval = 1_000

    static func sample(_ t: TimeInterval, _ trigger: PowerTrigger = .periodic, host: PowerHostState = .idle,
                       app: PowerAppState = .foreground, level: Double = 0.8, battery: PowerBatteryState = .unplugged,
                       cpu: Double = 0, wall: TimeInterval? = nil, uptime: TimeInterval? = nil,
                       lowPower: Bool = false, thermal: PowerThermalState = .nominal,
                       units: ComputePolicy.Units? = nil, alwaysOn: Bool = false,
                       protected: PowerProtectedData? = .available) -> PowerSample {
        PowerSample(wallTime: wallBase.addingTimeInterval(wall ?? t), uptime: uptime ?? uptimeBase + t, trigger: trigger,
                    hostState: host, appState: app, batteryLevel: level, batteryState: battery, lowPowerMode: lowPower,
                    thermalState: thermal, cpuUserSeconds: cpu * 0.75, cpuSystemSeconds: cpu * 0.25,
                    memoryMB: 120.5, memoryPeakMB: 166.0, computeUnits: units, build: "1", device: "iPhone16,1",
                    alwaysOn: alwaysOn, protectedData: protected)
    }
}
