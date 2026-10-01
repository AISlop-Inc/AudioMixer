import AppKit
import CoreAudio
import Synchronization
import Darwin

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw AudioFailure(message: "\(operation) failed (OSStatus \(status))") }
}
func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
    var result = initial, size = UInt32(MemoryLayout<T>.size), property = address(selector, scope)
    try withUnsafeMutablePointer(to: &result) { pointer in
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer), "Read \(selector)")
    }
    return result
}
func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
    var property = address(selector, scope), size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "Read list size")
    if size == 0 { return [] }
    var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    try result.withUnsafeMutableBytes { bytes in
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, bytes.baseAddress!), "Read list")
    }
    return result
}
func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    try value(object, selector, "" as CFString) as String
}
func supportsSampleRate(_ device: AudioObjectID, _ rate: Double) throws -> Bool {
    var property = address(kAudioDevicePropertyAvailableNominalSampleRates), size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size), "Read supported sample rates")
    guard size > 0 else { return false }
    var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
    try ranges.withUnsafeMutableBytes { bytes in
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, bytes.baseAddress!), "Read supported sample rates")
    }
    return rateIsSupported(rate, ranges: ranges)
}
func rateIsSupported(_ rate: Double, ranges: [AudioValueRange]) -> Bool {
    rate.isFinite && rate > 0 && ranges.contains { rate >= $0.mMinimum && rate <= $0.mMaximum }
}
func setSampleRate(_ device: AudioObjectID, _ rate: Double) throws {
    var property = address(kAudioDevicePropertyNominalSampleRate), newRate = rate
    try check(AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Double>.size), &newRate), "Set device sample rate")
    // HAL device-rate changes can complete asynchronously. Bound the setup wait to 500ms.
    for _ in 0..<25 {
        if abs(try value(device, kAudioDevicePropertyNominalSampleRate, Float64(0)) - rate) < 1 { return }
        usleep(20_000)
    }
    throw AudioFailure(message: "出力デバイスのサンプルレート変更が完了しませんでした。")
}
struct Choice: Identifiable {
    let id: AudioObjectID
    let name: String
    let processes: [AudioObjectID]
    var icon: NSImage? = nil
    var appKey: String = ""
}
func outerApplicationURL(_ executable: URL) -> URL? {
    let parts = executable.pathComponents
    guard let index = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
    return URL(fileURLWithPath: NSString.path(withComponents: Array(parts.prefix(index + 1))))
}
func applicationIdentity(pid: pid_t, bundleID: String) -> (key: String, name: String, icon: NSImage?) {
    let app = NSRunningApplication(processIdentifier: pid)
    var executable = app?.executableURL ?? app?.bundleURL
    if executable == nil {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        if length > 0 { executable = URL(fileURLWithPath: String(cString: path)) }
    }
    if let executable, let root = outerApplicationURL(executable), let bundle = Bundle(url: root) {
        let owner = NSWorkspace.shared.runningApplications.first { $0.bundleURL == root }
        let name = owner?.localizedName
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? root.deletingPathExtension().lastPathComponent
        return (bundle.bundleIdentifier ?? root.path, name, owner?.icon ?? NSWorkspace.shared.icon(forFile: root.path))
    }
    return (bundleID.isEmpty ? "pid-\(pid)" : bundleID,
            app?.localizedName ?? (bundleID.isEmpty ? "PID \(pid)" : bundleID), app?.icon)
}
func audioApps() throws -> [Choice] {
    let ids = try objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    var grouped: [String: Choice] = [:]
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
        let (key, name, icon) = applicationIdentity(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "")
        if key == "dev.mattyatea.AudioMixerPoC" { continue }
        grouped[key] = Choice(id: AudioObjectID(app.processIdentifier), name: name, processes: [], icon: icon, appKey: key)
    }
    for id in ids {
        guard let pid = try? value(id, kAudioProcessPropertyPID, pid_t(0)), pid != getpid() else { continue }
        let bundle = (try? string(id, kAudioProcessPropertyBundleID)) ?? ""
        let (key, name, icon) = applicationIdentity(pid: pid, bundleID: bundle)
        if key == "dev.mattyatea.AudioMixerPoC" { continue }
        let previous = grouped[key]
        if previous == nil, (try? value(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) != 1 { continue }
        grouped[key] = Choice(id: previous?.id ?? id, name: name, processes: (previous?.processes ?? []) + [id], icon: icon, appKey: key)
    }
    return grouped.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}
func audioOutputs() throws -> [Choice] {
    try objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
        guard let streams = try? objects(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput), !streams.isEmpty else { return nil }
        return Choice(id: id, name: (try? string(id, kAudioObjectPropertyName)) ?? "Device \(id)", processes: [])
    }.sorted { $0.name < $1.name }
}

// One shared HAL callback handles capture and playback; Core Audio handles tap clock drift.
final class TapSession {
    private var tap: AudioObjectID = 0
    private var tapUID = ""
    private var aggregate: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    let gain = Atomic<UInt32>(Float(0.5).bitPattern)
    let sawPermissionAudio = Atomic<Bool>(false)
    let callbacks = Atomic<UInt64>(0)
    let peak = Atomic<UInt32>(Float(0).bitPattern)
    private var inputChannelsToSkip = 0
    private var previousGain: Float = 0.5
    private(set) var originalOutputRate: Double?
    private(set) var outputSampleRate: Double = 0

    // A tap-only device asks macOS for audio capture permission without changing playback.
    func requestPermission() throws {
        stop()
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "AudioMixer Permission Request"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create permission tap")
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "AudioMixer PoC Permission",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                 kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Create permission device")
            try validate(try value(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()))
            try check(AudioDeviceCreateIOProcID(aggregate, { _, _, input, _, _, _, context in
                guard let context else { return noErr }
                let session = Unmanaged<TapSession>.fromOpaque(context).takeUnretainedValue()
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for index in 0..<(Int(buffer.mDataByteSize) / 4) where samples[index].isFinite && samples[index] != 0 {
                        session.sawPermissionAudio.store(true, ordering: .relaxed)
                        return noErr
                    }
                }
                return noErr
            }, Unmanaged.passUnretained(self).toOpaque(), &io), "Create permission callback")
            try check(AudioDeviceStart(aggregate, io), "Request system audio capture")
        } catch { stop(); throw error }
    }
    func start(processes: [AudioObjectID], output: AudioObjectID) throws {
        stop()
        originalOutputRate = nil
        guard !processes.isEmpty else { throw AudioFailure(message: "音声を再生しているアプリを選択してください。") }
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.name = "AudioMixer PoC"
            description.isPrivate = true
            description.muteBehavior = .muted
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create Process Tap")
            tapUID = description.uuid.uuidString
            try restartOutput(output)
        } catch { stop(); throw error }
    }
    func pausePlayback() {
        if aggregate != 0, let io {
            AudioDeviceStop(aggregate, io)
            AudioDeviceDestroyIOProcID(aggregate, io)
        }
        io = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
    }
    func restartOutput(_ output: AudioObjectID) throws {
        pausePlayback() // Keep the .muted tap alive throughout output reconfiguration.
        originalOutputRate = nil
        do {
            let uid = try string(output, kAudioDevicePropertyDeviceUID)
            let tapFormat = try value(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            try validate(tapFormat)
            outputSampleRate = tapFormat.mSampleRate
            let rate = try value(output, kAudioDevicePropertyNominalSampleRate, Float64(0))
            if abs(rate - tapFormat.mSampleRate) >= 1 {
                guard try supportsSampleRate(output, tapFormat.mSampleRate) else {
                    throw AudioFailure(message: "出力先はTapの\(Int(tapFormat.mSampleRate))Hzに対応していません。音声変換は行わず、開始を中止しました。")
                }
                originalOutputRate = rate
                try setSampleRate(output, tapFormat.mSampleRate)
            }
            // Physical subdevice input streams precede the tap in the aggregate input list.
            inputChannelsToSkip = try objects(output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).reduce(0) { count, stream in
                count + Int(try value(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()).mChannelsPerFrame)
            }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "AudioMixer PoC",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Create aggregate")
            let outputStreams = try objects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            guard !outputStreams.isEmpty else { throw AudioFailure(message: "出力ストリームがありません。") }
            for stream in outputStreams {
                let format = try value(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
                try validate(format)
                guard abs(format.mSampleRate - tapFormat.mSampleRate) < 1 else {
                    throw AudioFailure(message: "出力先のサンプルレート変更が反映されていません。音声変換は行わず、開始を中止しました。")
                }

            }
            previousGain = 0
            callbacks.store(0, ordering: .relaxed)
            peak.store(0, ordering: .relaxed)
            try check(AudioDeviceCreateIOProcID(aggregate, { _, _, input, _, output, _, context in
                guard let context else { return noErr }
                let session = Unmanaged<TapSession>.fromOpaque(context).takeUnretainedValue()
                session.render(input: input, output: output)
                return noErr
            }, Unmanaged.passUnretained(self).toOpaque(), &io), "Create audio callback")
            try disablePhysicalInputs()
            try check(AudioDeviceStart(aggregate, io), "Start audio")
        } catch { pausePlayback(); throw error }
    }
    private func disablePhysicalInputs() throws {
        let physicalCount = try objects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count - 1
        guard physicalCount > 0 else { return }
        // Keep stream positions, but do not activate the physical microphone inputs.
        let count = physicalCount + 1
        let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + (count - 1) * MemoryLayout<UInt32>.size
        let storage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let usage = storage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        guard let io else { throw AudioFailure(message: "Audio callback is missing") }
        usage.pointee.mIOProc = unsafeBitCast(io, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(count)
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        storage.advanced(by: offset).assumingMemoryBound(to: UInt32.self)[physicalCount] = 1
        var property = address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        try check(AudioObjectSetPropertyData(aggregate, &property, 0, nil, UInt32(size), storage), "Disable physical input streams")
    }
    private func validate(_ format: AudioStreamBasicDescription) throws {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mBitsPerChannel == 32 else {
            throw AudioFailure(message: "PoCはFloat32 PCMのみ対応しています。別の出力デバイスを選択してください。")
        }
    }
    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let target = Float(bitPattern: gain.load(ordering: .relaxed))
        var highest: Float = 0
        var channelOffset = 0
        for buffer in outputs {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            let frames = Int(buffer.mDataByteSize) / (4 * channels)
            let destination = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<channels {
                // ponytail: first stereo pair only; add a channel matrix for surround routing.
                let sourceChannel = channelOffset + channel
                guard sourceChannel < 2 else { continue }
                var remaining = inputChannelsToSkip + sourceChannel
                for source in inputs {
                    let sourceChannels = Int(source.mNumberChannels)
                    if remaining >= sourceChannels { remaining -= sourceChannels; continue }
                    if let sourceData = source.mData, sourceChannels > 0 {
                        let samples = sourceData.assumingMemoryBound(to: Float.self)
                        let available = min(frames, Int(source.mDataByteSize) / (4 * sourceChannels))
                        for frame in 0..<available {
                            let ramp = previousGain + (target - previousGain) * Float(frame + 1) / Float(max(1, available))
                            let sample = samples[frame * sourceChannels + remaining]
                            destination[frame * channels + channel] = min(1, max(-1, sample * ramp))
                            highest = max(highest, abs(sample))
                        }

                    }
                    break
                }
            }
            channelOffset += channels
        }
        previousGain = target
        peak.store(highest.bitPattern, ordering: .relaxed)
        _ = callbacks.wrappingAdd(1, ordering: .relaxed)
    }
    func stop() {
        pausePlayback()
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
    deinit { stop() }

    static func selfCheck() {
        assert(outerApplicationURL(URL(fileURLWithPath: "/Applications/Helium.app/Contents/Frameworks/Helium Helper.app/Contents/MacOS/Helper"))?.path == "/Applications/Helium.app")
        assert(outerApplicationURL(URL(fileURLWithPath: "/Applications/Vesktop.app/Contents/MacOS/vesktop"))?.path == "/Applications/Vesktop.app")
        assert(outerApplicationURL(URL(fileURLWithPath: "/usr/bin/afplay")) == nil)
        assert(rateIsSupported(48000, ranges: [AudioValueRange(mMinimum: 44100, mMaximum: 96000)]))
        assert(!rateIsSupported(48000, ranges: [AudioValueRange(mMinimum: 96000, mMaximum: 96000)]))
        assert(!rateIsSupported(.nan, ranges: [AudioValueRange(mMinimum: 0, mMaximum: 96000)]))
        let session = TapSession()
        session.gain.store(Float(0.5).bitPattern, ordering: .relaxed)
        var source: [Float] = [1, -1, 0.5, -0.5]
        var destination = [Float](repeating: 99, count: 4)
        source.withUnsafeMutableBytes { src in
            destination.withUnsafeMutableBytes { dst in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(src.count), mData: src.baseAddress))
                var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(dst.count), mData: dst.baseAddress))
                session.render(input: &input, output: &output)
                session.gain.store(Float(0).bitPattern, ordering: .relaxed)
                session.render(input: &input, output: &output)
            }
        }
        assert(destination == [0.25, -0.25, 0, 0], "Gain ramp / stereo mapping failed")
        assert(session.callbacks.load(ordering: .relaxed) == 2)
        session.previousGain = 0
        session.gain.store(Float(2).bitPattern, ordering: .relaxed)
        source.withUnsafeMutableBytes { src in
            destination.withUnsafeMutableBytes { dst in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(src.count), mData: src.baseAddress))
                var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(dst.count), mData: dst.baseAddress))
                session.render(input: &input, output: &output)
            }
        }
        assert(destination == [1, -1, 1, -1], "Startup ramp / 200% boost failed")
        source.withUnsafeMutableBytes { src in
            destination.withUnsafeMutableBytes { dst in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(src.count), mData: src.baseAddress))
                var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(dst.count), mData: dst.baseAddress))
                session.render(input: &input, output: &output)
            }
        }
        assert(destination == [1, -1, 1, -1], "Boost clipping guard failed")
        print("PASS: stereo PCM, gain ramp, mute, callback counter, sample-rate support, parent app resolution, startup ramp, boost")
    }
}
