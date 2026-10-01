import SwiftUI

final class AccentSliderCell: NSSliderCell {
    var fullScaleFraction: CGFloat {
        CGFloat(min(1, max(0, (1 - minValue) / max(0.001, maxValue - minValue))))
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fraction = CGFloat(
            min(1, max(0, (doubleValue - minValue) / max(0.001, maxValue - minValue))))
        if fraction > 0 {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: track.minX, y: track.minY, width: track.width * fraction, height: track.height),
                xRadius: 2, yRadius: 2
            )
            .fill()
        }
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(
            rect: NSRect(
                x: track.minX + track.width * fullScaleFraction - 0.5, y: track.midY - 4, width: 1,
                height: 8)
        )
        .fill()
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
        let button = NSButton(
            title: title, target: context.coordinator, action: #selector(Coordinator.performAction(_:)))
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

        @objc func changed(_ slider: TrackingVolumeSlider) {
            if slider.isTrackingVolume,
                slider.doubleValue > 1, volume.wrappedValue <= 1
            {
                return
            }
            volume.wrappedValue = slider.doubleValue
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator($volume) }

    func makeNSView(context: Context) -> TrackingVolumeSlider {
        let slider = TrackingVolumeSlider()
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
        slider.toolTip = "\(Int(volume * 100))%"
        return slider
    }

    func updateNSView(_ slider: TrackingVolumeSlider, context: Context) {
        context.coordinator.volume = $volume
        slider.maxValue = maximum
        if !slider.isTrackingVolume {
            slider.doubleValue = volume
        }
        slider.setAccessibilityLabel(label)
        slider.toolTip = "\(Int(slider.doubleValue * 100))%"
    }

    @MainActor static func selfCheck() {
        var displayedVolume = 1.0
        var updates = 0
        let binding = Binding<Double>(
            get: { displayedVolume },
            set: {
                displayedVolume = $0
                updates += 1
            })
        let coordinator = Coordinator(binding)
        let slider = TrackingVolumeSlider()
        slider.minValue = 0
        slider.maxValue = 2
        slider.doubleValue = 1.6
        slider.isTrackingVolume = true
        coordinator.changed(slider)
        precondition(
            displayedVolume == 1 && updates == 0, "Boost request changed layout while dragging")
        slider.isTrackingVolume = false
        coordinator.changed(slider)
        precondition(displayedVolume == 1.6 && updates == 1, "Boost request was lost on release")
        coordinator.changed(slider)
        precondition(displayedVolume == 1.6, "Released slider reset pending boost")
        let cell = AccentSliderCell()
        cell.minValue = 0
        cell.maxValue = 3
        precondition(
            abs(cell.fullScaleFraction - 1 / 3) < 0.0001, "100% mark must be at one third for 300%")
        slider.maxValue = 3
        slider.doubleValue = 3
        coordinator.changed(slider)
        precondition(displayedVolume == 3, "300% boost request was clamped to 200%")
        print("PASS: boost release, pending value, 300% range, dynamic 100% mark")
    }

}
