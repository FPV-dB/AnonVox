# Voice Scrambler (macOS, Swift + SwiftUI + AVAudioEngine)

A small real-time voice scrambler: it captures your mic, wobbles the pitch
up and down on an LFO, adds a gritty distortion/EQ pass, and plays the
result out live. Four sliders control base pitch, wobble depth, wobble
speed, and distortion mix.

## How it works

The design treats **intelligibility** and **anonymity** as two separate
objectives rather than piling effects on top of each other. Speaker identity
lives mostly in the spectral *envelope* (vocal tract shape) and the *excitation*
(glottal source); the words live in timing, syllable boundaries and consonant
transients. So the chain modifies the former and leaves the latter alone.

```
mic → tap → SpectralVoiceProcessor (STFT: formant warp, band warp,
                                    excitation replacement, slow drift, clarity)
    → AVAudioPlayerNode
    → AVAudioUnitTimePitch      (pitch only; formant side-effect cancelled)
    → AVAudioUnitEQ (5 band: low cut, mud cut, low shelf, presence, high shelf)
    → distortion → delay → reverb  (all default to off)
    → dynamics processor → main mixer → output
```

`SpectralVoiceProcessor` (`VoiceDSP.swift`) is a 1024-point STFT with 75%
overlap and a square-root Hann window, built on Accelerate/vDSP. It estimates
the spectral envelope, warps it along the frequency axis, and recombines it with
the unwarped fine structure — which moves the formants while leaving pitch
untouched. Measured behaviour:

- neutral round-trip error **−97.8 dB** relative to signal
- pitch held at exactly 120 Hz while formants move
- **0.8%** of real time CPU, **23.2 ms** added latency at 48 kHz
- `process()` performs no allocation, locking, file I/O or logging

Because `AVAudioUnitTimePitch` moves formants along with pitch, the requested
formant shift is divided by the pitch ratio before being handed to the STFT
stage. The two cancel, giving genuinely independent pitch and formant controls.

### Why the old chain sounded muddy

1. The LFO defaulted to ±900 cents at 5 Hz — a full 18-semitone excursion every
   200 ms, against a syllable length of 150–250 ms. Formant trajectories are the
   main vowel cue and this destroyed them. Now ±60 cents at 0.8 Hz.
2. `AVAudioUnitTimePitch` is not formant-preserving, so −500 cents dragged the
   whole envelope down 25%. Now the formant shift is an explicit, independent
   control and the default pitch move is −200 cents.
3. Nothing addressed 200–400 Hz, exactly where a downshifted voice piles up.
   There is now a dedicated mud-cut band, on by default.
4. Distortion was on by default at 20% with a band-limited preset. Now Clean.
5. There was no metering or gain staging at all. There are now input/output
   meters, a clip indicator, DSP load, latency readout, and measured per-preset
   level matching applied inside the chain so it affects recordings too.

### Two AVAudioEngine constraints this design works around

Both abort the process with an uncaught Objective-C exception rather than
returning an error:

1. **A time effect cannot sit downstream of the live input node.** Wiring
   `inputNode` into `AVAudioUnitTimePitch` aborts with `required condition is
   false: false == isInputConnToConverter`. Inserting mixers does *not* help —
   the check walks the whole input chain. Feeding the time effect from an
   `AVAudioPlayerNode` is the supported workaround.
2. **`AVAudioUnitReverb` is stereo-only.** On a mono bus it fails with
   `kAudioUnitErr_FormatNotSupported` (-10868). A mixer converts mono to stereo
   before the effects chain.

## Controls

A preset menu sits under the Start button with fourteen starting points,
grouped by what they cost you in comprehension. Loudness is measured per preset
and matched inside the chain, so nothing sounds better merely by being louder.
**Randomize** picks a fresh disguise inside intelligible ranges and **Reset**
restores defaults; editing any slider switches the label to "Custom".

**Blend** mixes two presets. Continuous parameters interpolate; discrete ones
(LFO shape, distortion character, reverb space, stage count, switches) snap to
whichever side the slider favours, since averaging them is meaningless. The
blend is driven from key-path lists in `ScramblerSettings`, with a test
asserting that amount 0 reproduces the left preset exactly and amount 1 the
right — across all 196 ordered pairs. That endpoint check is what catches a
field omitted from the lists, and it also caught a floating-point issue: the
usual `a + (b - a)·t` does not return exactly `b` at t = 1, so the blend uses
`(1 - t)·a + t·b` instead.

| Group | Preset | Mechanism |
|---|---|---|
| Clear | Clear Disguise | Formant shift, small pitch move (the default) |
| Clear | Announcer | No wobble, hard compression, forward presence |
| Clear | Lighter Voice | Shifts **upward** — the one direction the others don't |
| Clear | Deep Anonymous | Lengthened tract plus a real pitch drop |
| Clear | Neutral Anonymous | Aims for unremarkable rather than obviously processed |
| Character | Telephone | 300 Hz–3.4 kHz band limit; strong timbre disguise, very readable |
| Character | Radio Intelligence | Band-limited comms character |
| Character | Breathy Stranger | 28% excitation replacement — breath, not whisper |
| Character | Distant Room | Room reflections; texture over clarity |
| Maximum | Spectral Mask | Band warping below the consonant region |
| Maximum | Synthetic Voice | 45% excitation replacement |
| Maximum | Whisper Mask | 85% excitation replacement; removes pitch identity |
| Maximum | Unstable Identity | Slow drift so no stable voiceprint forms |
| Maximum | Glitch Comms | Square-wave wobble and bit-crushed grit |

- **Pitch** — base shift in cents (±1200 = one octave), wobble depth and
  rate, and the LFO shape. Random is the hardest to follow by ear.
- **EQ** — a 5-band `AVAudioUnitEQ`: a switchable high-pass low cut, a dedicated mud cut, a low
  shelf at 120 Hz, a sweepable parametric mid, and a high shelf at 6 kHz,
  each ±24 dB, plus a global bypass.
- **Effects** — a **Drive** knob for distortion (six `AVAudioUnitDistortion`
  factory presets for character; drive at 0 bypasses the unit, so there is no
  separate "clean" setting and the knob is never disabled), a **phaser** with
  Depth / Rate / Feedback knobs and a 2–8 stage selector, plus delay and reverb.
  Delay, reverb and phaser all default to off. Knobs drag vertically and
  double-click to reset.

  The phaser is not a stock Audio Unit — Apple ships none — so it is
  implemented in `VoiceDSP.swift` as a cascade of first-order all-pass sections
  with an LFO on their break frequency, sweeping 180–1600 Hz. Coefficients
  update at a 32-sample control rate. Verified: bit-exact bypass at depth 0,
  notches sweeping (1488 Hz → 480 Hz over one second at 0.25 Hz), and stable
  for 10 s at feedback 0.9 with 8 stages (peak 0.683, no clipping).
- **Output** — a three-way monitor (**Off / Original / Processed**) and volume,
  plus a compressor. The same control sits in the header with a ⌘M mute
  shortcut. **Off** silences the speakers while processing and recording carry
  on; **Original** bypasses the transform for A/B against your untreated voice. The compressor
  is Apple's `kAudioUnitSubType_DynamicsProcessor`, which has no Swift
  wrapper, so its parameters are set through `AudioUnitSetParameter`.
  Turning the monitor **off** silences the speakers while recording
  continues — the reliable way to avoid feedback without headphones.
- **Record** — captures the fully processed output to
  `~/Music/Voice Scrambler`. WAV is written natively; **MP3 requires the
  `lame` encoder** (`brew install lame`), because Apple's frameworks can
  decode MP3 but not encode it. If `lame` is missing the app keeps the WAV
  and says so. The unprocessed voice is never written to disk.
- **Help** — in-app guidance on staying anonymous while remaining
  understandable, including an honest note on what this does *not* protect
  against.

## Routing into Zoom, Discord or OBS

macOS will not let one app's output become another app's microphone, so a
virtual audio device has to sit in between. There is a second constraint that
shapes the whole setup: **AVAudioEngine drives input and output from a single
HAL unit**, so the app cannot take audio from your mic and send it to a
different device. Verified rather than assumed — setting input and output to
two different devices fails with `kAudioUnitErr_InvalidPropertyValue` (-10851),
and setting only the input leaves the output format at 0 Hz with the engine
refusing to run.

The way around both is an aggregate device:

1. `brew install blackhole-2ch`. If it doesn't show up afterwards, run
   `sudo killall coreaudiod` — CoreAudio only scans for HAL drivers at launch,
   so a daemon older than the install will never see it.
2. In Voice Scrambler, **Output → Create routing device**. That builds the
   aggregate (microphone + BlackHole, mic as clock master) and selects it.
   Audio MIDI Setup is not required; **Remove** deletes it again.
3. In Zoom / Discord / OBS, choose **BlackHole 2ch** as the microphone.

Verified end to end on a MacBook Air mic plus BlackHole 2ch: the aggregate
enumerates as 3 in / 2 out at 48 kHz, the engine runs on it at 21.3 ms added
latency and 0.9% CPU, and a separate process listening on BlackHole's input
goes from 0.00000 to 0.078 peak once the scrambler starts.

The aggregate presents the microphone on input channel 0 and BlackHole's
loopback on channels 1–2 — which is this app's own output. **The engine
captures channel 0 only**; capturing all of them would feed the output
straight back in. Measured stable across successive windows, no runaway.

Resulting chain: `mic → aggregate → Voice Scrambler → BlackHole → other app`.

Notes:

- **Latency.** The spectral stage adds one FFT frame — 21 ms at 48 kHz, 43 ms
  at 24 kHz — and the tap-plus-player buffering roughly doubles it. Fine for a
  call, too much for anything needing tight sync.
- **Avoid Bluetooth hands-free mics.** In call mode AirPods run at 24 kHz mono
  with little usable content above 4 kHz, which throws away the consonant
  energy Clarity exists to protect. The app flags this with a narrow-band
  warning next to the device picker. A built-in or wired mic at 48 kHz is a
  large, free quality win.
- Some virtual devices accept configuration and then refuse to start, or
  renegotiate their format when idle. The app detects a device that starts
  without actually running, falls back to the system default, and says so.

## Setting it up in Xcode (5 minutes)

1. Open Xcode → **File > New > Project** → macOS → **App**.
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Name it `VoiceScrambler` (or whatever you like).
2. Xcode generates `VoiceScramblerApp.swift`, `ContentView.swift`, and
   `Info.plist` automatically — **delete the generated
   `VoiceScramblerApp.swift` and `ContentView.swift`** and drag in the
   three `.swift` files from this folder instead (check "Copy items if
   needed").
3. Add the microphone permission key: select your target → **Info** tab →
   click **+** → add `Privacy - Microphone Usage Description` (this is
   `NSMicrophoneUsageDescription` under the hood) → set the value to
   something like *"Voice Scrambler needs microphone access to process
   your voice."* (See `Info-additions.plist` for the raw key/value.)
4. Turn off the App Sandbox, or configure it for audio input:
   - Select your target → **Signing & Capabilities**.
   - If "App Sandbox" is present, either remove it (simplest, fine for a
     personal/dev-signed build), or keep it and make sure **Audio Input**
     is checked.
5. Build and run (⌘R). The first time you hit Start, macOS will prompt
   for microphone access — allow it.

## Usage notes

- **Wear headphones.** Without them, the speaker output will feed back
  into the mic and howl/scream — this is normal for any live mic-through
  setup, not a bug.
- **Base pitch** shifts the whole voice up or down (in cents; ±1200 =
  one octave).
- **Scramble depth/rate** control how far and how fast the pitch wobbles
  around that base — low rate + high depth gives a slow "warping" effect,
  high rate + moderate depth gives a more jittery/robotic effect.
- **Grit** blends in the distortion unit for a rougher, more disguised
  texture.

## Extending it

A few natural next steps if you want to push it further:
- Swap `.speechRadioTower` for another `AVAudioUnitDistortion` preset
  (e.g. `.multiEcho1`, `.multiEcho2`) for a different character.
- Add an `AVAudioUnitReverb` node in the chain for spatial texture.
- Add a "randomize" button that jumps `basePitchCents` to a new random
  value each time you press Start, so the disguise changes per session.
- For routing into other apps (Zoom, Discord, etc.) rather than just
  playing out loud, you'd need a virtual audio device (e.g. via
  BlackHole or a custom Audio Server Plug-In) so this app's output can
  be selected as another app's microphone input — that's a separate,
  more involved project since it requires a system audio driver rather
  than just an AVAudioEngine graph.

## September 2026 clarity revision

Build with `bash build.sh --no-run`; run repeatable checks with `bash test.sh`.
`Info.plist` is source configuration in the repository root. `build/`, the
standalone `VoiceScrambler` executable, and macOS/Xcode local metadata are
ignored. Icons remain tracked. Existing Git history is retained.

The live path is channel 0 → STFT → optional phaser → mono/stereo mixer →
pitch → five-band EQ → distortion → delay → reverb → compression → monitor.
The final compressor output supplies both recording and metering, before
monitor volume/mute. Original monitor mode bypasses processing and therefore
also changes what a concurrent recording captures; use Processed or Off when
recording a disguised voice.

Changes in this revision:

- Bound the formant envelope correction to ±12 dB per bin. Previously a
  warped envelope divided by a quiet spectral trough could produce unbounded
  gain. The bound limits that coloration without adding an untreated voice
  signal to the processed path. Extreme formant settings may sound milder.
- Increase the live envelope smoothing width from 180 to 300 Hz to reduce
  harmonic-scale coloration. Pitch, formant, band-warp, whisper and modulation
  controls remain available. This is still an approximate envelope estimator.
- Default high-pass: 90 → 100 Hz; presence EQ: +4 → +2 dB at 2.4 kHz;
  high shelf: −2 → 0 dB at 6 kHz; compressor makeup: +4 → +2 dB.
  Keep the existing −6.3 dB mud cut at 300 Hz and 40% spectral clarity.
  These defaults preserve consonant bandwidth and reduce stacked gain.
  Presets inherit these changes unless they explicitly override a field.
- Meter the final processed stereo signal instead of the pre-EQ mono buffer.
  Recording start/stop now shares that tap without disconnecting metering.
- Correct the clarity gain comment: its maximum amplitude multiplier of 1.9
  is +5.6 dB, not +8 dB. Clarify the UI wording about recovery and anonymity.

The earlier README's measured loudness/CPU and perceptual claims describe
prior work, not validation of this revision. Existing preset trims have not
been recalibrated for these changes. Strong whisper replacement, square/random
pitch modulation, phaser notches, distortion and wet delay/reverb can still
reduce intelligibility. Bluetooth capture bandwidth and unusually loud input
can also dominate the result; no filter can recover missing consonants.

Automated checks cover neutral STFT reconstruction, finite transformed output,
chunk-size independence at 24/44.1/48 kHz, all 196 preset-blend endpoint pairs,
and configured default EQ/distortion bypass. They use synthetic signals;
they do not measure word recognition, speaker anonymity, microphone routing,
or live recording behavior. Listening with representative speech remains
necessary. The output clip indicator now observes downstream boosts, but the
compressor is not a guaranteed brick-wall limiter.
