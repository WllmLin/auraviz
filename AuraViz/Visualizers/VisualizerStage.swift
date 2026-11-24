import AppKit
import SwiftUI

/// The current visualizer for `mode`, fed live from the audio manager. Has no
/// background or chrome of its own; the preview card and the output window
/// wrap it.
struct VisualizerStage: View {
    @ObservedObject var audio: AudioEngineManager
    var mode: VisualMode
    var theme: ColorTheme
    var framesPerSecond: Int = 30
    /// Kinetic type laid over every mode; nil hides it.
    var lyrics: String? = nil
    /// Display font for the overlay type.
    var lyricsFont: OverlayFont = .systemRounded
    /// Uploaded images laid over every mode, under the lyrics.
    var images: [StageImageOverlay] = []
    var isShowingImages = false
    /// Beat mode's background picture; nil until one is chosen.
    var beatBackground: CGImage? = nil
    /// Whether that picture keeps its proportions or stretches to the stage.
    var beatBackgroundFit: BeatBackgroundFit = .fill

    var body: some View {
        ZStack {
            // Beat mode's picture covers the whole stage, so the orbs wouldn't show.
            if mode != .beat {
                StageOrbs(audio: audio, theme: theme, isActive: audio.isRunning)
            }
            visualizer
            if !images.isEmpty {
                // Fades itself (see ImageOverlayLayer); a fading container
                // would break the blend modes.
                ImageOverlayLayer(audio: audio, overlays: images, isShown: isShowingImages, isActive: audio.isRunning)
                    .transition(.identity)
            }
            if let lyrics {
                LyricsOverlay(audio: audio, text: lyrics, theme: theme, isActive: audio.isRunning, font: lyricsFont)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var visualizer: some View {
        let drums = audio.drumReactivity(for: mode)
        switch mode {
        case .circle:
            CircularVisualizerView(
                spectrum: audio.spectrum,
                volume: audio.volume,
                theme: theme,
                sensitivity: audio.sensitivity,
                framesPerSecond: framesPerSecond,
                isActive: audio.isRunning,
                beat: audio.beat,
                beatReactivity: audio.beatReactivity,
                drumReactivity: drums
            )
        case .waves:
            WaveVisualizerView(spectrum: audio.spectrum, waveform: audio.waveform, volume: audio.volume, theme: theme, sensitivity: audio.sensitivity, isActive: audio.isRunning, beat: audio.beat, beatReactivity: audio.beatReactivity, drumReactivity: drums)
        case .y2k:
            Y2KBarVisualizerView(spectrum: audio.spectrum, volume: audio.volume, theme: theme, sensitivity: audio.sensitivity, isActive: audio.isRunning, beat: audio.beat, beatReactivity: audio.beatReactivity, drumReactivity: drums)
        case .tunnel:
            TunnelVisualizerView(spectrum: audio.spectrum, volume: audio.volume, theme: theme, sensitivity: audio.sensitivity, isActive: audio.isRunning, beat: audio.beat, beatReactivity: audio.beatReactivity, drumReactivity: drums)
        case .beat:
            BeatVisualizerView(image: beatBackground, fit: beatBackgroundFit, volume: audio.volume, theme: theme, isActive: audio.isRunning, beat: audio.beat, beatReactivity: audio.beatReactivity, drumReactivity: drums)
        case .kaleidoscope:
            KaleidoscopeVisualizerView(spectrum: audio.spectrum, volume: audio.volume, theme: theme, sensitivity: audio.sensitivity, isActive: audio.isRunning, beat: audio.beat, beatReactivity: audio.beatReactivity, drumReactivity: drums)
        }
    }
}

/// Three soft theme-colored orbs behind the visualizer. They drift on slow
/// Lissajous paths and swell with the bass (or the volume at zero beat
/// reactivity), seen through the slow `DriftCamera`, redrawing at most 30
/// times a second and freezing while audio is stopped.
///
/// Takes the manager unobserved and reads it per tick, so audio frames don't
/// redraw the orbs faster than their own timeline.
struct StageOrbs: View {
    let audio: AudioEngineManager
    var theme: ColorTheme
    var isActive: Bool

    private struct Orb {
        var center: CGPoint
        var amplitude: CGPoint
        var frequency: CGPoint
        var phase: CGPoint
        /// Radius as a fraction of the shorter canvas side.
        var radius: CGFloat
        var opacity: Double
    }

    // Incommensurate frequencies (rad/s, periods of ~40–100 s) so the paths
    // don't visibly repeat.
    private static let orbs = [
        Orb(center: CGPoint(x: 0.25, y: 0.25), amplitude: CGPoint(x: 0.16, y: 0.13), frequency: CGPoint(x: 0.071, y: 0.113), phase: CGPoint(x: 0, y: 1.3), radius: 0.62, opacity: 0.30),
        Orb(center: CGPoint(x: 0.78, y: 0.70), amplitude: CGPoint(x: 0.14, y: 0.16), frequency: CGPoint(x: 0.089, y: 0.061), phase: CGPoint(x: 2.1, y: 0.4), radius: 0.72, opacity: 0.26),
        Orb(center: CGPoint(x: 0.50, y: 0.50), amplitude: CGPoint(x: 0.20, y: 0.12), frequency: CGPoint(x: 0.053, y: 0.097), phase: CGPoint(x: 4.0, y: 2.7), radius: 0.52, opacity: 0.22),
    ]

    /// Shared so every stage layer, in the preview and the output, draws the
    /// orbs in the same place and a crossfade doesn't show two sets.
    private static let drift = OrbDrift()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive)) { timeline in
            let now = BeatClock.time(for: timeline.date)
            let target = isActive ? 0.5 * audio.volume + CGFloat(audio.beatReactivity) * audio.bassEnvelope(at: now) : 0
            let state = Self.drift.advance(to: now, target: Double(min(1, max(0, target))), isActive: isActive)
            let camera = DriftCamera.pose(at: now, isActive: isActive)
            let colors = theme.orbColors
            Canvas { context, size in
                // The drift camera, applied inside the canvas so the zoom
                // never draws past the stage.
                var context = context
                context.translateBy(x: size.width * (0.5 + camera.offset.width), y: size.height * (0.5 + camera.offset.height))
                context.scaleBy(x: camera.scale, y: camera.scale)
                context.translateBy(x: -size.width / 2, y: -size.height / 2)
                draw(in: context, size: size, time: state.time, level: state.level, colors: colors)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext, size: CGSize, time t: Double, level: Double, colors: [Color]) {
        guard !colors.isEmpty else { return }
        let side = min(size.width, size.height)
        for (i, orb) in Self.orbs.enumerated() {
            let center = CGPoint(
                x: size.width * (orb.center.x + orb.amplitude.x * CGFloat(sin(orb.frequency.x * t + orb.phase.x))),
                y: size.height * (orb.center.y + orb.amplitude.y * CGFloat(sin(orb.frequency.y * t + orb.phase.y)))
            )
            let r = side * orb.radius * CGFloat(1 + 0.3 * level)
            let alpha = min(1, orb.opacity * (1 + 0.6 * level))
            let color = colors[i % colors.count]
            // Gaussian-like falloff that reaches clear at the ellipse edge, so
            // the orb looks blurred without an offscreen blur pass.
            let gradient = Gradient(stops: [
                .init(color: color.opacity(alpha), location: 0),
                .init(color: color.opacity(alpha * 0.72), location: 0.25),
                .init(color: color.opacity(alpha * 0.36), location: 0.5),
                .init(color: color.opacity(alpha * 0.11), location: 0.75),
                .init(color: color.opacity(0), location: 1),
            ])
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: r)
            )
        }
    }
}

/// Drift time that only advances while audio runs, so the orbs resume where
/// they stopped, and a smoothed level so they swell and settle instead of
/// twitching with the fast bass envelope. A class so it can advance inside a
/// `TimelineView` update without invalidating SwiftUI state.
private final class OrbDrift {
    private static let attackTime: TimeInterval = 0.08
    private static let releaseTime: TimeInterval = 0.6

    private var time: Double = 0
    private var level: Double = 0
    private var lastTime: TimeInterval?

    func advance(to now: TimeInterval, target: Double, isActive: Bool) -> (time: Double, level: Double) {
        defer { lastTime = now }
        guard isActive, let lastTime else { return (time, level) }
        // Clamped so resuming after a pause or a hidden window continues
        // instead of jumping; several layers advancing per frame see dt ≈ 0.
        let dt = min(0.1, max(0, now - lastTime))
        time += dt
        let tau = target > level ? Self.attackTime : Self.releaseTime
        level += (target - level) * (1 - exp(-dt / tau))
        return (time, level)
    }
}

/// Where the slow drift camera holds the stage background at one moment:
/// a gentle zoom, and a shift that never exceeds the room the zoom makes, so
/// a full-bleed picture's edges never show.
struct DriftPose: Equatable {
    var scale: CGFloat = 1
    /// Shift as fractions of the stage's width and height.
    var offset: CGSize = .zero
}

/// A slow, audio-independent camera over the stage background (the orbs, or
/// Beat mode's picture) that makes it breathe: the zoom swells and settles
/// and the frame wanders, each on two slow sines with incommensurate periods
/// (about 20–70 s), so the motion never visibly loops or jerks.
///
/// The time only advances while audio runs, like the orbs, so the camera
/// freezes in place when audio stops and resumes from there. Shared, so the
/// preview and the output, and both layers of a transition, frame the
/// background the same way.
enum DriftCamera {
    /// Zoom at the middle of the breath (5 % in).
    static let baseZoom = 0.05
    /// How far the zoom swings either side of that: 2.5 %–7.5 % in.
    static let zoomSwing = 0.025
    /// Share of the zoom's spare margin the frame may wander into, so a
    /// picture's edge never reaches the stage edge.
    static let reach = 0.85

    // Periods (s): zoom 23 and 37, x 41 and 67, y 29 and 53. Two sines
    // weighted 0.6 / 0.4, so each stays within ±1.
    private static let zoomTerms = [(weight: 0.6, period: 23.0, phase: 0.0), (weight: 0.4, period: 37.0, phase: 1.9)]
    private static let xTerms = [(weight: 0.6, period: 41.0, phase: 0.7), (weight: 0.4, period: 67.0, phase: 3.1)]
    private static let yTerms = [(weight: 0.6, period: 53.0, phase: 2.3), (weight: 0.4, period: 29.0, phase: 4.4)]

    private static let clock = DriftClock()

    /// The pose for the shared drift time, advancing it to `now` while active.
    static func pose(at now: TimeInterval, isActive: Bool) -> DriftPose {
        pose(time: clock.advance(to: now, isActive: isActive))
    }

    /// The pose `t` seconds into the drift. The shift along each axis stays
    /// within `reach` of the zoom's margin, `(scale − 1) / 2` of that axis,
    /// so the scaled background still covers the stage.
    static func pose(time t: Double) -> DriftPose {
        guard t.isFinite else { return DriftPose(scale: CGFloat(1 + baseZoom)) }
        let scale = 1 + baseZoom + zoomSwing * wave(zoomTerms, t)
        let margin = reach * (scale - 1) / 2
        return DriftPose(
            scale: CGFloat(scale),
            offset: CGSize(width: margin * wave(xTerms, t), height: margin * wave(yTerms, t))
        )
    }

    private static func wave(_ terms: [(weight: Double, period: Double, phase: Double)], _ t: Double) -> Double {
        terms.reduce(0) { $0 + $1.weight * sin(2 * .pi * t / $1.period + $1.phase) }
    }
}

/// Drift time that only advances while audio runs. A class so it can advance
/// inside a `TimelineView` update without invalidating SwiftUI state.
private final class DriftClock {
    private var time: Double = 0
    private var lastTime: TimeInterval?

    func advance(to now: TimeInterval, isActive: Bool) -> Double {
        guard isActive, let lastTime else {
            lastTime = now
            return time
        }
        // Clamped so resuming after a pause or a hidden window continues
        // instead of jumping; several layers advancing per frame see dt ≈ 0,
        // and a caller a moment behind another doesn't rewind the clock.
        let dt = min(0.1, max(0, now - lastTime))
        time += dt
        self.lastTime = max(lastTime, now)
        return time
    }
}

extension View {
    /// Frames the view through the drift camera: zoomed about its center,
    /// then shifted by the pose's fractions of its size.
    func driftCamera(_ pose: DriftPose) -> some View {
        scaleEffect(pose.scale)
            .visualEffect { content, proxy in
                content.offset(x: pose.offset.width * proxy.size.width, y: pose.offset.height * proxy.size.height)
            }
    }
}

extension ColorTheme {
    /// Up to three of the theme's colors, skipping near-black ones that would
    /// vanish on the dark stage.
    var orbColors: [Color] {
        Array(colors(brighterThan: 0.12).prefix(3))
    }

    /// The theme's colors with a luma over `luma`, or all of them if none is.
    func colors(brighterThan luma: CGFloat) -> [Color] {
        let visible = gradient.filter { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return true }
            return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent > luma
        }
        return visible.isEmpty ? gradient : visible
    }
}

/// The stage for the shared performance look, so the preview and the output
/// show the same thing. Each layer keeps its identity (and its modifier
/// chain) across a transition, so the outgoing look keeps animating while it
/// hands over to the incoming one.
struct PerformanceStage: View {
    let audio: AudioEngineManager
    @EnvironmentObject var performance: PerformanceState
    @EnvironmentObject var imageOverlays: ImageOverlayStore

    var body: some View {
        let handoff = performance.handoff
        TimelineView(.animation(paused: handoff == nil)) { timeline in
            let progress = handoff?.progress(at: BeatClock.time(for: timeline.date)) ?? 1
            ZStack {
                layer(0, handoff: handoff, progress: progress)
                layer(1, handoff: handoff, progress: progress)
                if let handoff, handoff.style == .wipe {
                    WipeEdge(position: StageLayerEffect.wipeEdge(progress), colors: performance.theme.orbColors)
                        .zIndex(2)
                }
            }
        }
    }

    @ViewBuilder
    private func layer(_ index: Int, handoff: StageHandoff?, progress: Double) -> some View {
        if let look = performance.look(forStageLayer: index) {
            let isIncoming = index == performance.liveStageLayer
            let effect = StageLayerEffect(handoff: handoff, progress: progress, isIncoming: isIncoming)
            // Both layers show the current lyrics and images, so a
            // transition only recolors the lyrics.
            VisualizerStage(audio: audio, mode: look.mode, theme: look.theme, framesPerSecond: look.framesPerSecond, lyrics: performance.stageLyrics, lyricsFont: performance.overlayFont, images: imageOverlays.stageOverlays, isShowingImages: imageOverlays.isEnabled, beatBackground: imageOverlays.beatBackgroundImage, beatBackgroundFit: imageOverlays.beatBackgroundFit)
                .scaleEffect(effect.scale)
                .visualEffect { content, proxy in
                    content.offset(x: effect.offset * proxy.size.width)
                }
                .clipShape(StageClip(spans: effect.spans, axis: effect.clipAxis))
                .opacity(effect.opacity)
                .zIndex(isIncoming ? 1 : 0)
        }
    }
}

/// How one stage layer looks at a point in a handoff. Idle, it's the plain
/// layer: full size and opacity, unclipped, in place.
struct StageLayerEffect {
    var scale: CGFloat = 1
    /// Horizontal shift as a fraction of the stage width.
    var offset: CGFloat = 0
    var opacity: Double = 1
    /// The fractions of the stage, along `clipAxis`, the layer shows.
    var spans: [ClosedRange<CGFloat>] = [0...1]
    var clipAxis: Axis = .horizontal

    private static let glitchBandCount = 14
    /// Jitter steps per second; displacement only, so the glitch doesn't
    /// flash (see `PerformanceState.strobeMinimumInterval`).
    private static let glitchJitterRate = 30.0

    init(handoff: StageHandoff?, progress p: Double, isIncoming: Bool) {
        guard let handoff else { return }
        let eased = CGFloat(p * p * (3 - 2 * p))
        switch handoff.style {
        case .crossfade:
            opacity = Double(isIncoming ? eased : 1 - eased)
        case .wipe:
            let edge = Self.wipeEdge(p)
            spans = isIncoming ? [0...edge] : [edge...1]
        case .zoom:
            // Flies through the old look as the new one rises up behind it.
            scale = isIncoming ? 0.6 + 0.4 * eased : 1 + 1.4 * eased
            opacity = Double(isIncoming ? eased : 1 - eased)
        case .glitch:
            spans = Self.glitchBands(progress: p, seed: handoff.seed, isIncoming: isIncoming)
            clipAxis = .vertical
            // Each layer tears sideways on its own, strongest mid-transition.
            let step = Int((p * handoff.style.duration * Self.glitchJitterRate).rounded(.down))
            let layerSeed = handoff.seed &* 2 &+ (isIncoming ? 1 : 0)
            let jitter = Self.noise(step, layerSeed) * 2 - 1
            offset = CGFloat(0.06 * sin(.pi * p) * jitter)
        case .cut:
            break
        }
    }

    /// Where the wipe's edge is, as a fraction of the stage width.
    static func wipeEdge(_ p: Double) -> CGFloat {
        CGFloat(p * p * (3 - 2 * p))
    }

    /// Horizontal bands of uneven height, each switching to the incoming look
    /// once at its own random moment (all by 80 %), so the handoff tears in
    /// without flickering back.
    private static func glitchBands(progress p: Double, seed: UInt64, isIncoming: Bool) -> [ClosedRange<CGFloat>] {
        let weights = (0..<glitchBandCount).map { 0.3 + noise($0, seed) }
        let total = weights.reduce(0, +)
        var spans: [ClosedRange<CGFloat>] = []
        var top = 0.0
        for (index, weight) in weights.enumerated() {
            let bottom = index == glitchBandCount - 1 ? 1 : top + weight / total
            let switched = p >= 0.8 * noise(index, seed &+ 0x9E37_79B9)
            if switched == isIncoming { spans.append(CGFloat(top)...CGFloat(bottom)) }
            top = bottom
        }
        return spans
    }

    /// Deterministic 0..<1 noise (SplitMix64), so the preview and the output
    /// draw the same glitch.
    private static func noise(_ index: Int, _ seed: UInt64) -> Double {
        var z = seed &+ UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

/// The spans of the stage a layer shows: columns across a horizontal axis,
/// rows down a vertical one.
struct StageClip: Shape {
    var spans: [ClosedRange<CGFloat>]
    var axis: Axis

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for span in spans {
            switch axis {
            case .horizontal:
                path.addRect(CGRect(x: rect.minX + rect.width * span.lowerBound, y: rect.minY, width: rect.width * (span.upperBound - span.lowerBound), height: rect.height))
            case .vertical:
                path.addRect(CGRect(x: rect.minX, y: rect.minY + rect.height * span.lowerBound, width: rect.width, height: rect.height * (span.upperBound - span.lowerBound)))
            }
        }
        return path
    }
}

/// A glowing theme-colored line along the wipe's edge, hiding the seam
/// between the two looks.
private struct WipeEdge: View {
    /// Fraction of the stage width.
    var position: CGFloat
    var colors: [Color]

    var body: some View {
        Canvas { context, size in
            let scale = size.visualizerScale
            let x = size.width * position
            let glowWidth = 28 * scale
            let color = colors.first ?? .white
            context.fill(
                Path(CGRect(x: x - glowWidth / 2, y: 0, width: glowWidth, height: size.height)),
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0), color.opacity(0.75), color.opacity(0)]),
                    startPoint: CGPoint(x: x - glowWidth / 2, y: 0),
                    endPoint: CGPoint(x: x + glowWidth / 2, y: 0)
                )
            )
            context.fill(Path(CGRect(x: x - scale, y: 0, width: 2 * scale, height: size.height)), with: .color(.white.opacity(0.9)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Vibe kill, strobe flashes, the output dimmer and blackout from the shared
/// performance state, laid over a stage so the preview and the output show
/// the same thing.
struct StageEffectsOverlay: View {
    @EnvironmentObject var performance: PerformanceState

    var body: some View {
        ZStack {
            // Below the strobe and blackout, which stay deliberate actions.
            AmbientLoop(isActive: performance.isVibeKilled)
                .opacity(performance.isVibeKilled ? 1 : 0)
                .animation(.easeInOut(duration: PerformanceState.vibeKillFadeDuration), value: performance.isVibeKilled)
            // Over every mode and the vibe kill, under the strobe so its
            // flashes stay clean white, and under the dimmer and blackout so
            // they take the grain down with the picture.
            if performance.filmGrain > 0 {
                FilmGrainOverlay(amount: performance.filmGrain)
            }
            Color.white
                .keyframeAnimator(initialValue: 0.0, trigger: performance.strobeFlashTime) { content, opacity in
                    content.opacity(opacity)
                } keyframes: { _ in
                    MoveKeyframe(1.0)
                    LinearKeyframe(1.0, duration: 0.05)
                    LinearKeyframe(0.0, duration: 0.07)
                }
            // Above the strobe so the flashes dim too.
            Color.black
                .opacity(1 - performance.outputBrightness)
            // Above the strobe so a blackout always wins.
            Color.black
                .opacity(performance.isBlackedOut ? 1 : 0)
                .animation(.easeInOut(duration: PerformanceState.blackoutFadeDuration), value: performance.isBlackedOut)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The vibe kill's stage: one dim, neutral orb on black that breathes and
/// drifts slowly on its own clock, ignoring the audio, so nothing on stage
/// reacts while the room is quiet or a request is being handled. Freezes
/// once inactive, while it fades out.
private struct AmbientLoop: View {
    var isActive: Bool

    /// Seconds per breath.
    private static let breathPeriod = 8.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive)) { timeline in
            let t = BeatClock.time(for: timeline.date)
            Canvas { context, size in
                draw(in: context, size: size, time: t)
            }
        }
        .background(.black)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext, size: CGSize, time t: Double) {
        let breath = 0.5 - 0.5 * cos(2 * .pi * t / Self.breathPeriod)
        let side = min(size.width, size.height)
        let center = CGPoint(
            x: size.width * (0.5 + 0.03 * CGFloat(sin(0.11 * t))),
            y: size.height * (0.5 + 0.03 * CGFloat(sin(0.07 * t + 1.3)))
        )
        let r = side * CGFloat(0.34 + 0.04 * breath)
        let alpha = 0.10 + 0.08 * breath
        let color = Color(white: 0.82)
        // Same falloff as the stage orbs.
        let gradient = Gradient(stops: [
            .init(color: color.opacity(alpha), location: 0),
            .init(color: color.opacity(alpha * 0.72), location: 0.25),
            .init(color: color.opacity(alpha * 0.36), location: 0.5),
            .init(color: color.opacity(alpha * 0.11), location: 0.75),
            .init(color: color.opacity(0), location: 1),
        ])
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: r)
        )
    }
}

/// A monochrome film finish over the whole stage: animated grain that
/// re-rolls 24 times a second like projected film, a faint lift in the
/// blacks where the grain lives on the film base, and a soft vignette.
/// `amount` (0...1) scales all three.
///
/// The grain is a handful of pre-rendered gray tiles, picked and shifted per
/// frame from the clock, so a frame costs two tiled fills and the preview and
/// output show the same grain.
struct FilmGrainOverlay: View {
    var amount: Double

    /// Film's frame rate: the grain changes on every frame.
    static let grainFrameRate = 24.0
    /// Overlay-blended grain at full amount; overlay leaves pure black alone.
    static let midtoneOpacity = 0.7
    /// Screen-blended grain at full amount, so the blacks carry grain too.
    /// Small, since it also lifts them (by about half this).
    static let shadowOpacity = 0.07
    /// Corner darkening at full amount.
    static let vignetteOpacity = 0.45

    var body: some View {
        let amount = min(1, max(0, amount))
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / Self.grainFrameRate)) { timeline in
                let frame = Int((BeatClock.time(for: timeline.date) * Self.grainFrameRate).rounded(.down))
                ZStack {
                    grain(frame: frame)
                        .opacity(Self.midtoneOpacity * amount)
                        .blendMode(.overlay)
                    // A different tile from the midtone pass, so the two
                    // don't just stack into a stronger copy.
                    grain(frame: frame &+ 7919)
                        .opacity(Self.shadowOpacity * amount)
                        .blendMode(.screen)
                }
            }
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let reach = hypot(size.width, size.height) / 2
                let darkness = Self.vignetteOpacity * amount
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: .clear, location: 0.45),
                            .init(color: .black.opacity(darkness * 0.35), location: 0.75),
                            .init(color: .black.opacity(darkness), location: 1),
                        ]),
                        center: center, startRadius: 0, endRadius: reach
                    )
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One frame of grain tiled over the stage, from a tile and offset chosen
    /// by `frame`, so consecutive frames don't visibly repeat.
    private func grain(frame: Int) -> some View {
        Canvas { context, size in
            let tiles = FilmGrainTiles.images
            guard !tiles.isEmpty else { return }
            let pick = FilmGrainTiles.random(frame, 0)
            let tile = tiles[Int(pick * Double(tiles.count)) % tiles.count]
            let scale = FilmGrainTiles.pointsPerPixel(for: size)
            let side = CGFloat(FilmGrainTiles.side) * scale
            let origin = CGPoint(
                x: -side * CGFloat(FilmGrainTiles.random(frame, 1)),
                y: -side * CGFloat(FilmGrainTiles.random(frame, 2))
            )
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .tiledImage(tile, origin: origin, scale: scale)
            )
        }
    }
}

/// Seamless gray grain tiles centered on mid-gray, so overlay blending
/// leaves the picture's average brightness alone. Each mixes per-pixel noise
/// with softer clumps a few pixels wide, closer to film's irregular grain
/// than flat digital noise. Gray only, so the grain is monochrome.
enum FilmGrainTiles {
    /// Tile edge in pixels.
    static let side = 256
    static let count = 8
    /// Grain strength in gray levels (one standard deviation).
    static let contrast = 38.0
    /// Pixel size of the clumps.
    private static let clumpSize = 3
    /// Fine noise vs clumps; the clumps are what read as film.
    private static let fineWeight = 0.55

    static let images: [Image] = (0..<count).compactMap { index in
        makeTile(seed: 0xF11A_6EA1 &+ UInt64(index)).map { Image(decorative: $0, scale: 1) }
    }

    /// Grain pixels are about one device pixel at 1080p and stay that share
    /// of the frame on bigger outputs; never below half a point, so Retina
    /// previews keep visible grain.
    static func pointsPerPixel(for size: CGSize) -> CGFloat {
        max(0.5, min(size.width, size.height) / 1080)
    }

    /// Gray levels around 128, `side` × `side`, row-major. Wraps at the edges
    /// so the tile repeats without seams.
    static func makeValues(seed: UInt64) -> [UInt8] {
        let n = side
        let m = n / clumpSize + (n % clumpSize == 0 ? 0 : 1)
        var state = seed
        func gaussian() -> Double {
            // Irwin–Hall: four uniforms, rescaled to unit variance.
            var sum = 0.0
            for _ in 0..<4 { sum += nextUniform(&state) }
            return (sum - 2) * 3.0.squareRoot()
        }
        let lattice = (0..<(m * m)).map { _ in gaussian() }
        var raw = [Double](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                // Clumps: the coarse lattice, bilinearly interpolated with
                // wraparound. Spanning the whole tile, so it tiles seamlessly.
                let fx = Double(x) * Double(m) / Double(n)
                let fy = Double(y) * Double(m) / Double(n)
                let x0 = Int(fx), y0 = Int(fy)
                let x1 = (x0 + 1) % m, y1 = (y0 + 1) % m
                let tx = fx - Double(x0), ty = fy - Double(y0)
                let top = lattice[y0 * m + x0] * (1 - tx) + lattice[y0 * m + x1] * tx
                let bottom = lattice[y1 * m + x0] * (1 - tx) + lattice[y1 * m + x1] * tx
                let clump = top * (1 - ty) + bottom * ty
                raw[y * n + x] = fineWeight * gaussian() + (1 - fineWeight) * clump
            }
        }
        // Normalize, since interpolation softens the clumps' spread.
        let mean = raw.reduce(0, +) / Double(raw.count)
        let variance = raw.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(raw.count)
        let deviation = max(variance.squareRoot(), 1e-9)
        return raw.map { value in
            UInt8(min(255, max(0, (128 + (value - mean) / deviation * contrast).rounded())))
        }
    }

    private static func makeTile(seed: UInt64) -> CGImage? {
        let values = makeValues(seed: seed)
        guard let provider = CGDataProvider(data: Data(values) as CFData) else { return nil }
        return CGImage(
            width: side, height: side,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Deterministic 0..<1 noise for a frame and a channel (tile pick, x or
    /// y shift), so every window draws the same grain.
    static func random(_ frame: Int, _ channel: UInt64) -> Double {
        var state = UInt64(bitPattern: Int64(frame)) &* 0x9E37_79B9_7F4A_7C15 &+ channel &* 0xD1B5_4A32_D192_ED03
        return nextUniform(&state)
    }

    /// SplitMix64 step: advances `state`, returns 0..<1.
    private static func nextUniform(_ state: inout UInt64) -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

extension CGSize {
    /// The visualizers were designed for the original 420pt preview card.
    /// Larger canvases (full screen, projectors, 4K, ultrawide) multiply fixed
    /// point sizes — line widths, paddings, spacings — by this factor so they
    /// keep the preview's proportions; smaller canvases keep the designed sizes.
    var visualizerScale: CGFloat { max(1, min(width, height) / 420) }
}
