import Foundation
import Accelerate

/// Performs a windowed FFT on incoming audio and exposes smoothed
/// bass / mid / treble levels plus a simple beat detector.
///
/// Thread-safety: `append(samples:)` is called from the audio capture thread;
/// `currentFeatures()` is read from the render thread. Both go through `lock`.
final class AudioAnalyzer {

    struct Features {
        var bass: Float = 0     // 0...1-ish
        var mid: Float = 0
        var treble: Float = 0
        var level: Float = 0    // overall loudness
        var beat: Float = 0     // 0 = no beat, >0 = beat strength
    }

    var sampleRate: Double = 48_000

    private let fftSize = 2048
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]

    private var ring: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]

    private let lock = NSLock()
    private var features = Features()

    // Auto-gain so quiet and loud tracks both fill the visual range.
    private var bassMax: Float = 1e-4
    private var midMax: Float = 1e-4
    private var trebleMax: Float = 1e-4

    // Beat detection state.
    private var bassEnergyAvg: Float = 0

    init() {
        log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: fftSize)
        realp = [Float](repeating: 0, count: fftSize / 2)
        imagp = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Append new mono samples. Keeps a sliding window of the last `fftSize`.
    func append(samples: [Float]) {
        guard !samples.isEmpty else { return }

        if samples.count >= fftSize {
            ring = Array(samples.suffix(fftSize))
        } else {
            let keep = fftSize - samples.count
            ring.removeFirst(ring.count - keep)
            ring.append(contentsOf: samples)
        }
        analyze()
    }

    func currentFeatures() -> Features {
        lock.lock(); defer { lock.unlock() }
        var f = features
        // Beat is a one-shot value; consume it after reading.
        features.beat = 0
        return f
    }

    // MARK: FFT

    private func analyze() {
        // Apply window.
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(ring, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack real input into split-complex form.
        var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)
        windowed.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { typeConverted in
                vDSP_ctoz(typeConverted, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
            }
        }

        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

        // Magnitudes (squared), then sqrt and normalize.
        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
        var n = Float(fftSize)
        vDSP_vsdiv(magnitudes, 1, &n, &magnitudes, 1, vDSP_Length(fftSize / 2))

        let binHz = Float(sampleRate) / Float(fftSize)
        let bass = bandEnergy(20, 150, binHz: binHz)
        let mid = bandEnergy(150, 2_000, binHz: binHz)
        let treble = bandEnergy(2_000, 8_000, binHz: binHz)

        // Absolute loudness gate. The per-band auto-gain below would otherwise
        // amplify the silent noise floor up to full range, making the visuals
        // move even with no music playing. This gate is NOT auto-gained, so
        // true silence -> 0 -> the fluid stops.
        var rms: Float = 0
        vDSP_rmsqv(ring, 1, &rms, vDSP_Length(fftSize))
        let gate = smoothstep(0.004, 0.045, rms)

        // Adaptive normalization with slow decay (for relative band *shape*).
        bassMax = max(bassMax * 0.999, bass, 1e-4)
        midMax = max(midMax * 0.999, mid, 1e-4)
        trebleMax = max(trebleMax * 0.999, treble, 1e-4)

        // Gate every band so quiet passages and silence genuinely calm down.
        let nBass = clamp01(bass / bassMax) * gate
        let nMid = clamp01(mid / midMax) * gate
        let nTreble = clamp01(treble / trebleMax) * gate
        let level = gate * clamp01((nBass + nMid + nTreble) / 3.0 + 0.0)

        // Beat: a bass spike well above the running average (only while audible).
        bassEnergyAvg = bassEnergyAvg * 0.92 + bass * 0.08
        var beat: Float = 0
        if gate > 0.25 && bass > bassEnergyAvg * 1.45 && nBass > 0.25 {
            beat = clamp01((bass / max(bassEnergyAvg, 1e-5) - 1.45))
        }

        lock.lock()
        // Smooth the continuous bands for fluid (less jittery) motion.
        features.bass = features.bass * 0.6 + nBass * 0.4
        features.mid = features.mid * 0.6 + nMid * 0.4
        features.treble = features.treble * 0.6 + nTreble * 0.4
        features.level = features.level * 0.7 + level * 0.3
        if beat > features.beat { features.beat = beat }
        lock.unlock()
    }

    /// Average magnitude across the bins covering [loHz, hiHz].
    private func bandEnergy(_ loHz: Float, _ hiHz: Float, binHz: Float) -> Float {
        let lo = max(1, Int(loHz / binHz))
        let hi = min(fftSize / 2 - 1, Int(hiHz / binHz))
        guard hi >= lo else { return 0 }
        var sum: Float = 0
        for i in lo...hi { sum += sqrt(magnitudes[i]) }
        return sum / Float(hi - lo + 1)
    }

    private func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }

    private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = clamp01((x - edge0) / max(edge1 - edge0, 1e-6))
        return t * t * (3 - 2 * t)
    }
}
