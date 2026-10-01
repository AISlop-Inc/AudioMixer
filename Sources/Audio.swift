import AppKit
import CoreAudio
import Darwin

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw AudioFailure(message: localized("%@ failed (OSStatus %d).", operation, status)) }
}

func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func value<T>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> T {
    var result = initial
    var size = UInt32(MemoryLayout<T>.size)
    var property = address(selector, scope)
    try withUnsafeMutablePointer(to: &result) { pointer in
        try check(
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer),
            localized("Read property %u", selector))
    }
    return result
}

func objects(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> [AudioObjectID] {
    var property = address(selector, scope)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), localized("Read list size"))
    if size == 0 { return [] }
    var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    try result.withUnsafeMutableBytes { bytes in
        try check(
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, bytes.baseAddress!), localized("Read list"))
    }
    return result
}

func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    try value(object, selector, "" as CFString) as String
}

func supportsSampleRate(_ device: AudioObjectID, _ rate: Double) throws -> Bool {
    var property = address(kAudioDevicePropertyAvailableNominalSampleRates)
    var size: UInt32 = 0
    try check(
        AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size), localized("Read supported sample rates"))
    guard size > 0 else { return false }
    var ranges = [AudioValueRange](
        repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
    try ranges.withUnsafeMutableBytes { bytes in
        try check(
            AudioObjectGetPropertyData(device, &property, 0, nil, &size, bytes.baseAddress!),
            localized("Read supported sample rates"))
    }
    return rateIsSupported(rate, ranges: ranges)
}

func rateIsSupported(_ rate: Double, ranges: [AudioValueRange]) -> Bool {
    rate.isFinite && rate > 0 && ranges.contains { rate >= $0.mMinimum && rate <= $0.mMaximum }
}

func setSampleRate(_ device: AudioObjectID, _ rate: Double) throws {
    var property = address(kAudioDevicePropertyNominalSampleRate)
    var newRate = rate
    try check(
        AudioObjectSetPropertyData(
            device, &property, 0, nil, UInt32(MemoryLayout<Double>.size), &newRate),
        localized("Set device sample rate"))
    // HAL device-rate changes can complete asynchronously. Bound the setup wait to 500ms.
    for _ in 0..<25 {
        if abs(try value(device, kAudioDevicePropertyNominalSampleRate, Float64(0)) - rate) < 1 {
            return
        }
        usleep(20_000)
    }
    throw AudioFailure(message: localized("The output device sample-rate change did not complete."))
}

struct AudioApp: Identifiable {
    var id: String { appKey }
    let name: String
    let processes: [AudioObjectID]
    let icon: NSImage?
    let appKey: String
}

struct AudioOutput: Identifiable {
    let id: AudioObjectID
    let name: String
}

func outerApplicationURL(_ executable: URL) -> URL? {
    let parts = executable.pathComponents
    guard let index = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
        return nil
    }
    return URL(fileURLWithPath: NSString.path(withComponents: Array(parts.prefix(index + 1))))
}

func applicationIdentity(pid: pid_t, bundleID: String) -> (
    key: String, name: String, icon: NSImage?
) {
    let app = NSRunningApplication(processIdentifier: pid)
    var executable = app?.executableURL ?? app?.bundleURL
    if executable == nil {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        if length > 0 { executable = URL(fileURLWithPath: String(cString: path)) }
    }
    if let executable, let root = outerApplicationURL(executable), let bundle = Bundle(url: root) {
        let owner = NSWorkspace.shared.runningApplications.first { $0.bundleURL == root }
        let name =
            owner?.localizedName
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? root.deletingPathExtension().lastPathComponent
        return (
            bundle.bundleIdentifier ?? root.path, name,
            owner?.icon ?? NSWorkspace.shared.icon(forFile: root.path)
        )
    }
    return (
        bundleID.isEmpty ? "pid-\(pid)" : bundleID,
        app?.localizedName ?? (bundleID.isEmpty ? "PID \(pid)" : bundleID), app?.icon
    )
}

func audioApps() throws -> [AudioApp] {
    let ids = try objects(
        AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    var grouped: [String: AudioApp] = [:]
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular && app.processIdentifier != getpid() {
        let (key, name, icon) = applicationIdentity(
            pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "")
        if key == "dev.mattyatea.AudioMixerPoC" { continue }
        grouped[key] = AudioApp(name: name, processes: [], icon: icon, appKey: key)
    }
    for id in ids {
        guard let pid = try? value(id, kAudioProcessPropertyPID, pid_t(0)), pid != getpid() else {
            continue
        }
        let bundle = (try? string(id, kAudioProcessPropertyBundleID)) ?? ""
        let (key, name, icon) = applicationIdentity(pid: pid, bundleID: bundle)
        if key == "dev.mattyatea.AudioMixerPoC" { continue }
        let previous = grouped[key]
        if previous == nil, (try? value(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) != 1 {
            continue
        }
        grouped[key] = AudioApp(
            name: name, processes: (previous?.processes ?? []) + [id], icon: icon, appKey: key)
    }
    return grouped.values.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}

func audioOutputs() throws -> [AudioOutput] {
    try objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        .compactMap {
            id in
            guard
                let streams = try? objects(
                    id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput), !streams.isEmpty
            else { return nil }
            return AudioOutput(id: id, name: (try? string(id, kAudioObjectPropertyName)) ?? "Device \(id)")
        }
        .sorted { $0.name < $1.name }
}
