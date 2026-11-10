import AppKit
import SwiftUI

/// The app's slider: shows its value in a bubble over the knob while hovered
/// or dragged, and snaps back to `defaultValue` on a double-click.
struct ControlSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    /// Formats the value for the bubble, e.g. "75%" or "1.2x".
    let format: (Double) -> String

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var doubleClickMonitor: Any?
    /// Bumped by the monitor; the reset itself runs in `onChange` so it uses
    /// the current binding and default (the drum sliders' change with the mode).
    @State private var resetRequests = 0

    /// Distance from the slider's ends to the knob's center at either extreme.
    private static let knobInset: CGFloat = 10

    init(value: Binding<Double>, in range: ClosedRange<Double>, default defaultValue: Double, format: @escaping (Double) -> String) {
        _value = value
        self.range = range
        self.defaultValue = defaultValue
        self.format = format
    }

    var body: some View {
        Slider(value: $value, in: range, onEditingChanged: { isDragging = $0 })
            .onHover { hovering in
                isHovering = hovering
                updateDoubleClickMonitor()
            }
            .onChange(of: isEnabled) { updateDoubleClickMonitor() }
            .onChange(of: resetRequests) { value = defaultValue }
            .onDisappear {
                isHovering = false
                updateDoubleClickMonitor()
            }
            .overlay { valueBubble }
            .accessibilityAction(named: "Reset to default") { value = defaultValue }
    }

    private var valueBubble: some View {
        GeometryReader { proxy in
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? ((value - range.lowerBound) / span).clamped(to: 0...1) : 0
            let track = max(proxy.size.width - Self.knobInset * 2, 0)
            Text(format(value))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.8), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                .fixedSize()
                .position(x: Self.knobInset + track * fraction, y: -9)
        }
        .opacity(isEnabled && (isHovering || isDragging) ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isHovering || isDragging)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Watches for double-clicks only while the pointer is over an enabled
    /// slider. The second click is swallowed so the knob doesn't jump to the
    /// pointer after the reset.
    private func updateDoubleClickMonitor() {
        let wantsMonitor = isHovering && isEnabled
        if wantsMonitor, doubleClickMonitor == nil {
            let resetRequests = $resetRequests
            doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                guard event.clickCount == 2 else { return event }
                resetRequests.wrappedValue += 1
                return nil
            }
        } else if !wantsMonitor, let monitor = doubleClickMonitor {
            NSEvent.removeMonitor(monitor)
            doubleClickMonitor = nil
        }
    }
}
