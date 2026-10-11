import Foundation

// The power log's model and CSV encoding (ARCHITECTURE.md, "Power log"; test builds only). Compiled
// and tested in every build, but only code behind `LOCALFLOW_POWER_LOG` calls it. A row holds numbers
// and enums only, plus the build number and the hardware model identifier: never text, audio,
// transcripts, field or app context, or other identifiers.

/// Why a sample was taken.
enum PowerTrigger: String, CaseIterable, Sendable {
    case periodic, state, battery, thermal, powerMode, launch, foreground, background, terminate
    /// Schema 2: protected data became unavailable (locked) or available again.
    case protectedData
}

/// `UIApplication.isProtectedDataAvailable`; unavailable means locked (a proxy for screen off).
enum PowerProtectedData: String, CaseIterable, Sendable { case available, unavailable }

/// The protected-data value power samples record. UIKit's property still reads available while
/// `protectedDataWillBecomeUnavailable` is delivered, and a dictation the lock cancels publishes a state
/// sample around then, before or after the recorder's own observer runs. So the lock notification latches
/// `unavailable` until `protectedDataDidBecomeAvailable`, and the host's own lock latch counts too.
struct ProtectedDataState: Sendable {
    private var latched = false

    mutating func willBecomeUnavailable() { latched = true }
    mutating func didBecomeAvailable() { latched = false }
    /// Arriving in front: with protected data available it is an unlock, as for the host core (a suspended
    /// app can miss the unlock notification).
    mutating func activated(protectedDataAvailable: Bool) { if protectedDataAvailable { latched = false } }

    func effective(reading available: Bool, hostLocked: Bool) -> PowerProtectedData {
        latched || hostLocked || !available ? .unavailable : .available
    }
}

/// What the host was doing, derived from its published status.
enum PowerHostState: String, CaseIterable, Sendable {
    /// No audio session.
    case idle
    /// The audio session is active, but no dictation is being captured.
    case micOpen
    case recording
    case transcribing
    /// The model is loading or compiling.
    case preparing

    /// Preparation dominates, so its CPU time is never charged to a dictation; then the dictation
    /// phase; then whether a session holds the audio session.
    init(status: HostStatus) {
        if status.model == .preparing {
            self = .preparing
            return
        }
        switch status.dictation?.phase {
        case .starting?, .recording?: self = .recording
        case .transcribing?: self = .transcribing
        case .completed?, .failed?, .cancelled?, nil: self = status.session == .inactive ? .idle : .micOpen
        }
    }
}

/// UIKit's application state, with `.inactive` counting as foreground as everywhere in the host.
enum PowerAppState: String, CaseIterable, Sendable { case foreground, background }

enum PowerBatteryState: String, CaseIterable, Sendable { case unplugged, charging, full, unknown }

enum PowerThermalState: String, CaseIterable, Sendable { case nominal, fair, serious, critical }

struct PowerSample: Equatable, Sendable {
    var wallTime: Date
    /// Seconds on a monotonic clock that keeps counting while the device sleeps. Comparable only within
    /// one process run.
    var uptime: TimeInterval
    var trigger: PowerTrigger
    var hostState: PowerHostState
    var appState: PowerAppState
    /// `UIDevice.batteryLevel` as reported: 0...1, or −1 when unknown.
    var batteryLevel: Double
    var batteryState: PowerBatteryState
    var lowPowerMode: Bool
    var thermalState: PowerThermalState
    /// Cumulative for the process (`getrusage(RUSAGE_SELF)`); restarts at zero with every launch.
    var cpuUserSeconds: Double
    var cpuSystemSeconds: Double
    var memoryMB: Double?
    var memoryPeakMB: Double?
    /// The loaded runtime's compute units, nil when no runtime is loaded.
    var computeUnits: ComputePolicy.Units?
    var build: String
    var device: String
    /// Schema 2: the always-on microphone test mode at sample time; false in schema 1 files.
    var alwaysOn = false
    /// Schema 2; nil in schema 1 files.
    var protectedData: PowerProtectedData? = nil

    var cpuSeconds: Double { cpuUserSeconds + cpuSystemSeconds }
}

/// Schema 2: a header row, a `# schema=2` line, then one row per sample. Schema 1 files (no `always_on`
/// or `protected_data`) still read. `.` is the decimal separator
/// whatever the locale; text fields are quoted when needed and never span lines.
enum PowerLogCSV {
    static let schema = 2
    static let columns = [
        "wall_time", "uptime_s", "trigger", "host_state", "app_state", "battery_level", "battery_state",
        "low_power_mode", "thermal_state", "cpu_user_s", "cpu_system_s", "memory_mb", "memory_peak_mb",
        "compute_units", "build", "device", "always_on", "protected_data",
    ]
    static let header = columns.joined(separator: ",")
    /// Schema 1's header: the first 16 columns.
    static let schema1Header = columns.prefix(16).joined(separator: ",")
    static let schemaLine = "# schema=\(schema)"
    static let preamble = header + "\n" + schemaLine + "\n"

    /// One row, without its line terminator.
    static func line(_ sample: PowerSample) -> String {
        [
            wallTimeFormatter.string(from: sample.wallTime),
            decimal(sample.uptime, places: 3),
            sample.trigger.rawValue,
            sample.hostState.rawValue,
            sample.appState.rawValue,
            sample.batteryLevel < 0 ? "-1" : decimal(sample.batteryLevel, places: 3),
            sample.batteryState.rawValue,
            sample.lowPowerMode ? "true" : "false",
            sample.thermalState.rawValue,
            decimal(sample.cpuUserSeconds, places: 3),
            decimal(sample.cpuSystemSeconds, places: 3),
            sample.memoryMB.map { decimal($0, places: 1) } ?? "",
            sample.memoryPeakMB.map { decimal($0, places: 1) } ?? "",
            sample.computeUnits?.rawValue ?? "",
            text(sample.build),
            text(sample.device),
            sample.alwaysOn ? "true" : "false",
            sample.protectedData?.rawValue ?? "",
        ].joined(separator: ",")
    }

    /// A fixed-point number with a `.` separator and no grouping, independent of the locale.
    static func decimal(_ value: Double, places: Int) -> String {
        let scale = pow(10, Double(places))
        let rounded = (value * scale).rounded() / scale
        return String(format: "%.\(places)f", locale: posix, rounded == 0 ? 0 : rounded)
    }

    /// Samples from a whole file, schema 2 or 1. Skips comments, blank lines, rows that do not parse, rows
    /// under a header of an unknown schema, and the last line unless it ends with a newline (a write cut
    /// short).
    static func parse(_ text: String) -> [PowerSample] {
        // "\r\n" is a single Character in Swift, so it is a separator of its own.
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        lines.removeLast()   // empty after a final newline, otherwise an unterminated (truncated) row
        var samples: [PowerSample] = []
        var readable: Int? = schema   // the schema rows are read as; nil under an unknown header
        for raw in lines {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("# schema="), let current = readable, line != "# schema=\(current)" { readable = nil }
                continue
            }
            if line.hasPrefix("wall_time,") {
                readable = line == header ? schema : line == schema1Header ? 1 : nil
                continue
            }
            if let readable, let sample = sample(fromLine: line, schema: readable) { samples.append(sample) }
        }
        return samples
    }

    static func sample<Line: StringProtocol>(fromLine line: Line, schema: Int = PowerLogCSV.schema) -> PowerSample? {
        guard schema == 1 || schema == 2, let fields = split(line), fields.count == (schema == 1 ? 16 : columns.count),
              let wallTime = parseWallTime(fields[0]),
              let uptime = number(fields[1]),
              let trigger = PowerTrigger(rawValue: fields[2]),
              let hostState = PowerHostState(rawValue: fields[3]),
              let appState = PowerAppState(rawValue: fields[4]),
              let batteryLevel = number(fields[5]),
              let batteryState = PowerBatteryState(rawValue: fields[6]),
              let lowPowerMode = ["false": false, "true": true][fields[7]],
              let thermalState = PowerThermalState(rawValue: fields[8]),
              let cpuUser = number(fields[9]),
              let cpuSystem = number(fields[10]),
              let memory = optionalNumber(fields[11]),
              let memoryPeak = optionalNumber(fields[12])
        else { return nil }
        let units: ComputePolicy.Units?
        if fields[13].isEmpty {
            units = nil
        } else {
            guard let parsed = ComputePolicy.Units(rawValue: fields[13]) else { return nil }
            units = parsed
        }
        var alwaysOn = false
        var protectedData: PowerProtectedData?
        if schema == 2 {
            guard let on = ["false": false, "true": true][fields[16]] else { return nil }
            alwaysOn = on
            if !fields[17].isEmpty {
                guard let parsed = PowerProtectedData(rawValue: fields[17]) else { return nil }
                protectedData = parsed
            }
        }
        return PowerSample(wallTime: wallTime, uptime: uptime, trigger: trigger, hostState: hostState, appState: appState,
                           batteryLevel: batteryLevel < 0 ? -1 : batteryLevel, batteryState: batteryState,
                           lowPowerMode: lowPowerMode, thermalState: thermalState, cpuUserSeconds: cpuUser,
                           cpuSystemSeconds: cpuSystem, memoryMB: memory, memoryPeakMB: memoryPeak, computeUnits: units,
                           build: fields[14], device: fields[15], alwaysOn: alwaysOn, protectedData: protectedData)
    }

    // MARK: Private

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static let wallTimeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Rounded to the millisecond written, so a row reads back as the sample that wrote it.
    private static func parseWallTime(_ field: String) -> Date? {
        guard let date = wallTimeFormatter.date(from: field) ?? wholeSecondFormatter.date(from: field) else { return nil }
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    private static func number(_ field: String) -> Double? {
        guard let value = Double(field), value.isFinite else { return nil }
        return value
    }

    /// nil when malformed; `.some(nil)` when empty.
    private static func optionalNumber(_ field: String) -> Double?? {
        if field.isEmpty { return .some(nil) }
        guard let value = number(field) else { return nil }
        return .some(value)
    }

    /// Control characters (line breaks included) are dropped; a field with a comma or quote is quoted.
    private static func text(_ value: String) -> String {
        let clean = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        })
        guard clean.contains(",") || clean.contains("\"") else { return clean }
        return "\"" + clean.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// RFC 4180 fields of one line; nil for an unterminated quote.
    private static func split<Line: StringProtocol>(_ line: Line) -> [String]? {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var iterator = line.makeIterator()
        var pending: Character? = nil
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    let next = iterator.next()
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        quoted = false
                        pending = next
                        if next == nil { break }
                    }
                } else {
                    field.append(character)
                }
            } else if character == "," {
                fields.append(field)
                field = ""
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else {
                field.append(character)
            }
        }
        guard !quoted else { return nil }
        fields.append(field)
        return fields
    }
}

enum PowerLogRotation {
    /// 4 MB, about two weeks of samples at one per minute.
    static let limitBytes = 4 * 1_048_576

    /// Rotate before an append that would take a non-empty file past the limit.
    static func shouldRotate(existingBytes: Int, appendingBytes: Int, limit: Int = limitBytes) -> Bool {
        existingBytes > 0 && existingBytes + appendingBytes > limit
    }
}
