import AVFoundation
import Foundation

/// Bounded, streaming resampling to mono float32 16 kHz. Checks EOF before
/// asking AVAudioFile to read again (AIFF can throw when read after EOF).
enum ParakeetAudioReader {
    static func read(fileURL: URL, check: () throws -> Void,
                     consume: ([Float]) throws -> Void) throws {
        let file = try AVAudioFile(forReading: fileURL)
        guard file.processingFormat.channelCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw LocalParakeetError.invalid("Unable to prepare audio for the local model.")
        }
        var ended = false
        while !ended {
            try check()
            var readError: Error?, conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                guard file.framePosition < file.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    let remaining = AVAudioFrameCount(min(file.length - file.framePosition, AVAudioFramePosition(input.frameCapacity)))
                    try file.read(into: input, frameCount: min(requested, remaining))
                    inputStatus.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch {
                    readError = error; inputStatus.pointee = .endOfStream; return nil
                }
            }
            guard readError == nil, conversionError == nil, status != .error else {
                throw LocalParakeetError.invalid("Unable to decode the recorded audio.")
            }
            if let samples = output.floatChannelData?[0] {
                try consume(Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength))))
            }
            ended = status == .endOfStream
            if status == .inputRanDry && output.frameLength == 0 {
                throw LocalParakeetError.invalid("Audio conversion stopped before reaching the end.")
            }
        }
    }
}
