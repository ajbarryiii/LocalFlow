#if LOCALFLOW_POWER_LOG
import Darwin
import Foundation
import UIKit

/// Test builds only (`make POWER_LOG=1`; ARCHITECTURE.md, "Power log"). Records content-free power
/// proxies to `Application Support/PowerLog` in the app's own container, never the App Group.
///
/// It samples on every host-state and app-state transition, on battery, thermal and Low Power Mode
/// notifications, at launch and termination, and from a 60 s timer while background execution is
/// justified: the app is in front, or the host holds an audio session or is working. When that stops
/// (in the background with no session, for example after lock, idle expiry or End session) the boundary
/// sample is flushed and the timer invalidated; sampling resumes on foreground or a new session. It
/// never keeps the process awake and starts no background task.
///
/// The main thread only takes samples. Every file operation goes to `PowerLogStore`, the serialized
/// owner on a utility queue. Rows are flushed at most every 5 minutes, and at every background
/// transition, suspension boundary and termination.
@MainActor
final class PowerRecorder {
    static let shared = PowerRecorder()

    static let periodicInterval: TimeInterval = 60
    static let writeInterval: TimeInterval = 300
    /// The termination flush may hold the main thread this long at most.
    static let terminationWait: TimeInterval = 1

    static let directoryName = "PowerLog"
    static let fileName = "power-log.csv"
    static let rotatedFileName = "power-log.1.csv"
    static let exportDirectoryName = "PowerLogExport"

    /// What Diagnostics shows: everything logged, disk plus buffer, at one point in the store's order.
    struct Status: Sendable {
        var summary: PowerLogSummary
        var bytesOnDisk: Int
        var fileCount: Int
        var droppedSamples: Int
        var generation: UInt64
    }

    private let store: PowerLogStore?
    /// Export copies, in the app's own temporary directory.
    private let exportDirectory: URL
    private let build: String
    private let device: String
    private var lastFlushUptime: TimeInterval = 0
    private var hostState = PowerHostState.idle
    private var computeUnits: @MainActor () -> ComputePolicy.Units? = { nil }
    private var alwaysOn: @MainActor () -> Bool = { false }
    private var hostLocked: @MainActor () -> Bool = { false }
    private var protectedState = ProtectedDataState()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isStarted = false

    private init() {
        store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first.map {
            PowerLogStore(files: PowerLogFiles(directory: $0.appendingPathComponent(Self.directoryName, isDirectory: true),
                                               fileName: Self.fileName, rotatedFileName: Self.rotatedFileName))
        }
        exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.exportDirectoryName, isDirectory: true)
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        device = Self.hardwareModel()
    }

    /// Call once at launch, before the host's run recovery publishes its first status.
    func start(computeUnits: @escaping @MainActor () -> ComputePolicy.Units?, alwaysOn: @escaping @MainActor () -> Bool,
               hostLocked: @escaping @MainActor () -> Bool) {
        guard !isStarted else { return }
        isStarted = true
        self.computeUnits = computeUnits
        self.alwaysOn = alwaysOn
        self.hostLocked = hostLocked
        lastFlushUptime = Self.uptime()
        store?.removeExports(in: exportDirectory)   // left by a run that died while sharing
        UIDevice.current.isBatteryMonitoringEnabled = true
        observeNotifications()
        record(.launch)
    }

    /// The host's passive observer hook (`HostSessionCore.onPublish`): samples when the derived state
    /// changes. It reads the status only and never acts on the host.
    func hostStatusPublished(_ status: HostStatus) {
        let state = PowerHostState(status: status)
        guard state != hostState else { return }
        hostState = state
        if isStarted { record(.state) }
    }

    /// The always-on test mode was switched: a sample marks the boundary.
    func alwaysOnChanged() {
        if isStarted { record(.state) }
    }

    /// Diagnostics. Discard the result unless `isCurrent`: a Clear may have come in between.
    func status() async -> Status? {
        guard let store else { return nil }
        return await withCheckedContinuation { continuation in
            store.snapshot { snapshot in
                continuation.resume(returning: Status(
                    summary: PowerLogSummary(samples: snapshot.samples), bytesOnDisk: snapshot.bytesOnDisk,
                    fileCount: snapshot.fileCount, droppedSamples: snapshot.droppedSamples, generation: snapshot.generation))
            }
        }
    }

    func isCurrent(_ status: Status) -> Bool {
        store?.isCurrent(generation: status.generation) ?? false
    }

    /// Complete, immutable copies for the share sheet (disk plus buffer); pass them to `discard` when
    /// sharing completes. Removing copies twice is harmless.
    func exportSnapshot() async -> PowerLogStore.ExportOutcome {
        guard let store else { return .failed }
        let directory = exportDirectory
        return await withCheckedContinuation { continuation in
            store.exportSnapshot(into: directory) { continuation.resume(returning: $0) }
        }
    }

    func discard(_ export: PowerLogStore.Export) {
        store?.removeExport(export)
    }

    /// `.failed` keeps the log as it was; `.partiallyCleared` deleted some of it.
    func clear() async -> PowerLogClearOutcome {
        guard let store else { return .failed }
        return await withCheckedContinuation { continuation in
            store.clear { continuation.resume(returning: $0) }
        }
    }

    // MARK: Private

    /// `protectedData` is the notification's own value; it also latches (`ProtectedDataState`), because
    /// during "will become unavailable" UIKit still reports protected data as available.
    private func record(_ trigger: PowerTrigger, protectedData notified: PowerProtectedData? = nil) {
        guard let store else { return }
        var protectedData = notified
        if trigger == .foreground {
            // Arriving in front with protected data available is an unlock even if the notification was
            // missed. Stated explicitly: the host's own latch may not be cleared yet (observer order).
            let available = UIApplication.shared.isProtectedDataAvailable
            protectedState.activated(protectedDataAvailable: available)
            protectedData = available ? .available : .unavailable
        }
        switch notified {
        case .unavailable?: protectedState.willBecomeUnavailable()
        case .available?: protectedState.didBecomeAvailable()
        case nil: break
        }
        let now = Self.uptime()
        var sample = sample(trigger, uptime: now)
        if let protectedData { sample.protectedData = protectedData }
        store.append(sample)
        // Nothing but LocalFlow's own front or its audio session and work keeps it running.
        let justified = sample.appState == .foreground || hostState != .idle
        if trigger == .terminate {
            store.flush()
            store.waitUntilIdle(timeout: Self.terminationWait)
            lastFlushUptime = now
        } else if trigger == .background || !justified || now - lastFlushUptime >= Self.writeInterval {
            store.flush()
            lastFlushUptime = now
        }
        if justified, trigger != .terminate {
            startTimer()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.periodicInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.record(.periodic) }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample(_ trigger: PowerTrigger, uptime: TimeInterval) -> PowerSample {
        let device = UIDevice.current
        let appState: PowerAppState
        switch trigger {
        case .foreground: appState = .foreground   // willEnterForeground still reports `.background`
        case .background: appState = .background
        default: appState = UIApplication.shared.applicationState == .background ? .background : .foreground
        }
        let batteryState: PowerBatteryState
        switch device.batteryState {
        case .unplugged: batteryState = .unplugged
        case .charging: batteryState = .charging
        case .full: batteryState = .full
        case .unknown: batteryState = .unknown
        @unknown default: batteryState = .unknown
        }
        let thermalState: PowerThermalState
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalState = .nominal
        case .fair: thermalState = .fair
        case .serious: thermalState = .serious
        case .critical: thermalState = .critical
        @unknown default: thermalState = .critical
        }
        var usage = rusage()
        let cpu = getrusage(RUSAGE_SELF, &usage) == 0
            ? (user: Self.seconds(usage.ru_utime), system: Self.seconds(usage.ru_stime)) : (user: 0, system: 0)
        let footprint = ProcessMemory.footprint()
        return PowerSample(
            wallTime: Date(), uptime: uptime, trigger: trigger, hostState: hostState, appState: appState,
            batteryLevel: Double(device.batteryLevel), batteryState: batteryState,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: thermalState,
            cpuUserSeconds: cpu.user, cpuSystemSeconds: cpu.system, memoryMB: footprint?.currentMB,
            memoryPeakMB: footprint?.peakMB, computeUnits: computeUnits(), build: build, device: self.device,
            alwaysOn: alwaysOn(),
            protectedData: protectedState.effective(reading: UIApplication.shared.isProtectedDataAvailable,
                                                    hostLocked: hostLocked()))
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ trigger: PowerTrigger, protectedData: PowerProtectedData? = nil) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.record(trigger, protectedData: protectedData) }
            })
        }
        on(UIApplication.willEnterForegroundNotification, .foreground)
        on(UIApplication.didEnterBackgroundNotification, .background)
        on(UIApplication.willTerminateNotification, .terminate)
        on(UIDevice.batteryLevelDidChangeNotification, .battery)
        on(UIDevice.batteryStateDidChangeNotification, .battery)
        on(ProcessInfo.thermalStateDidChangeNotification, .thermal)
        on(Notification.Name.NSProcessInfoPowerStateDidChange, .powerMode)
        on(UIApplication.protectedDataWillBecomeUnavailableNotification, .protectedData, protectedData: .unavailable)
        on(UIApplication.protectedDataDidBecomeAvailableNotification, .protectedData, protectedData: .available)
        // Becoming active without a foreground transition takes no sample, but may lift the latch too.
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.protectedState.activated(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
            }
        })
    }

    /// Continues while the device sleeps (unlike `systemUptime`), so suspended intervals within one run
    /// keep their real length.
    private static func uptime() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    /// The hardware model identifier, such as `iPhone16,1`; the simulated model on the simulator.
    private static func hardwareModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        guard uname(&info) == 0 else { return "?" }
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
#endif
