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

    var body: some View {
        ZStack {
            StageOrbs(audio: audio, theme: theme, isActive: audio.isRunning)
            visualizer
            if let lyrics {
                LyricsOverlay(audio: audio, text: lyrics, theme: theme, isActive: audio.isRunning)
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
        case .particles:
            ParticleVisualizerView(spectrum: audio.spectrum, volume: audio.volume, theme: theme, sensitivity: audio.sensitivity, isActive: audio.isRunning, beat: audio.beat, beatReactivity: audio.beatReactivity, drumReactivity: drums)
        case .laser:
            LaserVisualizerView(spectrum: audio.spectrum, volume: audio.volume, theme: theme, sensitivity: audio.sensitivity, isActive: audio.isRunning, beat: audio.beat, beatReactivity: audio.beatReactivity, drumReactivity: drums)
        }
    }
}

/// Three soft theme-colored orbs behind the visualizer. They drift on slow
/// Lissajous paths and swell with the bass (or the volume at zero beat
/// reactivity), redrawing at most 30 times a second and freezing while audio
/// is stopped.
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
            let colors = theme.orbColors
            Canvas { context, size in
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
/// show the same thing. Each layer keeps its identity across a crossfade, so
/// the outgoing look keeps animating while it fades out under (or over) the
/// incoming one.
struct PerformanceStage: View {
    let audio: AudioEngineManager
    @EnvironmentObject var performance: PerformanceState

    var body: some View {
        ZStack {
            layer(0)
            layer(1)
        }
    }

    @ViewBuilder
    private func layer(_ index: Int) -> some View {
        if let look = performance.look(forStageLayer: index) {
            // Both layers show the current lyrics, so a crossfade only
            // recolors them.
            VisualizerStage(audio: audio, mode: look.mode, theme: look.theme, framesPerSecond: look.framesPerSecond, lyrics: performance.stageLyrics)
                .opacity(index == performance.liveStageLayer ? 1 : 0)
                .transition(.opacity)
        }
    }
}

/// Strobe flashes and blackout from the shared performance state, laid over
/// a stage so the preview and the output show the same thing.
struct StageEffectsOverlay: View {
    @EnvironmentObject var performance: PerformanceState

    var body: some View {
        ZStack {
            Color.white
                .keyframeAnimator(initialValue: 0.0, trigger: performance.strobeFlashTime) { content, opacity in
                    content.opacity(opacity)
                } keyframes: { _ in
                    MoveKeyframe(1.0)
                    LinearKeyframe(1.0, duration: 0.05)
                    LinearKeyframe(0.0, duration: 0.07)
                }
            // Above the strobe so a blackout always wins.
            Color.black
                .opacity(performance.isBlackedOut ? 1 : 0)
                .animation(.easeInOut(duration: PerformanceState.blackoutFadeDuration), value: performance.isBlackedOut)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension CGSize {
    /// The visualizers were designed for the original 420pt preview card.
    /// Larger canvases (full screen, projectors, 4K, ultrawide) multiply fixed
    /// point sizes — line widths, paddings, spacings — by this factor so they
    /// keep the preview's proportions; smaller canvases keep the designed sizes.
    var visualizerScale: CGFloat { max(1, min(width, height) / 420) }
}
