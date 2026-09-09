import AVFoundation
import CoreAudio
import AudioToolbox

/// Store stable device UIDs, never transient Core Audio object IDs. Selecting a
/// microphone affects this recorder only, not the Mac's system input setting.
struct VoiceInputDevice: Identifiable, Equatable {
    static let defaultsKey = "voiceInputDeviceUID"
    let id: String
    let name: String
    let audioID: AudioDeviceID

    static func available() -> [Self] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Self(id: uid, name: name, audioID: id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static var defaultDeviceID: AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: id))
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    static func resolve(uid: String, devices: [Self], defaultID: AudioDeviceID) throws -> Self {
        guard let device = devices.first(where: { uid.isEmpty ? $0.audioID == defaultID : $0.id == uid }) else {
            throw VoiceFailure(uid.isEmpty
                ? "No microphone is available. Connect one and choose it in Settings → General."
                : "The selected microphone is disconnected. Choose another in Settings → General.")
        }
        return device
    }

    static func configure(_ engine: AVAudioEngine) throws -> Self {
        let device = try resolve(uid: UserDefaults.standard.string(forKey: defaultsKey) ?? "",
                                 devices: available(), defaultID: defaultDeviceID)
        guard let unit = engine.inputNode.audioUnit else { throw VoiceFailure("The microphone couldn’t be opened.") }
        var id = device.audioID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout.size(ofValue: id)))
        guard status == noErr else {
            throw VoiceFailure("Couldn’t open \(device.name) (\(status)). Choose another microphone in Settings → General.")
        }
        return device
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            .contains { $0.mNumberChannels > 0 }
    }
}
