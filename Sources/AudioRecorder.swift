import AVFoundation
import CoreMedia
import Foundation
import os.log

private let recordingLog = OSLog(subsystem: "com.ajbarryiii.localflow", category: "Recording")

struct AudioDevice: Identifiable {
    let id: String
    let uid: String
    let name: String

    fileprivate static func captureDevices() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func availableInputDevices() -> [AudioDevice] {
        var seenUIDs = Set<String>()
        return captureDevices()
            .compactMap { device in
                let uid = device.uniqueID.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = device.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !uid.isEmpty, !name.isEmpty, seenUIDs.insert(uid).inserted else {
                    return nil
                }
                return AudioDevice(id: uid, uid: uid, name: name)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

enum AudioRecorderError: LocalizedError {
    case invalidInputFormat(String)
    case missingInputDevice
    case noAudioBuffersReceived
    case failedToCreateCaptureInput(String)
    case failedToStartCaptureSession(String)
    case failedToBeginFileRecording(String)
    /// A cancel arrived before this start reached the capture queue.
    case captureCancelled

    var errorDescription: String? {
        switch self {
        case .captureCancelled:
            return "Recording was cancelled."
        case .invalidInputFormat(let details):
            return "Invalid input format: \(details)"
        case .missingInputDevice:
            return "No audio input device available."
        case .noAudioBuffersReceived:
            return "No audio buffers were received from the selected microphone."
        case .failedToCreateCaptureInput(let details):
            return "Could not open the selected microphone: \(details)"
        case .failedToStartCaptureSession(let details):
            return "Could not start the capture session: \(details)"
        case .failedToBeginFileRecording(let details):
            return "Could not begin recording audio: \(details)"
        }
    }
}

final class AudioRecorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private static let sessionQueueKey = DispatchSpecificKey<UInt8>()
    private var captureSession: AVCaptureSession?
    private var currentInput: AVCaptureDeviceInput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private var sessionObservers: [NSObjectProtocol] = []
    private var tempFileURL: URL?
    private let _bufferCount = OSAllocatedUnfairLock(initialState: 0)
    private let fileWriteErrorLock = OSAllocatedUnfairLock(initialState: ())
    private var watchdogTimer: DispatchSourceTimer?
    private let sessionQueue = DispatchQueue(label: "com.ajbarryiii.localflow.capture.session")
    /// Tickets, capture ids, readiness, failures and attached outputs (see CaptureLifecycle).
    private let lifecycle = CaptureLifecycle()
    private let sampleBufferQueue = DispatchQueue(label: "com.ajbarryiii.localflow.capture.samples")
    private var activeAudioFile: AVAudioFile?
    private var activeAudioFormat: AVAudioFormat?
    private var recordedFrameCount: AVAudioFramePosition = 0
    private var loggedCaptureFormat = false
    private var fileWriteError: Error?
    private var isSessionInterrupted = false

    @Published var isRecording = false
    private let _recording = OSAllocatedUnfairLock(initialState: false)
    @Published var audioLevel: Float = 0.0
    private let liveLevelNormalizerLock = OSAllocatedUnfairLock(initialState: LiveAudioLevelNormalizer())

    var onRecordingReady: (() -> Void)?
    var onRecordingFailure: ((Error) -> Void)?
    private let recordingConverterLock = OSAllocatedUnfairLock<AVAudioConverter?>(initialState: nil)
    private let recordingTargetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
    }()
    private static let watchdogTimeout: TimeInterval = 2.0
    private static let sampleRateLogLimit = 40

    override init() {
        super.init()
        sessionQueue.setSpecific(key: Self.sessionQueueKey, value: 1)
    }

    deinit {
        let cleanup = {
            self.cancelWatchdog()
            self.teardownSessionLocked()
        }

        if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
            cleanup()
        } else {
            sessionQueue.sync(execute: cleanup)
        }
    }

    private static func captureDevice(forUID uid: String) -> AVCaptureDevice? {
        AudioDevice.captureDevices().first(where: { $0.uniqueID == uid })
    }

    private static func defaultCaptureDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio) ?? AudioDevice.captureDevices().first
    }

    private func preferredCaptureDevice(
        for requestedDeviceUID: String?,
        reason: String
    ) throws -> AVCaptureDevice {
        guard let requestedDeviceUID, !requestedDeviceUID.isEmpty, requestedDeviceUID != "default" else {
            guard let device = Self.defaultCaptureDevice() else {
                throw AudioRecorderError.missingInputDevice
            }
            os_log(.info, log: recordingLog, "%{public}@ — using system default device: %{public}@", reason, device.localizedName)
            return device
        }

        if let device = Self.captureDevice(forUID: requestedDeviceUID) {
            os_log(.info, log: recordingLog, "%{public}@ — keeping selected device: %{public}@ [uid=%{public}@]", reason, device.localizedName, device.uniqueID)
            return device
        }

        guard let fallbackDevice = Self.defaultCaptureDevice() else {
            throw AudioRecorderError.missingInputDevice
        }

        os_log(
            .info,
            log: recordingLog,
            "%{public}@ — selected device unavailable [uid=%{public}@], falling back to system default: %{public}@ [uid=%{public}@]",
            reason,
            requestedDeviceUID,
            fallbackDevice.localizedName,
            fallbackDevice.uniqueID
        )
        return fallbackDevice
    }

    private func installSessionObservers(for session: AVCaptureSession, capture: UInt64) {
        removeSessionObservers()

        let runtimeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let wrapped = error.map { AudioRecorderError.failedToStartCaptureSession($0.localizedDescription) }
                ?? AudioRecorderError.failedToStartCaptureSession("Unknown runtime error")
            self?.reportRecordingFailure(wrapped, capture: capture)
        }
        sessionObservers.append(runtimeObserver)

        let interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleSessionInterrupted(notification)
        }
        sessionObservers.append(interruptionObserver)

        let interruptionEndedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleSessionInterruptionEnded(notification)
        }
        sessionObservers.append(interruptionEndedObserver)
    }

    private func removeSessionObservers() {
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        sessionObservers.removeAll()
    }

    private func teardownSessionLocked() {
        removeSessionObservers()
        isSessionInterrupted = false

        audioDataOutput?.setSampleBufferDelegate(nil, queue: nil)
        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }

        captureSession = nil
        currentInput = nil
        audioDataOutput = nil
    }

    /// A failure of `capture` only: a queued failure from an earlier capture
    /// claims, tears down and calls back for nothing.
    private func reportRecordingFailure(_ error: Error, capture: UInt64, completion: ((URL?) -> Void)? = nil) {
        sessionQueue.async {
            guard self.lifecycle.claimFailure(capture) else { return }
            self.cancelWatchdog()
            self._recording.withLock { $0 = false }

            let completion = completion
            let disposition = self.lifecycle.stop(capture) { self.finishAudioFileLocked(discard: true) }
            self.teardownSessionLocked()
            self.liveLevelNormalizerLock.withLock { $0.reset() }
            disposition.removeDiscarded()

            DispatchQueue.main.async {
                guard self.lifecycle.mayDeliver(capture) else { return }
                self.isRecording = false
                self.audioLevel = 0.0
                self.onRecordingFailure?(error)
                completion?(nil)
            }
        }
    }

    private func startBufferWatchdog(capture: UInt64) {
        let baselineCount = _bufferCount.withLock { $0 }
        cancelWatchdog()

        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + Self.watchdogTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self._recording.withLock({ $0 }), self.lifecycle.isCurrent(capture) else { return }
            guard !self.isSessionInterrupted else {
                os_log(.info, log: recordingLog, "watchdog suspended while capture session is interrupted")
                return
            }

            let count = self._bufferCount.withLock { $0 }
            if count == baselineCount {
                os_log(.error, log: recordingLog, "watchdog: no new buffers after %.1fs — giving up", Self.watchdogTimeout)
                self.reportRecordingFailure(AudioRecorderError.noAudioBuffersReceived, capture: capture)
            } else {
                os_log(.info, log: recordingLog, "watchdog: %d new buffers after %.1fs — healthy", count - baselineCount, Self.watchdogTimeout)
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func cancelWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    /// Drains the writer, then decides the file: the caller keeps `keep` and must
    /// call `removeDiscarded()`, so a discarded or empty recording is deleted.
    private func finishAudioFileLocked(discard: Bool) -> AudioFileDisposition {
        var disposition = AudioFileDisposition(keep: nil, delete: nil)

        // Drain all queued sample-buffer callbacks before releasing the writer.
        sampleBufferQueue.sync {
            disposition = AudioFileDisposition.decide(
                url: self.tempFileURL, discard: discard, recordedFrames: Int64(self.recordedFrameCount),
                writeFailed: self.fileWriteErrorLock.withLock { _ in self.fileWriteError != nil })
            self.activeAudioFile = nil
            self.activeAudioFormat = nil
        }

        defer {
            self.recordedFrameCount = 0
            self.fileWriteErrorLock.withLock { _ in
                self.fileWriteError = nil
            }
            if disposition.keep == nil {
                self.tempFileURL = nil
            }
        }

        return disposition
    }

    private func handleSessionInterrupted(_ notification: Notification) {
        _ = notification
        sessionQueue.async {
            guard self._recording.withLock({ $0 }) else { return }
            self.isSessionInterrupted = true
            self.cancelWatchdog()
            os_log(.info, log: recordingLog, "capture session interrupted — waiting for recovery")
        }
    }

    private func handleSessionInterruptionEnded(_ notification: Notification) {
        _ = notification
        sessionQueue.async {
            guard self._recording.withLock({ $0 }) else { return }
            self.isSessionInterrupted = false
            os_log(.info, log: recordingLog, "capture session interruption ended — restarting watchdog")
            if let capture = self.lifecycle.currentCapture { self.startBufferWatchdog(capture: capture) }
        }
    }

    private func appendSampleBufferToFile(_ sampleBuffer: CMSampleBuffer) throws {
        if let fileWriteError = fileWriteErrorLock.withLock({ _ in
            self.fileWriteError
        }) {
            throw fileWriteError
        }

        guard let outputURL = tempFileURL else {
            throw AudioRecorderError.failedToBeginFileRecording("Missing temporary output URL.")
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw AudioRecorderError.invalidInputFormat("Could not determine audio format from sample buffer.")
        }
        let rawSourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let sourceFormat = try validatedPCMBufferFormat(
            rawSourceFormat,
            context: "capture sample buffer"
        )

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return }
        let inputBuffer = try makePCMBuffer(from: sampleBuffer, format: sourceFormat, frameCount: frameCount)

        let targetFormat = recordingTargetFormat
        if !loggedCaptureFormat {
            loggedCaptureFormat = true
            os_log(
                .info,
                log: recordingLog,
                "capture audio format source=%{public}@ %.0fHz %u ch interleaved=%{public}@ target=%{public}@ %.0fHz %u ch interleaved=%{public}@ conversion=%{public}@",
                String(describing: sourceFormat.commonFormat),
                sourceFormat.sampleRate,
                sourceFormat.channelCount,
                String(sourceFormat.isInterleaved),
                String(describing: targetFormat.commonFormat),
                targetFormat.sampleRate,
                targetFormat.channelCount,
                String(targetFormat.isInterleaved),
                String(sourceFormat != targetFormat)
            )
        }
        if activeAudioFile == nil {
            let settings = pcmFileSettings(for: targetFormat)
            let audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: targetFormat.commonFormat,
                interleaved: targetFormat.isInterleaved
            )
            activeAudioFile = audioFile
            activeAudioFormat = targetFormat
            os_log(.info, log: recordingLog, "audio file writer created at %{public}@", outputURL.path)
        }

        guard let activeAudioFile else {
            throw AudioRecorderError.failedToBeginFileRecording("Audio file writer was not initialized.")
        }

        if sourceFormat == targetFormat {
            try activeAudioFile.write(from: inputBuffer)
            recordedFrameCount += AVAudioFramePosition(inputBuffer.frameLength)
            return
        }

        let outputBuffer = try convertRecordingBuffer(
            inputBuffer,
            from: sourceFormat,
            to: targetFormat
        )
        guard outputBuffer.frameLength > 0 else { return }
        try activeAudioFile.write(from: outputBuffer)
        recordedFrameCount += AVAudioFramePosition(outputBuffer.frameLength)
    }

    private func validatedPCMBufferFormat(
        _ format: AVAudioFormat,
        context: String
    ) throws -> AVAudioFormat {
        let isPCM = format.commonFormat == .pcmFormatFloat32
            || format.commonFormat == .pcmFormatFloat64
            || format.commonFormat == .pcmFormatInt16
            || format.commonFormat == .pcmFormatInt32

        guard isPCM else {
            throw AudioRecorderError.invalidInputFormat(
                "\(context) is not PCM (commonFormat=\(String(describing: format.commonFormat)), settings=\(format.settings))."
            )
        }

        guard format.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat(
                "\(context) reported zero channels."
            )
        }

        guard format.sampleRate > 0 else {
            throw AudioRecorderError.invalidInputFormat(
                "\(context) reported an invalid sample rate (\(format.sampleRate))."
            )
        }

        return format
    }

    private func pcmFileSettings(for format: AVAudioFormat) -> [String: Any] {
        let isFloat = isFloatFormat(format.commonFormat)
        let bitDepth = bitDepth(for: format.commonFormat)

        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved,
        ]
    }

    private func isFloatFormat(_ commonFormat: AVAudioCommonFormat) -> Bool {
        commonFormat == .pcmFormatFloat32 || commonFormat == .pcmFormatFloat64
    }

    private func bitDepth(for commonFormat: AVAudioCommonFormat) -> Int {
        switch commonFormat {
        case .pcmFormatFloat64:
            64
        case .pcmFormatFloat32, .pcmFormatInt32:
            32
        case .pcmFormatInt16:
            16
        default:
            0
        }
    }

    private func makePCMBuffer(
        from sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioRecorderError.failedToBeginFileRecording("Could not allocate PCM buffer for format \(format.settings).")
        }
        inputBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            throw AudioRecorderError.failedToBeginFileRecording("Could not copy sample buffer data (OSStatus \(copyStatus)).")
        }
        return inputBuffer
    }

    private struct ConversionResult {
        let buffer: AVAudioPCMBuffer
        let status: String
    }

    private func convertRecordingBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let converter = recordingConverterLock.withLock { existing -> AVAudioConverter? in
            if let existing, existing.inputFormat == sourceFormat {
                return existing
            }
            let new = AVAudioConverter(from: sourceFormat, to: targetFormat)
            existing = new
            return new
        }
        guard let converter else {
            throw AudioRecorderError.failedToBeginFileRecording("Could not create recording converter.")
        }

        return try convertBuffer(
            inputBuffer,
            from: sourceFormat,
            using: converter,
            to: targetFormat
        ).buffer
    }

    private func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        using converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) throws -> ConversionResult {
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            throw AudioRecorderError.failedToBeginFileRecording("Could not allocate converted audio buffer.")
        }

        var suppliedInput = false
        var converterError: NSError?
        let status = converter.convert(to: outputBuffer, error: &converterError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        if let converterError {
            throw AudioRecorderError.failedToBeginFileRecording("Audio conversion failed: \(converterError.localizedDescription)")
        }
        guard status != .error, outputBuffer.frameLength > 0 else {
            throw AudioRecorderError.failedToBeginFileRecording("Audio conversion produced no data.")
        }
        return ConversionResult(buffer: outputBuffer, status: String(describing: status))
    }

    private func makeSession(deviceUID: String?, outputURL: URL, capture: UInt64) throws {
        teardownSessionLocked()

        let device = try preferredCaptureDevice(for: deviceUID, reason: "initial start")

        let session = AVCaptureSession()
        let dataOutput = AVCaptureAudioDataOutput()
        dataOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: recordingTargetFormat.sampleRate,
            AVNumberOfChannelsKey: Int(recordingTargetFormat.channelCount),
            AVLinearPCMBitDepthKey: bitDepth(for: recordingTargetFormat.commonFormat),
            AVLinearPCMIsFloatKey: isFloatFormat(recordingTargetFormat.commonFormat),
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !recordingTargetFormat.isInterleaved,
        ]
        dataOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)
        lifecycle.attach(ObjectIdentifier(dataOutput), to: capture)

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AudioRecorderError.failedToCreateCaptureInput(error.localizedDescription)
        }

        session.beginConfiguration()
        var needsCommitConfiguration = true
        defer {
            if needsCommitConfiguration {
                session.commitConfiguration()
            }
        }

        guard session.canAddInput(input) else {
            throw AudioRecorderError.failedToCreateCaptureInput("Session rejected device input for \(device.localizedName).")
        }
        session.addInput(input)

        guard session.canAddOutput(dataOutput) else {
            throw AudioRecorderError.failedToStartCaptureSession("Session rejected audio data output.")
        }
        session.addOutput(dataOutput)

        session.commitConfiguration()
        needsCommitConfiguration = false

        captureSession = session
        currentInput = input
        audioDataOutput = dataOutput
        isSessionInterrupted = false
        activeAudioFile = nil
        activeAudioFormat = nil
        recordingConverterLock.withLock { $0 = nil }
        recordedFrameCount = 0
        loggedCaptureFormat = false
        fileWriteErrorLock.withLock { _ in
            fileWriteError = nil
        }
        installSessionObservers(for: session, capture: capture)

        os_log(.info, log: recordingLog, "configured capture session with device %{public}@ [uid=%{public}@]", device.localizedName, device.uniqueID)

        session.startRunning()
        guard session.isRunning else {
            throw AudioRecorderError.failedToStartCaptureSession("Session failed to enter running state.")
        }

        os_log(.info, log: recordingLog, "capture session running with device %{public}@ [uid=%{public}@]", device.localizedName, device.uniqueID)
        tempFileURL = outputURL
    }

    /// Reserve on the main thread before dispatching a start; a cancel after
    /// this voids the ticket, wherever the start's work then is.
    func reserveCapture() -> UInt64 { lifecycle.reserve() }

    func startRecording(deviceUID: String? = nil) throws {
        try startRecording(deviceUID: deviceUID, ticket: lifecycle.reserve())
    }

    func startRecording(deviceUID: String?, ticket: UInt64) throws {
        let t0 = CFAbsoluteTimeGetCurrent()

        os_log(.info, log: recordingLog, "startRecording() entered")

        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")

        // One session-queue operation: admission (a cancel since the ticket was
        // reserved wins), per-capture resets, setup, and on failure all of this
        // start's cleanup. Nothing runs later that could touch a start queued
        // behind it, such as clearing its file URL.
        let capture = try sessionQueue.sync {
            try self.lifecycle.start(ticket: ticket, at: t0, setup: { capture in
                self._bufferCount.withLock { $0 = 0 }
                self.liveLevelNormalizerLock.withLock { $0.reset() }
                try self.makeSession(deviceUID: deviceUID, outputURL: outputURL, capture: capture)
                self._recording.withLock { $0 = true }
                self.startBufferWatchdog(capture: capture)
            }, cleanUp: {
                self.tempFileURL = nil
            }, cancelled: AudioRecorderError.captureCancelled)
        }

        // Published only if this capture is still the live one when the block runs:
        // a cancel or stop in between (a discarded tap) has already published false.
        DispatchQueue.main.async {
            guard self.lifecycle.mayPublishStart(capture) else { return }
            self.isRecording = true
            self.audioLevel = 0.0
        }
        os_log(.info, log: recordingLog, "startRecording() complete: %.3fms total", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        let count = _bufferCount.withLock { $0 }
        let elapsed = (CFAbsoluteTimeGetCurrent() - lifecycle.startTime) * 1000
        os_log(.info, log: recordingLog, "stopRecording() called: %.3fms after start, %d buffers received", elapsed, count)

        sessionQueue.async {
            self.cancelWatchdog()
            let capture = self.lifecycle.currentCapture
            self.teardownSessionLocked()
            // Buffers already queued from this capture still count until drained.
            let disposition = self.lifecycle.stop(capture) { self.finishAudioFileLocked(discard: false) }
            disposition.removeDiscarded()
            let outputURL = disposition.keep
            self._recording.withLock { $0 = false }
            self.liveLevelNormalizerLock.withLock { $0.reset() }
            DispatchQueue.main.async {
                self.isRecording = false
                self.audioLevel = 0.0
                completion(outputURL)
            }
        }
    }

    func cancelRecording() {
        // At once, from the caller: a start still on its way to the queue is void.
        lifecycle.cancel()
        sessionQueue.async {
            self.cancelWatchdog()
            let capture = self.lifecycle.currentCapture
            self.teardownSessionLocked()
            let disposition = self.lifecycle.stop(capture) { self.finishAudioFileLocked(discard: true) }
            self._recording.withLock { $0 = false }
            self.liveLevelNormalizerLock.withLock { $0.reset() }
            disposition.removeDiscarded()
            DispatchQueue.main.async {
                self.isRecording = false
                self.audioLevel = 0.0
            }
        }
    }

    func cleanup() {
        let cleanup = {
            if let url = self.tempFileURL {
                try? FileManager.default.removeItem(at: url)
                self.tempFileURL = nil
            }
        }

        if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
            cleanup()
        } else {
            sessionQueue.sync(execute: cleanup)
        }
    }

    private func updateAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return 0 }
        guard let sourceFormat = try? validatedPCMBufferFormat(
            AVAudioFormat(cmAudioFormatDescription: formatDescription),
            context: "audio level sample buffer"
        ) else { return 0 }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return 0 }
        guard let inputBuffer = try? makePCMBuffer(
            from: sampleBuffer,
            format: sourceFormat,
            frameCount: frameCount
        ) else { return 0 }

        let rms = rmsLevel(for: inputBuffer)
        let normalizedDisplayLevel = liveLevelNormalizerLock.withLock {
            $0.normalizedLevel(forRMS: rms)
        }

        DispatchQueue.main.async {
            self.audioLevel = normalizedDisplayLevel
        }
        return rms
    }

    private func rmsLevel(for buffer: AVAudioPCMBuffer) -> Float {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        var totalSamples = 0
        var sumOfSquares: Double = 0

        for audioBuffer in audioBuffers {
            guard let baseAddress = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
                continue
            }

            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let pointer = baseAddress.assumingMemoryBound(to: Float.self)
                totalSamples += samples
                for index in 0..<samples {
                    let sample = Double(pointer[index])
                    sumOfSquares += sample * sample
                }
            case .pcmFormatFloat64:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
                let pointer = baseAddress.assumingMemoryBound(to: Double.self)
                totalSamples += samples
                for index in 0..<samples {
                    let sample = pointer[index]
                    sumOfSquares += sample * sample
                }
            case .pcmFormatInt16:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                let pointer = baseAddress.assumingMemoryBound(to: Int16.self)
                totalSamples += samples
                for index in 0..<samples {
                    let sample = Double(pointer[index]) / 32768.0
                    sumOfSquares += sample * sample
                }
            case .pcmFormatInt32:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                let pointer = baseAddress.assumingMemoryBound(to: Int32.self)
                totalSamples += samples
                for index in 0..<samples {
                    let sample = Double(pointer[index]) / 2147483648.0
                    sumOfSquares += sample * sample
                }
            default:
                continue
            }
        }

        guard totalSamples > 0 else { return 0 }
        return Float(sqrt(sumOfSquares / Double(totalSamples)))
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard _recording.withLock({ $0 }), let capture = lifecycle.capture(for: ObjectIdentifier(output)) else { return }

        do {
            try appendSampleBufferToFile(sampleBuffer)
        } catch {
            fileWriteErrorLock.withLock { _ in
                fileWriteError = error
            }
            os_log(.error, log: recordingLog, "audio file write failed: %{public}@", error.localizedDescription)
            reportRecordingFailure(error, capture: capture)
            return
        }


        let count = _bufferCount.withLock { value -> Int in
            value += 1
            return value
        }

        let rms = updateAudioLevel(from: sampleBuffer)
        if count <= Self.sampleRateLogLimit {
            let elapsed = (CFAbsoluteTimeGetCurrent() - lifecycle.startTime) * 1000
            os_log(.info, log: recordingLog, "buffer #%d at %.3fms, rms=%.6f", count, elapsed, rms)
        }

        if lifecycle.claimReady(capture, rms: rms) {
            let elapsed = (CFAbsoluteTimeGetCurrent() - lifecycle.startTime) * 1000
            os_log(.info, log: recordingLog, "FIRST non-silent buffer at %.3fms — recording ready", elapsed)
            DispatchQueue.main.async {
                guard self.lifecycle.mayDeliver(capture) else { return }
                self.onRecordingReady?()
            }
        }
    }
}
