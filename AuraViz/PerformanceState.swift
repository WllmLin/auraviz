import AppKit
import SwiftUI

/// Performance state shared by the control window's preview, the output
/// window and the Performance menu, so both windows always render the same
/// visual and its shortcuts work from either window.
final class PerformanceState: ObservableObject {
    static let blackoutFadeDuration: TimeInterval = 0.3
    static let vibeKillFadeDuration: TimeInterval = 1.0
    /// At most three flashes in any one-second window, the photosensitive
    /// seizure limit (WCAG 2.3.1). Comfortably over 1/3 s so display-frame
    /// jitter can't squeeze a fourth flash into a window.
    static let strobeMinimumInterval: TimeInterval = 0.36

    static let circleFrameRates = [30, 60]
    /// How long the crossfade transition dissolves the stage from the old look.
    static let crossfadeDuration: TimeInterval = 0.5
    /// A switch asked for this soon after a beat or bar lands on that one
    /// instead of waiting a whole beat or bar for the next.
    static let quantizeLateTolerance: TimeInterval = 0.06

    /// Set directly, these cut. Mode switches and preset recalls go through
    /// `show(_:clock:)` to use the chosen transition and quantize.
    @Published var mode: VisualMode = .circle {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: SettingsKey.mode) }
    }
    /// Theme and frame-rate changes apply at once, and carry into a queued
    /// look so it doesn't revert them when it lands.
    @Published var theme: ColorTheme = .aurora {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: SettingsKey.theme)
            queuedLook?.theme = theme
        }
    }
    @Published var circleFramesPerSecond = 30 {
        didSet {
            UserDefaults.standard.set(circleFramesPerSecond, forKey: SettingsKey.circleFramesPerSecond)
            queuedLook?.framesPerSecond = circleFramesPerSecond
        }
    }
    /// How the stage hands over from one look to the next.
    @Published var transition: StageTransition = .crossfade {
        didSet { UserDefaults.standard.set(transition.rawValue, forKey: SettingsKey.stageTransition) }
    }
    /// Whether look changes wait for the next beat or bar of the beat grid.
    @Published var transitionQuantize: TransitionQuantize = .off {
        didSet {
            UserDefaults.standard.set(transitionQuantize.rawValue, forKey: SettingsKey.transitionQuantize)
            if transitionQuantize == .off { showQueuedLookNow() }
        }
    }
    /// Fades the stage to black; audio and analysis keep running.
    @Published var isBlackedOut = false
    /// Covers the stage with a dim, neutral ambient loop for awkward silences
    /// and requests; audio keeps running. Any look change brings the show back.
    @Published var isVibeKilled = false
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
    /// a transition the other keeps showing the handoff's outgoing look.
    @Published private(set) var liveStageLayer = 0
    @Published private(set) var handoff: StageHandoff?
    /// The look waiting for the next beat or bar while quantized.
    @Published private(set) var queuedLook: StageLook?
    private var handoffID = 0
    private var queueTimer: Timer?

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
        queueTimer?.invalidate()
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
        if let transition = defaults.string(forKey: SettingsKey.stageTransition).flatMap(StageTransition.init(rawValue:)) {
            self.transition = transition
        }
        if let quantize = defaults.string(forKey: SettingsKey.transitionQuantize).flatMap(TransitionQuantize.init(rawValue:)) {
            transitionQuantize = quantize
        }
        lyricsText = defaults.string(forKey: SettingsKey.lyricsText) ?? lyricsText
        isLyricsEnabled = defaults.bool(forKey: SettingsKey.lyricsEnabled)
    }

    func cycleTheme(by offset: Int) {
        let themes = ColorTheme.allCases
        let index = themes.firstIndex(of: theme) ?? 0
        theme = themes[((index + offset) % themes.count + themes.count) % themes.count]
    }

    // MARK: - Transitions

    var look: StageLook {
        StageLook(mode: mode, theme: theme, framesPerSecond: circleFramesPerSecond)
    }

    /// The look the stage is headed for: the queued one, else the current one.
    var targetLook: StageLook { queuedLook ?? look }

    /// The look stage layer `layer` shows, or nil if it's idle.
    func look(forStageLayer layer: Int) -> StageLook? {
        layer == liveStageLayer ? look : handoff?.outgoingLook
    }

    func switchMode(to mode: VisualMode, clock: BeatClock?) {
        var target = targetLook
        target.mode = mode
        show(target, clock: clock)
    }

    /// Hands the stage over to `target` through `transition`: now, or, while
    /// quantized and `clock` has a tempo, on its next beat or bar. A later
    /// call replaces a queued look; asking for the current look cancels it.
    /// Either way it ends a vibe kill.
    func show(_ target: StageLook, clock: BeatClock?) {
        isVibeKilled = false
        queueTimer?.invalidate()
        queueTimer = nil
        guard target != look else {
            queuedLook = nil
            return
        }
        guard let clock, let delay = transitionQuantize.delay(untilNextStepOf: clock, at: BeatClock.now) else {
            queuedLook = nil
            startHandoff(to: target)
            return
        }
        queuedLook = target
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.showQueuedLookNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        queueTimer = timer
    }

    /// Lands the queued look without waiting for the beat.
    func showQueuedLookNow() {
        queueTimer?.invalidate()
        queueTimer = nil
        guard let target = queuedLook else { return }
        queuedLook = nil
        startHandoff(to: target)
    }

    private func startHandoff(to target: StageLook) {
        handoffID += 1
        let id = handoffID
        let style = transition
        if style.duration > 0 {
            handoff = StageHandoff(outgoingLook: look, style: style, startTime: BeatClock.now, seed: UInt64(id))
            liveStageLayer = 1 - liveStageLayer
        } else {
            handoff = nil
        }
        mode = target.mode
        theme = target.theme
        circleFramesPerSecond = target.framesPerSecond
        guard style.duration > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + style.duration) { [weak self] in
            guard let self, self.handoffID == id else { return }
            self.handoff = nil
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

/// How the stage hands over from one look to the next.
enum StageTransition: String, CaseIterable, Identifiable {
    case crossfade = "Fade"
    case wipe = "Wipe"
    case glitch = "Glitch"
    case zoom = "Zoom"
    case cut = "Cut"

    var id: Self { self }

    /// 0 cuts straight to the new look.
    var duration: TimeInterval {
        switch self {
        case .crossfade: return PerformanceState.crossfadeDuration
        case .wipe: return 0.6
        case .glitch: return 0.4
        case .zoom: return 0.6
        case .cut: return 0
        }
    }

    var help: String {
        switch self {
        case .crossfade: return "Dissolve to the new look"
        case .wipe: return "Wipe the new look in from the left"
        case .glitch: return "Tear the new look in, band by band"
        case .zoom: return "Zoom through the old look into the new one"
        case .cut: return "Cut straight to the new look"
        }
    }
}

/// Which grid step a look change waits for.
enum TransitionQuantize: String, CaseIterable, Identifiable {
    case off = "Off"
    case beat = "Beat"
    case bar = "Bar"

    var id: Self { self }

    private var beatsPerStep: Double? {
        switch self {
        case .off: return nil
        case .beat: return 1
        case .bar: return 4
        }
    }

    /// Seconds from `time` to the next beat or bar of `clock`, or nil to
    /// switch now: unquantized, or just past a step. Bars start on multiples
    /// of four beats, where a tap-tempo downbeat lands.
    func delay(untilNextStepOf clock: BeatClock, at time: TimeInterval) -> TimeInterval? {
        guard let beatsPerStep, clock.beatsPerSecond > 0 else { return nil }
        let step = clock.beatPhase(at: time) / beatsPerStep
        let secondsPerStep = beatsPerStep / clock.beatsPerSecond
        let sinceStep = (step - step.rounded(.down)) * secondsPerStep
        guard sinceStep >= PerformanceState.quantizeLateTolerance else { return nil }
        return secondsPerStep - sinceStep
    }
}

/// A transition in flight: what the outgoing layer shows and how it leaves.
struct StageHandoff: Equatable {
    var outgoingLook: StageLook
    var style: StageTransition
    /// `BeatClock.now` when it began.
    var startTime: TimeInterval
    /// Varies the glitch pattern from one handoff to the next.
    var seed: UInt64

    /// 0 at the start, 1 once the incoming look has fully taken over.
    func progress(at time: TimeInterval) -> Double {
        guard style.duration > 0 else { return 1 }
        return min(1, max(0, (time - startTime) / style.duration))
    }
}

extension AudioEngineManager {
    /// The beat grid quantized look changes snap to, or nil while there's no
    /// tempo to follow (stopped, or none detected or tapped yet).
    var transitionClock: BeatClock? {
        isRunning && bpm > 0 ? beatClock : nil
    }
}
