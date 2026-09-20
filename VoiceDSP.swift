import Accelerate
import Foundation

/// Fixed-allocation FFT analyser used by the output tap. It publishes 96
/// logarithmically-spaced bands from 60 Hz to 12 kHz (or Nyquist) as 0...1
/// levels, where 0 is -80 dBFS and 1 is 0 dBFS.
final class SpectrumAnalyzer {
    private let fftSize = 2048
    private let bins = 1024
    private let bandCount = 96
    private let sampleRate: Float
    private let lock = NSLock()
    private var fftSetup: FFTSetup
    private let input: UnsafeMutablePointer<Float>
    private let window: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private let bands: UnsafeMutablePointer<Float>
    private let nextBands: UnsafeMutablePointer<Float>
    private var inputCount = 0

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        fftSetup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
        func allocate(_ count: Int) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
            return pointer
        }
        input = allocate(fftSize)
        window = allocate(fftSize)
        frame = allocate(fftSize)
        real = allocate(bins)
        imaginary = allocate(bins)
        magnitudes = allocate(bins)
        bands = allocate(bandCount)
        nextBands = allocate(bandCount)
        vDSP_hann_window(window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        [input, window, frame, real, imaginary, magnitudes, bands, nextBands].forEach { $0.deallocate() }
    }

    func process(_ samples: UnsafePointer<Float>, count: Int) {
        var sourceOffset = 0
        while sourceOffset < count {
            let copied = min(fftSize - inputCount, count - sourceOffset)
            (input + inputCount).update(from: samples + sourceOffset, count: copied)
            inputCount += copied
            sourceOffset += copied
            guard inputCount == fftSize else { continue }
            analyseFrame()
            inputCount = 0
        }
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return Array(UnsafeBufferPointer(start: bands, count: bandCount))
    }

    private func analyseFrame() {
        vDSP_vmul(input, 1, window, 1, frame, 1, vDSP_Length(fftSize))
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: bins) { complex in
            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(bins))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, 11, FFTDirection(kFFTDirection_Forward))
        imaginary[0] = 0
        vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(bins))

        let upperHz = min(12_000, sampleRate * 0.5)
        let ratio = upperHz / 60
        for band in 0..<bandCount {
            let lowHz = 60 * pow(ratio, Float(band) / Float(bandCount))
            let highHz = 60 * pow(ratio, Float(band + 1) / Float(bandCount))
            let lowBin = max(1, min(bins - 1, Int(lowHz * Float(fftSize) / sampleRate)))
            let highBin = max(lowBin + 1, min(bins, Int(ceil(highHz * Float(fftSize) / sampleRate))))
            var peak: Float = 0
            vDSP_maxv(magnitudes + lowBin, 1, &peak, vDSP_Length(highBin - lowBin))
            let amplitude = max(1e-8, peak * 2 / Float(fftSize))
            let decibels = 20 * log10(amplitude)
            nextBands[band] = max(0, min(1, (decibels + 80) / 80))
        }

        lock.lock()
        bands.update(from: nextBands, count: bandCount)
        lock.unlock()
    }
}

/// Real-time safe STFT voice transformer.
///
/// The design goal is to separate **what was said** from **who said it**:
/// the short-time spectral *envelope* (vocal tract shape, i.e. formants) and
/// the *excitation* (glottal pulse train, i.e. pitch) carry most speaker
/// identity, while timing, syllable boundaries and consonant transients carry
/// the words. This processor warps the envelope and can replace the excitation
/// while leaving frame timing completely untouched — no time stretching, no
/// resampling, so transients stay exactly where they were.
///
/// Every buffer is allocated in `init`. `process` performs no allocation, no
/// locking, no file I/O and no logging, so it is safe to call from an audio
/// thread.
final class SpectralVoiceProcessor {

    /// Per-frame transform settings. Plain values so the audio thread can copy
    /// the whole struct at once without touching shared mutable state.
    struct Parameters {
        /// Formant scale. >1 shortens the apparent vocal tract (brighter,
        /// "smaller" speaker), <1 lengthens it. 0.75...1.35 is the useful range.
        var formantRatio: Float = 1.0
        /// 0...1 depth of piecewise band warping below the consonant region.
        var bandWarp: Float = 0
        /// 0...1 replacement of voiced excitation with shaped noise.
        var whisper: Float = 0
        /// 0...1 presence restoration across 2-5 kHz.
        var clarity: Float = 0
        /// 0...1 depth of slow, continuous drift applied to the warp.
        var morphDepth: Float = 0
        /// Rate of that drift, in Hz.
        var morphRate: Float = 0.15
    }

    // MARK: Configuration

    private let fftSize: Int
    private let hop: Int
    private let bins: Int
    private let log2n: vDSP_Length
    private let sampleRate: Float

    /// Latency the STFT itself adds, in samples. Verified against a measured
    /// impulse response rather than derived — the overlap-add pipeline costs a
    /// full frame, not `fftSize - hop`.
    var latencyInSamples: Int { fftSize }

    // MARK: Preallocated state

    private let window: UnsafeMutablePointer<Float>
    private let inFIFO: UnsafeMutablePointer<Float>
    private let outFIFO: UnsafeMutablePointer<Float>
    private let outAccum: UnsafeMutablePointer<Float>

    private let frame: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>

    private let magnitude: UnsafeMutablePointer<Float>
    private let phase: UnsafeMutablePointer<Float>
    private let logMagnitude: UnsafeMutablePointer<Float>
    private let envelope: UnsafeMutablePointer<Float>
    private let warpedEnvelope: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    private let sinBuffer: UnsafeMutablePointer<Float>
    private let cosBuffer: UnsafeMutablePointer<Float>
    private let clarityCurve: UnsafeMutablePointer<Float>

    private var fftSetup: FFTSetup
    private var rover: Int
    private var normalization: Float
    private var morphPhase: Float = 0
    private var rngState: UInt32 = 0x9E3779B9

    /// Half-width, in bins, of the box filter used to estimate the spectral
    /// envelope. Sized to roughly 300 Hz, which sits between formant spacing
    /// and harmonic spacing so it follows formants but ignores individual
    /// harmonics.
    private let envelopeHalfWidth: Int

    // MARK: Init

    init(sampleRate: Float, fftSize: Int = 1024, overlap: Int = 4, envelopeWidthHz: Float = 300) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hop = fftSize / overlap
        self.bins = fftSize / 2
        self.log2n = vDSP_Length(log2(Double(fftSize)).rounded())

        func allocate(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
            return p
        }

        window = allocate(fftSize)
        inFIFO = allocate(fftSize)
        outFIFO = allocate(fftSize)
        outAccum = allocate(fftSize * 2)
        frame = allocate(fftSize)
        realp = allocate(bins)
        imagp = allocate(bins)
        magnitude = allocate(bins)
        phase = allocate(bins)
        logMagnitude = allocate(bins)
        envelope = allocate(bins)
        warpedEnvelope = allocate(bins)
        scratch = allocate(bins)
        sinBuffer = allocate(bins)
        cosBuffer = allocate(bins)
        clarityCurve = allocate(bins)

        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        rover = fftSize - hop

        // Square-root Hann on both analysis and synthesis. With 75% overlap the
        // squared window sums to a constant, so overlap-add reconstructs exactly.
        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        for i in 0..<fftSize {
            window[i] = sqrt(hann[i])
        }

        // Measure the constant the overlapped squared windows sum to, rather
        // than assuming it, so changing `overlap` stays correct.
        var sum: Float = 0
        var index = 0
        while index < fftSize {
            sum += window[index] * window[index]
            index += hop
        }
        normalization = sum > 0 ? sum : 1

        let binHz = sampleRate / Float(fftSize)
        // Two box passes, so each is half the target width.
        envelopeHalfWidth = max(1, Int(envelopeWidthHz / (2 * binHz)))

        buildClarityCurve(binHz: binHz)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        for p in [window, inFIFO, outFIFO, outAccum, frame, realp, imagp,
                  magnitude, phase, logMagnitude, envelope, warpedEnvelope,
                  scratch, sinBuffer, cosBuffer, clarityCurve] {
            p.deallocate()
        }
    }

    /// A raised bump over the consonant region. Fricatives and stop bursts
    /// (S, T, K, F, P, CH) concentrate here, so this is what the Clarity
    /// control lifts.
    private func buildClarityCurve(binHz: Float) {
        for k in 0..<bins {
            let hz = Float(k) * binHz
            let value: Float
            switch hz {
            case ..<1800:
                value = 0
            case 1800..<2600:
                value = (hz - 1800) / 800
            case 2600..<5000:
                value = 1
            case 5000..<7000:
                value = 1 - (hz - 5000) / 2000
            default:
                value = 0
            }
            clarityCurve[k] = value
        }
    }

    func reset() {
        inFIFO.update(repeating: 0, count: fftSize)
        outFIFO.update(repeating: 0, count: fftSize)
        outAccum.update(repeating: 0, count: fftSize * 2)
        rover = fftSize - hop
        morphPhase = 0
    }

    // MARK: - Processing

    /// Transforms `count` samples in place. Output is delayed by
    /// `latencyInSamples` relative to the input.
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int, parameters: Parameters) {
        let latency = fftSize - hop

        for i in 0..<count {
            inFIFO[rover] = samples[i]
            samples[i] = outFIFO[rover - latency]
            rover += 1

            if rover >= fftSize {
                rover = latency
                transformFrame(parameters)

                // Publish one hop of finished output and slide both FIFOs.
                outFIFO.update(from: outAccum, count: hop)
                memmove(outAccum, outAccum + hop, (fftSize * 2 - hop) * MemoryLayout<Float>.size)
                (outAccum + fftSize * 2 - hop).update(repeating: 0, count: hop)
                memmove(inFIFO, inFIFO + hop, latency * MemoryLayout<Float>.size)
            }
        }
    }

    private func transformFrame(_ p: Parameters) {
        // --- analysis ---
        vDSP_vmul(inFIFO, 1, window, 1, frame, 1, vDSP_Length(fftSize))

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: bins) { typed in
            vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(bins))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

        // vDSP packs Nyquist into imagp[0]; drop it so bin 0 is purely real.
        imagp[0] = 0

        vDSP_zvabs(&split, 1, magnitude, 1, vDSP_Length(bins))
        vDSP_zvphas(&split, 1, phase, 1, vDSP_Length(bins))

        // --- separate envelope (identity) from fine structure (pitch) ---
        var floorValue: Float = 1e-7
        var n32 = Int32(bins)
        vDSP_vsadd(magnitude, 1, &floorValue, scratch, 1, vDSP_Length(bins))
        vvlogf(logMagnitude, scratch, &n32)

        smoothIntoEnvelope()

        // residual = logMagnitude - envelope, kept in logMagnitude
        vDSP_vsub(envelope, 1, logMagnitude, 1, logMagnitude, 1, vDSP_Length(bins))

        // --- warp the envelope: this is the identity change ---
        morphPhase += 2 * .pi * p.morphRate * Float(hop) / sampleRate
        if morphPhase > 2 * .pi { morphPhase -= 2 * .pi }
        let drift = p.morphDepth * 0.18 * sin(morphPhase)
        let ratio = max(0.5, min(2.0, p.formantRatio * (1 + drift)))

        warpEnvelope(ratio: ratio, bandWarp: p.bandWarp)

        // --- excitation replacement ---
        // Flattening the residual removes the harmonic comb (the glottal
        // source) while the envelope — and therefore the words — survives.
        if p.whisper > 0 {
            var keep = 1 - p.whisper
            vDSP_vsmul(logMagnitude, 1, &keep, logMagnitude, 1, vDSP_Length(bins))
        }

        // Bound envelope correction to ±12 dB. Dividing by a deep spectral
        // trough previously produced arbitrarily large gains, accentuating
        // individual harmonics/noise instead of a smooth vocal-tract change.
        // Keep the residual/phase transform; this adds no original-voice mix.
        let maxCorrection: Float = log(10) * 12 / 20
        for k in 0..<bins {
            let correction = max(-maxCorrection, min(maxCorrection, warpedEnvelope[k] - envelope[k]))
            warpedEnvelope[k] = envelope[k] + correction
        }

        // recombine and leave the log domain
        vDSP_vadd(warpedEnvelope, 1, logMagnitude, 1, scratch, 1, vDSP_Length(bins))
        vvexpf(magnitude, scratch, &n32)

        // --- clarity: lift the consonant band ---
        if p.clarity > 0 {
            let boost = p.clarity * 0.9 // up to +5.6 dB (20 log10(1.9))
            for k in 0..<bins {
                magnitude[k] *= 1 + boost * clarityCurve[k]
            }
        }

        // --- phase: randomise for whisper, otherwise keep it intact ---
        if p.whisper > 0 {
            let spread = p.whisper * Float.pi
            for k in 0..<bins {
                phase[k] += spread * nextUniform()
            }
        }

        // --- synthesis ---
        vvsincosf(sinBuffer, cosBuffer, phase, &n32)
        vDSP_vmul(magnitude, 1, cosBuffer, 1, realp, 1, vDSP_Length(bins))
        vDSP_vmul(magnitude, 1, sinBuffer, 1, imagp, 1, vDSP_Length(bins))
        imagp[0] = 0

        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        frame.withMemoryRebound(to: DSPComplex.self, capacity: bins) { typed in
            vDSP_ztoc(&split, 1, typed, 2, vDSP_Length(bins))
        }

        var scale = 1 / (2 * Float(fftSize) * normalization)
        vDSP_vsmul(frame, 1, &scale, frame, 1, vDSP_Length(fftSize))
        vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(fftSize))
        vDSP_vadd(outAccum, 1, frame, 1, outAccum, 1, vDSP_Length(fftSize))
    }

    /// Box-smooths the log magnitude twice to approximate a Gaussian, giving a
    /// spectral envelope that tracks formants but steps over harmonics.
    private func smoothIntoEnvelope() {
        boxFilter(source: logMagnitude, destination: envelope)
        boxFilter(source: envelope, destination: scratch)
        envelope.update(from: scratch, count: bins)
    }

    private func boxFilter(source: UnsafeMutablePointer<Float>,
                           destination: UnsafeMutablePointer<Float>) {
        let width = envelopeHalfWidth
        var runningSum: Float = 0
        for k in 0...min(width, bins - 1) { runningSum += source[k] }
        var count = min(width, bins - 1) + 1

        for k in 0..<bins {
            destination[k] = runningSum / Float(count)
            let leaving = k - width
            let entering = k + width + 1
            if entering < bins {
                runningSum += source[entering]
                count += 1
            }
            if leaving >= 0 {
                runningSum -= source[leaving]
                count -= 1
            }
        }
    }

    /// Resamples the envelope along the frequency axis. `ratio` > 1 moves
    /// formants up. `bandWarp` adds a piecewise stretch that deliberately
    /// leaves the consonant region alone, so words survive the warp.
    private func warpEnvelope(ratio: Float, bandWarp: Float) {
        let binHz = sampleRate / Float(fftSize)
        let consonantStartBin = Float(1800 / binHz)

        for k in 0..<bins {
            var source = Float(k) / ratio

            if bandWarp > 0 {
                // Stretch low/low-mid bands where vocal tract size shows most,
                // fading to identity by the time we reach the fricative region.
                let position = min(1, Float(k) / consonantStartBin)
                let taper = 1 - position * position
                source *= 1 + bandWarp * 0.25 * taper
            }

            if source <= 0 {
                warpedEnvelope[k] = envelope[0]
            } else if source >= Float(bins - 1) {
                warpedEnvelope[k] = envelope[bins - 1]
            } else {
                let index = Int(source)
                let fraction = source - Float(index)
                warpedEnvelope[k] = envelope[index] * (1 - fraction) + envelope[index + 1] * fraction
            }
        }
    }

    /// xorshift PRNG returning -1...1. No allocation, no locks, deterministic
    /// cost — safe on the audio thread, unlike `Float.random`.
    private func nextUniform() -> Float {
        rngState ^= rngState << 13
        rngState ^= rngState >> 17
        rngState ^= rngState << 5
        return Float(Int32(bitPattern: rngState)) / Float(Int32.max)
    }
}

/// Classic swept all-pass phaser.
///
/// A cascade of first-order all-pass sections shifts phase by an amount that
/// varies with frequency; summing that against the dry signal produces notches,
/// and sweeping the sections' break frequency with an LFO walks those notches
/// through the spectrum. Unlike the distortion and reverb units this is not a
/// stock Audio Unit — Apple ships no phaser — so it is implemented here.
///
/// Coefficients update every 32 samples rather than every sample: `tan` is not
/// cheap and the LFO runs at a few Hz, so per-sample recomputation buys nothing
/// audible. All state is preallocated; `process` is safe on an audio thread.
final class Phaser {

    struct Parameters {
        /// 0...1. At 0 the phaser is bypassed entirely.
        var depth: Float = 0
        /// Sweep rate in Hz.
        var rate: Float = 0.4
        /// 0...0.9. Resonance — sharpens the notches.
        var feedback: Float = 0.3
        /// Number of all-pass sections. More sections, more notches.
        var stages: Int = 6
    }

    private let maxStages = 8
    private let sampleRate: Float
    private let controlInterval = 32

    /// Sweep range, chosen to sit over the vowel formants rather than the
    /// consonant band, so the effect colours identity more than clarity.
    private let minHz: Float = 180
    private let maxHz: Float = 1600

    private var lastInput: UnsafeMutablePointer<Float>
    private var lastOutput: UnsafeMutablePointer<Float>
    private var lfoPhase: Float = 0
    private var feedbackSample: Float = 0

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        lastInput = UnsafeMutablePointer<Float>.allocate(capacity: maxStages)
        lastOutput = UnsafeMutablePointer<Float>.allocate(capacity: maxStages)
        lastInput.initialize(repeating: 0, count: maxStages)
        lastOutput.initialize(repeating: 0, count: maxStages)
    }

    deinit {
        lastInput.deallocate()
        lastOutput.deallocate()
    }

    func reset() {
        lastInput.update(repeating: 0, count: maxStages)
        lastOutput.update(repeating: 0, count: maxStages)
        lfoPhase = 0
        feedbackSample = 0
    }

    func process(_ samples: UnsafeMutablePointer<Float>, count: Int, parameters: Parameters) {
        let depth = max(0, min(1, parameters.depth))
        guard depth > 0 else { return }

        let stages = max(2, min(maxStages, parameters.stages))
        let feedback = max(0, min(0.9, parameters.feedback))
        let wet = depth * 0.5

        var index = 0
        while index < count {
            let block = min(controlInterval, count - index)

            // Control-rate LFO. Sweeping logarithmically keeps the movement
            // even to the ear across the range.
            lfoPhase += 2 * .pi * parameters.rate * Float(block) / sampleRate
            if lfoPhase > 2 * .pi { lfoPhase -= 2 * .pi }
            let normalised = 0.5 * (1 + sin(lfoPhase))
            let cutoff = minHz * pow(maxHz / minHz, normalised)

            let tangent = tan(.pi * cutoff / sampleRate)
            let coefficient = (tangent - 1) / (tangent + 1)

            for n in index..<(index + block) {
                let dry = samples[n]
                // Trim what enters the all-pass chain as feedback rises;
                // without this, resonance at high settings pushes peaks past
                // full scale (measured 1.125 with feedback 0.9).
                var value = dry * (1 - feedback * 0.5) + feedbackSample * feedback

                for stage in 0..<stages {
                    let out = coefficient * value + lastInput[stage] - coefficient * lastOutput[stage]
                    lastInput[stage] = value
                    lastOutput[stage] = out
                    value = out
                }

                // Guard the feedback path: a denormal or NaN here would poison
                // every subsequent sample.
                feedbackSample = value.isFinite ? max(-4, min(4, value)) : 0

                samples[n] = dry * (1 - wet) + value * wet
            }
            index += block
        }
    }
}
