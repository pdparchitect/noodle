import AVFoundation
import CoreAudio
import AudioToolbox
import SwiftUI

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
                ? "No microphone is available. Connect one and choose it in Settings → Conversation."
                : "The selected microphone is disconnected. Choose another in Settings → Conversation.")
        }
        return device
    }

    static func configure(_ engine: AVAudioEngine,
                          uid: String = UserDefaults.standard.string(forKey: defaultsKey) ?? "") throws -> Self {
        let device = try resolve(uid: uid,
                                 devices: available(), defaultID: defaultDeviceID)
        // AVAudioEngine already follows the system input through its aggregate
        // device. Re-selecting the physical device needlessly changes that route.
        if uid.isEmpty { return device }
        guard let unit = engine.inputNode.audioUnit else { throw VoiceFailure("The microphone couldn’t be opened.") }
        var current = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: current))
        if AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &current, &size) == noErr, current == device.audioID {
            return device
        }
        var id = device.audioID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout.size(ofValue: id)))
        guard status == noErr else {
            throw VoiceFailure("Couldn’t open \(device.name) (\(status)). Try recording again.")
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

/// Settings > Conversation's microphone choice, for any app that compiles this file. The list is reread while it shows,
/// so a microphone plugged in or out appears without reopening Settings.
struct MicrophoneSettingsSection: View {
    @AppStorage(VoiceInputDevice.defaultsKey) private var microphoneUID = ""
    @State private var microphones: [VoiceInputDevice] = []
    @State private var defaultMicrophoneID: UInt32 = 0
    var devices: () -> [VoiceInputDevice] = VoiceInputDevice.available
    var systemID: () -> UInt32 = { VoiceInputDevice.defaultDeviceID }

    var body: some View {
        Section {
            Picker("Microphone", selection: $microphoneUID) {
                Text(microphones.first(where: { $0.audioID == defaultMicrophoneID })
                    .map { "System Default — \($0.name)" } ?? "System Default").tag("")
                ForEach(microphones) { microphone in
                    Text(microphone.name).tag(microphone.id)
                }
                if !microphoneUID.isEmpty && !microphones.contains(where: { $0.id == microphoneUID }) {
                    Text("Selected microphone unavailable").tag(microphoneUID)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                microphones = devices()
                defaultMicrophoneID = systemID()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }
}
