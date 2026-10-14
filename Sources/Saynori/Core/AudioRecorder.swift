import AVFoundation
import Foundation

/// Captures the default microphone as 16 kHz mono PCM16 and publishes a live level
/// for the waveform. The engine only runs while recording, so the mic indicator is
/// off (and CPU is ~0) the rest of the time.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var samples = [Int16]()
    private(set) var isRecording = false

    /// Called on the main queue ~20×/s with a 0…1 loudness value.
    var onLevel: ((Float) -> Void)?

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    static var hasPermission: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); samples.reserveCapacity(16_000 * 30); lock.unlock()

        // Fresh engine each take so mic switches (AirPods, USB mics) are always picked up.
        engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw RecorderError.noInput }
        converter = AVAudioConverter(from: inFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRecording = true
    }

    /// Stops capture and returns the recorded PCM16 samples.
    @discardableResult
    func stop() -> [Int16] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    var duration: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / Self.sampleRate
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        // Level meter from the raw float input.
        if let ch = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            // Map roughly -55 dB…-10 dB into 0…1 for a lively but not jumpy meter.
            let db = 20 * log10(max(rms, 1e-7))
            let level = max(0, min(1, (db + 55) / 45))
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }

        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let data = out.int16ChannelData?[0] else { return }
        let count = Int(out.frameLength)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
        lock.unlock()
    }

    enum RecorderError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input available" }
    }
}

enum WAV {
    static func encode(_ samples: ArraySlice<Int16>, sampleRate: Int = 16_000) -> Data {
        var d = Data()
        let dataSize = UInt32(samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// Splits long audio into ≤28 s pieces, cutting at the quietest 20 ms frame
    /// between 22–28 s so words aren't sliced in half (Sarvam REST caps at 30 s).
    static func chunks(_ s: [Int16], sampleRate: Int = 16_000) -> [ArraySlice<Int16>] {
        let maxLen = 28 * sampleRate, minLen = 22 * sampleRate, frame = sampleRate / 50
        var out: [ArraySlice<Int16>] = []
        var start = 0
        while s.count - start > maxLen {
            var best = start + maxLen, bestE = Int.max
            var i = start + minLen
            while i + frame <= start + maxLen {
                var e = 0
                for j in i..<(i + frame) { e += abs(Int(s[j])) }
                if e < bestE { bestE = e; best = i + frame / 2 }
                i += frame
            }
            out.append(s[start..<best])
            start = best
        }
        out.append(s[start..<s.count])
        return out
    }

    /// True when the clip is essentially silence (avoids sending empty audio / hallucinations).
    static func isSilent(_ s: [Int16]) -> Bool {
        guard !s.isEmpty else { return true }
        var peak = 0
        var i = 0
        while i < s.count { peak = max(peak, abs(Int(s[i]))); i += 4 }
        return peak < 600
    }
}
