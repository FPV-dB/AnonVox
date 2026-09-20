import Accelerate
import AVFoundation
import AudioToolbox
import Combine

/// Output container for a saved recording.
enum RecordingFormat: String, CaseIterable, Identifiable {
    case wav = "WAV"
    case mp3 = "MP3"

    var id: String { rawValue }
    var fileExtension: String { self == .wav ? "wav" : "mp3" }
}

/// What the speakers are fed. `off` silences them without touching the
/// processing chain, so recording carries on regardless.
enum MonitorSource: String, CaseIterable, Identifiable {
    case off = "Off"
    case original = "Original"
    case processed = "Processed"

    var id: String { rawValue }

    /// Whether anything reaches the speakers in this mode.
    var isAudible: Bool { self != .off }
}

/// Shape of the low-frequency oscillator that wobbles the pitch.
enum LFOWaveform: String, CaseIterable, Identifiable {
    case sine = "Sine"
    case triangle = "Triangle"
    case square = "Square"
    case random = "Random"

    var id: String { rawValue }
}

/// Distortion flavours, drawn from the factory presets on `AVAudioUnitDistortion`.
enum DistortionCharacter: String, CaseIterable, Identifiable {
    case radioTower = "Radio Tower"
    case cosmic = "Cosmic"
    case goldenPi = "Golden Pi"
    case waves = "Waves"
    case echoTight = "Echo Tight"
    case bitBrush = "Bit Brush"

    var id: String { rawValue }

    var preset: AVAudioUnitDistortionPreset {
        switch self {
        case .radioTower: return .speechRadioTower
        case .cosmic:     return .speechCosmicInterference
        case .goldenPi:   return .speechGoldenPi
        case .waves:      return .speechWaves
        case .echoTight:  return .multiEchoTight1
        case .bitBrush:   return .drumsBitBrush
        }
    }
}

/// Reverb spaces, drawn from the factory presets on `AVAudioUnitReverb`.
enum ReverbSpace: String, CaseIterable, Identifiable {
    case smallRoom = "Small Room"
    case mediumRoom = "Medium Room"
    case largeHall = "Large Hall"
    case cathedral = "Cathedral"
    case plate = "Plate"

    var id: String { rawValue }

    var preset: AVAudioUnitReverbPreset {
        switch self {
        case .smallRoom:  return .smallRoom
        case .mediumRoom: return .mediumRoom
        case .largeHall:  return .largeHall
        case .cathedral:  return .cathedral
        case .plate:      return .plate
        }
    }
}

/// Every tunable value in one place, so presets and "reset to defaults" are
/// just a matter of handing the engine a different instance.
struct ScramblerSettings: Equatable {
    var basePitchCents: Float = -200
    var scrambleDepthCents: Float = 60
    var scrambleRateHz: Double = 0.8
    var lfoWaveform: LFOWaveform = .sine

    var eqEnabled = true
    var lowCutEnabled = true
    var lowCutFrequency: Float = 100
    var eqLowGain: Float = 0
    var eqMidGain: Float = 2
    var eqMidFrequency: Float = 2400
    var eqHighGain: Float = 0
    var eqHighFrequency: Float = 6000

    var distortionCharacter: DistortionCharacter = .radioTower
    var distortionMix: Float = 0

    var delayTime: Double = 0.15
    var delayFeedback: Float = 30
    var delayMix: Float = 0

    /// Phaser. Not a stock Audio Unit — see `Phaser` in VoiceDSP.swift.
    var phaserDepth: Float = 0
    var phaserRate: Double = 0.4
    var phaserFeedback: Float = 30
    var phaserStages: Int = 6

    var reverbSpace: ReverbSpace = .mediumRoom
    var reverbMix: Float = 0

    var compressorEnabled = true
    var compressorThreshold: Float = -20
    var compressorMakeupGain: Float = 2

    var monitorVolume: Float = 100

    // --- identity transform (STFT stage) ---
    /// -100...100. Moves formants without moving pitch; the primary identity
    /// control, because vocal tract shape carries more speaker identity than f0.
    var formantShift: Float = 35
    /// 0...100 replacement of voiced excitation with shaped noise.
    var whisperAmount: Float = 0
    /// 0...100 piecewise warping of the bands below the consonant region.
    var bandWarpAmount: Float = 0
    /// 0...100 depth of slow drift applied to the warp, so the disguise has no
    /// single stable signature to characterise.
    var morphDepth: Float = 0
    var morphRate: Double = 0.15
    /// 0...100 scales every identity change at once. Clarity is deliberately
    /// excluded so full strength never has to mean unusable speech.
    var strength: Float = 100

    // --- intelligibility ---
    /// 0...100 presence lift across the 2-5 kHz consonant region.
    var clarityAmount: Float = 40
    /// 0...100 cut depth at `mudFrequency`, where downshifted voices pile up.
    var mudCut: Float = 35
    var mudFrequency: Float = 300
    /// Output trim in dB, used to level-match presets.
    var outputTrim: Float = 0
}

extension ScramblerSettings {

    /// Continuous parameters, listed once so blending can't silently miss one.
    /// `blended(with:amount:)` is covered by a test asserting that amount 0
    /// reproduces the left side exactly and amount 1 the right, which is what
    /// catches a field left out of these lists.
    static let floatKeys: [WritableKeyPath<ScramblerSettings, Float>] = [
        \.basePitchCents, \.scrambleDepthCents,
        \.lowCutFrequency, \.eqLowGain, \.eqMidGain, \.eqMidFrequency,
        \.eqHighGain, \.eqHighFrequency,
        \.distortionMix, \.phaserDepth, \.phaserFeedback,
        \.delayFeedback, \.delayMix, \.reverbMix,
        \.compressorThreshold, \.compressorMakeupGain, \.monitorVolume,
        \.formantShift, \.whisperAmount, \.bandWarpAmount, \.morphDepth,
        \.strength, \.clarityAmount, \.mudCut, \.mudFrequency, \.outputTrim
    ]

    static let doubleKeys: [WritableKeyPath<ScramblerSettings, Double>] = [
        \.scrambleRateHz, \.phaserRate, \.delayTime, \.morphRate
    ]

    /// Mixes two settings sets. Continuous values interpolate; discrete ones
    /// (waveform, distortion character, reverb space, stage count, switches)
    /// can't be averaged meaningfully, so they snap to whichever side is
    /// dominant.
    func blended(with other: ScramblerSettings, amount: Float) -> ScramblerSettings {
        let t = max(0, min(1, amount))
        var result = self

        // Use (1-t)·a + t·b rather than a + (b-a)·t. The latter does not
        // return exactly `b` at t = 1 in floating point — 0.22 to 0.15 lands
        // on 0.15000000000000002 — which makes the endpoints not quite equal
        // the presets they came from.
        for key in Self.floatKeys {
            result[keyPath: key] = (1 - t) * self[keyPath: key] + t * other[keyPath: key]
        }
        let td = Double(t)
        for key in Self.doubleKeys {
            result[keyPath: key] = (1 - td) * self[keyPath: key] + td * other[keyPath: key]
        }

        let dominant = t < 0.5 ? self : other
        result.lfoWaveform = dominant.lfoWaveform
        result.distortionCharacter = dominant.distortionCharacter
        result.reverbSpace = dominant.reverbSpace
        result.phaserStages = dominant.phaserStages
        result.eqEnabled = dominant.eqEnabled
        result.lowCutEnabled = dominant.lowCutEnabled
        result.compressorEnabled = dominant.compressorEnabled

        return result
    }
}

/// Named starting points. Each targets a *different anonymisation mechanism*
/// rather than a different setting of the same one.
enum ScramblerPreset: String, CaseIterable, Identifiable {
    case clearDisguise = "Clear Disguise"
    case deepAnonymous = "Deep Anonymous"
    case neutralAnonymous = "Neutral Anonymous"
    case spectralMask = "Spectral Mask"
    case radioIntelligence = "Radio Intelligence"
    case syntheticVoice = "Synthetic Voice"
    case whisperMask = "Whisper Mask"
    case unstableIdentity = "Unstable Identity"
    case announcer = "Announcer"
    case lighterVoice = "Lighter Voice"
    case telephone = "Telephone"
    case breathyStranger = "Breathy Stranger"
    case distantRoom = "Distant Room"
    case glitchComms = "Glitch Comms"

    var id: String { rawValue }

    /// Grouping for the preset menu, ordered by what the preset costs you in
    /// comprehension.
    enum Category: String, CaseIterable {
        case clear = "Clear"
        case character = "Character"
        case heavy = "Maximum disguise"
    }

    var category: Category {
        switch self {
        case .clearDisguise, .announcer, .lighterVoice, .deepAnonymous, .neutralAnonymous:
            return .clear
        case .telephone, .radioIntelligence, .breathyStranger, .distantRoom:
            return .character
        case .spectralMask, .syntheticVoice, .whisperMask, .unstableIdentity, .glitchComms:
            return .heavy
        }
    }

    /// The mechanism this preset leans on, and what it costs.
    var detail: String {
        switch self {
        case .clearDisguise:
            return "Formant shift with only a small pitch move. The most intelligible disguise."
        case .deepAnonymous:
            return "Lengthened vocal tract plus a real pitch drop. Deep, still clear."
        case .neutralAnonymous:
            return "Aims for an unremarkable voice rather than an obviously processed one."
        case .spectralMask:
            return "Warps low and low-mid bands while leaving the consonant region alone."
        case .radioIntelligence:
            return "Band-limited comms character. Heavily processed but highly articulate."
        case .syntheticVoice:
            return "Partly replaces the glottal source with shaped noise. Uncanny, still readable."
        case .whisperMask:
            return "Near-total excitation replacement — removes pitch identity almost entirely."
        case .unstableIdentity:
            return "Slowly drifts the transform so no single stable voiceprint forms."
        case .announcer:
            return "Level, compressed and forward. A different confident speaker, maximum clarity."
        case .lighterVoice:
            return "Shifts upward instead of down — the disguise direction nothing else here uses."
        case .telephone:
            return "Band-limited to a phone line. Strong timbre disguise, and ears are trained on it."
        case .breathyStranger:
            return "Noise mixed into the glottal source. Breathier and older, still clearly readable."
        case .distantRoom:
            return "Adds room reflections. Texture over clarity — consonants do smear."
        case .glitchComms:
            return "Square-wave wobble and bit-crushed grit. Heaviest disguise, expect lost words."
        }
    }

    var settings: ScramblerSettings {
        var s = ScramblerSettings()
        switch self {
        case .clearDisguise:
            break // the shipped defaults are this preset

        case .deepAnonymous:
            s.formantShift = -42
            s.basePitchCents = -330
            s.mudCut = 48
            s.clarityAmount = 58
            s.eqMidGain = 5
            s.lowCutFrequency = 110

        case .neutralAnonymous:
            s.formantShift = 22
            s.basePitchCents = -120
            s.morphDepth = 18
            s.morphRate = 0.08
            s.clarityAmount = 45
            s.mudCut = 30

        case .spectralMask:
            s.outputTrim = -0.3 // measured level match
            s.formantShift = 28
            s.bandWarpAmount = 70
            s.morphDepth = 30
            s.basePitchCents = -140
            s.clarityAmount = 52
            s.mudCut = 40

        case .radioIntelligence:
            s.formantShift = 20
            s.basePitchCents = -220
            s.distortionCharacter = .radioTower
            s.distortionMix = 24
            s.lowCutFrequency = 200
            s.mudCut = 55
            s.eqMidGain = 6
            s.eqMidFrequency = 2500
            s.eqHighGain = -6
            s.clarityAmount = 60

        case .syntheticVoice:
            s.outputTrim = 3.7 // measured level match
            s.formantShift = 30
            s.whisperAmount = 45
            s.morphDepth = 22
            s.basePitchCents = -160
            s.clarityAmount = 62
            s.mudCut = 42

        case .whisperMask:
            s.outputTrim = 8.4 // measured level match
            s.formantShift = 15
            s.whisperAmount = 85
            s.basePitchCents = 0
            s.scrambleDepthCents = 0
            s.clarityAmount = 72
            s.mudCut = 38

        case .announcer:
            // No wobble at all, hard compression, forward presence.
            s.formantShift = 26
            s.basePitchCents = -150
            s.scrambleDepthCents = 0
            s.clarityAmount = 62
            s.mudCut = 45
            s.eqMidGain = 6
            s.eqMidFrequency = 2600
            s.lowCutFrequency = 110
            s.compressorThreshold = -26
            s.compressorMakeupGain = 8

        case .lighterVoice:
            // The one direction nothing else here goes: upward.
            s.formantShift = 58
            s.basePitchCents = 210
            s.scrambleDepthCents = 40
            s.clarityAmount = 50
            s.mudCut = 25
            s.eqHighGain = -4
            s.lowCutFrequency = 120

        case .telephone:
            // Classic 300 Hz - 3.4 kHz band. Disguises timbre hard while
            // staying very intelligible, because listeners know this sound.
            s.formantShift = 24
            s.basePitchCents = -160
            s.scrambleDepthCents = 0
            s.lowCutFrequency = 300
            s.eqHighFrequency = 3400
            s.eqHighGain = -20
            s.eqMidGain = 7
            s.eqMidFrequency = 1900
            s.mudCut = 50
            s.clarityAmount = 55
            s.compressorThreshold = -24
            s.compressorMakeupGain = 7

        case .breathyStranger:
            s.outputTrim = 2.1 // measured level match
            // Only a little excitation replacement: breath, not whisper.
            s.formantShift = -20
            s.basePitchCents = -170
            s.whisperAmount = 28
            s.morphDepth = 12
            s.morphRate = 0.06
            s.clarityAmount = 60
            s.mudCut = 40
            s.eqHighGain = 2

        case .distantRoom:
            s.formantShift = -30
            s.basePitchCents = -240
            s.reverbSpace = .largeHall
            s.reverbMix = 34
            s.delayMix = 12
            s.delayTime = 0.11
            s.delayFeedback = 18
            s.clarityAmount = 66
            s.mudCut = 50
            s.lowCutFrequency = 140

        case .glitchComms:
            s.outputTrim = -0.3 // measured level match
            s.formantShift = 34
            s.basePitchCents = -300
            s.scrambleDepthCents = 260
            s.scrambleRateHz = 6
            s.lfoWaveform = .square
            s.distortionCharacter = .bitBrush
            s.distortionMix = 38
            s.bandWarpAmount = 35
            s.clarityAmount = 70
            s.mudCut = 52
            s.lowCutFrequency = 180

        case .unstableIdentity:
            s.outputTrim = -0.3 // measured level match
            s.formantShift = 30
            s.morphDepth = 90
            s.morphRate = 0.22
            s.bandWarpAmount = 40
            s.basePitchCents = -180
            s.clarityAmount = 55
            s.mudCut = 40
        }
        return s
    }
}

/// Captures the microphone, warps the pitch on a wobbling LFO, runs it through
/// EQ / distortion / delay / reverb / compression, and plays the result out live.
///
/// AVAudioEngine refuses to initialize a graph that has a time-effect unit
/// (`AVAudioUnitTimePitch`) anywhere downstream of the live input node — it
/// throws `required condition is false: false == isInputConnToConverter`.
/// So instead of wiring the mic straight into the effects, we tap the mic and
/// replay its buffers through an `AVAudioPlayerNode`, which *is* allowed to
/// feed a time effect. The cost is roughly one buffer of extra latency.
final class VoiceScramblerEngine: ObservableObject {

    /// Not a `let`: selecting a different device needs a fresh engine, because
    /// an already-initialised HAL unit rejects `setDeviceID`.
    private var engine = AVAudioEngine()
    private var needsEngineRebuild = false
    private var playerNode = AVAudioPlayerNode()
    /// Converts the mic's format into the chain's processing format. The mic is
    /// often mono, and AVAudioUnitReverb only accepts stereo — connecting it to
    /// a mono bus fails with kAudioUnitErr_FormatNotSupported (-10868).
    private var formatMixer = AVAudioMixerNode()
    private var pitchUnit = AVAudioUnitTimePitch()
    private var eqUnit = AVAudioUnitEQ(numberOfBands: 5)
    private var distortionUnit = AVAudioUnitDistortion()
    private var delayUnit = AVAudioUnitDelay()
    private var reverbUnit = AVAudioUnitReverb()
    private var compressorUnit = VoiceScramblerEngine.makeCompressor()

    private static func makeCompressor() -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription:
            AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                      componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                      componentManufacturer: kAudioUnitManufacturer_Apple,
                                      componentFlags: 0,
                                      componentFlagsMask: 0))
    }

    /// A device change needs an engine that has never been initialised, and
    /// nodes that have never been attached to another engine — reusing either
    /// leaves the graph unable to start.
    private func rebuildEngineAndNodes() {
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        formatMixer = AVAudioMixerNode()
        pitchUnit = AVAudioUnitTimePitch()
        eqUnit = AVAudioUnitEQ(numberOfBands: 5)
        distortionUnit = AVAudioUnitDistortion()
        delayUnit = AVAudioUnitDelay()
        reverbUnit = AVAudioUnitReverb()
        compressorUnit = Self.makeCompressor()
        configureEffects()
    }

    /// Last effect in the chain — what we play out and what we record.
    private var outputTapNode: AVAudioNode { compressorUnit }

    /// Every node `start()` attaches, in signal order.
    private var effectNodes: [AVAudioNode] {
        [playerNode, formatMixer, pitchUnit, eqUnit,
         distortionUnit, delayUnit, reverbUnit, compressorUnit]
    }

    /// One STFT transformer per input channel. Created in `start()` so they
    /// match the device sample rate; never touched from the audio thread except
    /// through `process`.
    private var spectralProcessors: [SpectralVoiceProcessor] = []
    private var phasers: [Phaser] = []

    // Meter backing store. Written from the capture tap and read by a timer on
    // the main thread. Deliberately plain `Float`s rather than @Published:
    // publishing from the audio thread would allocate and hop queues.
    private var meterInputPeak: Float = 0
    private var meterOutputPeak: Float = 0
    private var meterClipped = false
    private var meterDSPLoad: Float = 0
    private var meterTimer: Timer?

    private var tapFormat: AVAudioFormat?
    /// Mono format the captured audio is reduced to before processing.
    ///
    /// Aggregate devices concatenate their subdevices' channels, so a
    /// "mic + BlackHole" aggregate presents the mic on channel 0 and
    /// BlackHole's loopback on channels 1-2 — which is this app's own output.
    /// Capturing every channel would feed that straight back in. Voice is mono
    /// anyway, so taking channel 0 is both the right source and the fix.
    private var captureFormat: AVAudioFormat?
    private var lfoTimer: Timer?
    private var lfoPhase: Double = 0
    private var randomHold: Float = 0
    private var lastRandomCycle = -1
    private let lfoUpdateInterval: Double = 1.0 / 30.0 // 30 Hz control-rate updates

    // Recording state. `recordingFile` is touched from the capture tap as well
    // as the main thread, so every access goes through `recordingLock`.
    private var recordingFile: AVAudioFile?
    private let recordingLock = NSLock()
    private var recordingWAVURL: URL?
    private var recordingStart: Date?
    private var recordingTimer: Timer?

    /// Suppresses per-property pushes while a whole settings struct is applied.
    private var isApplyingSettings = false

    /// Snapshot of the STFT parameters, refreshed on the main thread whenever a
    /// control changes. The capture tap reads this instead of the @Published
    /// properties, which must not be touched from an audio thread.
    private var cachedSpectralParameters = SpectralVoiceProcessor.Parameters()
    private var cachedPhaserParameters = Phaser.Parameters()

    // MARK: Device selection

    /// `nil` means follow the system default.
    @Published var selectedDeviceID: AudioDeviceID? {
        didSet {
            guard oldValue != selectedDeviceID else { return }
            needsEngineRebuild = true
            if isRunning { restart() }
        }
    }
    @Published private(set) var availableDevices: [AudioDevice] = AudioDeviceCatalog.all()
    @Published private(set) var activeSampleRate: Double = 0

    /// Devices that can run the whole chain. Input-only devices are excluded
    /// because AVAudioEngine cannot pair them with a different output.
    var selectableDevices: [AudioDevice] { availableDevices.filter(\.isDuplex) }

    var selectedDevice: AudioDevice? {
        selectedDeviceID.flatMap { id in availableDevices.first { $0.id == id } }
    }

    /// A loopback device (BlackHole and friends) if one is installed.
    var loopbackDevice: AudioDevice? { availableDevices.first(where: \.isLoopback) }

    /// The aggregate this app creates, if it exists.
    var routingDevice: AudioDevice? {
        availableDevices.first { $0.name == AudioDeviceCatalog.routingDeviceName }
    }

    /// A real, physical-ish input to pair with the loopback: anything that
    /// takes audio in and isn't itself a loopback or an aggregate.
    var candidateMicrophone: AudioDevice? {
        let defaultID = AudioDeviceCatalog.defaultInputID()
        let usable = availableDevices.filter { $0.inputChannels > 0 && !$0.isLoopback && !$0.isAggregate }
        return usable.first { $0.id == defaultID } ?? usable.first
    }

    /// Builds the mic + loopback aggregate and selects it, so the processed
    /// voice becomes available to other apps as a microphone.
    func createRoutingDevice() {
        guard let loopback = loopbackDevice else {
            errorMessage = "No loopback device found. Install one first (brew install blackhole-2ch)."
            return
        }
        guard let microphone = candidateMicrophone else {
            errorMessage = "No microphone available to pair with \(loopback.name)."
            return
        }
        do {
            let id = try AudioDeviceCatalog.createRoutingDevice(microphone: microphone, loopback: loopback)
            refreshDevices()
            selectedDeviceID = id
            errorMessage = "Created \"\(AudioDeviceCatalog.routingDeviceName)\" from \(microphone.name) + \(loopback.name). Choose \(loopback.name) as the microphone in the other app."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeRoutingDevice() {
        guard let device = routingDevice else { return }
        if selectedDeviceID == device.id { selectedDeviceID = nil }
        do {
            try AudioDeviceCatalog.removeRoutingDevice(device.id)
            refreshDevices()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshDevices() {
        availableDevices = AudioDeviceCatalog.all()
        // Drop a selection whose device has gone away.
        if let id = selectedDeviceID, !availableDevices.contains(where: { $0.id == id }) {
            selectedDeviceID = nil
            errorMessage = "That audio device disappeared — back to the system default."
        }
    }

    private func restart() {
        stop()
        start()
    }

    @Published private(set) var isRunning = false
    @Published var errorMessage: String?

    @Published private(set) var isRecording = false
    @Published private(set) var isConverting = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published var recordingFormat: RecordingFormat = .wav

    // MARK: Pitch / scramble

    @Published var basePitchCents: Float = ScramblerSettings().basePitchCents {
        didSet { push { if !isRunning { pitchUnit.pitch = basePitchCents } } }
    }
    @Published var scrambleDepthCents: Float = ScramblerSettings().scrambleDepthCents
    @Published var scrambleRateHz: Double = ScramblerSettings().scrambleRateHz
    @Published var lfoWaveform: LFOWaveform = ScramblerSettings().lfoWaveform

    // MARK: EQ

    @Published var eqEnabled = ScramblerSettings().eqEnabled {
        didSet { push { eqUnit.bypass = !eqEnabled } }
    }
    @Published var lowCutEnabled = ScramblerSettings().lowCutEnabled {
        didSet { push { eqUnit.bands[0].bypass = !lowCutEnabled } }
    }
    @Published var lowCutFrequency: Float = ScramblerSettings().lowCutFrequency {
        didSet { push { eqUnit.bands[0].frequency = lowCutFrequency } }
    }
    @Published var eqLowGain: Float = ScramblerSettings().eqLowGain {
        didSet { push { eqUnit.bands[2].gain = eqLowGain } }
    }
    @Published var eqMidGain: Float = ScramblerSettings().eqMidGain {
        didSet { push { eqUnit.bands[3].gain = eqMidGain } }
    }
    @Published var eqMidFrequency: Float = ScramblerSettings().eqMidFrequency {
        didSet { push { eqUnit.bands[3].frequency = eqMidFrequency } }
    }
    @Published var eqHighGain: Float = ScramblerSettings().eqHighGain {
        didSet { push { eqUnit.bands[4].gain = eqHighGain } }
    }
    /// Movable high shelf. Dropping it to ~3.4 kHz band-limits the voice the
    /// way a phone line does: a strong timbre disguise that stays very easy to
    /// understand, because listeners are thoroughly trained on phone audio.
    @Published var eqHighFrequency: Float = ScramblerSettings().eqHighFrequency {
        didSet { push { eqUnit.bands[4].frequency = eqHighFrequency } }
    }

    // MARK: Distortion

    @Published var distortionCharacter: DistortionCharacter = ScramblerSettings().distortionCharacter {
        didSet { push { applyDistortion() } }
    }
    @Published var distortionMix: Float = ScramblerSettings().distortionMix {
        didSet { push { applyDistortion() } }
    }

    // MARK: Delay

    @Published var delayTime: Double = ScramblerSettings().delayTime {
        didSet { push { delayUnit.delayTime = delayTime } }
    }
    @Published var delayFeedback: Float = ScramblerSettings().delayFeedback {
        didSet { push { delayUnit.feedback = delayFeedback } }
    }
    @Published var delayMix: Float = ScramblerSettings().delayMix {
        didSet { push { delayUnit.wetDryMix = delayMix } }
    }

    // MARK: Phaser

    @Published var phaserDepth: Float = ScramblerSettings().phaserDepth { didSet { push {} } }
    @Published var phaserRate: Double = ScramblerSettings().phaserRate { didSet { push {} } }
    @Published var phaserFeedback: Float = ScramblerSettings().phaserFeedback { didSet { push {} } }
    @Published var phaserStages: Int = ScramblerSettings().phaserStages { didSet { push {} } }

    // MARK: Reverb

    @Published var reverbSpace: ReverbSpace = ScramblerSettings().reverbSpace {
        didSet { push { reverbUnit.loadFactoryPreset(reverbSpace.preset); reverbUnit.wetDryMix = reverbMix } }
    }
    @Published var reverbMix: Float = ScramblerSettings().reverbMix {
        didSet { push { reverbUnit.wetDryMix = reverbMix } }
    }

    // MARK: Compressor

    @Published var compressorEnabled = ScramblerSettings().compressorEnabled {
        didSet { push { applyCompressor() } }
    }
    @Published var compressorThreshold: Float = ScramblerSettings().compressorThreshold {
        didSet { push { applyCompressor() } }
    }
    @Published var compressorMakeupGain: Float = ScramblerSettings().compressorMakeupGain {
        didSet { push { applyCompressor() } }
    }

    // MARK: Identity transform (STFT)

    @Published var formantShift: Float = ScramblerSettings().formantShift { didSet { push {} } }
    @Published var whisperAmount: Float = ScramblerSettings().whisperAmount { didSet { push {} } }
    @Published var bandWarpAmount: Float = ScramblerSettings().bandWarpAmount { didSet { push {} } }
    @Published var morphDepth: Float = ScramblerSettings().morphDepth { didSet { push {} } }
    @Published var morphRate: Double = ScramblerSettings().morphRate { didSet { push {} } }
    @Published var strength: Float = ScramblerSettings().strength { didSet { push {} } }

    // MARK: Intelligibility

    @Published var clarityAmount: Float = ScramblerSettings().clarityAmount { didSet { push {} } }
    @Published var mudCut: Float = ScramblerSettings().mudCut {
        didSet { push { eqUnit.bands[1].gain = -mudCut * 0.18 } }
    }
    @Published var mudFrequency: Float = ScramblerSettings().mudFrequency {
        didSet { push { eqUnit.bands[1].frequency = mudFrequency } }
    }
    /// Level-match trim. Applied inside the chain via the EQ's global gain, so
    /// it affects recordings as well as monitoring — a trim on the main mixer
    /// would only change what you hear.
    @Published var outputTrim: Float = ScramblerSettings().outputTrim {
        didSet { push { eqUnit.globalGain = outputTrim } }
    }

    /// Single source of truth for the monitor path: silent, untreated (A/B),
    /// or fully processed. Only `.original` changes the processing — `.off`
    /// leaves the chain running so recordings are unaffected.
    @Published var monitorSource: MonitorSource = .processed {
        didSet { push { applyBypass(); applyMonitor() } }
    }

    /// Remembers what to return to when unmuting.
    private var lastAudibleSource: MonitorSource = .processed

    /// Convenience for the mute button and the Output tab toggle.
    var isMonitorAudible: Bool { monitorSource.isAudible }

    func toggleMonitorMute() {
        if monitorSource == .off {
            monitorSource = lastAudibleSource
        } else {
            lastAudibleSource = monitorSource
            monitorSource = .off
        }
    }

    // MARK: Meters

    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputLevel: Float = 0
    @Published private(set) var isClipping = false
    @Published private(set) var dspLoad: Float = 0
    @Published private(set) var latencyMilliseconds: Double = 0

    // MARK: Monitoring

    @Published var monitorVolume: Float = ScramblerSettings().monitorVolume {
        didSet { push { applyMonitor() } }
    }

    @Published private(set) var activePreset: ScramblerPreset? = nil

    init() {
        configureEffects()
    }

    /// Runs a property's side effect unless we're mid-`apply(_:)`, which does
    /// one bulk `configureEffects()` at the end instead.
    private func push(_ work: () -> Void) {
        guard !isApplyingSettings else { return }
        work()
        cachedSpectralParameters = currentSpectralParameters()
        cachedPhaserParameters = currentPhaserParameters()
        activePreset = nil
        blendPair = nil
    }

    // MARK: - Settings, presets, reset

    var settings: ScramblerSettings {
        ScramblerSettings(basePitchCents: basePitchCents,
                          scrambleDepthCents: scrambleDepthCents,
                          scrambleRateHz: scrambleRateHz,
                          lfoWaveform: lfoWaveform,
                          eqEnabled: eqEnabled,
                          lowCutEnabled: lowCutEnabled,
                          lowCutFrequency: lowCutFrequency,
                          eqLowGain: eqLowGain,
                          eqMidGain: eqMidGain,
                          eqMidFrequency: eqMidFrequency,
                          eqHighGain: eqHighGain,
                          eqHighFrequency: eqHighFrequency,
                          distortionCharacter: distortionCharacter,
                          distortionMix: distortionMix,
                          delayTime: delayTime,
                          delayFeedback: delayFeedback,
                          delayMix: delayMix,
                          phaserDepth: phaserDepth,
                          phaserRate: phaserRate,
                          phaserFeedback: phaserFeedback,
                          phaserStages: phaserStages,
                          reverbSpace: reverbSpace,
                          reverbMix: reverbMix,
                          compressorEnabled: compressorEnabled,
                          compressorThreshold: compressorThreshold,
                          compressorMakeupGain: compressorMakeupGain,
                          monitorVolume: monitorVolume,
                          formantShift: formantShift,
                          whisperAmount: whisperAmount,
                          bandWarpAmount: bandWarpAmount,
                          morphDepth: morphDepth,
                          morphRate: morphRate,
                          strength: strength,
                          clarityAmount: clarityAmount,
                          mudCut: mudCut,
                          mudFrequency: mudFrequency,
                          outputTrim: outputTrim)
    }

    func apply(_ s: ScramblerSettings) {
        isApplyingSettings = true

        basePitchCents = s.basePitchCents
        scrambleDepthCents = s.scrambleDepthCents
        scrambleRateHz = s.scrambleRateHz
        lfoWaveform = s.lfoWaveform

        eqEnabled = s.eqEnabled
        lowCutEnabled = s.lowCutEnabled
        lowCutFrequency = s.lowCutFrequency
        eqLowGain = s.eqLowGain
        eqMidGain = s.eqMidGain
        eqMidFrequency = s.eqMidFrequency
        eqHighGain = s.eqHighGain
        eqHighFrequency = s.eqHighFrequency

        distortionCharacter = s.distortionCharacter
        distortionMix = s.distortionMix

        delayTime = s.delayTime
        delayFeedback = s.delayFeedback
        delayMix = s.delayMix

        phaserDepth = s.phaserDepth
        phaserRate = s.phaserRate
        phaserFeedback = s.phaserFeedback
        phaserStages = s.phaserStages
        reverbSpace = s.reverbSpace
        reverbMix = s.reverbMix

        compressorEnabled = s.compressorEnabled
        compressorThreshold = s.compressorThreshold
        compressorMakeupGain = s.compressorMakeupGain

        monitorVolume = s.monitorVolume

        formantShift = s.formantShift
        whisperAmount = s.whisperAmount
        bandWarpAmount = s.bandWarpAmount
        morphDepth = s.morphDepth
        morphRate = s.morphRate
        strength = s.strength
        clarityAmount = s.clarityAmount
        mudCut = s.mudCut
        mudFrequency = s.mudFrequency
        outputTrim = s.outputTrim

        isApplyingSettings = false
        configureEffects()
        applyMonitor()
        applyBypass()
        cachedSpectralParameters = currentSpectralParameters()
        cachedPhaserParameters = currentPhaserParameters()
    }

    func load(_ preset: ScramblerPreset) {
        apply(preset.settings)
        activePreset = preset
        blendPair = nil
    }

    // MARK: Blending

    /// The two presets currently being mixed, if any.
    @Published private(set) var blendPair: (a: ScramblerPreset, b: ScramblerPreset)?

    /// 0 = entirely the left preset, 100 = entirely the right.
    @Published var blendAmount: Float = 50 {
        didSet {
            guard !isApplyingSettings, blendPair != nil else { return }
            refreshBlend()
        }
    }

    func setBlend(_ a: ScramblerPreset, _ b: ScramblerPreset) {
        blendPair = (a, b)
        refreshBlend()
    }

    func clearBlend() {
        guard let pair = blendPair else { return }
        blendPair = nil
        load(blendAmount < 50 ? pair.a : pair.b)
    }

    private func refreshBlend() {
        guard let pair = blendPair else { return }
        let mixed = pair.a.settings.blended(with: pair.b.settings, amount: blendAmount / 100)
        let remembered = blendPair
        apply(mixed)
        blendPair = remembered   // `apply` clears the preset label; keep the pair
        activePreset = nil
    }

    /// Back to the app's shipped defaults. Leaves monitoring and the recording
    /// format alone — those are session choices, not part of the sound.
    func resetToDefaults() {
        apply(ScramblerSettings())
        activePreset = .clearDisguise
        errorMessage = nil
    }

    /// A fresh disguise, kept inside ranges that stay reasonably intelligible.
    func randomize() {
        var s = settings
        // Formants carry more speaker identity than f0, so randomise those
        // hardest and keep the pitch move modest.
        let formant = Float.random(in: 20...48)
        s.formantShift = Bool.random() ? -formant : formant
        s.basePitchCents = Float.random(in: -280...(-90))
        s.scrambleDepthCents = Float.random(in: 30...110)
        s.scrambleRateHz = Double.random(in: 0.5...1.5)
        s.lfoWaveform = [.sine, .triangle].randomElement() ?? .sine
        s.bandWarpAmount = Float.random(in: 0...45)
        s.morphDepth = Float.random(in: 0...35)
        s.eqMidGain = Float.random(in: 3...6)
        s.eqMidFrequency = Float.random(in: 2000...2800)
        s.eqHighGain = Float.random(in: -5...0)
        s.clarityAmount = Float.random(in: 40...65)
        s.compressorEnabled = true
        apply(s)
        activePreset = nil
    }

    // MARK: - Effect configuration

    /// Puts every effect unit into the state the published properties describe.
    private func configureEffects() {
        eqUnit.globalGain = outputTrim
        eqUnit.bypass = !eqEnabled

        let lowCut = eqUnit.bands[0]
        lowCut.filterType = .highPass
        lowCut.frequency = lowCutFrequency
        lowCut.bypass = !lowCutEnabled

        // Dedicated cut where downshifted voices pile up. The old EQ had a
        // shelf at 120 Hz and a parametric defaulting to 1 kHz, so nothing sat
        // on 200-400 Hz — the main source of the muddiness.
        let mud = eqUnit.bands[1]
        mud.filterType = .parametric
        mud.frequency = mudFrequency
        mud.bandwidth = 1.2
        mud.gain = -mudCut * 0.18 // 0...100 maps to 0...-18 dB
        mud.bypass = false

        let low = eqUnit.bands[2]
        low.filterType = .lowShelf
        low.frequency = 120
        low.gain = eqLowGain
        low.bypass = false

        let mid = eqUnit.bands[3]
        mid.filterType = .parametric
        mid.frequency = eqMidFrequency
        mid.bandwidth = 1.0
        mid.gain = eqMidGain
        mid.bypass = false

        let high = eqUnit.bands[4]
        high.filterType = .highShelf
        high.frequency = eqHighFrequency
        high.gain = eqHighGain
        high.bypass = false

        applyDistortion()

        delayUnit.delayTime = delayTime
        delayUnit.feedback = delayFeedback
        delayUnit.wetDryMix = delayMix
        delayUnit.lowPassCutoff = 15000

        reverbUnit.loadFactoryPreset(reverbSpace.preset)
        reverbUnit.wetDryMix = reverbMix

        applyCompressor()

        pitchUnit.pitch = basePitchCents
        pitchUnit.overlap = 8 // smoother granular quality at large pitch shifts
    }

    /// `loadFactoryPreset` overwrites `wetDryMix`, so the mix is always
    /// re-applied afterwards.
    private func applyDistortion() {
        // Drive at 0 is clean: bypass rather than run a unit at 0% wet, so
        // there is no reason for the control ever to be disabled.
        guard distortionMix > 0 else {
            distortionUnit.bypass = true
            return
        }
        distortionUnit.bypass = false
        distortionUnit.loadFactoryPreset(distortionCharacter.preset)
        distortionUnit.wetDryMix = distortionMix
    }

    /// The Apple dynamics processor has no Swift wrapper, so its parameters go
    /// in through the C Audio Unit API.
    private func applyCompressor() {
        compressorUnit.bypass = !compressorEnabled
        guard compressorEnabled else { return }

        let unit = compressorUnit.audioUnit
        func set(_ parameter: AudioUnitParameterID, _ value: Float) {
            AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, value, 0)
        }
        set(kDynamicsProcessorParam_Threshold, compressorThreshold)
        set(kDynamicsProcessorParam_HeadRoom, 5)
        set(kDynamicsProcessorParam_AttackTime, 0.005)
        set(kDynamicsProcessorParam_ReleaseTime, 0.15)
        set(kDynamicsProcessorParam_OverallGain, compressorMakeupGain)
    }

    private func applyMonitor() {
        engine.mainMixerNode.outputVolume = monitorSource.isAudible ? monitorVolume / 100 : 0
    }

    /// `.original` lifts every transform out of the path so A/B comparisons
    /// hear the untreated mic, without stopping the engine.
    private func applyBypass() {
        let original = monitorSource == .original
        eqUnit.bypass = original || !eqEnabled
        delayUnit.wetDryMix = original ? 0 : delayMix
        reverbUnit.wetDryMix = original ? 0 : reverbMix
        compressorUnit.bypass = original || !compressorEnabled
        if original {
            distortionUnit.bypass = true
            pitchUnit.pitch = 0
        } else {
            applyDistortion()
            pitchUnit.pitch = effectivePitchCents
        }
    }

    /// Strength scales every identity change at once, so one control moves the
    /// disguise without touching the intelligibility controls.
    private var strengthScale: Float { max(0, min(1, strength / 100)) }

    private var effectivePitchCents: Float { basePitchCents * strengthScale }

    /// Phaser settings for the audio thread. Strength scales depth so the
    /// master control governs this like every other identity effect.
    private func currentPhaserParameters() -> Phaser.Parameters {
        var p = Phaser.Parameters()
        guard monitorSource != .original else { return p }
        p.depth = (phaserDepth / 100) * strengthScale
        p.rate = Float(phaserRate)
        p.feedback = phaserFeedback / 100
        p.stages = phaserStages
        return p
    }

    /// Parameters handed to the STFT stage each buffer.
    ///
    /// `AVAudioUnitTimePitch` moves formants along with pitch, so the requested
    /// formant shift is divided by the pitch ratio. The two effects cancel and
    /// the user gets genuinely independent pitch and formant controls.
    func currentSpectralParameters() -> SpectralVoiceProcessor.Parameters {
        var p = SpectralVoiceProcessor.Parameters()
        // `.off` still processes; only the A/B original position bypasses.
        guard monitorSource != .original else { return p }

        let scale = strengthScale
        let targetRatio = pow(2, (formantShift / 100) * 0.45 * scale)
        let pitchRatio = pow(2, effectivePitchCents / 1200)
        p.formantRatio = max(0.5, min(2.0, targetRatio / pitchRatio))

        p.whisper = (whisperAmount / 100) * scale
        p.bandWarp = (bandWarpAmount / 100) * scale
        p.morphDepth = (morphDepth / 100) * scale
        p.morphRate = Float(morphRate)
        p.clarity = clarityAmount / 100 // never scaled by strength
        return p
    }

    /// Test hook: whether the distortion unit is actually in circuit.
    var distortionActive: Bool { !distortionUnit.bypass }

    /// Test hook: the gain actually reaching the speakers.
    var monitorOutputVolume: Float { engine.mainMixerNode.outputVolume }

    /// Test hooks: read back what actually landed on an EQ band.
    func eqBandGain(_ index: Int) -> Float { eqUnit.bands[index].gain }
    func eqBandFreq(_ index: Int) -> Float { eqUnit.bands[index].frequency }

    func requestMicPermissionIfNeeded(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Engine lifecycle

    func start() {
        guard !isRunning else { return }

        if needsEngineRebuild {
            rebuildEngineAndNodes()
            needsEngineRebuild = false
        }

        // Must happen before any format is read: reading initialises the HAL
        // unit, after which setDeviceID fails. Both directions get the same
        // device — different ones fail with -10851.
        if let deviceID = selectedDeviceID {
            do {
                try engine.inputNode.auAudioUnit.setDeviceID(deviceID)
                try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
            } catch {
                let label = selectedDevice?.name ?? "that device"
                errorMessage = "Couldn't use \(label) — falling back to the system default. Devices offering both input and output are required."
                selectedDeviceID = nil
                needsEngineRebuild = false
                rebuildEngineAndNodes()
            }
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = "No input device found. Check System Settings > Sound > Input."
            return
        }
        tapFormat = format
        activeSampleRate = format.sampleRate

        guard let capture = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1) else {
            errorMessage = "Couldn't build a capture format for this device."
            return
        }
        captureFormat = capture

        // Everything after the conversion mixer runs in stereo at the mic's rate.
        let processing = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate,
                                       channels: 2) ?? format

        for node in effectNodes {
            engine.attach(node)
        }

        engine.connect(playerNode, to: formatMixer, format: capture)
        engine.connect(formatMixer, to: pitchUnit, format: processing)
        engine.connect(pitchUnit, to: eqUnit, format: processing)
        engine.connect(eqUnit, to: distortionUnit, format: processing)
        engine.connect(distortionUnit, to: delayUnit, format: processing)
        engine.connect(delayUnit, to: reverbUnit, format: processing)
        engine.connect(reverbUnit, to: compressorUnit, format: processing)
        engine.connect(compressorUnit, to: engine.mainMixerNode, format: processing)

        spectralProcessors = (0..<1).map { _ in
            SpectralVoiceProcessor(sampleRate: Float(format.sampleRate),
                                   fftSize: 1024,
                                   overlap: 4,
                                   envelopeWidthHz: 300)
        }

        configureEffects()
        applyMonitor()
        applyBypass()
        cachedSpectralParameters = currentSpectralParameters()

        phasers = (0..<1).map { _ in
            Phaser(sampleRate: Float(format.sampleRate))
        }

        let stftLatency = Double(spectralProcessors.first?.latencyInSamples ?? 0)
        latencyMilliseconds = (stftLatency / format.sampleRate) * 1000

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.enqueue(buffer)
        }

        // Share the final tap between metering and recording; recording
        // start/stop must not remove the output meter.
        outputTapNode.installTap(onBus: 0, bufferSize: 1024, format: processing) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                var channelPeak: Float = 0
                vDSP_maxmgv(channels[channel], 1, &channelPeak, vDSP_Length(buffer.frameLength))
                peak = max(peak, channelPeak)
            }
            self.meterOutputPeak = peak
            if peak >= 0.999 { self.meterClipped = true }
            self.writeToRecording(buffer)
        }

        engine.prepare()

        do {
            try engine.start()
            guard engine.isRunning else {
                let label = selectedDevice?.name ?? "the selected device"
                errorMessage = "\(label) accepted the settings but wouldn't start. Some virtual devices only run while their host app is active."
                teardownGraph()
                if selectedDeviceID != nil {
                    selectedDeviceID = nil      // falls back to the default next time
                }
                return
            }
            playerNode.play()
            isRunning = true
            errorMessage = nil
            startLFO()
            startMeters()
        } catch {
            teardownGraph()
            // A device can pass configuration and still refuse to run — some
            // virtual devices renegotiate their format when idle. Rather than
            // leave the app dead, drop back to the system default and retry
            // once. The nil check stops this recursing.
            if selectedDeviceID != nil {
                let label = selectedDevice?.name ?? "that device"
                selectedDeviceID = nil
                start()
                errorMessage = isRunning
                    ? "Couldn't run on \(label) — using the system default instead."
                    : "Couldn't start audio engine: \(error.localizedDescription)"
                return
            }
            errorMessage = "Couldn't start audio engine: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRunning else { return }
        if isRecording { stopRecording() }

        lfoTimer?.invalidate()
        lfoTimer = nil
        meterTimer?.invalidate()
        meterTimer = nil
        inputLevel = 0
        outputLevel = 0
        dspLoad = 0
        activeSampleRate = 0

        // Order matters: the tap reads `spectralProcessors`, so it has to stop
        // firing before those are released. Freeing them first races the
        // capture thread and segfaults.
        engine.inputNode.removeTap(onBus: 0)

        playerNode.stop()
        engine.stop()
        teardownGraph()
        spectralProcessors.removeAll()
        phasers.removeAll()

        isRunning = false
    }

    /// The tap reuses its buffer, so copy the samples before handing them off
    /// to the player node.
    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard let capture = captureFormat,
              let copy = AVAudioPCMBuffer(pcmFormat: capture, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData,
              let destination = copy.floatChannelData
        else { return }

        let frames = Int(buffer.frameLength)
        copy.frameLength = buffer.frameLength

        let startedAt = CFAbsoluteTimeGetCurrent()
        let parameters = cachedSpectralParameters
        // Local snapshots: never subscript the shared arrays from this thread.
        let processors = spectralProcessors
        let phaserUnits = phasers
        let phaserParameters = cachedPhaserParameters

        // Channel 0 only — see `captureFormat`.
        let out = destination[0]
        out.update(from: source[0], count: frames)

        var peak: Float = 0
        vDSP_maxmgv(out, 1, &peak, vDSP_Length(frames))
        let inputPeak = peak

        if let processor = processors.first {
            processor.process(out, count: frames, parameters: parameters)
        }
        if let phaser = phaserUnits.first {
            phaser.process(out, count: frames, parameters: phaserParameters)
        }

        // Plain stores, read by a timer on the main thread. No allocation, no
        // locking and no publishing from the audio thread.
        meterInputPeak = inputPeak
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        let bufferDuration = Double(frames) / capture.sampleRate
        if bufferDuration > 0 {
            meterDSPLoad = Float(elapsed / bufferDuration)
        }

        playerNode.scheduleBuffer(copy, completionHandler: nil)
    }

    /// Unwinds everything added in `start()` so a later start rebuilds cleanly.
    private func teardownGraph() {
        engine.inputNode.removeTap(onBus: 0)
        outputTapNode.removeTap(onBus: 0)
        tapFormat = nil
        captureFormat = nil

        for node in effectNodes {
            engine.disconnectNodeInput(node)
        }
        engine.disconnectNodeInput(engine.mainMixerNode)
        for node in effectNodes {
            engine.detach(node)
        }
        engine.reset()
    }

    // MARK: - Meters

    /// Pulls the audio thread's plain counters onto the main thread at 15 Hz
    /// and publishes them. Peak values decay so the meters fall smoothly.
    private func startMeters() {
        meterClipped = false
        isClipping = false
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.inputLevel = max(self.meterInputPeak, self.inputLevel * 0.75)
            self.outputLevel = max(self.meterOutputPeak, self.outputLevel * 0.75)
            self.dspLoad = self.meterDSPLoad
            if self.meterClipped {
                self.isClipping = true
                self.meterClipped = false
            } else {
                self.isClipping = false
            }
        }
    }

    func resetClipIndicator() {
        meterClipped = false
        isClipping = false
    }

    // MARK: - LFO

    private func startLFO() {
        lfoPhase = 0
        lastRandomCycle = -1
        lfoTimer = Timer.scheduledTimer(withTimeInterval: lfoUpdateInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.monitorSource != .original else {
                self.pitchUnit.pitch = 0
                return
            }
            self.lfoPhase += self.lfoUpdateInterval * self.scrambleRateHz * 2 * .pi
            let scale = self.strengthScale
            let wobble = self.lfoValue(at: self.lfoPhase) * self.scrambleDepthCents * scale
            self.pitchUnit.pitch = self.effectivePitchCents + wobble
        }
    }

    /// Normalised -1...1 oscillator value for the selected waveform.
    private func lfoValue(at phase: Double) -> Float {
        switch lfoWaveform {
        case .sine:
            return Float(sin(phase))
        case .triangle:
            return Float(2 / Double.pi * asin(sin(phase)))
        case .square:
            return sin(phase) >= 0 ? 1 : -1
        case .random:
            // Sample and hold: pick a fresh value once per oscillator cycle.
            let cycle = Int(phase / (2 * .pi))
            if cycle != lastRandomCycle {
                lastRandomCycle = cycle
                randomHold = Float.random(in: -1...1)
            }
            return randomHold
        }
    }

    // MARK: - Recording

    /// Directory recordings are written to: ~/Music/Voice Scrambler.
    static var recordingsDirectory: URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Voice Scrambler", isDirectory: true)
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        guard isRunning else {
            errorMessage = "Start the scrambler before recording."
            return
        }

        // Record the fully processed signal: tap the last effect in the chain.
        let format = outputTapNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            errorMessage = "Couldn't determine the output format to record."
            return
        }

        let directory = Self.recordingsDirectory
        let stamp = Self.timestampFormatter.string(from: Date())
        // Always capture to WAV; MP3 is produced by converting this afterwards.
        let wavURL = directory.appendingPathComponent("Scramble \(stamp).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = try AVAudioFile(forWriting: wavURL,
                                       settings: settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            recordingLock.lock()
            recordingFile = file
            recordingLock.unlock()
        } catch {
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
            return
        }

        recordingWAVURL = wavURL

        recordingStart = Date()
        recordingDuration = 0
        lastRecordingURL = nil
        errorMessage = nil
        isRecording = true

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let started = self.recordingStart else { return }
            self.recordingDuration = Date().timeIntervalSince(started)
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStart = nil

        // Releasing the AVAudioFile flushes and closes the WAV.
        recordingLock.lock()
        recordingFile = nil
        recordingLock.unlock()

        isRecording = false

        guard let wavURL = recordingWAVURL else { return }
        recordingWAVURL = nil

        switch recordingFormat {
        case .wav:
            lastRecordingURL = wavURL
        case .mp3:
            convertToMP3(from: wavURL)
        }
    }

    private func writeToRecording(_ buffer: AVAudioPCMBuffer) {
        recordingLock.lock()
        defer { recordingLock.unlock() }
        guard let file = recordingFile else { return }
        try? file.write(from: buffer)
    }

    // MARK: - MP3 export

    /// Apple's frameworks decode MP3 but can't encode it, so shell out to the
    /// `lame` encoder. Falls back to keeping the WAV if it isn't installed.
    private func convertToMP3(from wavURL: URL) {
        guard let lame = Self.locateLAME() else {
            lastRecordingURL = wavURL
            errorMessage = "MP3 needs the 'lame' encoder (brew install lame). Saved as WAV instead."
            return
        }

        let mp3URL = wavURL.deletingPathExtension().appendingPathExtension("mp3")
        isConverting = true

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = lame
            process.arguments = ["--quiet", "-V", "2", wavURL.path, mp3URL.path]

            var failure: String?
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    failure = "lame exited with code \(process.terminationStatus)."
                }
            } catch {
                failure = error.localizedDescription
            }

            DispatchQueue.main.async {
                self.isConverting = false
                if let failure {
                    self.lastRecordingURL = wavURL
                    self.errorMessage = "MP3 conversion failed (\(failure)) — kept the WAV."
                } else {
                    try? FileManager.default.removeItem(at: wavURL)
                    self.lastRecordingURL = mp3URL
                }
            }
        }
    }

    private static func locateLAME() -> URL? {
        let candidates = ["/opt/homebrew/bin/lame", "/usr/local/bin/lame", "/opt/local/bin/lame"]
        return candidates.map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()
}
