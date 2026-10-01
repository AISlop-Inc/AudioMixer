import Foundation

// Volume policy and persistence have no dependency on audio capture or UI.
struct VolumeSettings {
    private let defaults: UserDefaults
    private var boostAcknowledged: Set<String> = []
    private(set) var volumes: [String: Double]
    private(set) var muted: Set<String>
    private(set) var maximumBoostPercent: Int
    var pendingBoost: (appKey: String, name: String, volume: Double)?

    var maximumGain: Double { Double(maximumBoostPercent) / 100 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        maximumBoostPercent = min(
            1000, max(100, defaults.object(forKey: "maximumBoostPercent") as? Int ?? 200))
        muted = Set(defaults.stringArray(forKey: "mutedApps") ?? [])
        let saved = defaults.dictionary(forKey: "appVolumes") as? [String: Double] ?? [:]
        let limit = Double(maximumBoostPercent) / 100
        volumes = saved.filter { $0.value.isFinite }.mapValues { min(limit, max(0, $0)) }
    }

    func volume(for key: String) -> Double { volumes[key] ?? 1 }

    func displayedVolume(for key: String) -> Double {
        if let request = pendingBoost, request.appKey == key { return request.volume }
        return volume(for: key)
    }

    func gain(for key: String) -> Float { muted.contains(key) ? 0 : Float(volume(for: key)) }

    // Returns false while Boost is awaiting approval or the input is invalid.
    mutating func setVolume(_ value: Double, for key: String, name: String) -> Bool {
        guard value.isFinite else { return false }
        let clamped = min(maximumGain, max(0, value))
        if clamped <= 1 {
            boostAcknowledged.remove(key)
            if pendingBoost?.appKey == key { pendingBoost = nil }
        }
        if clamped > 1, !boostAcknowledged.contains(key) {
            pendingBoost = (key, name, clamped)
            return false
        }
        volumes[key] = clamped
        defaults.set(volumes, forKey: "appVolumes")
        return true
    }

    mutating func confirmBoost() -> String? {
        guard let request = pendingBoost else { return nil }
        pendingBoost = nil
        boostAcknowledged.insert(request.appKey)
        _ = setVolume(request.volume, for: request.appKey, name: request.name)
        return request.appKey
    }

    mutating func setMuted(_ isMuted: Bool, for key: String) {
        if isMuted { muted.insert(key) } else { muted.remove(key) }
        defaults.set(Array(muted), forKey: "mutedApps")
    }

    mutating func setBoostLimit(_ percent: Int) {
        maximumBoostPercent = min(1000, max(100, percent))
        let limit = maximumGain
        volumes = volumes.mapValues { min($0, limit) }
        defaults.set(maximumBoostPercent, forKey: "maximumBoostPercent")
        defaults.set(volumes, forKey: "appVolumes")
        if let request = pendingBoost {
            pendingBoost = limit <= 1 ? nil : (request.appKey, request.name, min(request.volume, limit))
        }
        if limit <= 1 { boostAcknowledged.removeAll() }
    }
}

func batchVolumeChanges(
    appKeys: [String], selected: Set<String>, current: [String: Double], percent: Int, lowerOnly: Bool
) -> [String: Double] {
    let value = Double(min(100, max(0, percent))) / 100
    return appKeys.reduce(into: [:]) { result, key in
        if selected.contains(key), !lowerOnly || (current[key] ?? 1) > value { result[key] = value }
    }
}

func checkVolumeSettings() {
    let suite = "AudioMixer.self-test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var levels = VolumeSettings(defaults: defaults)
    precondition(!levels.setVolume(1.8, for: "app", name: "App"))
    precondition(levels.volume(for: "app") == 1 && levels.displayedVolume(for: "app") == 1.8)
    precondition(
        defaults.dictionary(forKey: "appVolumes") == nil, "Unapproved Boost must not be saved")
    precondition(levels.confirmBoost() == "app" && levels.volume(for: "app") == 1.8)
    levels.setMuted(true, for: "app")
    precondition(levels.gain(for: "app") == 0)
    precondition(levels.setVolume(0.5, for: "app", name: "App"))
    precondition(levels.gain(for: "app") == 0, "Volume changes must preserve mute")
    precondition(
        !levels.setVolume(1.6, for: "app", name: "App"),
        "Lowering below 100% must revoke Boost approval")
    levels.setBoostLimit(125)
    precondition(levels.pendingBoost?.volume == 1.25)
    _ = levels.confirmBoost()
    levels.setBoostLimit(110)
    precondition(levels.volume(for: "app") == 1.1)
    levels.setBoostLimit(300)
    precondition(levels.volume(for: "app") == 1.1, "Raising the limit must not raise the volume")
    let restored = VolumeSettings(defaults: defaults)
    precondition(
        restored.volume(for: "app") == 1.1 && restored.muted.contains("app")
            && restored.maximumBoostPercent == 300)
    precondition(!levels.setVolume(.nan, for: "app", name: "App"))
    precondition(!levels.setVolume(.infinity, for: "app", name: "App"))
    precondition(!levels.setVolume(2, for: "other", name: "Other"))
    levels.setBoostLimit(100)
    precondition(levels.pendingBoost == nil && levels.volume(for: "app") == 1)

    let current = ["keep": 1.5, "loud": 3.0, "quiet": 0.1]
    precondition(
        batchVolumeChanges(
            appKeys: ["keep", "loud", "quiet", "new"], selected: ["loud", "quiet", "new"],
            current: current, percent: 20, lowerOnly: true) == ["loud": 0.2, "new": 0.2])
    precondition(
        batchVolumeChanges(
            appKeys: ["keep", "quiet"], selected: ["quiet"], current: current, percent: 80,
            lowerOnly: false) == ["quiet": 0.8])
    precondition(
        batchVolumeChanges(
            appKeys: ["keep"], selected: [], current: current, percent: 0, lowerOnly: false
        )
        .isEmpty)
    print("PASS: Boost approval, limits, mute, persistence, invalid input, batch selection")
}
