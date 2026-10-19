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
        }
    }
}

extension CGSize {
    /// The visualizers were designed for the original 420pt preview card.
    /// Larger canvases (full screen, projectors, 4K, ultrawide) multiply fixed
    /// point sizes — line widths, paddings, spacings — by this factor so they
    /// keep the preview's proportions; smaller canvases keep the designed sizes.
    var visualizerScale: CGFloat { max(1, min(width, height) / 420) }
}
