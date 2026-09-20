import SwiftUI
import AppKit
import AppKit
import CoreAudio


/// A rotary control. Drag vertically to turn it; double-click to return it to
/// `resetsTo`. Used where a value reads better as an amount you dial in than as
/// a position on a line.
struct Knob: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var resetsTo: Float = 0
    var tint: Color = .accentColor
    var caption: String

    @State private var valueAtDragStart: Float?

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((value - range.lowerBound) / span)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            ZStack {
                // 270° of travel, opening at the bottom.
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.secondary.opacity(0.22),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(135))

                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(135))

                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: 13)
                    .offset(y: -17)
                    .rotationEffect(.degrees(-135 + 270 * Double(fraction)))
            }
            .frame(width: 58, height: 58)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gesture in
                        if valueAtDragStart == nil { valueAtDragStart = value }
                        let span = range.upperBound - range.lowerBound
                        // ~150 points of travel covers the whole range.
                        let delta = Float(-gesture.translation.height) / 150 * span
                        value = min(range.upperBound,
                                    max(range.lowerBound, (valueAtDragStart ?? value) + delta))
                    }
                    .onEnded { _ in valueAtDragStart = nil }
            )
            .onTapGesture(count: 2) { value = resetsTo }
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue(caption)
            .accessibilityAdjustableAction { direction in
                let step = (range.upperBound - range.lowerBound) / 20
                switch direction {
                case .increment: value = min(range.upperBound, value + step)
                case .decrement: value = max(range.lowerBound, value - step)
                default: break
                }
            }

            Text(caption)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: 84)
    }
}

/// A scrolling spectrogram: frequency runs left to right and time falls down
/// the display, with the newest processed-audio slice at the bottom.
struct WaterfallSpectrumView: View {
    let history: [[Float]]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Processed spectrum", systemImage: "water.waves")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("newest")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.015, green: 0.025, blue: 0.08)))
                guard let bandCount = history.last?.count, bandCount > 0, !history.isEmpty else { return }
                let cellWidth = size.width / CGFloat(bandCount)
                let cellHeight = size.height / CGFloat(history.count)
                for (row, spectrum) in history.enumerated() {
                    let y = CGFloat(row) * cellHeight
                    for (band, level) in spectrum.enumerated() {
                        let value = max(0, min(1, level))
                        let color = waterfallColor(value)
                        let rect = CGRect(x: CGFloat(band) * cellWidth,
                                          y: y,
                                          width: cellWidth + 0.5,
                                          height: cellHeight + 0.5)
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12)))

            HStack {
                Text("60 Hz")
                Spacer()
                Text("1 kHz")
                Spacer()
                Text("12 kHz")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live processed audio waterfall spectrum")
    }

    private func waterfallColor(_ value: Float) -> Color {
        let v = Double(value)
        if v < 0.35 {
            let t = v / 0.35
            return Color(red: 0.02, green: 0.08 + 0.35 * t, blue: 0.22 + 0.55 * t)
        } else if v < 0.7 {
            let t = (v - 0.35) / 0.35
            return Color(red: 0.02 + 0.18 * t, green: 0.43 + 0.48 * t, blue: 0.77 - 0.55 * t)
        } else {
            let t = (v - 0.7) / 0.3
            return Color(red: 0.2 + 0.8 * t, green: 0.91 - 0.18 * t, blue: 0.22 - 0.16 * t)
        }
    }
}

struct ContentView: View {
    @StateObject private var engine = VoiceScramblerEngine()
    @State private var showResetConfirmation = false
    @State private var showBlend = false
    @State private var blendA: ScramblerPreset = .deepAnonymous
    @State private var blendB: ScramblerPreset = .telephone
    @State private var showSaveSettings = false
    @State private var savedSettingsName = ""

    var body: some View {
        ZStack {
            osintBackground

            VStack(spacing: 14) {
                Text("AnonVox")
                    .font(.title2).bold()

            HStack(spacing: 10) {
                Button(action: toggle) {
                    Label(engine.isRunning ? "Stop" : "Start",
                          systemImage: engine.isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isRunning ? .red : .accentColor)
                .controlSize(.large)

                // Feedback is the most common way this app goes wrong, so the
                // mute lives next to Start rather than buried in a tab.
                Button {
                    engine.toggleMonitorMute()
                } label: {
                    Image(systemName: engine.isMonitorAudible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .frame(width: 30)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(engine.isMonitorAudible ? .secondary : .orange)
                .keyboardShortcut("m", modifiers: .command)
                .help(engine.isMonitorAudible
                      ? "Mute the speakers (⌘M). Processing and recording continue."
                      : "Unmute the speakers (⌘M)")
            }

            if !engine.isMonitorAudible {
                Label("Monitor off — speakers silent. Processing and recording continue.",
                      systemImage: "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            presetBar

            if engine.isRunning {
                WaterfallSpectrumView(history: engine.spectrumHistory)
                    .frame(height: 125)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let message = engine.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

                TabView {
                    identityTab.tabItem { Label("Identity", systemImage: "person.crop.circle.badge.questionmark") }
                    pitchTab.tabItem { Label("Pitch", systemImage: "waveform.path") }
                    eqTab.tabItem { Label("EQ", systemImage: "slider.vertical.3") }
                    effectsTab.tabItem { Label("Effects", systemImage: "wand.and.stars") }
                    outputTab.tabItem { Label("Output", systemImage: "speaker.wave.2") }
                    recordTab.tabItem { Label("Record", systemImage: "record.circle") }
                    helpTab.tabItem { Label("Help", systemImage: "questionmark.circle") }
                }
            }
            .padding(20)
        }
        .confirmationDialog("Reset all sound settings to their defaults?",
                            isPresented: $showResetConfirmation,
                            titleVisibility: .visible) {
            Button("Reset Settings", role: .destructive) { engine.resetToDefaults() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Pitch, EQ, effects and compression go back to defaults. Your recordings are not affected.")
        }
        .alert("Save Current Settings", isPresented: $showSaveSettings) {
            TextField("Name", text: $savedSettingsName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                engine.saveCurrentSettings(named: savedSettingsName)
                savedSettingsName = ""
            }
            .disabled(savedSettingsName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Saving with an existing name updates that saved setting.")
        }
    }

    @ViewBuilder
    private var osintBackground: some View {
        if let url = Bundle.main.url(forResource: "OSINTBackground", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            GeometryReader { geometry in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .opacity(0.42)
                    .overlay(Color.black.opacity(0.48))
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }

    // MARK: - Presets / reset

    private var presetBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    if !engine.savedSettings.isEmpty {
                        Section("Your Settings") {
                            ForEach(engine.savedSettings) { saved in
                                Button(saved.name) { engine.loadSavedSettings(saved) }
                            }
                        }
                    }
                    ForEach(ScramblerPreset.Category.allCases, id: \.self) { category in
                        Section(category.rawValue) {
                            ForEach(ScramblerPreset.allCases.filter { $0.category == category }) { preset in
                                Button(preset.rawValue) { engine.load(preset) }
                            }
                        }
                    }
                } label: {
                    Label(presetLabel, systemImage: "slider.horizontal.3")
                }
                .frame(maxWidth: 220)

                Button {
                    savedSettingsName = activeSavedName ?? presetLabel
                    if savedSettingsName == "Custom" { savedSettingsName = "" }
                    showSaveSettings = true
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .help("Save the current sound settings")

                if !engine.savedSettings.isEmpty {
                    Menu {
                        ForEach(engine.savedSettings) { saved in
                            Button("Delete \(saved.name)", role: .destructive) {
                                engine.deleteSavedSettings(saved)
                            }
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete saved settings")
                }
            }

            HStack(spacing: 8) {
                Button {
                    engine.randomize()
                } label: {
                    Label("Randomize", systemImage: "dice")
                }
                .help("Pick a fresh disguise, kept within intelligible ranges")

                Button {
                    showBlend.toggle()
                    if showBlend && engine.blendPair == nil {
                        engine.setBlend(blendA, blendB)
                    }
                } label: {
                    Label("Blend", systemImage: "arrow.triangle.merge")
                }
                .help("Mix two presets together")

                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .help("Restore all sound settings to defaults")
            }

            if showBlend {
                blendRow
            }

            Picker("Monitor", selection: $engine.monitorSource) {
                ForEach(MonitorSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .help("Off silences the speakers; Original/Processed A/B the untreated mic against the transform")

            Text(engine.blendPair.map { "\($0.a.rawValue) blended with \($0.b.rawValue)." }
                 ?? engine.activePreset?.detail
                 ?? "Your own mix of settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var presetLabel: String {
        if let pair = engine.blendPair {
            return "\(pair.a.rawValue) × \(pair.b.rawValue)"
        }
        return activeSavedName ?? engine.activePreset?.rawValue ?? "Custom"
    }

    private var activeSavedName: String? {
        guard let id = engine.activeSavedSettingID else { return nil }
        return engine.savedSettings.first { $0.id == id }?.name
    }

    /// Two presets and a crossfade between them. Continuous values interpolate;
    /// discrete ones snap to whichever side the slider favours.
    private var blendRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                presetPicker(selection: $blendA)
                Image(systemName: "plus.circle.fill").foregroundStyle(.secondary)
                presetPicker(selection: $blendB)
                Button {
                    showBlend = false
                    engine.clearBlend()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop blending and keep the nearer preset")
            }

            HStack(spacing: 10) {
                Text(blendA.rawValue).font(.caption2).foregroundStyle(.secondary)
                Slider(value: $engine.blendAmount, in: 0...100, step: 1)
                Text(blendB.rawValue).font(.caption2).foregroundStyle(.secondary)
                Text("\(Int(engine.blendAmount))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .padding(.top, 2)
    }

    private func presetPicker(selection: Binding<ScramblerPreset>) -> some View {
        Menu {
            ForEach(ScramblerPreset.Category.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(ScramblerPreset.allCases.filter { $0.category == category }) { preset in
                        Button(preset.rawValue) {
                            selection.wrappedValue = preset
                            engine.setBlend(blendA, blendB)
                        }
                    }
                }
            }
        } label: {
            Text(selection.wrappedValue.rawValue).font(.caption)
        }
        .frame(maxWidth: 170)
    }

    // MARK: - Identity

    private var identityTab: some View {
        Form {
            Section("Vocal tract") {
                labelledSlider("Formant shift",
                               value: $engine.formantShift,
                               range: -100...100,
                               step: 1,
                               caption: formantCaption)
                Text("Moves the vocal resonances without moving pitch. This carries more speaker identity than pitch does, so it is the control to reach for first.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Excitation") {
                labelledSlider("Whisper / noise source",
                               value: $engine.whisperAmount,
                               range: 0...100,
                               step: 1,
                               caption: engine.whisperAmount == 0 ? "off" : "\(Int(engine.whisperAmount))%")
                Text("Replaces the glottal buzz with shaped noise while keeping the vocal-tract envelope, so words survive but pitch identity does not.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Spectral warp") {
                labelledSlider("Band warp",
                               value: $engine.bandWarpAmount,
                               range: 0...100,
                               step: 1,
                               caption: engine.bandWarpAmount == 0 ? "off" : "\(Int(engine.bandWarpAmount))%")
                labelledSlider("Drift depth",
                               value: $engine.morphDepth,
                               range: 0...100,
                               step: 1,
                               caption: engine.morphDepth == 0 ? "off" : "\(Int(engine.morphDepth))%")
                LabeledContent("Drift rate") {
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $engine.morphRate, in: 0.02...0.5, step: 0.01)
                        Text(String(format: "%.2f Hz", engine.morphRate))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Band warp stretches the low and low-mid bands and deliberately leaves 1.8 kHz upward alone, so consonants are untouched. Drift slowly varies the warp so no single stable voiceprint forms.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Strength") {
                labelledSlider("Overall strength",
                               value: $engine.strength,
                               range: 0...100,
                               step: 1,
                               caption: "\(Int(engine.strength))%")
                Text("Scales every identity change at once. Clarity is deliberately excluded, so 100% does not have to mean unintelligible.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var formantCaption: String {
        let v = engine.formantShift
        if v == 0 { return "neutral" }
        return v > 0 ? "+\(Int(v)) — shorter tract (brighter)" : "\(Int(v)) — longer tract (deeper)"
    }

    // MARK: - Pitch

    private var pitchTab: some View {
        Form {
            labelledSlider("Base pitch",
                           value: $engine.basePitchCents,
                           range: -1200...1200,
                           step: 10,
                           caption: "\(Int(engine.basePitchCents)) cents  (±1200 = one octave)")

            labelledSlider("Scramble depth",
                           value: $engine.scrambleDepthCents,
                           range: 0...1500,
                           step: 10,
                           caption: "±\(Int(engine.scrambleDepthCents)) cents")

            LabeledContent("Scramble rate") {
                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: $engine.scrambleRateHz, in: 0.5...20, step: 0.5)
                    Text(String(format: "%.1f Hz", engine.scrambleRateHz))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Picker("Wobble shape", selection: $engine.lfoWaveform) {
                ForEach(LFOWaveform.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(lfoHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var lfoHint: String {
        switch engine.lfoWaveform {
        case .sine:     return "Smooth, continuous warble. Easiest to listen to."
        case .triangle: return "Linear sweep up and down — more even than sine."
        case .square:   return "Jumps between two pitches, robot-intercom feel."
        case .random:   return "A new random pitch each cycle. Best disguise, hardest to follow."
        }
    }

    // MARK: - EQ

    private var eqTab: some View {
        Form {
            Toggle("Enable EQ", isOn: $engine.eqEnabled)

            Section("Intelligibility") {
                labelledSlider("Clarity",
                               value: $engine.clarityAmount,
                               range: 0...100,
                               step: 1,
                               caption: "\(Int(engine.clarityAmount))%")
                labelledSlider("Mud cut",
                               value: $engine.mudCut,
                               range: 0...100,
                               step: 1,
                               caption: String(format: "%.1f dB at %d Hz", -engine.mudCut * 0.18, Int(engine.mudFrequency)))
                labelledSlider("Mud frequency",
                               value: $engine.mudFrequency,
                               range: 150...600,
                               step: 10,
                               caption: "\(Int(engine.mudFrequency)) Hz")
                Text("Clarity lifts 2–5 kHz inside the spectral stage and is never scaled by Strength, to emphasize surviving consonant detail. It cannot recover detail lost during capture or guarantee anonymity. Mud cut removes the 200–400 Hz pile-up that downward pitch shifting creates.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Group {
                Section("Low cut") {
                    Toggle("Remove rumble below cutoff", isOn: $engine.lowCutEnabled)
                    labelledSlider("Cutoff",
                                   value: $engine.lowCutFrequency,
                                   range: 40...300,
                                   step: 5,
                                   caption: "\(Int(engine.lowCutFrequency)) Hz")
                        .disabled(!engine.lowCutEnabled)
                }

                Section("Tone") {
                    labelledSlider("Low shelf @ 120 Hz",
                                   value: $engine.eqLowGain,
                                   range: -24...24,
                                   step: 0.5,
                                   caption: gainCaption(engine.eqLowGain))

                    labelledSlider("Mid gain",
                                   value: $engine.eqMidGain,
                                   range: -24...24,
                                   step: 0.5,
                                   caption: gainCaption(engine.eqMidGain))

                    labelledSlider("Mid frequency",
                                   value: $engine.eqMidFrequency,
                                   range: 200...8000,
                                   step: 50,
                                   caption: "\(Int(engine.eqMidFrequency)) Hz")

                    labelledSlider("High shelf gain",
                                   value: $engine.eqHighGain,
                                   range: -24...24,
                                   step: 0.5,
                                   caption: gainCaption(engine.eqHighGain))

                    labelledSlider("High shelf frequency",
                                   value: $engine.eqHighFrequency,
                                   range: 2000...12000,
                                   step: 100,
                                   caption: "\(Int(engine.eqHighFrequency)) Hz")
                }
            }
            .disabled(!engine.eqEnabled)

            Text("Boosting 1.5–3 kHz sharpens consonants; cutting 6 kHz removes speaker-identity cues. See the Help tab.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func meterRow(_ title: String, level: Float) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                ProgressView(value: Double(min(level, 1)))
                    .tint(level > 0.95 ? .red : (level > 0.7 ? .orange : .green))
                Text(level > 0.0001 ? String(format: "%.0f dB", 20 * log10(level)) : "—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    private func gainCaption(_ value: Float) -> String {
        String(format: "%+.1f dB", value)
    }

    // MARK: - Effects

    private var effectsTab: some View {
        Form {
            Section("Distortion") {
                HStack(alignment: .top, spacing: 18) {
                    Knob(title: "Drive",
                         value: $engine.distortionMix,
                         range: 0...100,
                         tint: .orange,
                         caption: engine.distortionMix == 0 ? "clean" : "\(Int(engine.distortionMix))%")

                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Character", selection: $engine.distortionCharacter) {
                            ForEach(DistortionCharacter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Text("Drive at 0 is clean — the unit is bypassed entirely, so Character only matters once you turn it up. Double-click a knob to zero it.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Phaser") {
                HStack(alignment: .top, spacing: 14) {
                    Knob(title: "Depth",
                         value: $engine.phaserDepth,
                         range: 0...100,
                         tint: .purple,
                         caption: engine.phaserDepth == 0 ? "off" : "\(Int(engine.phaserDepth))%")

                    Knob(title: "Rate",
                         value: Binding(get: { Float(engine.phaserRate) },
                                        set: { engine.phaserRate = Double($0) }),
                         range: 0.05...4,
                         resetsTo: 0.4,
                         tint: .purple,
                         caption: String(format: "%.2f Hz", engine.phaserRate))

                    Knob(title: "Feedback",
                         value: $engine.phaserFeedback,
                         range: 0...90,
                         resetsTo: 30,
                         tint: .purple,
                         caption: "\(Int(engine.phaserFeedback))%")

                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Stages", selection: $engine.phaserStages) {
                            ForEach([2, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text("Swept notches across 180–1600 Hz. More stages means more notches; feedback sharpens them.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Delay") {
                LabeledContent("Time") {
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $engine.delayTime, in: 0...1, step: 0.01)
                        Text(String(format: "%.0f ms", engine.delayTime * 1000))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                labelledSlider("Feedback",
                               value: $engine.delayFeedback,
                               range: -100...100,
                               step: 1,
                               caption: "\(Int(engine.delayFeedback))%")
                labelledSlider("Mix",
                               value: $engine.delayMix,
                               range: 0...100,
                               step: 1,
                               caption: engine.delayMix == 0 ? "off" : "\(Int(engine.delayMix))%")
            }

            Section("Reverb") {
                Picker("Space", selection: $engine.reverbSpace) {
                    ForEach(ReverbSpace.allCases) { Text($0.rawValue).tag($0) }
                }
                labelledSlider("Mix",
                               value: $engine.reverbMix,
                               range: 0...100,
                               step: 1,
                               caption: engine.reverbMix == 0 ? "off" : "\(Int(engine.reverbMix))%")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Output

    private var outputTab: some View {
        Form {
            Section("Audio device") {
                Picker("Device", selection: $engine.selectedDeviceID) {
                    Text("System default").tag(AudioDeviceID?.none)
                    ForEach(engine.selectableDevices) { device in
                        Text(device.name).tag(AudioDeviceID?.some(device.id))
                    }
                }

                if let device = engine.selectedDevice {
                    Text(device.summary + (device.isAggregate ? " · aggregate" : ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if engine.activeSampleRate > 0 {
                    LabeledContent("Running at") {
                        Text("\(Int(engine.activeSampleRate)) Hz")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(engine.activeSampleRate < 32000 ? .orange : .secondary)
                    }
                }

                if engine.activeSampleRate > 0 && engine.activeSampleRate < 32000 {
                    Label("Narrow-band link (Bluetooth hands-free). Most consonant energy above 4 kHz is already gone before processing — switch to a wired or built-in mic for a real improvement.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 10) {
                    Button {
                        engine.refreshDevices()
                    } label: {
                        Label("Refresh list", systemImage: "arrow.clockwise")
                    }

                    if let routing = engine.routingDevice {
                        Button {
                            engine.selectedDeviceID = routing.id
                        } label: {
                            Label("Use routing device", systemImage: "arrow.triangle.branch")
                        }
                        .disabled(engine.selectedDeviceID == routing.id)

                        Button(role: .destructive) {
                            engine.removeRoutingDevice()
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    } else if let loopback = engine.loopbackDevice {
                        Button {
                            engine.createRoutingDevice()
                        } label: {
                            Label("Create routing device", systemImage: "wand.and.stars")
                        }
                        .help("Builds an aggregate of your microphone and \(loopback.name), then selects it")
                    }
                }
                .font(.caption)

                if let loopback = engine.loopbackDevice {
                    Text("\(loopback.name) is installed. **Create routing device** builds an aggregate of your microphone and \(loopback.name) and selects it — then choose **\(loopback.name)** as the microphone in Zoom, Discord or OBS. Only the microphone channel is captured, so the app never re-ingests its own output.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Only devices with **both** input and output are listed: AVAudioEngine drives both directions from one device, and pairing two different ones fails. To send this into another app, install a loopback device (`brew install blackhole-2ch`) and a **Create routing device** button will appear here.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section("Monitoring") {
                Picker("Send to speakers", selection: $engine.monitorSource) {
                    ForEach(MonitorSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                labelledSlider("Monitor volume",
                               value: $engine.monitorVolume,
                               range: 0...100,
                               step: 1,
                               caption: "\(Int(engine.monitorVolume))%")
                    .disabled(!engine.isMonitorAudible)
                Text("**Off** silences the speakers but keeps processing and recording running — the reliable way to avoid feedback when you have no headphones (⌘M toggles it). **Original** bypasses the transform so you can A/B against your untreated voice.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Meters") {
                meterRow("Input", level: engine.inputLevel)
                meterRow("Output", level: engine.outputLevel)
                LabeledContent("Clipping") {
                    Text(engine.isClipping ? "CLIPPING" : "clean")
                        .font(.caption.bold())
                        .foregroundStyle(engine.isClipping ? .red : .secondary)
                }
                LabeledContent("DSP load") {
                    Text(String(format: "%.1f%% of real time", engine.dspLoad * 100))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                LabeledContent("Added latency") {
                    Text(String(format: "%.1f ms (spectral stage)", engine.latencyMilliseconds))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            Section("Level match") {
                labelledSlider("Output trim",
                               value: $engine.outputTrim,
                               range: -12...12,
                               step: 0.1,
                               caption: gainCaption(engine.outputTrim))
                Text("Applied inside the chain, so it affects recordings too. Preset trims are measured, not guessed, so switching preset does not change loudness.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Compressor") {
                Toggle("Even out the volume", isOn: $engine.compressorEnabled)
                Group {
                    labelledSlider("Threshold",
                                   value: $engine.compressorThreshold,
                                   range: -40...0,
                                   step: 1,
                                   caption: "\(Int(engine.compressorThreshold)) dB")
                    labelledSlider("Makeup gain",
                                   value: $engine.compressorMakeupGain,
                                   range: -10...20,
                                   step: 0.5,
                                   caption: gainCaption(engine.compressorMakeupGain))
                }
                .disabled(!engine.compressorEnabled)
                Text("Lifts quiet consonants so they survive the pitch shift. The single biggest win for staying understandable.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Record

    private var recordTab: some View {
        Form {
            Section {
                HStack {
                    Button(action: engine.toggleRecording) {
                        Label(engine.isRecording ? "Stop Recording" : "Record",
                              systemImage: engine.isRecording ? "stop.circle.fill" : "record.circle")
                    }
                    .tint(.red)
                    .disabled(!engine.isRunning || engine.isConverting)

                    Spacer()

                    Picker("Format", selection: $engine.recordingFormat) {
                        ForEach(RecordingFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
                    .disabled(engine.isRecording)
                }

                if engine.isRecording {
                    Label(durationText, systemImage: "waveform")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                } else if engine.isConverting {
                    Label("Converting to MP3…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !engine.isRunning {
                    Text("Start the scrambler first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let url = engine.lastRecordingURL {
                Section("Last recording") {
                    HStack(spacing: 8) {
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .font(.caption)
                    }
                }
            }

            Section {
                Text("Recordings capture the processed output — everything you hear, including EQ and effects. Your unprocessed voice is never written to disk. Files go to ~/Music/Voice Scrambler. MP3 export uses the 'lame' encoder, since Apple's frameworks can't write MP3.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var durationText: String {
        let total = Int(engine.recordingDuration)
        return String(format: "Recording %02d:%02d", total / 60, total % 60)
    }

    // MARK: - Help

    private var helpTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                helpSection(
                    "The short version",
                    "Start on **Clear Disguise** (the default). It changes your vocal-tract shape rather than shredding your pitch, cuts the 200–400 Hz mud, and lifts the consonant band. If you need more disguise, raise **Strength**; if words start slipping, raise **Clarity** — the two are independent on purpose."
                )

                helpSection("Reach for formants before pitch", bullets: [
                    "The **Formant shift** control on the Identity tab moves your vocal resonances without moving pitch. Vocal-tract shape carries more of the \"that\'s Dave\" quality than f0 does, so it disguises more per unit of damage to intelligibility.",
                    "Big pitch shifts are the classic mistake. They drag the formants along with them, which is what produces the boomy monster sound. A modest pitch move plus a firm formant move beats a huge pitch move every time.",
                    "**Whisper** replaces the glottal buzz with shaped noise while keeping the vocal-tract envelope. It removes pitch identity almost entirely and stays surprisingly readable.",
                    "**Drift** slowly varies the transform so there is no single stable voiceprint to characterise across a recording."
                ])

                helpSection("Strength and Clarity are separate on purpose", bullets: [
                    "**Strength** scales every identity change at once. At 0 the transform is fully neutral.",
                    "**Clarity** lifts 2–5 kHz inside the spectral stage and is never scaled by Strength. It emphasizes surviving consonant detail, but heavy transformations can still obscure words; this is not a guarantee of anonymity.",
                    "Use the **Original / Processed** switch at the top to A/B the same phrase without stopping the engine. Preset loudness is measured and matched, so nothing sounds better merely by being louder."
                ])

                helpSection("Pitch: shift it, don't shred it", bullets: [
                    "−300 to −550 cents (or +300 to +500) changes your perceived identity while speech still sounds like a person.",
                    "Past about ±800 cents it turns robotic and listeners start losing words. Bigger is not more anonymous in any useful sense — it's just harder to hear.",
                    "Shifting up and shifting down are equally good disguises. Up tends to stay slightly more intelligible on small speakers."
                ])

                helpSection("The wobble", bullets: [
                    "Depth 60–250 cents at 0.5–2 Hz reads as \"processed voice\" without hurting comprehension much.",
                    "Deep and fast is the most anonymizing combination and the least intelligible. That's the whole trade-off in one control.",
                    "Sine is the easiest to listen to. Random hides you best because there's no steady pattern to subtract, but it costs the most clarity."
                ])

                helpSection("EQ for clarity", bullets: [
                    "Turn on the low cut at 80–150 Hz. It removes desk rumble and handling noise that eat headroom without carrying speech.",
                    "Boost +3 to +6 dB around 1.5–3 kHz. That's where consonants like s, t, k and f live — it's the difference between \"understandable\" and \"mush\".",
                    "Cut 2–4 dB at 6 kHz. High frequencies carry a lot of speaker-identity cues, so this adds disguise and costs little."
                ])

                helpSection("Compression", bullets: [
                    "Turn the compressor on. Threshold around −20 dB with +4 to +6 dB makeup gain.",
                    "It evens out loud and quiet parts, which matters more after pitch shifting because the shift makes quiet consonants even quieter."
                ])

                helpSection("Go easy on these", bullets: [
                    "Distortion at 10–25% mix adds useful disguise. Above roughly 40% intelligibility drops off a cliff.",
                    "Reverb and delay smear consonants together. Leave both at 0% whenever being understood matters; reach for them only when you want texture."
                ])

                helpSection("Technique beats sliders", bullets: [
                    "Speak a little slower and more deliberately than feels natural. This helps more than any control in this app.",
                    "Get closer to the mic and keep background noise down — the processing amplifies whatever else is in the room.",
                    "Use Randomize between sessions rather than reusing one favourite profile, so there's no consistent signature to track across recordings."
                ])

                helpSection("Avoiding the howl", bullets: [
                    "Wear headphones. Without them the mic re-captures the output and the loop screams. This is normal for any live mic-through setup.",
                    "No headphones? Turn off \"Play processed audio out loud\" on the Output tab. Recording keeps working with the speakers silent."
                ])

                helpSection("Using this as a mic in Zoom, Discord or OBS", steps: [
                    "Install a loopback device. BlackHole is free and open source. If it doesn't appear afterwards, run `sudo killall coreaudiod` — CoreAudio only scans for new drivers at launch.",
                    "On the **Output** tab, press **Create routing device**. That builds an aggregate of your microphone and BlackHole and selects it for you; there's no need to touch Audio MIDI Setup.",
                    "In Zoom, Discord or OBS, choose **BlackHole 2ch** as the microphone.",
                    "Press **Start** here. The other app now hears your scrambled voice."
                ])

                copyableCommand("brew install blackhole-2ch")

                helpSection("Why the setup looks like that", bullets: [
                    "macOS will not let one app's output be another app's microphone, so something has to present itself as a real input device in between. That is what BlackHole does.",
                    "The device list here only shows devices with **both** input and output. AVAudioEngine drives both directions from one device — pairing a separate mic and output fails outright — which is why the two have to be bundled into one aggregate device.",
                    "Expect 40–90 ms of added delay end to end. Fine for a conversation, too much for anything that has to stay in sync with video you are also recording.",
                    "If a virtual device accepts the settings but will not actually run, the app falls back to the system default and tells you. Some only work while their host app is running.",
                    "The routing device carries your microphone on channel 0 and BlackHole's loopback after it. Only channel 0 is captured — otherwise the app would hear its own output and feed back.",
                    "**Remove** on the Output tab deletes the routing device again. It is an ordinary aggregate device, so it also shows up in Audio MIDI Setup."
                ])

                helpSection(
                    "What this does and doesn't protect",
                    "This masks the **timbre** of your voice against casual listeners. It is not forensic-grade anonymity. A fixed pitch shift can be estimated and largely undone, and your cadence, vocabulary, accent, grammar, and background noise all survive the processing untouched. Treat it as a disguise, not as protection against someone who is determined and well-resourced."
                )
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func helpSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).bold()
            Text(.init(body)).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Numbered steps, for instructions where the order actually matters.
    private func helpSection(_ title: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).bold()
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .trailing)
                    Text(.init(step))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func copyableCommand(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .font(.caption)
            .buttonStyle(.borderless)
            Spacer()
        }
    }

    private func helpSection(_ title: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).bold()
            ForEach(bullets, id: \.self) { bullet in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text(.init(bullet))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func labelledSlider(_ title: String,
                                value: Binding<Float>,
                                range: ClosedRange<Float>,
                                step: Float.Stride,
                                caption: String) -> some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 2) {
                Slider(value: value, in: range, step: step)
                Text(caption)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func toggle() {
        if engine.isRunning {
            engine.stop()
        } else {
            engine.requestMicPermissionIfNeeded { granted in
                if granted {
                    engine.start()
                } else {
                    engine.errorMessage = "Microphone access is required. Enable it in System Settings > Privacy & Security > Microphone."
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
