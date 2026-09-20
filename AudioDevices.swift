import AVFoundation
import CoreAudio

/// A CoreAudio device as the picker needs to see it.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let sampleRate: Double
    let isAggregate: Bool

    /// AVAudioEngine on macOS drives input and output from a single HAL unit,
    /// so only a device offering both directions can run the whole chain.
    /// Setting input and output to *different* devices fails with
    /// kAudioUnitErr_InvalidPropertyValue (-10851) — verified, not assumed.
    var isDuplex: Bool { inputChannels > 0 && outputChannels > 0 }

    /// Hands-free Bluetooth links run at 16–24 kHz with very little usable
    /// bandwidth above 4 kHz, which strips out most of the consonant energy
    /// the Clarity control exists to protect.
    var isNarrowBand: Bool { sampleRate > 0 && sampleRate < 32000 }

    /// Known loopback drivers — devices whose output is readable as input,
    /// which is what lets another app treat this one as a microphone.
    var isLoopback: Bool {
        let lower = name.lowercased()
        return ["blackhole", "loopback", "soundflower", "vb-cable"].contains { lower.contains($0) }
    }

    var summary: String {
        let rate = sampleRate > 0 ? "\(Int(sampleRate)) Hz" : "unknown rate"
        return "\(inputChannels) in / \(outputChannels) out · \(rate)"
    }
}

/// Enumerates CoreAudio devices. Read-only; nothing here changes system state.
enum AudioDeviceCatalog {

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func all() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard let name = name(of: id) else { return nil }
            let input = channelCount(of: id, input: true)
            let output = channelCount(of: id, input: false)
            guard input > 0 || output > 0 else { return nil }
            return AudioDevice(id: id,
                               name: name,
                               inputChannels: input,
                               outputChannels: output,
                               sampleRate: sampleRate(of: id),
                               isAggregate: isAggregate(id))
        }
    }

    static func defaultInputID() -> AudioDeviceID { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }
    static func defaultOutputID() -> AudioDeviceID { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var addr = address(selector)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return device
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var addr = address(kAudioObjectPropertyName)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    private static func channelCount(of id: AudioDeviceID, input: Bool) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration,
                           input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer) == noErr else { return 0 }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func sampleRate(of id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    private static func isAggregate(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioObjectPropertyClass)
        var value = AudioClassID(0)
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value == kAudioAggregateDeviceClassID
    }
}

extension AudioDeviceCatalog {

    static let routingDeviceName = "Voice Scrambler Routing"
    static let routingDeviceUID = "com.anonvox.routing"

    enum RoutingError: LocalizedError {
        case missingUID
        case creationFailed(OSStatus)
        case removalFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .missingUID:
                return "Couldn't read a device identifier."
            case .creationFailed(let status):
                return "Couldn't create the routing device (CoreAudio status \(status))."
            case .removalFailed(let status):
                return "Couldn't remove the routing device (CoreAudio status \(status))."
            }
        }
    }

    static func existingRoutingDevice() -> AudioDevice? {
        all().first { $0.name == routingDeviceName }
    }

    static func uid(of id: AudioDeviceID) -> String? {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value as String
    }

    /// Builds an aggregate device pairing a real microphone with a loopback
    /// device, which is the only shape AVAudioEngine can use for this job: it
    /// drives input and output from one device, so both have to live inside a
    /// single aggregate.
    ///
    /// The microphone is the clock master. The resulting device exposes the
    /// mic on input channel 0 and the loopback's own input after it — the
    /// engine deliberately captures channel 0 only, or it would re-ingest its
    /// own output.
    @discardableResult
    static func createRoutingDevice(microphone: AudioDevice, loopback: AudioDevice) throws -> AudioDeviceID {
        guard let micUID = uid(of: microphone.id), let loopUID = uid(of: loopback.id) else {
            throw RoutingError.missingUID
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: routingDeviceName,
            kAudioAggregateDeviceUIDKey as String: routingDeviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: 0,
            kAudioAggregateDeviceMasterSubDeviceKey as String: micUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: micUID],
                [kAudioSubDeviceUIDKey as String: loopUID]
            ]
        ]
        var id = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != 0 else { throw RoutingError.creationFailed(status) }
        return id
    }

    static func removeRoutingDevice(_ id: AudioDeviceID) throws {
        let status = AudioHardwareDestroyAggregateDevice(id)
        guard status == noErr else { throw RoutingError.removalFailed(status) }
    }
}
