import Foundation
import CoreAudio
import AudioToolbox
import AppKit

/// Monitors microphone activity via Core Audio property listeners
final class MicActivityMonitor: @unchecked Sendable {
    private var currentDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var isMonitoring = false
    private let queue = DispatchQueue(label: "com.munin.micmonitor")

    var onMicActivityChanged: ((Bool) -> Void)?

    init() {}

    func startMonitoring() {
        queue.async { [weak self] in
            self?.setupMonitoring()
        }
    }

    func stopMonitoring() {
        queue.async { [weak self] in
            self?.teardownMonitoring()
        }
    }

    private func setupMonitoring() {
        guard !isMonitoring else { return }

        // Get default input device
        updateDefaultInputDevice()

        // Listen for default input device changes
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        AudioObjectAddPropertyListener(
            systemObjectID,
            &defaultDeviceAddress,
            defaultDeviceChangedCallback,
            selfPtr
        )

        isMonitoring = true
        debugLog("MicActivityMonitor started")
    }

    private func teardownMonitoring() {
        guard isMonitoring else { return }

        // Remove device-specific listener
        removeDeviceListener()

        // Remove default device listener
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        AudioObjectRemovePropertyListener(
            systemObjectID,
            &defaultDeviceAddress,
            defaultDeviceChangedCallback,
            selfPtr
        )

        isMonitoring = false
        currentDeviceID = kAudioObjectUnknown
        debugLog("MicActivityMonitor stopped")
    }

    private func updateDefaultInputDevice() {
        // Remove old listener if device changed
        removeDeviceListener()

        // Get new default input device
        var deviceID = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            debugLog("Failed to get default input device")
            return
        }

        currentDeviceID = deviceID
        addDeviceListener()

        // Check current state
        let isActive = isMicCurrentlyActive()
        debugLog("Monitoring device \(deviceID), currently active: \(isActive)")
    }

    private func addDeviceListener() {
        guard currentDeviceID != kAudioObjectUnknown else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        AudioObjectAddPropertyListener(
            currentDeviceID,
            &address,
            deviceRunningChangedCallback,
            selfPtr
        )
    }

    private func removeDeviceListener() {
        guard currentDeviceID != kAudioObjectUnknown else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        AudioObjectRemovePropertyListener(
            currentDeviceID,
            &address,
            deviceRunningChangedCallback,
            selfPtr
        )
    }

    func isMicCurrentlyActive() -> Bool {
        guard currentDeviceID != kAudioObjectUnknown else { return false }

        var isRunning: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            currentDeviceID,
            &address,
            0,
            nil,
            &propertySize,
            &isRunning
        )

        return status == noErr && isRunning != 0
    }

    /// Detects which running app is likely using the microphone
    /// Only returns app name if frontmost is a known conferencing/browser app (high confidence)
    func detectMicUsingApp() -> String? {
        let knownApps: Set<String> = [
            "zoom.us", "Zoom",
            "Microsoft Teams", "Teams",
            "Webex", "Cisco Webex Meetings",
            "Slack",
            "Discord",
            "FaceTime",
            "Skype",
            "Google Chrome", "Chrome",
            "Safari",
            "Firefox",
            "Arc",
            "Brave Browser",
            "Microsoft Edge"
        ]

        // Only return app name if frontmost - don't guess
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let name = frontmost.localizedName,
           knownApps.contains(name) {
            return name
        }

        return nil  // Shows generic "Meeting detected"
    }

    fileprivate func handleDefaultDeviceChanged() {
        queue.async { [weak self] in
            self?.updateDefaultInputDevice()
        }
    }

    fileprivate func handleRunningStateChanged() {
        let isActive = isMicCurrentlyActive()
        debugLog("Mic activity changed: \(isActive)")
        onMicActivityChanged?(isActive)
    }
}

// MARK: - Callbacks

private func defaultDeviceChangedCallback(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = clientData else { return noErr }
    let monitor = Unmanaged<MicActivityMonitor>.fromOpaque(clientData).takeUnretainedValue()
    monitor.handleDefaultDeviceChanged()
    return noErr
}

private func deviceRunningChangedCallback(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = clientData else { return noErr }
    let monitor = Unmanaged<MicActivityMonitor>.fromOpaque(clientData).takeUnretainedValue()
    monitor.handleRunningStateChanged()
    return noErr
}
