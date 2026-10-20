import AppKit
import SwiftUI

/// Performance state shared by the control window's preview, the output
/// window and the Performance menu, so both windows always render the same
/// visual and its shortcuts work from either window.
final class PerformanceState: ObservableObject {
    static let blackoutFadeDuration: TimeInterval = 0.3
    /// At most three flashes in any one-second window, the photosensitive
    /// seizure limit (WCAG 2.3.1). Comfortably over 1/3 s so display-frame
    /// jitter can't squeeze a fourth flash into a window.
    static let strobeMinimumInterval: TimeInterval = 0.36

    @Published var mode: VisualMode = .circle
    @Published var theme: ColorTheme = .aurora
    @Published var circleFramesPerSecond = 30
    /// Fades the stage to black; audio and analysis keep running.
    @Published var isBlackedOut = false
    /// `BeatClock.now` of the most recent strobe flash.
    @Published private(set) var strobeFlashTime: TimeInterval = -.infinity
    @Published var isShowingShortcuts = false

    private var isStrobeHeld = false
    private var strobeFlashedThisPress = false
    private var strobeTimer: Timer?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init() {
        // Menu key equivalents only fire on key down, so holding S is tracked
        // here, app-wide, and consumed before it reaches the menu.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.charactersIgnoringModifiers?.lowercased() == "s" else { return event }
            if event.type == .keyDown {
                guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
                if !event.isARepeat { self.beginStrobe() }
            } else {
                guard self.isStrobeHeld else { return event }
                self.endStrobe()
            }
            return nil
        }
        // The key-up would go to another app and leave the strobe running.
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endStrobe()
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        strobeTimer?.invalidate()
    }

    func cycleTheme(by offset: Int) {
        let themes = ColorTheme.allCases
        let index = themes.firstIndex(of: theme) ?? 0
        theme = themes[((index + offset) % themes.count + themes.count) % themes.count]
    }

    // MARK: - Strobe

    /// Flashes now, then every `strobeMinimumInterval` until `endStrobe()`.
    /// A press during the cooldown after the previous flash waits it out.
    func beginStrobe() {
        guard !isStrobeHeld else { return }
        isStrobeHeld = true
        strobeFlashedThisPress = false
        scheduleStrobeFlash()
    }

    /// Stops strobing; a press that hasn't flashed yet still flashes once.
    func endStrobe() {
        isStrobeHeld = false
        if strobeFlashedThisPress {
            strobeTimer?.invalidate()
            strobeTimer = nil
        }
    }

    /// A single flash, subject to the same rate limit.
    func strobeOnce() {
        guard !isStrobeHeld else { return }
        beginStrobe()
        endStrobe()
    }

    private func scheduleStrobeFlash() {
        guard strobeTimer == nil else { return }
        let delay = strobeFlashTime + Self.strobeMinimumInterval - BeatClock.now
        guard delay > 0 else {
            flashStrobe()
            return
        }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.strobeTimer = nil
            self?.flashStrobe()
        }
        RunLoop.main.add(timer, forMode: .common)
        strobeTimer = timer
    }

    private func flashStrobe() {
        strobeFlashTime = BeatClock.now
        strobeFlashedThisPress = true
        if isStrobeHeld { scheduleStrobeFlash() }
    }
}
