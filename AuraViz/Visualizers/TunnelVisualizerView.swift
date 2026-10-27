import SwiftUI

/// Pseudo-3D tunnel: hexagonal rings fly toward the viewer at one ring per
/// beat (or a volume-driven cruise until a tempo is known), their outlines
/// wobbling with the spectrum. Every beat launches a bright ring down the
/// tunnel; kicks make it breathe, snares light the corner rails and hats spark
/// a scatter of ring corners.
struct TunnelVisualizerView: View {
    var spectrum: [CGFloat]
    var volume: CGFloat
    var theme: ColorTheme
    var sensitivity: Double
    var isActive: Bool = true
    var beat = BeatAnalysis()
    /// 0 keeps the volume-only look; 1 applies the full beat effects.
    var beatReactivity: Double = 0
    /// Kicks breathe the rings, snares light the rails, hats spark corners.
    var drumReactivity = DrumReactivity.off

    @State private var flight = TunnelFlight()

    /// Rings visible along the tunnel, one depth unit apart.
    private static let ringCount = 22
    /// Rings closer than this have flown past the viewer.
    private static let nearDepth = 0.55
    /// How far down the tunnel a beat ring appears.
    private static let beatRingDepth = 6.0
    private static let sides = 6
    private static let ringPoints = 96
    /// The tunnel makes one full twist every this many rings.
    private static let ringsPerTwist = 48.0
    private static let angles = (0..<ringPoints).map { Double($0) / Double(ringPoints) * 2 * .pi }

    var body: some View {
        let palette = TunnelPalette(theme: theme)
        let profile = radialProfile()
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let now = BeatClock.time(for: timeline.date)
            let depth = flight.advance(
                to: t,
                now: now,
                beat: beat,
                volume: Double(volume),
                spawnDepth: Self.beatRingDepth,
                nearDepth: Self.nearDepth
            )
            let flash = isActive ? beatReactivity * beat.flash(at: now) : 0
            let drums = drumReactivity.scaled(by: beatReactivity)
            let accents = TunnelDrumAccents(
                kick: isActive ? drums.kick * beat.kick.pulse(at: now) : 0,
                snare: isActive ? drums.snare * beat.snare.pulse(at: now) : 0,
                hat: isActive ? drums.hat * beat.hat.pulse(at: now) : 0,
                hatHits: beat.hat
            )
            Canvas { context, size in
                draw(in: context, size: size, time: t, depth: depth, flash: flash, drums: accents, profile: profile, palette: palette)
            }
        }
        .background(Color.clear)
    }

    private func draw(in context: GraphicsContext, size: CGSize, time t: Double, depth: Double, flash: Double, drums: TunnelDrumAccents, profile: [Double], palette: TunnelPalette) {
        let w = size.width
        let h = size.height
        let s = size.visualizerScale
        let center = CGPoint(x: w/2, y: h/2)
        // A ring one unit ahead just about covers the view.
        let reach = hypot(w, h) / 2
        let focal = reach * 0.9
        let n = Double(Self.ringCount)
        let energy = Double(min(1, max(0, volume)))
        let spin = t * 0.1
        let twistStep = 2 * Double.pi / Self.ringsPerTwist
        let breath = 1 + 0.05 * flash + 0.06 * drums.kick
        // The far end wanders slowly, so the tunnel seems to curve.
        let drift = CGSize(width: sin(t * 0.31) * w * 0.06, height: cos(t * 0.23) * h * 0.05)
        var glow = context
        glow.blendMode = .plusLighter

        func ringCenter(_ z: Double) -> CGPoint {
            let k = min(1, z / n * 1.6)
            return CGPoint(x: center.x + drift.width * k, y: center.y + drift.height * k)
        }
        func point(_ j: Int, center c: CGPoint, radius r: Double, rotation: Double) -> CGPoint {
            let a = Self.angles[j] + rotation
            let pr = r * profile[j]
            return CGPoint(x: c.x + cos(a) * pr, y: c.y + sin(a) * pr)
        }
        func ring(center c: CGPoint, radius r: Double, rotation: Double) -> Path {
            var path = Path()
            path.move(to: point(0, center: c, radius: r, rotation: rotation))
            for j in 1..<Self.ringPoints {
                path.addLine(to: point(j, center: c, radius: r, rotation: rotation))
            }
            path.closeSubpath()
            return path
        }
        func corners(center c: CGPoint, radius r: Double, rotation: Double) -> [CGPoint] {
            stride(from: 0, to: Self.ringPoints, by: Self.ringPoints / Self.sides).map {
                point($0, center: c, radius: r, rotation: rotation)
            }
        }
        /// Fades rings in out of the fog and out as they grow past the edges.
        func visibility(z: Double, radius r: Double, fogPower: Double) -> Double {
            let fog = pow(max(0, 1 - z / n), fogPower)
            let nearFade = min(1, max(0, (1.3 * reach - r) / (0.4 * reach)))
            return fog * nearFade
        }

        // light at the end of the tunnel
        let farCenter = ringCenter(n)
        let lightR = reach * 0.22
        glow.fill(
            Path(ellipseIn: CGRect(x: farCenter.x - lightR, y: farCenter.y - lightR, width: lightR*2, height: lightR*2)),
            with: .radialGradient(Gradient(colors: [palette.hot.opacity(0.30 + 0.25 * energy + 0.35 * flash), Color.clear]), center: farCenter, startRadius: 0, endRadius: lightR)
        )

        // structural rings, far to near, tied together by corner rails
        let first = Int((depth + Self.nearDepth).rounded(.up))
        let last = Int((depth + n).rounded(.down))
        var previousCorners: [CGPoint]?
        var sparks = Path()
        if first <= last {
            for i in stride(from: last, through: first, by: -1) {
                let z = Double(i) - depth
                let r = focal / z * breath
                let c = ringCenter(z)
                let rotation = spin + Double(i).truncatingRemainder(dividingBy: Self.ringsPerTwist) * twistStep
                let ringCorners = corners(center: c, radius: r, rotation: rotation)
                defer { previousCorners = ringCorners }
                let alpha = min(1, visibility(z: z, radius: r, fogPower: 1.3) * (0.55 + 0.35 * energy + 0.5 * flash))
                guard alpha > 0.01, r > 2 * s else { continue }

                let color = palette.rings[((i % palette.rings.count) + palette.rings.count) % palette.rings.count]
                let lineWidth = min(7 * s, s * (0.7 + 2.6 / z))
                let path = ring(center: c, radius: r, rotation: rotation)
                glow.stroke(path, with: .color(color.opacity(alpha * 0.25)), lineWidth: lineWidth * 3.5)
                glow.stroke(path, with: .color(color.opacity(alpha)), lineWidth: lineWidth)

                if let previousCorners {
                    var rails = Path()
                    for (from, to) in zip(previousCorners, ringCorners) {
                        rails.move(to: from)
                        rails.addLine(to: to)
                    }
                    context.stroke(rails, with: .color(.white.opacity((0.14 + 0.6 * drums.snare) * alpha)), lineWidth: (0.8 + 1.2 * drums.snare) * s)
                }

                // Each hat sparks a fresh scatter of about one corner in five.
                if drums.hat > 0.01 {
                    let sparkR = min(5 * s, s * (0.8 + 2.4 / z)) * (1 + drums.hat)
                    for (k, corner) in ringCorners.enumerated() where drums.hatHits.scatter(i * Self.sides + k) < 0.2 * alpha {
                        sparks.addEllipse(in: CGRect(x: corner.x - sparkR, y: corner.y - sparkR, width: sparkR * 2, height: sparkR * 2))
                    }
                }
            }
        }
        if drums.hat > 0.01 {
            glow.fill(sparks, with: .color(.white.opacity(min(1, drums.hat))))
        }

        // beat rings — white-hot cores in a bloom of the theme's brightest color
        guard beatReactivity > 0 else { return }
        for beatRing in flight.beatRings {
            let z = beatRing.depth - depth
            guard z > Self.nearDepth, z < n else { continue }
            let r = focal / z * breath * 0.97
            let alpha = min(1, visibility(z: z, radius: r, fogPower: 0.5) * beatReactivity * (0.5 + 0.5 * beatRing.strength))
            guard alpha > 0.01 else { continue }
            let rotation = spin + beatRing.depth.truncatingRemainder(dividingBy: Self.ringsPerTwist) * twistStep
            let path = ring(center: ringCenter(z), radius: r, rotation: rotation)
            let lineWidth = min(9 * s, s * (1.2 + 3.5 / z))
            glow.stroke(path, with: .color(palette.rim.opacity(alpha * 0.18)), lineWidth: lineWidth * 6)
            glow.stroke(path, with: .color(palette.rim.opacity(alpha * 0.45)), lineWidth: lineWidth * 2.5)
            glow.stroke(path, with: .color(.white.opacity(alpha)), lineWidth: lineWidth)
        }
    }

    /// Per-point radius multiplier shared by every ring: a hexagon whose
    /// outline bulges with the spectrum, folded twice around the ring so
    /// each frequency shows on opposite sides.
    private func radialProfile() -> [Double] {
        let sector = 2 * Double.pi / Double(Self.sides)
        return Self.angles.enumerated().map { j, angle in
            let local = angle.truncatingRemainder(dividingBy: sector) - sector / 2
            let polygon = cos(sector / 2) / cos(local)
            return polygon * (1 + 0.3 * spectrumLevel(at: j))
        }
    }

    private func spectrumLevel(at index: Int) -> Double {
        guard !spectrum.isEmpty else { return 0 }
        let phase = Double(index) / Double(Self.ringPoints) * 4
        let cycle = phase.truncatingRemainder(dividingBy: 2)
        let folded = cycle <= 1 ? cycle : 2 - cycle
        let position = folded * Double(spectrum.count - 1)
        let lower = Int(floor(position))
        let upper = min(spectrum.count - 1, lower + 1)
        let fraction = position - Double(lower)
        let value = Double(spectrum[lower]) * (1 - fraction) + Double(spectrum[upper]) * fraction
        return min(1, pow(max(0, value), 0.8) * sensitivity)
    }
}

/// One frame's drum accents, already scaled by the reactivity, each 0-1.
private struct TunnelDrumAccents {
    var kick: Double
    var snare: Double
    var hat: Double
    /// Picks which corners spark on the current hat.
    var hatHits: DrumHits
}

/// Camera position along the tunnel plus the beat rings in flight. A class
/// so it can advance inside a `TimelineView` update without invalidating
/// SwiftUI state.
private final class TunnelFlight {
    struct BeatRing {
        /// Absolute depth along the tunnel, in ring spacings.
        var depth: Double
        var strength: Double
    }

    private static let maxBeatRings = 16

    private let travel = BeatSyncedPhase()
    private var lastBeatCount: Int?
    private(set) var beatRings: [BeatRing] = []

    /// Returns the camera depth at `time`, spawning a beat ring ahead of
    /// the camera for each new beat and dropping the ones it has passed.
    func advance(to time: TimeInterval, now: TimeInterval, beat: BeatAnalysis, volume: Double, spawnDepth: Double, nearDepth: Double) -> Double {
        // One ring per beat once a tempo is known; until then, cruise
        // between 0.5 and 4 rings per second with the volume. Integrated,
        // so gaining or losing the tempo changes speed without a jump.
        let position = travel.advance(
            to: time,
            wallRate: 0.5 + 3.5 * min(1, max(0, volume)),
            gridPhase: beat.clock.beatPhase(at: now),
            gridRate: 1,
            nominalGridSpeed: beat.clock.beatsPerSecond,
            reactivity: beat.bpm > 0 ? 1 : 0
        )
        if let lastBeatCount, beat.beatCount != lastBeatCount {
            beatRings.append(BeatRing(depth: position + spawnDepth, strength: Double(beat.beatStrength)))
            if beatRings.count > Self.maxBeatRings {
                beatRings.removeFirst(beatRings.count - Self.maxBeatRings)
            }
        }
        lastBeatCount = beat.beatCount
        beatRings.removeAll { $0.depth - position < nearDepth }
        return position
    }
}

/// Ring colors picked from a theme: dark gradient stops (black, deep navy)
/// would vanish against the black stage, so they're skipped.
private struct TunnelPalette {
    let rings: [Color]
    /// The brightest theme color, for beat-ring bloom.
    let rim: Color
    /// `rim` pushed toward white, for the light at the end of the tunnel.
    let hot: Color

    init(theme: ColorTheme) {
        typealias RGB = (r: Double, g: Double, b: Double)
        let colors: [RGB] = theme.gradient.compactMap { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        func luminance(_ c: RGB) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
        func color(_ c: RGB) -> Color { Color(red: c.r, green: c.g, blue: c.b) }
        let bright = colors.filter { luminance($0) > 0.2 }
        let vivid: [RGB] = bright.isEmpty ? [(1, 1, 1)] : bright
        let top = vivid.max { luminance($0) < luminance($1) }!

        rings = vivid.map(color)
        rim = color(top)
        hot = Color(red: 0.4 * top.r + 0.6, green: 0.4 * top.g + 0.6, blue: 0.4 * top.b + 0.6)
    }
}

#Preview {
    TunnelVisualizerView(spectrum: Array(repeating: 0.5, count: 64), volume: 0.6, theme: .aurora, sensitivity: 1.0)
        .frame(width: 500, height: 500)
        .background(Color.black)
}
