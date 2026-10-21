import SwiftUI

/// The current visualizer for `mode`, fed live from the audio manager. Has no
/// background or chrome of its own; the preview card and the output window
/// wrap it.
struct VisualizerStage: View {
    @ObservedObject var audio: AudioEngineManager
    var mode: VisualMode
    var theme: ColorTheme
    var framesPerSecond: Int = 30

    var body: some View {
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
                beatReactivity: audio.beatReactivity
            )
        case .waves:
            WaveVisualizerView(spectrum: audio.spectrum, waveform: audio.waveform, volume: audio.volume, theme: theme, sensitivity: audio.sensitivity, isActive: audio.isRunning, beat: audio.beat, beatReactivity: audio.beatReactivity)
        case .y2k:
            Y2KBarVisualizerView(spectrum: audio.spectrum, volume: audio.volume, theme: theme, sensitivity: audio.sensitivity, isActive: audio.isRunning, beat: audio.beat, beatReactivity: audio.beatReactivity)
        case .tunnel:
            TunnelVisualizerView(spectrum: audio.spectrum, volume: audio.volume, theme: theme, sensitivity: audio.sensitivity, isActive: audio.isRunning, beat: audio.beat, beatReactivity: audio.beatReactivity)
        case .particles:
            ParticleVisualizerView(spectrum: audio.spectrum, volume: audio.volume, theme: theme, sensitivity: audio.sensitivity, isActive: audio.isRunning, beat: audio.beat, beatReactivity: audio.beatReactivity)
        }
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
            VisualizerStage(audio: audio, mode: look.mode, theme: look.theme, framesPerSecond: look.framesPerSecond)
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
