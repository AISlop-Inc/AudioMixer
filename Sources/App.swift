import SwiftUI
import CoreAudio
import Combine

func batchVolumeChanges(appKeys: [String], selected: Set<String>, current: [String: Double], percent: Int, lowerOnly: Bool) -> [String: Double] {
    let value = Double(min(100, max(0, percent))) / 100
    return appKeys.reduce(into: [:]) { result, key in
        if selected.contains(key), !lowerOnly || (current[key] ?? 1) > value { result[key] = value }
    }
}
func checkBatchVolumes() {
    let current = ["keep": 1.5, "loud": 3.0, "quiet": 0.1]
    let result = batchVolumeChanges(appKeys: ["keep", "loud", "quiet", "new"], selected: ["loud", "quiet", "new"], current: current, percent: 20, lowerOnly: true)
    assert(result == ["loud": 0.2, "new": 0.2], "Batch reduction must preserve unchecked apps and quieter volumes")
    assert(batchVolumeChanges(appKeys: ["keep", "quiet"], selected: ["quiet"], current: current, percent: 20, lowerOnly: false) == ["quiet": 0.2])
    let applied = batchVolumeChanges(appKeys: ["keep", "quiet"], selected: ["quiet"], current: current, percent: 80, lowerOnly: false)
    assert(applied == ["quiet": 0.8], "Applying a higher value must raise the checked app")
    assert(batchVolumeChanges(appKeys: ["keep"], selected: [], current: current, percent: 0, lowerOnly: false).isEmpty)
    print("PASS: checked batch selection, lower-only mode, exact volume, empty selection")
}

@MainActor
final class MixerModel: ObservableObject {
    @Published var apps: [Choice] = []
    @Published var outputs: [Choice] = []
    @Published var output: AudioObjectID = 0
    @Published var managesApps = true
    @Published var batchSelection: Set<String> = []
    @Published var batchLowerOnly = false
    @Published var batchVolumePercent = 20
    @Published var compactDisplay = UserDefaults.standard.bool(forKey: "compactDisplay") {
        didSet { UserDefaults.standard.set(compactDisplay, forKey: "compactDisplay") }
    }
    @Published private(set) var maximumBoostPercent = max(100, min(1000, (UserDefaults.standard.object(forKey: "maximumBoostPercent") as? Int) ?? 200))
    var maximumGain: Double { Double(maximumBoostPercent) / 100 }
    private var excluded: Set<AudioObjectID> = []
    private var boostAcknowledged: Set<String> = []
    @Published var pendingBoost: (appKey: String, name: String, volume: Double)?
    @Published var volumes: [String: Double] = (UserDefaults.standard.dictionary(forKey: "appVolumes") as? [String: Double]) ?? [:]
    @Published var active: Set<AudioObjectID> = []
    @Published var muted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "mutedApps") ?? [])
    private var captureReady = false
    @Published var meters: [AudioObjectID: Float] = [:]
    @Published var status = "アプリで音声を再生すると一覧に表示されます。"
    private var sessions: [AudioObjectID: TapSession] = [:]
    private var timer: Timer?
    private var ticks = 0
    private var originalRates: [AudioObjectID: (before: Double, applied: Double)] = [:]
    private var permissionProbe: TapSession?
    init() {
        requestPermission()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.permissionProbe?.sawPermissionAudio.load(ordering: .relaxed) == true {
                    self.captureReady = true
                    self.permissionProbe?.stop()
                    self.permissionProbe = nil
                    self.refresh()
                }
                self.meters = self.sessions.mapValues { Float(bitPattern: $0.peak.load(ordering: .relaxed)) }
                self.ticks += 1
                if self.ticks % 8 == 0 { self.refresh() }
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func requestPermission() {
        permissionProbe?.stop()
        permissionProbe = nil
        let probe = TapSession()
        do {
            try probe.requestPermission()
            permissionProbe = probe
            status = "音声収録の許可を要求しました。標準ダイアログで許可してください。表示されない場合はシステム設定を確認してください。"

        } catch { status = "許可要求に失敗しました。\(error.localizedDescription)" }
    }
    func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }
    func refresh() {
        do {
            let fresh = try audioApps()
            outputs = try audioOutputs().filter { !$0.name.hasPrefix("AudioMixer PoC") }
            let defaultID = try value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
            if output != defaultID {
                output = defaultID
                restart()
            }
            if output == 0 { output = defaultID }
            for old in apps where active.contains(old.id) {
                guard let current = fresh.first(where: { $0.appKey == old.appKey }) else {
                    disable(old.id, manually: false)
                    continue
                }
                if current.processes != old.processes || current.id != old.id || (captureReady && sessions[old.id] == nil && !current.processes.isEmpty) {
                    enable(current, replacing: true, previousID: old.id)
                }
            }
            apps = fresh
            if managesApps {
                for app in apps where !excluded.contains(app.id) && !active.contains(app.id) { enable(app) }
            }
            if !outputs.contains(where: { $0.id == output }) {
                stopAll()
                status = "出力先が切断されました。出力先を選び直してください。"
            }
        } catch { status = error.localizedDescription }
    }
    func enable(_ app: Choice, replacing: Bool = false, previousID: AudioObjectID? = nil) {
        excluded.remove(app.id)
        if !captureReady || app.processes.isEmpty {
            active.insert(app.id)
            return
        }
        permissionProbe?.stop()
        permissionProbe = nil
        guard sessions[app.id] == nil || replacing else { return }
        let oldID = previousID ?? app.id
        let old = sessions[oldID]
        old?.pausePlayback()
        let session = TapSession()
        session.gain.store(Float(muted.contains(app.appKey) ? 0 : (volumes[app.appKey] ?? 1)).bitPattern, ordering: .relaxed)
        do {
            try session.start(processes: app.processes, output: output)
            rememberRate(session)
            old?.stop()
            sessions.removeValue(forKey: oldID)
            active.remove(oldID)
            sessions[app.id] = session
            active.insert(app.id)
            status = "調整中。停止すると元の出力へ戻ります。"
        } catch {
            rememberRate(session)
            if sessions.isEmpty { restoreRates() }
            status = error.localizedDescription
            fputs("AudioMixer start failed: \(error.localizedDescription)\n", stderr)
        }
    }
    func disable(_ id: AudioObjectID, manually: Bool = true) {
        if manually { excluded.insert(id) }
        sessions.removeValue(forKey: id)?.stop()
        active.remove(id)
        meters.removeValue(forKey: id)
        if sessions.isEmpty { restoreRates() }
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
    var batchApps: [Choice] { apps.filter { batchSelection.contains($0.appKey) } }
    func applyBatchVolume() {
        let changes = batchVolumeChanges(appKeys: apps.map(\.appKey), selected: batchSelection, current: volumes, percent: batchVolumePercent, lowerOnly: batchLowerOnly)
        for app in batchApps {
            if let volume = changes[app.appKey] { setVolume(app, volume) }
        }
        if let request = pendingBoost, batchSelection.contains(request.appKey) { pendingBoost = nil }
        status = "選択した\(changes.count)アプリの音量を\(batchVolumePercent)%\(batchLowerOnly ? "以下に調整" : "に設定")しました。"
    }
    func setBatchMuted(_ isMuted: Bool) {
        let selected = batchApps
        for app in selected { setMuted(app, isMuted) }
        status = "選択した\(selected.count)アプリを\(isMuted ? "ミュート" : "アンミュート")しました。"
    }
    func setBoostLimit(_ percent: Int) {
        maximumBoostPercent = max(100, min(1000, percent))
        UserDefaults.standard.set(maximumBoostPercent, forKey: "maximumBoostPercent")
        for key in Array(volumes.keys) where (volumes[key] ?? 0) > maximumGain {
            volumes[key] = maximumGain
            if let app = apps.first(where: { $0.appKey == key }) {
                sessions[app.id]?.gain.store(Float(muted.contains(key) ? 0 : maximumGain).bitPattern, ordering: .relaxed)
            }
        }
        UserDefaults.standard.set(volumes, forKey: "appVolumes")
        if let request = pendingBoost {
            pendingBoost = maximumGain <= 1 ? nil : (request.appKey, request.name, min(request.volume, maximumGain))
        }
        if maximumGain <= 1 { boostAcknowledged.removeAll() }
    }
    func setVolume(_ app: Choice, _ volume: Double) {
        let clamped = min(maximumGain, max(0, volume))
        if clamped <= 1 {
            boostAcknowledged.remove(app.appKey)
            if pendingBoost?.appKey == app.appKey { pendingBoost = nil }
        }
        if clamped > 1, !boostAcknowledged.contains(app.appKey) {
            pendingBoost = (app.appKey, app.name, clamped)
            return
        }
        volumes[app.appKey] = clamped
        UserDefaults.standard.set(volumes, forKey: "appVolumes")
        if sessions[app.id] == nil { enable(app) }
        sessions[app.id]?.gain.store(Float(muted.contains(app.appKey) ? 0 : clamped).bitPattern, ordering: .relaxed)
    }
    func confirmBoost() {
        guard let request = pendingBoost else { return }
        pendingBoost = nil
        guard let app = apps.first(where: { $0.appKey == request.appKey }) else { return }
        boostAcknowledged.insert(app.appKey)
        setVolume(app, request.volume)
    }
    func setMuted(_ app: Choice, _ isMuted: Bool) {
        if isMuted { muted.insert(app.appKey) } else { muted.remove(app.appKey) }
        UserDefaults.standard.set(Array(muted), forKey: "mutedApps")
        if sessions[app.id] == nil { enable(app) }
        sessions[app.id]?.gain.store(Float(isMuted ? 0 : (volumes[app.appKey] ?? 1)).bitPattern, ordering: .relaxed)
    }
    func restart() {
        for session in sessions.values { session.pausePlayback() }
        restoreRates()
        for session in sessions.values {
            do {
                try session.restartOutput(output)
                rememberRate(session)
            } catch {
                rememberRate(session)
                status = "出力の切り替えに失敗したため無音にしています。\(error.localizedDescription)"
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
        active.removeAll()
        meters.removeAll()
        status = "調整停止。元の音声出力に戻りました。"
    }
}

final class AccentSliderCell: NSSliderCell {
    var fullScaleFraction: CGFloat {
        CGFloat(min(1, max(0, (1 - minValue) / max(0.001, maxValue - minValue))))
    }
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fraction = CGFloat(min(1, max(0, (doubleValue - minValue) / max(0.001, maxValue - minValue))))
        if fraction > 0 {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height), xRadius: 2, yRadius: 2).fill()
        }
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(rect: NSRect(x: track.minX + track.width * fullScaleFraction - 0.5, y: track.midY - 4, width: 1, height: 8)).fill()
    }
}

struct NativeActionButton: NSViewRepresentable {
    let title: String
    let action: () -> Void
    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func performAction(_ sender: NSButton) { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.performAction(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        context.coordinator.action = action
    }
}

final class TrackingVolumeSlider: NSSlider {
    var isTrackingVolume = false
    override func mouseDown(with event: NSEvent) {
        isTrackingVolume = true
        super.mouseDown(with: event)
        isTrackingVolume = false
        if let action { sendAction(action, to: target) }
    }
}

struct NativeVolumeSlider: NSViewRepresentable {
    @Binding var volume: Double
    let maximum: Double
    let label: String
    final class Coordinator: NSObject {
        var volume: Binding<Double>
        init(_ volume: Binding<Double>) { self.volume = volume }
        @objc func changed(_ slider: NSSlider) {
            if (slider as? TrackingVolumeSlider)?.isTrackingVolume == true,
               slider.doubleValue > 1, volume.wrappedValue <= 1 { return }
            volume.wrappedValue = slider.doubleValue
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator($volume) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = TrackingVolumeSlider(value: volume, minValue: 0, maxValue: maximum, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.cell = AccentSliderCell()
        slider.minValue = 0
        slider.maxValue = maximum
        slider.doubleValue = volume
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.numberOfTickMarks = 0
        slider.setAccessibilityLabel(label)
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.volume = $volume
        slider.maxValue = maximum
        if (slider as? TrackingVolumeSlider)?.isTrackingVolume != true {
            slider.doubleValue = volume
        }
        slider.setAccessibilityLabel(label)
    }
    @MainActor static func selfCheck() {
        var displayedVolume = 1.0
        var updates = 0
        let binding = Binding<Double>(get: { displayedVolume }, set: { displayedVolume = $0; updates += 1 })
        let coordinator = Coordinator(binding)
        let slider = TrackingVolumeSlider()
        slider.minValue = 0
        slider.maxValue = 2
        slider.doubleValue = 1.6
        slider.isTrackingVolume = true
        coordinator.changed(slider)
        assert(displayedVolume == 1 && updates == 0, "Boost request changed layout while dragging")
        slider.isTrackingVolume = false
        coordinator.changed(slider)
        assert(displayedVolume == 1.6 && updates == 1, "Boost request was lost on release")
        coordinator.changed(slider)
        assert(displayedVolume == 1.6, "Released slider reset pending boost")
        let cell = AccentSliderCell()
        cell.minValue = 0
        cell.maxValue = 3
        assert(abs(cell.fullScaleFraction - 1 / 3) < 0.0001, "100% mark must be at one third for 300%")
        slider.maxValue = 3
        slider.doubleValue = 3
        coordinator.changed(slider)
        assert(displayedVolume == 3, "300% boost request was clamped to 200%")
        print("PASS: boost release, pending value, 300% range, dynamic 100% mark")
    }

}
struct MixerPanel: View {
    @ObservedObject var model: MixerModel
    @ViewBuilder private func appIcon(_ app: Choice) -> some View {
        Group {
            if let icon = app.icon { Image(nsImage: icon).resizable() }
            else { Image(systemName: "app.fill").resizable() }
        }.frame(width: 20, height: 20)
            .overlay(alignment: .bottom) {
                if (model.volumes[app.appKey] ?? 1) > 1 {
                    Text("Boost").font(.system(size: 8, weight: .semibold)).fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.white).padding(.horizontal, 2)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 2))
                        .offset(y: 7)
                }
            }
            .help("\(app.name)\((model.volumes[app.appKey] ?? 1) > 1 ? "・Boost中" : "")")
            .accessibilityLabel(app.name)
    }
    private func muteButton(_ app: Choice) -> some View {
        let isMuted = model.muted.contains(app.appKey)
        return Button { model.setMuted(app, !isMuted) } label: {
            HStack(spacing: 4) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                if !model.compactDisplay { Text(isMuted ? "ミュート中" : "音声オン") }
            }.font(.caption).frame(minWidth: model.compactDisplay ? 24 : 78, minHeight: 24)
        }.buttonStyle(.borderless)
            .help("\(app.name)は\(isMuted ? "ミュート中。クリックで音声オン" : "音声オン。クリックでミュート")")
            .accessibilityLabel("\(app.name)を\(isMuted ? "アンミュート" : "ミュート")")
            .accessibilityValue(isMuted ? "ミュート中" : "音声オン")
    }
    private func volumeSlider(_ app: Choice) -> some View {
        NativeVolumeSlider(volume: Binding(get: { model.pendingBoost?.appKey == app.appKey ? model.pendingBoost!.volume : (model.volumes[app.appKey] ?? 1) }, set: { model.setVolume(app, $0) }), maximum: model.maximumGain, label: "\(app.name)の音量。100%の目印より右がBoost")
            .frame(height: 22)
            .help("\(app.name)・\(Int((model.volumes[app.appKey] ?? 1) * 100))%・100%よりBoost")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("アプリの音量").font(.headline)
            if let request = model.pendingBoost {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(request.name)の音量を\(Int(request.volume * 100))%に上げますか？", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .semibold))
                    Text("100%を超える音量は、聴覚への負担や音割れにつながる場合があります。周囲の音量とヘッドフォンの装着状態を確認し、少しずつ調整してください。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        NativeActionButton(title: "キャンセル") { model.pendingBoost = nil }
                            .frame(width: 82, height: 24)
                        Spacer()
                        NativeActionButton(title: "Boostを有効にする") { model.confirmBoost() }
                            .frame(width: 136, height: 24)
                    }
                }.padding(10)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.apps.isEmpty {
                Text("起動中のアプリはありません。")
                    .foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: model.compactDisplay ? 6 : 14) {
                        ForEach(model.apps) { app in
                            if model.compactDisplay {
                                HStack(spacing: 8) {
                                    appIcon(app)
                                    volumeSlider(app)
                                    muteButton(app)
                                }
                            } else {
                                VStack(spacing: 4) {
                                    HStack(spacing: 6) {
                                        appIcon(app)
                                        Text(app.name).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 2)
                                        Text("\(Int((model.volumes[app.appKey] ?? 1) * 100))%\((model.volumes[app.appKey] ?? 1) > 1 ? " Boost" : "")")
                                            .foregroundStyle((model.volumes[app.appKey] ?? 1) > 1 ? Color.accentColor : Color.secondary).monospacedDigit()
                                        muteButton(app)
                                    }
                                    HStack(spacing: 6) {
                                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                                        VStack(spacing: 0) {
                                            volumeSlider(app)
                                            GeometryReader { proxy in
                                                Text("100%").font(.system(size: 9)).foregroundStyle(.secondary)
                                                    .position(x: proxy.size.width / CGFloat(model.maximumGain), y: 6)
                                            }.frame(height: 12)
                                        }
                                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }.padding(.vertical, 4)
                }.frame(height: min(320, CGFloat(model.apps.count) * (model.compactDisplay ? 32 : 76)))
            }
        }.font(.system(size: 12)).padding(14).frame(width: 310)
    }
}

struct MixerSettings: View {
    @ObservedObject var model: MixerModel
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Picker("表示モード", selection: $model.compactDisplay) {
                Text("リッチ").tag(false)
                Text("コンパクト").tag(true)
            }.pickerStyle(.segmented)

            HStack {
                Text("Boostの上限")
                Spacer()
                TextField("上限", value: Binding(get: { model.maximumBoostPercent }, set: { model.setBoostLimit($0) }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 64)
                    .accessibilityLabel("Boost上限のパーセント")
                Text("%")
                Stepper("Boost上限", value: Binding(get: { model.maximumBoostPercent }, set: { model.setBoostLimit($0) }), in: 100...1000, step: 25).labelsHidden()
            }
            Text("100〜1000%で設定できます。上限を下げると、現在の音量もその範囲に収まります。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("一括制御").font(.headline)
                Spacer()
                Text("\(model.batchApps.count)アプリ選択中").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("全選択") { model.batchSelection = Set(model.apps.map(\.appKey)) }
                Button("選択解除") { model.batchSelection.removeAll() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.apps) { app in
                        Toggle(isOn: Binding(get: { model.batchSelection.contains(app.appKey) }, set: { checked in
                            if checked { model.batchSelection.insert(app.appKey) } else { model.batchSelection.remove(app.appKey) }
                        })) {
                            HStack(spacing: 6) {
                                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                                Text(app.name).lineLimit(1)
                                Spacer()
                                Text(model.muted.contains(app.appKey) ? "ミュート中" : "\(Int((model.volumes[app.appKey] ?? 1) * 100))%")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox)
                    }
                }.padding(.vertical, 4)
            }.frame(height: min(160, CGFloat(model.apps.count) * 30))
            HStack {
                Text("音量")
                Slider(value: Binding(get: { Double(model.batchVolumePercent) }, set: { model.batchVolumePercent = min(100, max(0, Int($0))) }), in: 0...100, step: 1)
                    .accessibilityLabel("選択したアプリに適用する音量")
                Text("\(model.batchVolumePercent)%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            Toggle("音量を下げるだけ（指定値より小さい音量は維持）", isOn: $model.batchLowerOnly)
            HStack {
                Button("選択したアプリに適用") { model.applyBatchVolume() }
                Button("ミュート") { model.setBatchMuted(true) }
                Button("アンミュート") { model.setBatchMuted(false) }
            }.disabled(model.batchApps.isEmpty)
            Text("適用すると、チェックしたアプリの音量を指定値へ変更します。ミュート状態は変えません。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("アプリを自動で管理", isOn: Binding(get: { model.managesApps }, set: { enabled in
                if enabled { model.resumeManagement() } else { model.stopAll() }
            }))
            Text("再生先はシステムの出力先に自動で追従します。")
                .font(.caption).foregroundStyle(.secondary)
            Button("音声収録の許可設定を開く…") { model.openPermissionSettings() }
            Divider()
            Text(model.status).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("すべて停止") { model.stopAll() }.disabled(model.active.isEmpty && !model.managesApps)
                Spacer()
                Button("終了") { NSApplication.shared.terminate(nil) }
            }
        }.padding(20).frame(maxWidth: .infinity)
        }.frame(width: 400, height: 620)
    }
}

final class MenuHostingView: NSHostingView<MixerPanel> {
    override var isOpaque: Bool { false }
    override var allowsVibrancy: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var hostingView: MenuHostingView?
    private var resizeSubscription: AnyCancellable?
    private var model: MixerModel?
    private var terminationSignal: DispatchSourceSignal?
    private var settingsWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal.setEventHandler { NSApplication.shared.terminate(nil) }
        terminationSignal.resume()
        self.terminationSignal = terminationSignal
        let model = MixerModel()
        self.model = model
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        item.button?.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "AudioMixer")
        menu.delegate = self
        menu.autoenablesItems = false
        let hostingView = MenuHostingView(rootView: MixerPanel(model: model))
        hostingView.sizingOptions = [.intrinsicContentSize]
        self.hostingView = hostingView
        let mixerItem = NSMenuItem()
        mixerItem.view = hostingView
        menu.addItem(mixerItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "設定…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)
        item.menu = menu
        resizeMenuContent()
        resizeSubscription = model.objectWillChange.sink { [weak self] _ in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { self?.resizeMenuContent() }
            }
        }
    }
    private func resizeMenuContent() {
        guard let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        hostingView.setFrameSize(hostingView.fittingSize)
    }
    func menuWillOpen(_ menu: NSMenu) { resizeMenuContent() }
    @objc private func showSettings() {
        guard let model else { return }
        menu.cancelTracking()
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: MixerSettings(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "AudioMixer 設定"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func applicationWillTerminate(_ notification: Notification) { model?.stopAll() }
}

@main
struct AudioMixerApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") { TapSession.selfCheck(); NativeVolumeSlider.selfCheck(); checkBatchVolumes(); return }
        if CommandLine.arguments.contains("--list") {
            do {
                for app in try audioApps() { print("APP \(app.id) \(app.name) processes=\(app.processes)") }
                for device in try audioOutputs() { print("OUT \(device.id) \(device.name)") }
                return
            } catch { print(error.localizedDescription); exit(1) }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
