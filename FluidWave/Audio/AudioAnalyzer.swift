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
        var level: Float = 0    // perceptual loudness (Stevens power law)
        var beat: Float = 0     // onset strength via spectral flux (0 = none)
        var centroid: Float = 0.5 // normalized spectral centroid (timbral brightness)
        var bpm: Float = 0      // estimated tempo (0 = unknown yet)
        var trackChange: Bool = false // one-shot: silence gap -> new track
        var waveform: [Float] = [] // 256 downsampled time-domain samples
    }

    static let waveformLength = 256

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

    // Onset detection state (spectral flux with an adaptive threshold;
    // Bello et al. 2005, Dixon 2006).
    private var prevSpectrum: [Float]
    private var fluxMean: Float = 0
    private var fluxDev: Float = 0

    // Tempo estimation: autocorrelation of the onset-strength (flux) envelope.
    private var fluxHistory: [Float] = []
    private var hopDuration: Float = 0.021 // EMA of seconds per analysis hop
    private var analysesSinceTempo = 0
    private var bpmSmoothed: Float = 0

    // Track-change detection: a silence gap followed by sound again.
    private var silentDuration: Float = 0
    private var hasPlayed = false

    init() {
        log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: fftSize)
        realp = [Float](repeating: 0, count: fftSize / 2)
        imagp = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        prevSpectrum = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Append new mono samples. Keeps a sliding window of the last `fftSize`.
    func append(samples: [Float]) {
        guard !samples.isEmpty else { return }

        // Track the real hop duration so autocorrelation lags map to seconds.
        let hop = Float(samples.count) / Float(sampleRate)
        hopDuration = hopDuration * 0.95 + hop * 0.05

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
        let f = features
        // Beat and trackChange are one-shot values; consume them after reading.
        features.beat = 0
        features.trackChange = false
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

        // Amplitude spectrum (sqrt of power), computed once.
        var amp = [Float](repeating: 0, count: fftSize / 2)
        var count = Int32(fftSize / 2)
        vvsqrtf(&amp, magnitudes, &count)

        let binHz = Float(sampleRate) / Float(fftSize)
        let bass = bandEnergy(20, 150, amp: amp, binHz: binHz)
        let mid = bandEnergy(150, 2_000, amp: amp, binHz: binHz)
        let treble = bandEnergy(2_000, 8_000, amp: amp, binHz: binHz)
        let maxBin = min(fftSize / 2 - 1, Int(8_000 / binHz))

        // Absolute loudness gate. The per-band auto-gain below would otherwise
        // amplify the silent noise floor up to full range, making the visuals
        // move even with no music playing. This gate is NOT auto-gained, so
        // true silence -> 0 -> the fluid stops.
        var rms: Float = 0
        vDSP_rmsqv(ring, 1, &rms, vDSP_Length(fftSize))
        let gate = smoothstep(0.004, 0.045, rms)

        // Track change: silence of >1s followed by sound again. Reset the
        // tempo estimate so the new track's BPM is measured fresh.
        var trackChanged = false
        if gate < 0.05 {
            silentDuration += hopDuration
        } else {
            if hasPlayed && silentDuration > 1.0 {
                trackChanged = true
                bpmSmoothed = 0
                fluxHistory.removeAll(keepingCapacity: true)
            }
            silentDuration = 0
            hasPlayed = true
        }

        // Perceptual loudness: Stevens' power law (exponent ~0.6 for loudness),
        // so the visuals track how loud the music FEELS, not raw signal power.
        let loudness = gate * pow(clamp01(rms / 0.20), 0.6)

        // Spectral centroid = timbral "brightness" (Schubert & Wolfe 2006),
        // normalized on a log-frequency axis (~250 Hz dark ... ~4 kHz bright).
        var num: Float = 0, den: Float = 0
        for i in 1...maxBin {
            num += Float(i) * binHz * amp[i]
            den += amp[i]
        }
        let centroidHz = den > 1e-6 ? num / den : 1_000
        let centroid = clamp01((log2(centroidHz) - log2(250)) / (log2(4_000) - log2(250)))

        // Onset detection via spectral flux: the half-wave-rectified increase
        // of the spectrum between frames, against an adaptive threshold of
        // running mean + k * deviation (Bello et al. 2005; Dixon 2006). This
        // fires on real musical attacks (drums, note onsets), not just level.
        var flux: Float = 0
        for i in 1...maxBin {
            flux += max(0, amp[i] - prevSpectrum[i])
        }
        flux /= Float(maxBin)
        prevSpectrum = amp

        let diff = flux - fluxMean
        fluxMean += 0.06 * diff
        fluxDev = fluxDev * 0.94 + abs(diff) * 0.06
        var onset: Float = 0
        let threshold = fluxMean + 1.6 * fluxDev
        if gate > 0.25 && flux > threshold && threshold > 1e-6 {
            onset = clamp01((flux - threshold) / threshold)
        }

        // Tempo: autocorrelate the recent onset envelope every ~2 seconds.
        fluxHistory.append(flux)
        if fluxHistory.count > 600 {
            fluxHistory.removeFirst(fluxHistory.count - 600)
        }
        analysesSinceTempo += 1
        if analysesSinceTempo >= 96 {
            analysesSinceTempo = 0
            if gate > 0.3 { estimateTempo() }
        }

        // Adaptive normalization with slow decay (for relative band *shape*).
        bassMax = max(bassMax * 0.999, bass, 1e-4)
        midMax = max(midMax * 0.999, mid, 1e-4)
        trebleMax = max(trebleMax * 0.999, treble, 1e-4)

        // Gate every band so quiet passages and silence genuinely calm down.
        let nBass = clamp01(bass / bassMax) * gate
        let nMid = clamp01(mid / midMax) * gate
        let nTreble = clamp01(treble / trebleMax) * gate

        // Downsampled waveform snapshot for oscilloscope-style scenes,
        // gated so silence yields a flat line instead of noise.
        let waveLength = Self.waveformLength
        var wave = [Float](repeating: 0, count: waveLength)
        let step = fftSize / waveLength
        for i in 0..<waveLength {
            wave[i] = ring[i * step] * gate
        }

        lock.lock()
        // Smooth the continuous bands for fluid (less jittery) motion.
        features.bass = features.bass * 0.6 + nBass * 0.4
        features.mid = features.mid * 0.6 + nMid * 0.4
        features.treble = features.treble * 0.6 + nTreble * 0.4
        features.level = features.level * 0.7 + loudness * 0.3
        features.centroid = features.centroid * 0.8 + centroid * 0.2
        features.bpm = bpmSmoothed
        features.waveform = wave
        if onset > features.beat { features.beat = onset }
        if trackChanged { features.trackChange = true }
        lock.unlock()
    }

    /// Tempo estimation: autocorrelation of the onset-strength envelope
    /// (standard approach, cf. Scheirer 1998 "Tempo and beat analysis of
    /// acoustic musical signals"). The lag with the strongest self-similarity
    /// in the 60-200 BPM range is the beat period; octave errors are folded
    /// into a 70-170 BPM preferred range.
    private func estimateTempo() {
        let n = fluxHistory.count
        guard n >= 250, hopDuration > 1e-4 else { return }
        let window = Array(fluxHistory.suffix(min(n, 500)))
        let m = window.count

        var mean: Float = 0
        vDSP_meanv(window, 1, &mean, vDSP_Length(m))
        var x = window
        var negMean = -mean
        vDSP_vsadd(window, 1, &negMean, &x, 1, vDSP_Length(m))

        var r0: Float = 0
        vDSP_dotpr(x, 1, x, 1, &r0, vDSP_Length(m))
        guard r0 > 1e-9 else { return }

        let lagMin = max(2, Int((60.0 / 200.0) / hopDuration))
        let lagMax = min(m - 10, Int((60.0 / 60.0) / hopDuration))
        guard lagMax > lagMin else { return }

        var bestLag = 0
        var bestR: Float = 0
        x.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for lag in lagMin...lagMax {
                var r: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &r, vDSP_Length(m - lag))
                let normalized = r / r0
                if normalized > bestR {
                    bestR = normalized
                    bestLag = lag
                }
            }
        }

        // Require a clear periodicity; otherwise keep the previous estimate.
        guard bestR > 0.2, bestLag > 0 else { return }

        var bpm = 60.0 / (Float(bestLag) * hopDuration)
        while bpm < 70 { bpm *= 2 }
        while bpm > 170 { bpm /= 2 }

        if bpmSmoothed == 0 || abs(bpm - bpmSmoothed) / bpmSmoothed > 0.12 {
            bpmSmoothed = bpm
        } else {
            bpmSmoothed = bpmSmoothed * 0.8 + bpm * 0.2
        }
    }

    /// Average amplitude across the bins covering [loHz, hiHz].
    private func bandEnergy(_ loHz: Float, _ hiHz: Float, amp: [Float], binHz: Float) -> Float {
        let lo = max(1, Int(loHz / binHz))
        let hi = min(fftSize / 2 - 1, Int(hiHz / binHz))
        guard hi >= lo else { return 0 }
        var sum: Float = 0
        for i in lo...hi { sum += amp[i] }
        return sum / Float(hi - lo + 1)
    }

    private func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }

    private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = clamp01((x - edge0) / max(edge1 - edge0, 1e-6))
        return t * t * (3 - 2 * t)
    }
}
