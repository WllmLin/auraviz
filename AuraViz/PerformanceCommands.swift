import AppKit
import SwiftUI

/// The Performance menu. Its key equivalents are app-wide, so the shortcuts
/// work from the control window and the output window alike.
struct PerformanceCommands: Commands {
    let audio: AudioEngineManager
    let performance: PerformanceState
    let output: OutputWindowController

    var body: some Commands {
        CommandMenu("Performance") {
            PerformanceMenu(audio: audio, performance: performance, output: output)
        }
    }
}

/// A view so it can observe the shared state (for checkmarks) and open the
/// output window. Audio isn't observed: it publishes at display rate.
private struct PerformanceMenu: View {
    let audio: AudioEngineManager
    @ObservedObject var performance: PerformanceState
    let output: OutputWindowController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Off while a preset is being named or the lyrics edited, so these
        // single keys type.
        Group {
            shortcuts
        }
        .disabled(performance.isTypingText)
    }

    @ViewBuilder
    private var shortcuts: some View {
        ForEach(Array(VisualMode.allCases.enumerated()), id: \.element) { index, mode in
            // Unchecked during a vibe kill, so even the current mode's key
            // brings the show back.
            Toggle(mode.rawValue, isOn: Binding(
                get: { !performance.isVibeKilled && performance.targetLook.mode == mode },
                set: { if $0 { performance.switchMode(to: mode, clock: audio.transitionClock) } }
            ))
            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
        }
        Divider()
        Button("Next Theme") { performance.cycleTheme(by: 1) }
            .keyboardShortcut("t", modifiers: [])
        Button("Previous Theme") { performance.cycleTheme(by: -1) }
            .keyboardShortcut("t", modifiers: .shift)
        Toggle("Lyrics Overlay", isOn: Binding(
            get: { performance.isLyricsEnabled },
            set: { isOn in ignoringKeyRepeat { withAnimation(.easeInOut(duration: 0.3)) { performance.isLyricsEnabled = isOn } } }
        ))
        .keyboardShortcut("l", modifiers: [])
        Divider()
        Toggle("Blackout", isOn: Binding(
            get: { performance.isBlackedOut },
            set: { isOn in ignoringKeyRepeat { performance.isBlackedOut = isOn } }
        ))
        .keyboardShortcut(.space, modifiers: [])
        // Only enters, so a panicked double press doesn't undo it; a mode key exits.
        Button("Vibe Kill (Ambient Loop)") { performance.isVibeKilled = true }
            .keyboardShortcut("k", modifiers: [])
        // Holding S is handled by PerformanceState's key monitor; the menu
        // item shows the key and gives a single flash when clicked.
        Button("Strobe (Hold)") { performance.strobeOnce() }
            .keyboardShortcut("s", modifiers: [])
        Divider()
        Button("Tap Tempo") { ignoringKeyRepeat { audio.tapTempo() } }
            .keyboardShortcut("b", modifiers: [])
        // Nudges repeat while held. The fine steps are bound to the shifted
        // characters: a non-letter key equivalent with ⇧ wouldn't match the
        // typed "{" / "}" (like ⌘? for Help).
        Button("Nudge Tempo Down 0.5 BPM") { audio.nudgeTempo(by: -0.5) }
            .keyboardShortcut("[", modifiers: [])
        Button("Nudge Tempo Up 0.5 BPM") { audio.nudgeTempo(by: 0.5) }
            .keyboardShortcut("]", modifiers: [])
        Button("Nudge Tempo Down 0.1 BPM") { audio.nudgeTempo(by: -0.1) }
            .keyboardShortcut("{", modifiers: [])
        Button("Nudge Tempo Up 0.1 BPM") { audio.nudgeTempo(by: 0.1) }
            .keyboardShortcut("}", modifiers: [])
        Button("Reset Controls") { audio.resetVisualizationControls() }
            .keyboardShortcut("r", modifiers: [])
        Divider()
        Button("Toggle Output Full Screen") { ignoringKeyRepeat(toggleOutputFullScreen) }
            .keyboardShortcut("f", modifiers: [])
        Button("Screenshot Output to Desktop") { ignoringKeyRepeat(output.captureFrame) }
            .keyboardShortcut("p", modifiers: [])
        Divider()
        Button("Keyboard Shortcuts") { ignoringKeyRepeat { performance.isShowingShortcuts.toggle() } }
            .keyboardShortcut("/", modifiers: .command)
    }

    private func toggleOutputFullScreen() {
        if output.isOpen {
            output.toggleFullScreen()
        } else {
            output.presentOutput()
            openWindow(id: OutputWindowController.windowID)
        }
    }

    /// Menu key equivalents fire again on key repeat; toggles and taps should
    /// only react to the initial press.
    private func ignoringKeyRepeat(_ action: () -> Void) {
        if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
        action()
    }
}

/// The cheat sheet's rows, in menu order.
private let performanceShortcuts: [(keys: String, action: String)] = [
    ("1 – 6", "Circle / Waves / Bars / Tunnel / Particles / Laser"),
    ("T", "Next theme"),
    ("⇧T", "Previous theme"),
    ("L", "Lyrics overlay on / off"),
    ("Space", "Blackout (audio keeps running)"),
    ("K", "Vibe kill: fade to a calm ambient loop (1 – 6 exits)"),
    ("S hold", "Strobe, at most 3 flashes/s"),
    ("B", "Tap tempo"),
    ("[ / ]", "Nudge tempo −/+ 0.5 BPM"),
    ("⇧[ / ⇧]", "Nudge tempo −/+ 0.1 BPM"),
    ("R", "Reset sensitivity, smoothing & beat/drum reactivity"),
    ("F", "Output full screen"),
    ("Esc", "Leave output full screen"),
    ("P", "Screenshot the output to the Desktop"),
    ("H", "Show / hide controls"),
    ("⌘/", "This cheat sheet"),
]

/// Dimmed overlay over the control window listing the performance shortcuts.
struct ShortcutCheatSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("KEYBOARD SHORTCUTS")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.white)
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
                    .accessibilityLabel("Close")
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(performanceShortcuts, id: \.keys) { shortcut in
                        GridRow {
                            Text(shortcut.keys)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
                                .gridColumnAlignment(.trailing)
                            Text(shortcut.action)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                Text("Work from either window. Also in the Performance menu.")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(20)
            .frame(width: 360)
            .glassCard()
        }
    }
}
