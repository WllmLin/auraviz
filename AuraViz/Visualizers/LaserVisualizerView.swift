import AppKit
import SwiftUI

/// Club laser wall: fans of beams from emitters along the top edge and the
/// bottom corners sweep across the whole stage. The sweep locks to the beat
/// grid (an edge on every beat, one full swing per two beats), the beams
/// brighten with the kick and the low band, and everything is drawn
/// additively in the theme's gradient. Kick flashes are rate-limited to the
/// strobe cap, so fast kicks can't make the beams flash more than 3 times a
/// second. Kick hits punch the hot spots at the apertures, snares throw the
/// fans open and hats make a scatter of beam cores shimmer.
struct LaserVisualizerView: View {
    var spectrum: [CGFloat]
    var volume: CGFloat
    var theme: ColorTheme
    var sensitivity: Double
    var isActive: Bool = true
    var beat = BeatAnalysis()
    /// 0 keeps the volume-only look; 1 applies the full beat effects.
    var beatReactivity: Double = 0
    /// Kicks punch the apertures, snares open the fans, hats shimmer the beams.
    var drumReactivity = DrumReactivity.off

    @State private var sweep = BeatSyncedPhase()
    @State private var light = LaserLight()

    private struct Emitter {
        /// Position as a fraction of the canvas.
        var position: CGPoint
        /// Center of the fan at rest, in radians (screen coordinates, y down).
        var heading: Double
        /// +1 or -1, so neighbors swing in opposite directions and cross.
        var direction: Double
        /// Peak swing either side of `heading`, in radians.
        var swing: Double
        /// Angle between the outermost beams of the fan, in radians.
        var spread: Double
        var beams: Int
    }

    private static let emitters = [
        Emitter(position: CGPoint(x: 0.15, y: 0), heading: .pi / 2, direction: 1, swing: 0.6, spread: 0.9, beams: 7),
        Emitter(position: CGPoint(x: 0.50, y: 0), heading: .pi / 2, direction: -1, swing: 0.6, spread: 0.9, beams: 7),
        Emitter(position: CGPoint(x: 0.85, y: 0), heading: .pi / 2, direction: 1, swing: 0.6, spread: 0.9, beams: 7),
        Emitter(position: CGPoint(x: 0, y: 1), heading: -.pi / 4, direction: 1, swing: 0.35, spread: 0.6, beams: 5),
        Emitter(position: CGPoint(x: 1, y: 1), heading: -3 * .pi / 4, direction: -1, swing: 0.35, spread: 0.6, beams: 5),
    ]

    var body: some View {
        let palette = LaserPalette(theme: theme)
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let now = BeatClock.time(for: timeline.date)
            // One full swing per two beats at full reactivity; a slow drift
            // at 0.25 swings per second otherwise.
            let phase = sweep.advance(
                to: t,
                wallRate: 0.25,
                gridPhase: beat.clock.beatPhase(at: now),
                gridRate: 0.5,
                nominalGridSpeed: beat.clock.beatsPerSecond,
                reactivity: beatReactivity
            )
            let pulse = light.advance(to: now, beat: beat, isActive: isActive)
            let energy = Double(min(1, max(0, volume)))
            let kick = beatReactivity * pulse.flash
            let low = beatReactivity * pulse.bass
            // Never fully dark between kicks, so the kick modulates the beams
            // rather than switching them on and off.
            let level = min(1.2, 0.3 + (0.5 - 0.2 * beatReactivity) * energy + 0.3 * low + 0.6 * kick)
            let drums = drumReactivity.scaled(by: beatReactivity)
            let accents = LaserDrumAccents(
                kick: isActive ? drums.kick * beat.kick.pulse(at: now) : 0,
                snare: isActive ? drums.snare * beat.snare.pulse(at: now) : 0,
                hat: isActive ? drums.hat * beat.hat.pulse(at: now) : 0,
                hatHits: beat.hat
            )
            Canvas { context, size in
                draw(in: context, size: size, phase: phase, energy: energy, level: level, kick: kick, drums: accents, palette: palette)
            }
        }
        .background(Color.clear)
    }

    private func draw(in context: GraphicsContext, size: CGSize, phase: Double, energy: Double, level: Double, kick: Double, drums: LaserDrumAccents, palette: LaserPalette) {
        let w = size.width
        let h = size.height
        let s = size.visualizerScale
        let reach = hypot(w, h) * 1.1
        // cos puts the extremes of the swing on the beats.
        let swing = cos(2 * .pi * phase)
        let spreadScale = 1 + 0.25 * energy + 0.15 * kick + 0.3 * drums.snare
        var glow = context
        glow.blendMode = .plusLighter

        for (e, emitter) in Self.emitters.enumerated() {
            let origin = CGPoint(x: emitter.position.x * w, y: emitter.position.y * h)
            let center = emitter.heading + emitter.direction * emitter.swing * swing
            let spread = emitter.spread * spreadScale
            // Corner fans sit a little dimmer so the top wall leads.
            let emitterLevel = level * (emitter.position.y > 0.5 ? 0.75 : 1)

            for k in 0..<emitter.beams {
                let u = emitter.beams > 1 ? Double(k) / Double(emitter.beams - 1) : 0.5
                let angle = center + (u - 0.5) * spread
                let end = CGPoint(x: origin.x + cos(angle) * reach, y: origin.y + sin(angle) * reach)
                // The fan spans the gradient, shifted per emitter so
                // neighboring fans don't repeat the same colors.
                let rgb = palette.sample((u + Double(e) * 0.37).truncatingRemainder(dividingBy: 1))
                let color = rgb.color
                let core = rgb.towardWhite(0.55).color
                let alpha = min(1, emitterLevel)

                var beam = Path()
                beam.move(to: origin)
                beam.addLine(to: end)
                // Brightest at the emitter, fading into the haze.
                func shading(_ c: Color, _ a: Double) -> GraphicsContext.Shading {
                    .linearGradient(
                        Gradient(colors: [c.opacity(min(1, a)), c.opacity(min(1, a) * 0.12)]),
                        startPoint: origin, endPoint: end
                    )
                }
                glow.stroke(beam, with: shading(color, alpha * 0.10), lineWidth: 16 * s)
                glow.stroke(beam, with: shading(color, alpha * 0.35), lineWidth: 5 * s)
                // Thin cores only, so the shimmer never brightens the stage much.
                let shimmer = drums.hat > 0.01 && drums.hatHits.scatter(e * 16 + k) < 0.35 ? drums.hat : 0
                glow.stroke(beam, with: shading(core, alpha * 0.9 + shimmer), lineWidth: (1.2 + 0.8 * kick + 1.2 * shimmer) * s)
            }

            // Hot spot at the aperture.
            let r = (22 + 18 * level + 26 * drums.kick) * s
            glow.fill(
                Path(ellipseIn: CGRect(x: origin.x - r, y: origin.y - r, width: r * 2, height: r * 2)),
                with: .radialGradient(
                    Gradient(colors: [palette.sample(Double(e) * 0.37).towardWhite(0.5).color.opacity(min(1, 0.5 * emitterLevel)), Color.clear]),
                    center: origin, startRadius: 0, endRadius: r
                )
            )
        }
    }
}

/// One frame's drum accents, already scaled by the reactivity, each 0-1.
private struct LaserDrumAccents {
    var kick: Double
    var snare: Double
    var hat: Double
    /// Picks which beams shimmer on the current hat.
    var hatHits: DrumHits
}

/// Beam brightness inputs. Kicks only fire a flash at least
/// `PerformanceState.strobeMinimumInterval` after the last one, holding the
/// beams to the 3 Hz strobe cap; the low band is smoothed with a slow release
/// so it swells under the flashes instead of flickering. A class so it can
/// advance inside a `TimelineView` update without invalidating SwiftUI state.
private final class LaserLight {
    private static let attackTime: TimeInterval = 0.04
    private static let releaseTime: TimeInterval = 0.4
    private static let flashDecay: TimeInterval = 0.15

    private var flashTime: TimeInterval = -.infinity
    private var flashStrength = 0.0
    private var lastBeatCount: Int?
    private var bass = 0.0
    private var lastTime: TimeInterval?

    func advance(to now: TimeInterval, beat: BeatAnalysis, isActive: Bool) -> (flash: Double, bass: Double) {
        // Clamped so resuming after a pause continues instead of jumping.
        let dt = lastTime.map { min(0.1, max(0, now - $0)) } ?? 0
        lastTime = now
        guard isActive else { return (0, bass) }

        if let lastBeatCount, beat.beatCount != lastBeatCount,
           beat.lastBeatTime - flashTime >= PerformanceState.strobeMinimumInterval {
            flashTime = beat.lastBeatTime
            flashStrength = Double(beat.beatStrength)
        }
        lastBeatCount = beat.beatCount

        let target = Double(min(1, max(0, beat.bassEnvelope(at: now))))
        let tau = target > bass ? Self.attackTime : Self.releaseTime
        bass += (target - bass) * (1 - exp(-dt / tau))

        let flash = exp(-max(0, now - flashTime) / Self.flashDecay) * (0.4 + 0.6 * flashStrength)
        return (flash, bass)
    }
}

/// The theme's gradient as RGB for interpolation, skipping near-black stops
/// that would vanish on the dark stage.
private struct LaserPalette {
    struct RGB {
        var r: Double
        var g: Double
        var b: Double

        var color: Color { Color(red: r, green: g, blue: b) }

        func towardWhite(_ amount: Double) -> RGB {
            RGB(r: r + (1 - r) * amount, g: g + (1 - g) * amount, b: b + (1 - b) * amount)
        }
    }

    let stops: [RGB]

    init(theme: ColorTheme) {
        let colors: [RGB] = theme.gradient.compactMap { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
            return RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
        }
        let vivid = colors.filter { 0.2126 * $0.r + 0.7152 * $0.g + 0.0722 * $0.b > 0.12 }
        stops = vivid.isEmpty ? [RGB(r: 1, g: 1, b: 1)] : vivid
    }

    /// The gradient at `u` in 0...1.
    func sample(_ u: Double) -> RGB {
        guard stops.count > 1 else { return stops[0] }
        let position = min(1, max(0, u)) * Double(stops.count - 1)
        let lower = min(stops.count - 2, Int(position))
        let f = position - Double(lower)
        let a = stops[lower]
        let b = stops[lower + 1]
        return RGB(r: a.r + (b.r - a.r) * f, g: a.g + (b.g - a.g) * f, b: a.b + (b.b - a.b) * f)
    }
}

#Preview {
    LaserVisualizerView(spectrum: Array(repeating: 0.5, count: 64), volume: 0.6, theme: .aurora, sensitivity: 1.0)
        .frame(width: 500, height: 500)
        .background(Color.black)
}
