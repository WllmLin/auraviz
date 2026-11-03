import SwiftUI

/// Uploaded images laid over the stage, bottom to top, each in its spot and
/// blended with the visualizer beneath it. Every beat punches each image up
/// by its own pulse amount, scaled by the beat reactivity; punches keep to the
/// 3-per-second strobe cap, like the lyrics.
///
/// Takes the manager unobserved and reads it per tick, so audio frames don't
/// redraw the images faster than their own timeline.
struct ImageOverlayLayer: View {
    let audio: AudioEngineManager
    var overlays: [StageImageOverlay]
    /// Fades the images in and out; off, they're kept so they can fade.
    var isShown: Bool
    var isActive: Bool

    /// Shared so every stage layer, in the preview and the output, punches
    /// the images together and a crossfade doesn't show two sizes.
    private static let motion = ImageOverlayMotion()
    /// Scale added by a full-strength beat at full pulse and beat reactivity.
    private static let maximumPunch = 0.12
    private static let fadeDuration: TimeInterval = 0.3

    var body: some View {
        // Holds still, without redrawing, when no image pulses or shows.
        let isPulsing = overlays.contains { $0.overlay.pulse > 0 }
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive || !isPulsing || !isShown)) { timeline in
            let kick = Self.motion.advance(to: BeatClock.time(for: timeline.date), audio: audio, isActive: isActive)
            GeometryReader { proxy in
                ForEach(overlays) { item in
                    image(item, kick: kick, stage: proxy.size)
                }
            }
        }
        .allowsHitTesting(false)
        // The overlay chips in the controls already name the images.
        .accessibilityHidden(true)
    }

    /// Blended per image, against the visualizer and the images below it.
    /// Fades through the image's own opacity, inside the blend: fading the
    /// whole layer would group it first, and a Screen image's black
    /// background would show while it fades.
    private func image(_ item: StageImageOverlay, kick: Double, stage: CGSize) -> some View {
        let overlay = item.overlay
        let frame = overlay.placement.frame(forImage: CGSize(width: item.image.width, height: item.image.height), size: overlay.size, in: stage)
        return Image(decorative: item.image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(CGFloat(1 + Self.maximumPunch * overlay.pulse * kick))
            .position(x: frame.midX, y: frame.midY)
            .frame(width: stage.width, height: stage.height)
            // Fill Stage overhangs the stage, and so does a punch near an edge.
            .clipped()
            .opacity(isShown ? overlay.opacity : 0)
            .animation(.easeInOut(duration: Self.fadeDuration), value: isShown)
            .blendMode(overlay.blend.blendMode)
    }
}

/// Rate-limited beat punches shared by every image layer. A class so it can
/// advance inside a `TimelineView` update without invalidating SwiftUI state.
private final class ImageOverlayMotion {
    private static let kickDecay: TimeInterval = 0.18

    private var kickTime: TimeInterval = -.infinity
    private var kickStrength = 0.0
    private var kick = 0.0
    private var lastBeatCount: Int?
    private var lastTime: TimeInterval?
    private var wasActive = false

    /// The punch at `now`, 0...1, scaled by the beat reactivity.
    func advance(to now: TimeInterval, audio: AudioEngineManager, isActive: Bool) -> Double {
        // Several layers in two windows advance per frame; only the first
        // call at a new time moves the motion.
        if let lastTime, now <= lastTime, isActive == wasActive { return kick }
        lastTime = now
        wasActive = isActive
        guard isActive else {
            // At rest while audio is stopped.
            kickTime = -.infinity
            kick = 0
            return kick
        }

        let beat = audio.beat
        if let lastBeatCount, beat.beatCount != lastBeatCount,
           beat.lastBeatTime - kickTime >= PerformanceState.strobeMinimumInterval {
            kickTime = beat.lastBeatTime
            kickStrength = Double(beat.beatStrength)
        }
        lastBeatCount = beat.beatCount

        let age = now - kickTime
        kick = age >= 0 ? audio.beatReactivity * exp(-age / Self.kickDecay) * (0.4 + 0.6 * kickStrength) : 0
        return kick
    }
}
