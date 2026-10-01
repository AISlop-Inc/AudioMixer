import AppKit
import Combine
import CoreAudio

@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var levels = VolumeSettings()
    @Published private(set) var managesApps = true
    @Published private(set) var status = localized("Play audio in an app to start adjusting its volume.")
    @Published var batchSelection: Set<String> = []
    @Published var batchLowerOnly = false
    @Published var batchVolumePercent = 20
    @Published var compactDisplay = UserDefaults.standard.bool(forKey: "compactDisplay") {
        didSet { UserDefaults.standard.set(compactDisplay, forKey: "compactDisplay") }
    }

    private var output: AudioObjectID = 0
    private var sessions: [String: TapSession] = [:]
    private var originalRates: [AudioObjectID: (before: Double, applied: Double)] = [:]
    private var permissionProbe: TapSession?
    private var captureReady = false
    private var timer: Timer?
    private var ticks = 0

    var hasSessions: Bool { !sessions.isEmpty }
    var batchApps: [AudioApp] { apps.filter { batchSelection.contains($0.appKey) } }

    init() {
        requestPermission()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func poll() {
        if permissionProbe?.sawPermissionAudio.load(ordering: .relaxed) == true {
            captureReady = true
            permissionProbe?.stop()
            permissionProbe = nil
            refresh()
        }
        ticks += 1
        if ticks % 8 == 0 { refresh() }
    }

    private func requestPermission() {
        let probe = TapSession()
        do {
            try probe.requestPermission()
            permissionProbe = probe
            status = localized(
                "Audio capture permission requested. Allow it in the system dialog. If no dialog appears, check System Settings."
            )
        } catch { status = localized("Could not request permission. %@", error.localizedDescription) }
    }

    func openPermissionSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }

    private func refresh() {
        do {
            let fresh = try audioApps()
            let defaultID = try value(
                AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                AudioObjectID(0))
            guard try audioOutputs().contains(where: { $0.id == defaultID }) else {
                stopAll()
                apps = fresh
                status = localized("Output device disconnected. Check the system output device.")
                return
            }
            if output != defaultID {
                output = defaultID
                restartOutput()
            }
            for key in Array(sessions.keys)
            where !fresh.contains(where: { $0.appKey == key && !$0.processes.isEmpty }) {
                sessions.removeValue(forKey: key)?.stop()
            }
            if sessions.isEmpty { restoreRates() }
            for app in fresh where managesApps || sessions[app.appKey] != nil {
                if sessions[app.appKey]?.processes != app.processes {
                    enable(app)
                }
            }
            apps = fresh
            batchSelection.formIntersection(Set(fresh.map(\.appKey)))
            if let request = levels.pendingBoost, !fresh.contains(where: { $0.appKey == request.appKey }) {
                cancelBoost()
            }
        } catch { status = error.localizedDescription }
    }

    private func enable(_ app: AudioApp) {
        guard captureReady, !app.processes.isEmpty else { return }
        let old = sessions[app.appKey]
        old?.pausePlayback()
        let session = TapSession()
        session.setGain(levels.gain(for: app.appKey))
        do {
            try session.start(processes: app.processes, output: output)
            rememberRate(session)
            old?.stop()
            sessions[app.appKey] = session
            status = localized("Adjusting volume. Stop to restore the original audio output.")
        } catch {
            rememberRate(session)
            if sessions.isEmpty { restoreRates() }
            status = error.localizedDescription
            fputs("AudioMixer start failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func rememberRate(_ session: TapSession) {
        if let before = session.originalOutputRate, originalRates[output] == nil {
            originalRates[output] = (before, session.outputSampleRate)
        }
    }

    private func restoreRates() {
        for (device, rates) in originalRates {
            do {
                // Preserve a rate the user changed independently while the mixer was running.
                let current = try value(device, kAudioDevicePropertyNominalSampleRate, Float64(0))
                if abs(current - rates.applied) < 1 { try setSampleRate(device, rates.before) }
            } catch { fputs("AudioMixer rate restore failed: \(error.localizedDescription)\n", stderr) }
        }
        originalRates.removeAll()
    }

    private func updateGain(_ app: AudioApp) {
        if sessions[app.appKey] == nil { enable(app) }
        sessions[app.appKey]?.setGain(levels.gain(for: app.appKey))
    }

    func setVolume(_ app: AudioApp, _ volume: Double) {
        if levels.setVolume(volume, for: app.appKey, name: app.name) { updateGain(app) }
    }

    func setMuted(_ app: AudioApp, _ isMuted: Bool) {
        levels.setMuted(isMuted, for: app.appKey)
        updateGain(app)
    }

    func cancelBoost() { levels.pendingBoost = nil }

    func confirmBoost() {
        guard let request = levels.pendingBoost,
            let app = apps.first(where: { $0.appKey == request.appKey })
        else {
            cancelBoost()
            return
        }
        _ = levels.confirmBoost()
        updateGain(app)
    }

    func setBoostLimit(_ percent: Int) {
        levels.setBoostLimit(percent)
        for (key, session) in sessions { session.setGain(levels.gain(for: key)) }
    }

    func applyBatchVolume() {
        let changes = batchVolumeChanges(
            appKeys: apps.map(\.appKey), selected: batchSelection, current: levels.volumes,
            percent: batchVolumePercent, lowerOnly: batchLowerOnly)
        for app in batchApps {
            if let volume = changes[app.appKey] { setVolume(app, volume) }
        }
        if let request = levels.pendingBoost, batchSelection.contains(request.appKey) { cancelBoost() }
        let message =
            batchLowerOnly
            ? "Reduced selected app volume to at most %2$ld%% (%1$ld selected)."
            : "Set selected app volume to %2$ld%% (%1$ld selected)."
        status = localized(message, changes.count, batchVolumePercent)
    }

    func setBatchMuted(_ isMuted: Bool) {
        let selected = batchApps
        for app in selected { setMuted(app, isMuted) }
        status = localized(
            isMuted ? "Muted selection (%ld selected)." : "Unmuted selection (%ld selected).", selected.count)
    }

    private func restartOutput() {
        for session in sessions.values { session.pausePlayback() }
        restoreRates()
        for session in sessions.values {
            do {
                try session.restartOutput(output)
                rememberRate(session)
            } catch {
                rememberRate(session)
                status = localized("Output switching failed; audio is muted. %@", error.localizedDescription)
                fputs("AudioMixer output restart failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    func resumeManagement() {
        managesApps = true
        if !captureReady, permissionProbe == nil { requestPermission() }
        refresh()
    }

    func stopAll() {
        managesApps = false
        permissionProbe?.stop()
        permissionProbe = nil
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        restoreRates()
        status = localized("Stopped. Original audio output restored.")
    }

    deinit { timer?.invalidate() }
}
