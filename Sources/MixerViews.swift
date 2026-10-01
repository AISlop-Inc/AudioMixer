import SwiftUI

struct MixerPanel: View {
    @ObservedObject var model: MixerModel
    @ViewBuilder private func appIcon(_ app: AudioApp) -> some View {
        let isBoosted = model.levels.volume(for: app.appKey) > 1
        Group {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
            }
        }
        .frame(width: 20, height: 20)
        .overlay(alignment: .bottom) {
            if isBoosted {
                Text("Boost")
                    .font(.system(size: 8, weight: .semibold))
                    .fixedSize(
                        horizontal: true, vertical: false
                    )
                    .foregroundStyle(.white)
                    .padding(.horizontal, 2)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 2))
                    .offset(y: 7)
            }
        }
        .help(isBoosted ? localized("%@ — Boost enabled", app.name) : app.name)
        .accessibilityLabel(app.name)
    }

    private func muteButton(_ app: AudioApp) -> some View {
        let isMuted = model.levels.muted.contains(app.appKey)
        return Button {
            model.setMuted(app, !isMuted)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                if !model.compactDisplay { Text(isMuted ? localized("Muted") : localized("Sound on")) }
            }
            .font(.caption)
            .frame(minWidth: model.compactDisplay ? 24 : 78, minHeight: 24)
        }
        .buttonStyle(.borderless)
        .help(localized(isMuted ? "%@ is muted. Click to turn sound on." : "%@ has sound on. Click to mute.", app.name))
        .accessibilityLabel(localized(isMuted ? "Unmute %@" : "Mute %@", app.name))
        .accessibilityValue(isMuted ? localized("Muted") : localized("Sound on"))
    }

    private func volumeSlider(_ app: AudioApp) -> some View {
        NativeVolumeSlider(
            volume: Binding(
                get: { model.levels.displayedVolume(for: app.appKey) },
                set: { model.setVolume(app, $0) }),
            maximum: model.levels.maximumGain,
            label: localized("Volume for %@. Boost is to the right of the 100%% mark.", app.name)
        )
        .frame(height: 22)
        .help(localized("%@ — %ld%% — Boost above 100%%", app.name, Int(model.levels.volume(for: app.appKey) * 100)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("App Volume"))
                .font(.headline)
            if let request = model.levels.pendingBoost {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        localized("Increase the volume of %@ to %ld%%?", request.name, Int(request.volume * 100)),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    Text(
                        localized(
                            "Volume above 100% may strain your hearing or distort audio. Check the surrounding volume and your headphones, then increase the level gradually."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        NativeActionButton(title: localized("Cancel")) { model.cancelBoost() }
                            .frame(width: 82, height: 24)
                        Spacer()
                        NativeActionButton(title: localized("Enable Boost")) { model.confirmBoost() }
                            .frame(width: 136, height: 24)
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.apps.isEmpty {
                Text(localized("No running apps."))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: model.compactDisplay ? 6 : 14) {
                        ForEach(model.apps) { app in
                            let volume = model.levels.volume(for: app.appKey)
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
                                        Text(app.name)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 2)
                                        Text(
                                            "\(Int(volume * 100))%\(volume > 1 ? " Boost" : "")"
                                        )
                                        .foregroundStyle(
                                            volume > 1 ? Color.accentColor : Color.secondary
                                        )
                                        .monospacedDigit()
                                        muteButton(app)
                                    }
                                    HStack(spacing: 6) {
                                        Image(systemName: "speaker.fill")
                                            .foregroundStyle(.secondary)
                                        VStack(spacing: 0) {
                                            volumeSlider(app)
                                            GeometryReader { proxy in
                                                Text("100%")
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(.secondary)
                                                    .position(
                                                        x: proxy.size.width / CGFloat(model.levels.maximumGain), y: 6)
                                            }
                                            .frame(height: 12)
                                        }
                                        Image(systemName: "speaker.wave.3.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: min(320, CGFloat(model.apps.count) * (model.compactDisplay ? 32 : 76)))
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 310)
    }
}

struct MixerSettings: View {
    @ObservedObject var model: MixerModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker(localized("Display mode"), selection: $model.compactDisplay) {
                    Text(localized("Rich")).tag(false)
                    Text(localized("Compact")).tag(true)
                }
                .pickerStyle(.segmented)

                HStack {
                    Text(localized("Boost limit"))
                    Spacer()
                    TextField(
                        localized("Limit"),
                        value: Binding(
                            get: { model.levels.maximumBoostPercent },
                            set: { model.setBoostLimit($0) }),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .accessibilityLabel(localized("Boost limit percentage"))
                    Text("%")
                    Stepper(
                        localized("Boost limit"),
                        value: Binding(
                            get: { model.levels.maximumBoostPercent },
                            set: { model.setBoostLimit($0) }),
                        in: 100...1000, step: 25
                    )
                    .labelsHidden()
                }
                Text(localized("Set a limit from 100% to 1000%. Lowering it also reduces volumes above the new limit."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text(localized("Batch Control"))
                        .font(.headline)
                    Spacer()
                    Text(localized("Selected: %ld", model.batchApps.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(localized("Select All")) { model.batchSelection = Set(model.apps.map(\.appKey)) }
                    Button(localized("Deselect All")) { model.batchSelection.removeAll() }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.apps) { app in
                            Toggle(
                                isOn: Binding(
                                    get: { model.batchSelection.contains(app.appKey) },
                                    set: { checked in
                                        if checked {
                                            model.batchSelection.insert(app.appKey)
                                        } else {
                                            model.batchSelection.remove(app.appKey)
                                        }
                                    })
                            ) {
                                HStack(spacing: 6) {
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .frame(width: 18, height: 18)
                                    }
                                    Text(app.name)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(
                                        model.levels.muted.contains(app.appKey)
                                            ? localized("Muted") : "\(Int(model.levels.volume(for: app.appKey) * 100))%"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: min(160, CGFloat(model.apps.count) * 30))
                HStack {
                    Text(localized("Volume"))
                    Slider(
                        value: Binding(
                            get: { Double(model.batchVolumePercent) },
                            set: { model.batchVolumePercent = min(100, max(0, Int($0))) }), in: 0...100, step: 1
                    )
                    .accessibilityLabel(localized("Volume to apply to selected apps"))
                    .help("\(model.batchVolumePercent)%")
                    Text("\(model.batchVolumePercent)%")
                        .monospacedDigit()
                        .frame(
                            width: 40, alignment: .trailing)
                }
                Toggle(localized("Only lower volume (keep quieter apps unchanged)"), isOn: $model.batchLowerOnly)
                HStack {
                    Button(localized("Apply to Selected Apps")) { model.applyBatchVolume() }
                    Button(localized("Mute")) { model.setBatchMuted(true) }
                    Button(localized("Unmute")) { model.setBatchMuted(false) }
                }
                .disabled(model.batchApps.isEmpty)
                Text(localized("Applies the volume to checked apps. Mute states stay unchanged."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Toggle(
                    localized("Automatically manage apps"),
                    isOn: Binding(
                        get: { model.managesApps },
                        set: { enabled in
                            if enabled {
                                model.resumeManagement()
                            } else {
                                model.stopAll()
                            }
                        }))
                Text(localized("Playback automatically follows the system output device."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(localized("Open Audio Capture Settings…")) { model.openPermissionSettings() }
                Divider()
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(localized("Stop All")) { model.stopAll() }
                        .disabled(!model.hasSessions && !model.managesApps)
                    Spacer()
                    Button(localized("Quit")) { NSApplication.shared.terminate(nil) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 400, height: 620)
    }
}
