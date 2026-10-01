import CoreAudio
import Synchronization

// One shared HAL callback handles capture and playback; Core Audio handles tap clock drift.
final class TapSession {
    private var tap: AudioObjectID = 0
    private var tapUID = ""
    private var aggregate: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private let gain = Atomic<UInt32>(Float(0.5).bitPattern)
    let sawPermissionAudio = Atomic<Bool>(false)
    private var inputChannelsToSkip = 0
    private var previousGain: Float = 0.5
    private(set) var originalOutputRate: Double?
    private(set) var outputSampleRate: Double = 0
    private(set) var processes: [AudioObjectID] = []

    func setGain(_ value: Float) { gain.store(value.bitPattern, ordering: .relaxed) }

    // A tap-only device asks macOS for audio capture permission without changing playback.
    func requestPermission() throws {
        stop()
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "AudioMixer Permission Request"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), localized("Create permission tap"))
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "AudioMixer PoC Permission",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ]
                ],
            ]
            try check(
                AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate),
                localized("Create permission device"))
            try validate(try value(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()))
            try check(
                AudioDeviceCreateIOProcID(
                    aggregate,
                    { _, _, input, _, _, _, context in
                        guard let context else { return noErr }
                        let session = Unmanaged<TapSession>.fromOpaque(context).takeUnretainedValue()
                        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                        for buffer in buffers {
                            guard let data = buffer.mData else { continue }
                            let samples = data.assumingMemoryBound(to: Float.self)
                            for index in 0..<(Int(buffer.mDataByteSize) / 4)
                            where samples[index].isFinite && samples[index] != 0 {
                                session.sawPermissionAudio.store(true, ordering: .relaxed)
                                return noErr
                            }
                        }
                        return noErr
                    }, Unmanaged.passUnretained(self).toOpaque(), &io), localized("Create permission callback"))
            try check(AudioDeviceStart(aggregate, io), localized("Request system audio capture"))
        } catch {
            stop()
            throw error
        }
    }

    func start(processes: [AudioObjectID], output: AudioObjectID) throws {
        stop()
        originalOutputRate = nil
        guard !processes.isEmpty else { throw AudioFailure(message: localized("Select an app that is playing audio.")) }
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.name = "AudioMixer PoC"
            description.isPrivate = true
            description.muteBehavior = .muted
            try check(AudioHardwareCreateProcessTap(description, &tap), localized("Create Process Tap"))
            tapUID = description.uuid.uuidString
            try restartOutput(output)
            self.processes = processes
        } catch {
            stop()
            throw error
        }
    }

    func pausePlayback() {
        if aggregate != 0, let io {
            AudioDeviceStop(aggregate, io)
            AudioDeviceDestroyIOProcID(aggregate, io)
        }
        io = nil
        if aggregate != 0 {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = 0
        }
    }

    func restartOutput(_ output: AudioObjectID) throws {
        pausePlayback()  // Keep the .muted tap alive throughout output reconfiguration.
        originalOutputRate = nil
        do {
            let uid = try string(output, kAudioDevicePropertyDeviceUID)
            let tapFormat = try value(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            try validate(tapFormat)
            outputSampleRate = tapFormat.mSampleRate
            let rate = try value(output, kAudioDevicePropertyNominalSampleRate, Float64(0))
            if abs(rate - tapFormat.mSampleRate) >= 1 {
                guard try supportsSampleRate(output, tapFormat.mSampleRate) else {
                    throw AudioFailure(
                        message: localized(
                            "The output does not support the tap rate of %ld Hz. Playback was not started; no resampling is performed.",
                            Int(tapFormat.mSampleRate)))
                }
                originalOutputRate = rate
                try setSampleRate(output, tapFormat.mSampleRate)
            }
            // Physical subdevice input streams precede the tap in the aggregate input list.
            inputChannelsToSkip = try objects(
                output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput
            )
            .reduce(0) { count, stream in
                count
                    + Int(
                        try value(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
                            .mChannelsPerFrame)
            }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "AudioMixer PoC",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
                ],
            ]
            try check(
                AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), localized("Create aggregate"))
            let outputStreams = try objects(
                aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            guard !outputStreams.isEmpty else {
                throw AudioFailure(message: localized("No output streams are available."))
            }
            for stream in outputStreams {
                let format = try value(
                    stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
                try validate(format)
                guard abs(format.mSampleRate - tapFormat.mSampleRate) < 1 else {
                    throw AudioFailure(
                        message: localized(
                            "The output sample-rate change has not taken effect. Playback was not started; no resampling is performed."
                        ))
                }

            }
            previousGain = 0
            try check(
                AudioDeviceCreateIOProcID(
                    aggregate,
                    { _, _, input, _, output, _, context in
                        guard let context else { return noErr }
                        let session = Unmanaged<TapSession>.fromOpaque(context).takeUnretainedValue()
                        session.render(input: input, output: output)
                        return noErr
                    }, Unmanaged.passUnretained(self).toOpaque(), &io), localized("Create audio callback"))
            try disablePhysicalInputs()
            try check(AudioDeviceStart(aggregate, io), localized("Start audio"))
        } catch {
            pausePlayback()
            throw error
        }
    }

    private func disablePhysicalInputs() throws {
        let physicalCount =
            try objects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            .count - 1
        guard physicalCount > 0 else { return }
        // Keep stream positions, but do not activate the physical microphone inputs.
        let count = physicalCount + 1
        let size =
            MemoryLayout<AudioHardwareIOProcStreamUsage>.size + (count - 1) * MemoryLayout<UInt32>.size
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let usage = storage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        guard let io else { throw AudioFailure(message: localized("Audio callback is missing")) }
        usage.pointee.mIOProc = unsafeBitCast(io, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(count)
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        storage.advanced(by: offset).assumingMemoryBound(to: UInt32.self)[physicalCount] = 1
        var property = address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        try check(
            AudioObjectSetPropertyData(aggregate, &property, 0, nil, UInt32(size), storage),
            localized("Disable physical input streams"))
    }

    private func validate(_ format: AudioStreamBasicDescription) throws {
        guard format.mFormatID == kAudioFormatLinearPCM,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
            format.mBitsPerChannel == 32
        else {
            throw AudioFailure(message: localized("Only Float32 PCM is supported. Choose another output device."))
        }
    }

    private func render(
        input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let target = Float(bitPattern: gain.load(ordering: .relaxed))
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
                    if remaining >= sourceChannels {
                        remaining -= sourceChannels
                        continue
                    }
                    if let sourceData = source.mData, sourceChannels > 0 {
                        let samples = sourceData.assumingMemoryBound(to: Float.self)
                        let available = min(frames, Int(source.mDataByteSize) / (4 * sourceChannels))
                        for frame in 0..<available {
                            let ramp =
                                previousGain + (target - previousGain) * Float(frame + 1) / Float(max(1, available))
                            let sample = samples[frame * sourceChannels + remaining]
                            destination[frame * channels + channel] = min(1, max(-1, sample * ramp))
                        }

                    }
                    break
                }
            }
            channelOffset += channels
        }
        previousGain = target
    }

    func stop() {
        pausePlayback()
        if tap != 0 {
            AudioHardwareDestroyProcessTap(tap)
            tap = 0
        }
        processes.removeAll()
    }

    deinit { stop() }

    static func selfCheck() {
        precondition(
            outerApplicationURL(
                URL(
                    fileURLWithPath:
                        "/Applications/Helium.app/Contents/Frameworks/Helium Helper.app/Contents/MacOS/Helper"))?
                .path == "/Applications/Helium.app")
        precondition(
            outerApplicationURL(URL(fileURLWithPath: "/Applications/Vesktop.app/Contents/MacOS/vesktop"))?
                .path == "/Applications/Vesktop.app")
        precondition(outerApplicationURL(URL(fileURLWithPath: "/usr/bin/afplay")) == nil)
        precondition(
            rateIsSupported(48000, ranges: [AudioValueRange(mMinimum: 44100, mMaximum: 96000)]))
        precondition(
            !rateIsSupported(48000, ranges: [AudioValueRange(mMinimum: 96000, mMaximum: 96000)]))
        precondition(!rateIsSupported(.nan, ranges: [AudioValueRange(mMinimum: 0, mMaximum: 96000)]))
        let session = TapSession()
        session.gain.store(Float(0.5).bitPattern, ordering: .relaxed)
        var source: [Float] = [1, -1, 0.5, -0.5]
        var destination = [Float](repeating: 99, count: 4)
        func render() {
            source.withUnsafeMutableBytes { src in
                destination.withUnsafeMutableBytes { dst in
                    var input = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 2, mDataByteSize: UInt32(src.count), mData: src.baseAddress))
                    var output = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 2, mDataByteSize: UInt32(dst.count), mData: dst.baseAddress))
                    session.render(input: &input, output: &output)
                }
            }
        }
        render()
        precondition(destination == [0.5, -0.5, 0.25, -0.25], "Stereo mapping failed")
        session.setGain(0)
        render()
        precondition(destination == [0.25, -0.25, 0, 0], "Gain ramp failed")
        render()
        precondition(destination == [0, 0, 0, 0], "Mute must clear the output")
        session.setGain(2)
        render()
        precondition(destination == [1, -1, 1, -1], "Startup ramp / 200% boost failed")
        render()
        precondition(destination == [1, -1, 1, -1], "Boost clipping guard failed")
        print(
            "PASS: stereo PCM, gain ramp, mute, sample-rate support, parent app resolution, startup ramp, boost"
        )
    }
}
