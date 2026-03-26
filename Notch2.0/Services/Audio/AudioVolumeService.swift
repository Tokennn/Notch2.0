import CoreAudio

final class AudioVolumeService {
    func currentVolume() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var address = makeVolumeAddress(element: kAudioObjectPropertyElementMain)

        if let volume = getVolume(deviceID: deviceID, address: &address) {
            return clamp(volume)
        }

        var leftAddress = makeVolumeAddress(element: 1)
        var rightAddress = makeVolumeAddress(element: 2)
        let left = getVolume(deviceID: deviceID, address: &leftAddress)
        let right = getVolume(deviceID: deviceID, address: &rightAddress)

        if let left, let right { return clamp((left + right) / 2) }
        if let left { return clamp(left) }
        if let right { return clamp(right) }
        return nil
    }

    func nudge(by delta: Float) -> Float? {
        guard let current = currentVolume() else { return nil }
        let updated = clamp(current + delta)

        guard setVolume(updated) else { return nil }
        return updated
    }

    private func setVolume(_ volume: Float) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }
        let clamped = clamp(volume)
        var address = makeVolumeAddress(element: kAudioObjectPropertyElementMain)

        if setVolume(deviceID: deviceID, address: &address, value: clamped) {
            return true
        }

        var leftAddress = makeVolumeAddress(element: 1)
        var rightAddress = makeVolumeAddress(element: 2)
        let leftSet = setVolume(deviceID: deviceID, address: &leftAddress, value: clamped)
        let rightSet = setVolume(deviceID: deviceID, address: &rightAddress, value: clamped)

        return leftSet || rightSet
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr else { return nil }
        return deviceID
    }

    private func makeVolumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private func getVolume(deviceID: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> Float? {
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return status == noErr ? Float(volume) : nil
    }

    private func setVolume(deviceID: AudioDeviceID, address: inout AudioObjectPropertyAddress, value: Float) -> Bool {
        var mutableVolume = Float32(value)
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mutableVolume)
        return status == noErr
    }

    private func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
