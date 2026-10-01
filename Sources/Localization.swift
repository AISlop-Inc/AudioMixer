import Foundation

// Bundle selection follows macOS preferred languages, including per-app language overrides.
func localized(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    if arguments.isEmpty { return format }
    return String(format: format, locale: Locale.current, arguments: arguments)
}

func checkLocalization() {
    let tables = ["en", "ja"]
        .map { language -> [String: String] in
            let url = Bundle.module.url(
                forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language)!
            return NSDictionary(contentsOf: url) as! [String: String]
        }
    precondition(Set(tables[0].keys) == Set(tables[1].keys), "Translations must cover the same keys")
    precondition(tables.allSatisfy { $0.values.allSatisfy { !$0.isEmpty } })
    let language = Bundle.module.preferredLocalizations.first!
    let selected = tables[language == "ja" ? 1 : 0]
    for (key, translation) in selected {
        precondition(localized(key) == translation, "Missing or incorrect translation: \(key)")
    }
    precondition(localized("Settings…") == (language == "ja" ? "設定…" : "Settings…"))
    let volume = localized("%@ — %ld%% — Boost above 100%%", "App %", 125)
    precondition(volume == (language == "ja" ? "App %・125%・100%よりBoost" : "App % — 125% — Boost above 100%"))
    let batch = localized("Set selected app volume to %2$ld%% (%1$ld selected).", 2, 20)
    precondition(
        batch == (language == "ja" ? "選択した2アプリの音量を20%に設定しました。" : "Set selected app volume to 20% (2 selected)."))
    if Bundle.main.bundleURL.pathExtension == "app" {
        precondition(Bundle.module.bundleURL.path.hasPrefix(Bundle.main.bundleURL.path + "/"), "Use bundled resources")
        let permission = Bundle.main.localizedString(
            forKey: "NSAudioCaptureUsageDescription", value: nil, table: "InfoPlist")
        precondition(
            permission
                == (language == "ja"
                    ? "選択したアプリの音声を取り込み、音量を調整して出力します。"
                    : "Capture audio from selected apps to adjust their volume and play it through the output device."))
    }
    print("PASS: English/Japanese translations, macOS language selection (\(language)), bundled resources")
}
