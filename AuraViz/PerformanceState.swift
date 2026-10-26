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

    static let circleFrameRates = [30, 60]
    /// How long a preset recall dissolves the stage from the old look.
    static let crossfadeDuration: TimeInterval = 0.5

    @Published var mode: VisualMode = .circle {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: SettingsKey.mode) }
    }
    @Published var theme: ColorTheme = .aurora {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: SettingsKey.theme) }
    }
    @Published var circleFramesPerSecond = 30 {
        didSet { UserDefaults.standard.set(circleFramesPerSecond, forKey: SettingsKey.circleFramesPerSecond) }
    }
    /// Fades the stage to black; audio and analysis keep running.
    @Published var isBlackedOut = false
    /// `BeatClock.now` of the most recent strobe flash.
    @Published private(set) var strobeFlashTime: TimeInterval = -.infinity
    @Published var isShowingShortcuts = false
    /// Set while the Save Preset alert takes a name. Single-key shortcuts
    /// stand down so the keys type into the name field instead.
    @Published var isNamingPreset = false
    /// Lyrics, a track title or a shout-out, shown as kinetic type over the
    /// stage while `isLyricsEnabled`.
    @Published var lyricsText = "" {
        didSet { UserDefaults.standard.set(lyricsText, forKey: SettingsKey.lyricsText) }
    }
    @Published var isLyricsEnabled = false {
        didSet { UserDefaults.standard.set(isLyricsEnabled, forKey: SettingsKey.lyricsEnabled) }
    }
    /// Set while the lyrics field has focus, so the keys type into it.
    @Published var isEditingLyrics = false

    /// True while a text field takes the keyboard; single-key shortcuts stand down.
    var isTypingText: Bool { isNamingPreset || isEditingLyrics }

    /// The text the stage overlays, or nil while the overlay is off.
    var stageLyrics: String? { isLyricsEnabled ? lyricsText : nil }

    /// The stage has two layers. The live one shows the current look; during
    /// a crossfade the other keeps showing `fadingLook` while it fades out.
    @Published private(set) var liveStageLayer = 0
    @Published private(set) var fadingLook: StageLook?
    private var crossfadeID = 0

    private var isStrobeHeld = false
    private var strobeFlashedThisPress = false
    private var strobeTimer: Timer?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init() {
        restoreSettings()
        // Menu key equivalents only fire on key down, so holding S is tracked
        // here, app-wide, and consumed before it reaches the menu.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, !self.isTypingText, event.charactersIgnoringModifiers?.lowercased() == "s" else { return event }
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

    private func restoreSettings() {
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: SettingsKey.mode).flatMap(VisualMode.init(rawValue:)) {
            self.mode = mode
        }
        if let theme = defaults.string(forKey: SettingsKey.theme).flatMap(ColorTheme.init(rawValue:)) {
            self.theme = theme
        }
        let framesPerSecond = defaults.integer(forKey: SettingsKey.circleFramesPerSecond)
        if Self.circleFrameRates.contains(framesPerSecond) {
            circleFramesPerSecond = framesPerSecond
        }
        lyricsText = defaults.string(forKey: SettingsKey.lyricsText) ?? lyricsText
        isLyricsEnabled = defaults.bool(forKey: SettingsKey.lyricsEnabled)
    }

    func cycleTheme(by offset: Int) {
        let themes = ColorTheme.allCases
        let index = themes.firstIndex(of: theme) ?? 0
        theme = themes[((index + offset) % themes.count + themes.count) % themes.count]
    }

    // MARK: - Crossfade

    var look: StageLook {
        StageLook(mode: mode, theme: theme, framesPerSecond: circleFramesPerSecond)
    }

    /// The look stage layer `layer` shows, or nil if it's idle.
    func look(forStageLayer layer: Int) -> StageLook? {
        layer == liveStageLayer ? look : fadingLook
    }

    /// Runs `changes` and dissolves the stage from the old look to the new one
    /// over `crossfadeDuration`, rather than cutting.
    func crossfade(_ changes: () -> Void) {
        crossfadeID += 1
        let id = crossfadeID
        withAnimation(.easeInOut(duration: Self.crossfadeDuration)) {
            fadingLook = look
            liveStageLayer = 1 - liveStageLayer
            changes()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.crossfadeDuration) { [weak self] in
            guard let self, self.crossfadeID == id else { return }
            self.fadingLook = nil
        }
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

/// What the stage draws; the audio controls only scale its motion.
struct StageLook: Equatable {
    var mode: VisualMode
    var theme: ColorTheme
    var framesPerSecond: Int
}
