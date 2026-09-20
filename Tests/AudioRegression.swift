import Foundation

@main
struct AudioRegression {
    static func render(_ input: [Float], rate: Float,
                       parameters: SpectralVoiceProcessor.Parameters,
                       chunk: Int = 257) -> [Float] {
        let processor = SpectralVoiceProcessor(sampleRate: rate, envelopeWidthHz: 300)
        var output = input + [Float](repeating: 0, count: processor.latencyInSamples)
        output.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = min(chunk, buffer.count - offset)
                processor.process(buffer.baseAddress! + offset, count: count, parameters: parameters)
                offset += count
            }
        }
        return Array(output.dropFirst(processor.latencyInSamples))
    }

    static func main() {
        for rate: Float in [24000, 44100, 48000] {
            let input: [Float] = (0..<Int(rate)).map { n in
                let t = Float(n) / rate
                return 0.12 * sin(2 * .pi * 120 * t) + 0.05 * sin(2 * .pi * 2400 * t)
            }
            let neutral = SpectralVoiceProcessor.Parameters()
            let roundTrip = render(input, rate: rate, parameters: neutral)
            // Ignore startup/end windows and compare with latency removed.
            let range = 2048..<(input.count - 2048)
            let error = range.reduce(Float(0)) { $0 + pow(roundTrip[$1] - input[$1], 2) }
            let energy = range.reduce(Float(0)) { $0 + input[$1] * input[$1] }
            let errorDB = 10 * log10(error / energy)
            precondition(errorDB < -70, "Neutral reconstruction: \(errorDB) dB")
            for ratio: Float in [0.5, 0.8, 1.25, 2] {
                var p = neutral
                p.formantRatio = ratio
                p.clarity = 0.4
                let output = render(input, rate: rate, parameters: p)
                precondition(output.allSatisfy { $0.isFinite })
                let peak = output.map { abs($0) }.max()!
                precondition(peak < 1, "Warp amplified quiet fixture above full scale: \(peak)")
                let otherChunks = render(input, rate: rate, parameters: p, chunk: 1024)
                precondition(zip(output, otherChunks).allSatisfy { abs($0 - $1) < 1e-6 }, "Buffer-size dependent DSP")
                print("rate=\(rate) ratio=\(ratio) peak=\(peak)")
            }
            var heavy = neutral
            heavy.formantRatio = 1.3
            heavy.whisper = 0.85
            heavy.bandWarp = 0.7
            heavy.morphDepth = 0.8
            heavy.clarity = 1
            precondition(render(input, rate: rate, parameters: heavy).allSatisfy { $0.isFinite })
            print("neutral reconstruction at \(rate): \(errorDB) dB")
        }
        for left in ScramblerPreset.allCases {
            for right in ScramblerPreset.allCases {
                precondition(left.settings.blended(with: right.settings, amount: 0) == left.settings)
                precondition(left.settings.blended(with: right.settings, amount: 1) == right.settings)
            }
        }
        let engine = VoiceScramblerEngine()
        precondition(engine.eqBandFreq(0) == 100)
        precondition(abs(engine.eqBandGain(1) + 6.3) < 0.001)
        precondition(engine.eqBandGain(3) == 2)
        precondition(engine.eqBandGain(4) == 0)
        precondition(!engine.distortionActive)

        let encoded = try! JSONEncoder().encode(ScramblerPreset.telephone.settings)
        let decoded = try! JSONDecoder().decode(ScramblerSettings.self, from: encoded)
        precondition(decoded == ScramblerPreset.telephone.settings, "Saved settings did not round-trip")

        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        let analyzerInput: [Float] = (0..<4096).map { n in
            0.25 * sin(2 * .pi * 1_000 * Float(n) / 48_000)
        }
        analyzerInput.withUnsafeBufferPointer { input in
            analyzer.process(input.baseAddress!, count: input.count)
        }
        let spectrum = analyzer.snapshot()
        precondition(spectrum.count == 96 && spectrum.max()! > 0.5,
                     "Spectrum analyser did not produce visible bands")

        print("PASS: DSP, 196 preset blend pairs, settings persistence, spectrum analyser, default EQ and distortion bypass")
    }
}
