import Combine
import SwiftUI

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
        item.button?.image = NSImage(
            systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "AudioMixer")
        menu.delegate = self
        menu.autoenablesItems = false
        let hostingView = MenuHostingView(rootView: MixerPanel(model: model))
        hostingView.sizingOptions = [.intrinsicContentSize]
        self.hostingView = hostingView
        let mixerItem = NSMenuItem()
        mixerItem.view = hostingView
        menu.addItem(mixerItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: localized("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
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
            window.title = localized("AudioMixer Settings")
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
        if CommandLine.arguments.contains("--self-test") {
            TapSession.selfCheck()
            NativeVolumeSlider.selfCheck()
            checkVolumeSettings()
            checkLocalization()
            return
        }
        if CommandLine.arguments.contains("--list") {
            do {
                for app in try audioApps() { print("APP \(app.id) \(app.name) processes=\(app.processes)") }
                for device in try audioOutputs() { print("OUT \(device.id) \(device.name)") }
                return
            } catch {
                print(error.localizedDescription)
                exit(1)
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
