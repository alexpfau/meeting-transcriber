import CoreAudio
import Foundation

/// CoreAudio queries backing `OutputDeviceAnchorPolicy`. Split from the policy
/// so the rules stay testable without hardware: everything here talks to the
/// HAL and returns plain values, everything there is a pure function of those
/// values.
enum OutputDeviceEnumeration {
    /// Every device on the system that can play audio, in HAL enumeration
    /// order. Input-only devices are excluded — an aggregate anchored to one
    /// has no output clock to follow.
    static func outputDevices() -> [OutputDeviceAnchorPolicy.Device] {
        deviceIDs().compactMap(describeOutputDevice)
    }

    /// The system default output as the policy wants it. `nil` when the HAL
    /// cannot answer, which is the same condition `getDefaultOutputDeviceUID`
    /// already treats as fatal for a capture attempt.
    static func defaultOutputDevice() -> OutputDeviceAnchorPolicy.Device? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID,
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        // Deliberately not `describeOutputDevice`: the default output is by
        // definition an output, and a driver that answers the stream-config
        // query oddly should not make the whole capture attempt fail.
        guard let uid = readCFStringAudioProperty(deviceID, kAudioDevicePropertyDeviceUID) else {
            return nil
        }
        return OutputDeviceAnchorPolicy.Device(
            uid: uid,
            name: readCFStringAudioProperty(deviceID, kAudioObjectPropertyName) ?? "?",
            transportType: transportType(deviceID) ?? 0,
        )
    }

    /// Short transport label for logs, e.g. "Virtual" or "Built-In". Shared with
    /// `getDefaultOutputDeviceTransportType` so the two never drift.
    static func transportLabel(_ raw: UInt32) -> String {
        transportTypeNames[raw] ?? "Unknown(\(raw))"
    }

    // MARK: - Internals

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size,
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids,
        ) == noErr else { return [] }
        return ids
    }

    private static func describeOutputDevice(_ deviceID: AudioObjectID) -> OutputDeviceAnchorPolicy.Device? {
        guard hasOutputStreams(deviceID),
              let uid = readCFStringAudioProperty(deviceID, kAudioDevicePropertyDeviceUID)
        else { return nil }
        return OutputDeviceAnchorPolicy.Device(
            uid: uid,
            name: readCFStringAudioProperty(deviceID, kAudioObjectPropertyName) ?? "?",
            transportType: transportType(deviceID) ?? 0,
        )
    }

    /// True when the device exposes at least one output channel. The stream
    /// configuration is a variable-length `AudioBufferList`, so it has to be
    /// read into a sized allocation rather than a fixed struct.
    private static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain,
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment,
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self),
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func transportType(_ deviceID: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var raw: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &raw) == noErr else {
            return nil
        }
        return raw
    }
}
