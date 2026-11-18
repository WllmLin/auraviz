import SwiftUI

/// Neon wireframe tunnel, after the reference clip: hexagon and rectangle
/// frames built from broken neon bars tumble toward the viewer out of a
/// glowing hexagonal core, each frame tilted on its own axes so the tunnel
/// reads as a cage of skewed outlines rather than flat rings. Frames fly two
/// per beat once a tempo is known (a volume-driven cruise until then), the
/// whole cage rolls one turn per 32 beats, and every bar is drawn
/// additively with a soft halo, a colored body and a white-hot core.
///
/// The music runs the clip's two lighting layers. Rhythm drives the cool
/// layer: on every beat the tunnel floods with the theme's primary color and
/// then drops to near-black, the clip's lit/dark strobe, with flashes held to
/// the 3-per-second strobe cap. Notes drive the warm layer: about a third of
/// the bars take the theme's contrasting colors and light only when the
/// pitch region they cross is sounding — bass along the floor of the screen,
/// treble across the top, mirrored left and right — so between beats the
/// melody paints the dark tunnel, and the loudest band burns white-hot.
/// Kicks punch the frames toward the viewer and swell the core, snares jolt
/// the roll and throw the outlines white, and hats glint a scatter of bar
/// ends.
struct NeonVisualizerView: View {
    var spectrum: [CGFloat]
    var volume: CGFloat
    var theme: ColorTheme
    var sensitivity: Double
    var isActive: Bool = true
    var beat = BeatAnalysis()
    /// 0 keeps the volume-only look; 1 applies the full beat effects.
    var beatReactivity: Double = 0
    /// Kicks punch the frames, snares jolt the roll, hats glint bar ends.
    var drumReactivity = DrumReactivity.off

    @State private var system = NeonSystem()

    /// Frames in flight along the tunnel, one spacing apart.
    static let frameCount = 40
    /// Camera-space depth of the nearest frame, and the gap between frames.
    private static let nearDepth = 0.28
    private static let spacing = 0.24
    /// Bar ends nearer than this are clipped so the projection stays finite.
    private static let clipDepth = 0.12
    /// Opacity steps the bars are batched into, about 1.75x apart, so the
    /// dark phase can sit as far below the lit phase as it does in the clip.
    private static let levelOpacities: [Double] = [0.06, 0.105, 0.18, 0.32, 0.56, 0.98]
    private static let levelRatio = log(1.75)
    /// Cool bars get shades of the primary color toward white; warm bars one
    /// of the contrasting colors.
    private static let coolShades = 4
    private static let warmColors = 6
    private static let hexagon: [(x: Double, y: Double)] = (0..<6).map { i in
        (x: cos(Double(i) * .pi / 3), y: sin(Double(i) * .pi / 3))
    }
    private static let square: [(x: Double, y: Double)] = (0..<4).map { i in
        (x: cos(.pi / 4 + Double(i) * .pi / 2), y: sin(.pi / 4 + Double(i) * .pi / 2))
    }

    var body: some View {
        let palette = ThemePalette(theme: theme)
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let now = BeatClock.time(for: timeline.date)
            let frame = system.advance(
                to: t,
                now: now,
                beat: beat,
                spectrum: spectrum,
                volume: Double(volume),
                sensitivity: sensitivity,
                beatReactivity: beatReactivity,
                isActive: isActive
            )
            let drums = drumReactivity.scaled(by: beatReactivity)
            let accents = NeonDrumAccents(
                kick: isActive ? drums.kick * beat.kick.pulse(at: now) : 0,
                snare: isActive ? drums.snare * beat.snare.pulse(at: now) : 0,
                hat: isActive ? drums.hat * beat.hat.pulse(at: now) : 0,
                hatHits: beat.hat
            )
            Canvas { context, size in
                draw(in: context, size: size, frame: frame, accents: accents, palette: palette)
            }
        }
        .background(Color.clear)
    }

    // MARK: - Drawing

    private func draw(in context: GraphicsContext, size: CGSize, frame: NeonFrame, accents: NeonDrumAccents, palette: ThemePalette) {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0 else { return }
        let s = size.visualizerScale
        let center = CGPoint(x: w / 2, y: h / 2)
        let reach = hypot(w, h) / 2
        // A frame of radius 1 at depth 1 spans the short side; kicks widen
        // the field of view so every frame jumps toward the viewer.
        let punch = 1 + 0.08 * accents.kick + 0.03 * frame.flash
        let focal = 0.5 * min(w, h) * CGFloat(punch)
        let colors = NeonColors(palette: palette, hue: frame.hue)
        var glow = context
        glow.blendMode = .plusLighter

        drawWash(in: glow, center: center, reach: reach, frame: frame, colors: colors)
        drawFrames(in: glow, center: center, focal: focal, scale: s, frame: frame, accents: accents, colors: colors)
        drawCore(in: glow, center: center, short: min(w, h), scale: s, frame: frame, accents: accents, colors: colors)
    }

    /// The clip's flood: on the lit beat the whole stage washes over in the
    /// primary color, then drains back to black with the cool layer.
    private func drawWash(in glow: GraphicsContext, center: CGPoint, reach: CGFloat, frame: NeonFrame, colors: NeonColors) {
        let color = colors.cool[1].color
        let inner = min(1, 0.08 * frame.lit + 0.24 * frame.flash + 0.04 * frame.energy)
        let outer = min(1, 0.05 * frame.lit + 0.14 * frame.flash)
        let radius = reach * 1.05
        glow.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: color.opacity(inner), location: 0),
                    .init(color: color.opacity(outer), location: 0.55),
                    .init(color: .clear, location: 1),
                ]),
                center: center, startRadius: 0, endRadius: radius
            )
        )
    }

    /// Every frame in flight, far to near. Each edge is split into one to
    /// three neon dashes in 3D, so the breaks foreshorten with the frame,
    /// and each dash becomes a tapered quad, wider at the nearer end. Quads
    /// are batched by color and opacity step so the whole cage is a few
    /// dozen fills instead of one per bar.
    private func drawFrames(in glow: GraphicsContext, center: CGPoint, focal: CGFloat, scale s: CGFloat, frame: NeonFrame, accents: NeonDrumAccents, colors: NeonColors) {
        let levels = Self.levelOpacities.count
        var buckets = [NeonBucket](repeating: NeonBucket(), count: (Self.coolShades + Self.warmColors) * levels)
        var glints = Path()
        let minHalfWidth = 0.45 * s
        let maxHalfWidth = 4.5 * s
        let glintRadius = CGFloat(1.4 + 2.4 * accents.hat) * s
        let showGlints = accents.hat > 0.02
        // Snares jolt the roll and push the cool bars toward white.
        let roll = frame.roll + 0.32 * accents.snare
        let snareWhite = 0.7 * accents.snare
        let count = Self.frameCount
        let first = Int(frame.travel.rounded(.down)) + 1

        for k in first..<(first + count) {
            // Steps from the near plane: 0 has just flown past the viewer,
            // `count` is just being born in the core.
            let steps = Double(k) - frame.travel
            let z = Self.nearDepth + steps * Self.spacing
            let fadeIn = min(1, (Double(count) - steps) / 3)
            let fadeOut = Self.smoothstep(Self.nearDepth, Self.nearDepth + 0.25, z)
            let fog = min(1, 0.3 + 0.7 * exp(-(z - 0.5) / 3.5))
            let fade = fadeIn * fadeOut * fog
            guard fade > 0.01 else { continue }

            let pose = NeonPose(frame: k, depth: z, roll: roll, tumble: frame.tumble)
            let unit = pose.sides == 6 ? Self.hexagon : Self.square
            // Distant frames whiten toward the core, as in the clip.
            let depthWhite = 0.25 * min(1, z / 7)

            for ring in 0..<pose.rings {
                let inset = ring == 0 ? 1.0 : 0.8
                for i in 0..<pose.sides {
                    let edgeSalt = 64 + (ring * 8 + i) * 8
                    let broken = Self.hash(k, edgeSalt)
                    guard broken >= 0.08 else { continue }
                    let a = pose.point(unit[i], inset: inset)
                    let b = pose.point(unit[(i + 1) % pose.sides], inset: inset)
                    let pattern = Self.hash(k, edgeSalt + 1)
                    let dashCount = pattern < 0.3 ? 1 : (pattern < 0.7 ? 2 : 3)
                    let gap = 0.035 + 0.06 * Self.hash(k, edgeSalt + 2)
                    let warm = Self.hash(k, edgeSalt + 3) < 0.32
                    let warmIndex = min(Self.warmColors - 1, Int(Self.hash(k, edgeSalt + 4) * Double(Self.warmColors)))
                    let jitter1 = (Self.hash(k, edgeSalt + 5) - 0.5) * 0.16
                    let jitter2 = (Self.hash(k, edgeSalt + 6) - 0.5) * 0.16

                    for dash in 0..<dashCount {
                        let t0 = Self.dashBoundary(dash, of: dashCount, jitter1: jitter1, jitter2: jitter2) + (dash == 0 ? 0.02 : gap)
                        let t1 = Self.dashBoundary(dash + 1, of: dashCount, jitter1: jitter1, jitter2: jitter2) - (dash == dashCount - 1 ? 0.02 : gap)
                        guard t1 > t0 else { continue }
                        var p0 = a.lerp(to: b, t0)
                        var p1 = a.lerp(to: b, t1)
                        if p0.z < Self.clipDepth && p1.z < Self.clipDepth { continue }
                        if p0.z < Self.clipDepth { p0 = p0.lerp(to: p1, (Self.clipDepth - p0.z) / (p1.z - p0.z)) }
                        if p1.z < Self.clipDepth { p1 = p1.lerp(to: p0, (Self.clipDepth - p1.z) / (p0.z - p1.z)) }
                        let q0 = CGPoint(x: center.x + CGFloat(p0.x / p0.z) * focal, y: center.y + CGFloat(p0.y / p0.z) * focal)
                        let q1 = CGPoint(x: center.x + CGFloat(p1.x / p1.z) * focal, y: center.y + CGFloat(p1.y / p1.z) * focal)
                        let w0 = min(maxHalfWidth, max(minHalfWidth, CGFloat(0.5 * pose.barWidth / p0.z) * focal))
                        let w1 = min(maxHalfWidth, max(minHalfWidth, CGFloat(0.5 * pose.barWidth / p1.z) * focal))

                        // The pitch region this bar crosses: 0 straight
                        // down (bass) to 1 straight up (treble).
                        let mx = Double((q0.x + q1.x) / 2 - center.x)
                        let my = Double((q0.y + q1.y) / 2 - center.y)
                        let note = frame.note(at: atan2(abs(mx), my) / .pi)
                        let peakBoost = note.isPeak ? 1.0 : 0.0

                        let colorIndex: Int
                        let alpha: Double
                        if warm {
                            alpha = fade * (0.10 + 0.9 * note.energy) * (0.7 + 0.4 * frame.lit) * (1 + 0.25 * peakBoost)
                            colorIndex = Self.coolShades + warmIndex
                        } else {
                            alpha = fade * frame.lit * (0.6 + 0.4 * note.energy + 0.3 * peakBoost)
                            let whiteness = depthWhite + 0.45 * note.energy + 0.35 * peakBoost + snareWhite
                            colorIndex = min(Self.coolShades - 1, Int(whiteness * Double(Self.coolShades)))
                        }
                        guard alpha > 0.035 else { continue }
                        let level = min(levels - 1, max(0, Int((log(alpha / Self.levelOpacities[0]) / Self.levelRatio).rounded())))
                        buckets[colorIndex * levels + level].add(q0, q1, w0, w1)

                        // Each hat glints a fresh scatter of bar ends.
                        if showGlints && alpha > 0.12 && accents.hatHits.scatter(k &* 64 &+ ring * 8 &+ i) < 0.06 {
                            glints.addEllipse(in: CGRect(x: q1.x - glintRadius, y: q1.y - glintRadius, width: glintRadius * 2, height: glintRadius * 2))
                        }
                    }
                }
            }
        }

        for index in buckets.indices where !buckets[index].isEmpty {
            let bucket = buckets[index]
            let level = index % levels
            let colorIndex = index / levels
            let opacity = Self.levelOpacities[level]
            let tint: ThemePalette.RGB
            let core: ThemePalette.RGB
            if colorIndex < Self.coolShades {
                tint = colors.cool[colorIndex]
                core = tint.towardWhite(0.65)
            } else {
                tint = colors.warm[colorIndex - Self.coolShades]
                core = tint.towardWhite(0.5)
            }
            // The faintest steps skip their halos; they wouldn't show.
            if level >= 2 {
                glow.fill(bucket.haloWide, with: .color(tint.color.opacity(0.06 * opacity)))
                glow.fill(bucket.haloNear, with: .color(tint.color.opacity(0.18 * opacity)))
            }
            glow.fill(bucket.body, with: .color(tint.color.opacity(0.75 * opacity)))
            glow.fill(bucket.core, with: .color(core.color.opacity(min(1, 0.95 * opacity))))
        }

        if !glints.isEmpty {
            glow.fill(glints, with: .color(.white.opacity(min(1, 0.3 + accents.hat))))
        }
    }

    /// The hot hexagonal core at the vanishing point: a glow that swells on
    /// kicks and lit beats, with small hexagons streaming out of it one per
    /// beat, matching the frames' flight.
    private func drawCore(in glow: GraphicsContext, center: CGPoint, short: CGFloat, scale s: CGFloat, frame: NeonFrame, accents: NeonDrumAccents, colors: NeonColors) {
        let swell = 1 + 0.45 * accents.kick + 0.2 * frame.flash + 0.1 * frame.energy
        let radius = short * 0.075 * CGFloat(swell)
        let lit = min(1, frame.lit)
        let haloColor = colors.cool[2].color
        let halo = radius * 4
        glow.fill(
            Path(ellipseIn: CGRect(x: center.x - halo, y: center.y - halo, width: halo * 2, height: halo * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: haloColor.opacity(0.22 + 0.30 * lit), location: 0),
                    .init(color: haloColor.opacity(0.06 + 0.10 * lit), location: 0.35),
                    .init(color: .clear, location: 1),
                ]),
                center: center, startRadius: 0, endRadius: halo
            )
        )

        let roll = frame.roll + 0.32 * accents.snare
        let lineColor = colors.cool[2].color
        for j in 0..<3 {
            let phase = (frame.travel * 0.5 + Double(j) / 3).truncatingRemainder(dividingBy: 1)
            let fade = sin(.pi * phase)
            let r = radius * CGFloat(0.25 + 0.95 * phase)
            var hex = Path()
            for i in 0..<6 {
                let angle = roll + Double(i) * .pi / 3
                let p = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
                if i == 0 { hex.move(to: p) } else { hex.addLine(to: p) }
            }
            hex.closeSubpath()
            glow.stroke(hex, with: .color(lineColor.opacity(0.18 * fade * (0.5 + 0.5 * lit))), lineWidth: 6 * s)
            glow.stroke(hex, with: .color(lineColor.opacity(fade * (0.55 + 0.45 * lit))), lineWidth: 1.6 * s)
            glow.stroke(hex, with: .color(.white.opacity(0.8 * fade * (0.4 + 0.6 * lit))), lineWidth: 0.7 * s)
        }

        let hot = radius * 0.6
        glow.fill(
            Path(ellipseIn: CGRect(x: center.x - hot, y: center.y - hot, width: hot * 2, height: hot * 2)),
            with: .radialGradient(Gradient(colors: [.white.opacity(0.25 + 0.35 * lit), .clear]), center: center, startRadius: 0, endRadius: hot)
        )
    }

    // MARK: - Helpers

    /// Where dash boundary `j` of `count` falls along an edge, jittered so
    /// the breaks don't line up from frame to frame.
    private static func dashBoundary(_ j: Int, of count: Int, jitter1: Double, jitter2: Double) -> Double {
        if j == 0 { return 0 }
        if j == count { return 1 }
        return Double(j) / Double(count) + (j == 1 ? jitter1 : jitter2)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// A stable pseudo-random 0..<1 for feature `salt` of frame `frame`, so a
    /// frame keeps its shape for its whole flight and the next one through
    /// the same slot gets a new one.
    static func hash(_ frame: Int, _ salt: Int) -> Double {
        var x = (UInt64(bitPattern: Int64(frame)) &* 0x9E37_79B9_7F4A_7C15) ^ (UInt64(bitPattern: Int64(salt)) &* 0xBF58_476D_1CE4_E5B9)
        x ^= x >> 31
        x = x &* 0x94D0_49BB_1331_11EB
        x ^= x >> 29
        return Double(x >> 11) / Double(1 << 53)
    }
}

/// A point in camera space: x right, y down, z into the screen.
private struct NeonPoint {
    var x: Double
    var y: Double
    var z: Double

    func lerp(to other: NeonPoint, _ t: Double) -> NeonPoint {
        NeonPoint(x: x + (other.x - x) * t, y: y + (other.y - y) * t, z: z + (other.z - z) * t)
    }
}

/// One frame's shape and orientation, fixed by its id except for the roll
/// and tumble, which turn with the music.
private struct NeonPose {
    let sides: Int
    /// 2 for a double frame with an inset inner outline.
    let rings: Int
    /// Bar thickness in world units.
    let barWidth: Double
    private let radius: Double
    private let aspect: Double
    private let offsetX: Double
    private let offsetY: Double
    private let depth: Double
    private let cosSpin: Double
    private let sinSpin: Double
    private let cosTiltX: Double
    private let sinTiltX: Double
    private let cosTiltY: Double
    private let sinTiltY: Double

    init(frame k: Int, depth: Double, roll: Double, tumble: Double) {
        func feature(_ n: Int) -> Double { NeonVisualizerView.hash(k, n) }
        let sideCount = feature(0) < 0.55 ? 6 : 4
        sides = sideCount
        rings = feature(14) < 0.45 ? 2 : 1
        barWidth = 0.016 + 0.022 * feature(15)
        radius = 1.0 + 1.4 * feature(1)
        aspect = sideCount == 6 ? 1 : 0.9 + 0.8 * feature(2)
        offsetX = (feature(3) - 0.5) * 0.5
        offsetY = (feature(4) - 0.5) * 0.5
        self.depth = depth
        // Each frame spins its own way on top of the shared roll, and the
        // tunnel twists a little with depth.
        let spinSign = feature(5) < 0.5 ? -1.0 : 1.0
        let spin = feature(6) * 2 * .pi + roll + 0.06 * depth + spinSign * tumble * (0.15 + 0.25 * feature(7))
        let tiltX = (0.35 + 0.55 * feature(8)) * sin(tumble * (0.6 + 0.6 * feature(9)) + feature(10) * 2 * .pi)
        let tiltY = (0.35 + 0.55 * feature(11)) * sin(tumble * (0.5 + 0.6 * feature(12)) + feature(13) * 2 * .pi)
        cosSpin = cos(spin)
        sinSpin = sin(spin)
        cosTiltX = cos(tiltX)
        sinTiltX = sin(tiltX)
        cosTiltY = cos(tiltY)
        sinTiltY = sin(tiltY)
    }

    /// A vertex of the unit outline, spun in the frame's plane, tilted about
    /// x then y, and placed at the frame's depth.
    func point(_ unit: (x: Double, y: Double), inset: Double) -> NeonPoint {
        let u = unit.x * radius * aspect * inset
        let v = unit.y * radius * inset
        let x1 = u * cosSpin - v * sinSpin
        let y1 = u * sinSpin + v * cosSpin
        let y2 = y1 * cosTiltX
        let z2 = y1 * sinTiltX
        let x3 = x1 * cosTiltY + z2 * sinTiltY
        let z3 = z2 * cosTiltY - x1 * sinTiltY
        return NeonPoint(x: x3 + offsetX, y: y2 + offsetY, z: depth + z3)
    }
}

/// Quads for one color and opacity step, in four passes from soft halo to
/// white-hot core. Every quad winds the same way, so overlaps fill once.
private struct NeonBucket {
    var haloWide = Path()
    var haloNear = Path()
    var body = Path()
    var core = Path()
    var isEmpty = true

    mutating func add(_ a: CGPoint, _ b: CGPoint, _ widthA: CGFloat, _ widthB: CGFloat) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.01 else { return }
        let nx = -dy / length
        let ny = dx / length
        Self.addQuad(to: &haloWide, a, b, nx, ny, widthA * 2.6, widthB * 2.6)
        Self.addQuad(to: &haloNear, a, b, nx, ny, widthA * 1.6, widthB * 1.6)
        Self.addQuad(to: &body, a, b, nx, ny, widthA, widthB)
        Self.addQuad(to: &core, a, b, nx, ny, widthA * 0.4, widthB * 0.4)
        isEmpty = false
    }

    private static func addQuad(to path: inout Path, _ a: CGPoint, _ b: CGPoint, _ nx: CGFloat, _ ny: CGFloat, _ wa: CGFloat, _ wb: CGFloat) {
        path.move(to: CGPoint(x: a.x + nx * wa, y: a.y + ny * wa))
        path.addLine(to: CGPoint(x: b.x + nx * wb, y: b.y + ny * wb))
        path.addLine(to: CGPoint(x: b.x - nx * wb, y: b.y - ny * wb))
        path.addLine(to: CGPoint(x: a.x - nx * wa, y: a.y - ny * wa))
        path.closeSubpath()
    }
}

/// The frame's colors: shades of the primary color for the cool layer and
/// contrasting stops of the theme gradient for the warm accents.
private struct NeonColors {
    let cool: [ThemePalette.RGB]
    let warm: [ThemePalette.RGB]

    init(palette: ThemePalette, hue: Double) {
        let base = palette.sample(hue)
        cool = [0, 0.28, 0.52, 0.8].map { base.towardWhite($0) }
        // Spread across the far side of the gradient from the primary.
        warm = (0..<6).map { j in
            let u = hue + 0.3 + 0.4 * Double(j) / 5
            return palette.sample(1 - abs(2 * u.truncatingRemainder(dividingBy: 1) - 1))
        }
    }
}

/// One frame's drum accents, already scaled by the reactivity, each 0-1.
private struct NeonDrumAccents {
    var kick: Double
    var snare: Double
    var hat: Double
    /// Picks which bar ends glint on the current hat.
    var hatHits: DrumHits
}

/// Immutable draw inputs for one frame, advanced by `NeonSystem`.
private struct NeonFrame {
    /// Frames flown past the viewer so far; the fraction is the progress
    /// toward the next.
    var travel = 0.0
    var roll = 0.0
    /// Clock for each frame's own tumble, faster with energy and beats.
    var tumble = 0.0
    /// Cool layer level: the beat's lit/dark strobe, or a volume glow at 0
    /// beat reactivity.
    var lit = 0.3
    /// Rate-limited beat flash, already scaled by beat reactivity.
    var flash = 0.0
    var energy = 0.0
    /// Smoothed note energy from bass to treble.
    var notes = [Double](repeating: 0, count: NeonSystem.noteBins)
    /// Note bin with the loudest spectrum slice right now, or -1 in quiet.
    var peakNote = -1
    /// Position of the primary color along the theme gradient, 0-0.35.
    var hue = 0.0

    /// Note energy at `position`, 0 for bass to 1 for treble, and whether
    /// it is the loudest bin.
    func note(at position: Double) -> (energy: Double, isPeak: Bool) {
        let x = min(1, max(0, position)) * Double(notes.count - 1)
        let lower = min(notes.count - 2, Int(x))
        let f = x - Double(lower)
        let energy = notes[lower] * (1 - f) + notes[lower + 1] * f
        return (energy, Int(x.rounded()) == peakNote)
    }
}

/// The tunnel's motion and lighting state: beat-synced flight and roll, a
/// tumble clock, the lit/dark strobe held to the strobe cap, and smoothed
/// note energies. A class so it can advance inside a `TimelineView` update
/// without invalidating SwiftUI state.
private final class NeonSystem {
    static let noteBins = 12
    /// Frames flown per beat once synced to the tempo.
    private static let framesPerBeat = 2.0
    /// One full roll every 32 beats once synced to the tempo.
    private static let rollPerBeat = 2 * Double.pi / 32
    /// The lit phase holds briefly at full, then drains, as in the clip.
    private static let litHold: TimeInterval = 0.07
    private static let litDecay: TimeInterval = 0.16
    private static let bassAttack: TimeInterval = 0.04
    private static let bassRelease: TimeInterval = 0.4

    private let travelPhase = BeatSyncedPhase()
    private let rollPhase = BeatSyncedPhase()
    private var extraTravel = 0.0
    private var tumble = 0.0
    private var notes = [Double](repeating: 0, count: noteBins)
    private var bass = 0.0
    private var calmLit = 0.3
    private var flashTime: TimeInterval = -.infinity
    private var flashStrength = 0.0
    private var lastBeatCount: Int?
    private var lastTime: TimeInterval?
    private var huePhase = 0.0
    private var snapshot = NeonFrame()

    func advance(to time: TimeInterval, now: TimeInterval, beat: BeatAnalysis, spectrum: [CGFloat], volume: Double, sensitivity: Double, beatReactivity: Double, isActive: Bool) -> NeonFrame {
        // Clamped so resuming after a pause continues instead of jumping.
        let dt = lastTime.map { min(0.1, max(0, time - $0)) } ?? 1.0 / 60
        lastTime = time
        guard isActive, dt > 0 else { return snapshot }

        let energy = min(1, max(0, volume))
        let synced = beat.bpm > 0 ? beatReactivity : 0
        let surge = beatReactivity * exp(-beat.beatAge(at: now) / 0.3) * (0.4 + 0.6 * Double(beat.beatStrength))
        let gridTravel = travelPhase.advance(
            to: time,
            wallRate: 1.5 + 3.5 * energy,
            gridPhase: beat.clock.beatPhase(at: now),
            gridRate: Self.framesPerBeat,
            nominalGridSpeed: beat.clock.beatsPerSecond,
            reactivity: synced
        )
        // Each beat gives the flight a little extra push.
        extraTravel += 2.5 * surge * dt
        let roll = rollPhase.advance(
            to: time,
            wallRate: 0.12 + 0.18 * energy,
            gridPhase: beat.clock.beatPhase(at: now),
            gridRate: Self.rollPerBeat,
            nominalGridSpeed: beat.clock.beatsPerSecond,
            reactivity: synced
        )
        tumble += dt * (0.35 + 0.6 * energy + 1.2 * surge)

        // Lit/dark strobe, accepting a new beat only past the strobe cap.
        if let lastBeatCount, beat.beatCount != lastBeatCount,
           beat.lastBeatTime - flashTime >= PerformanceState.strobeMinimumInterval {
            flashTime = beat.lastBeatTime
            flashStrength = Double(beat.beatStrength)
        }
        lastBeatCount = beat.beatCount
        let age = max(0, now - flashTime)
        let envelope = (age < Self.litHold ? 1 : exp(-(age - Self.litHold) / Self.litDecay)) * (0.45 + 0.55 * flashStrength)

        let bassTarget = Double(min(1, max(0, beat.bassEnvelope(at: now))))
        let bassTau = bassTarget > bass ? Self.bassAttack : Self.bassRelease
        bass += (bassTarget - bass) * (1 - exp(-dt / bassTau))

        // Without beats the cool layer glows with the volume; with them it
        // drops near black between flashes, like the clip's dark frames.
        let calmTarget = 0.28 + 0.5 * energy + 0.3 * bass
        calmLit += (calmTarget - calmLit) * (1 - exp(-dt / 0.12))
        let beatLit = 0.07 + 0.18 * bass + 0.85 * envelope
        let lit = min(1.1, (1 - beatReactivity) * calmLit + beatReactivity * beatLit)

        // Notes: bin k owns spectrum slice k, bass to treble; quick to rise,
        // slower to fall so a held note keeps its bars lit.
        let spectrumGain = 0.6 + 0.4 * min(2.2, max(0.3, sensitivity))
        var peakNote = -1
        var peakLevel = 0.15
        for k in 0..<Self.noteBins {
            let lower = k * spectrum.count / Self.noteBins
            let upper = min(spectrum.count, max(lower + 1, (k + 1) * spectrum.count / Self.noteBins))
            var target = 0.0
            if upper > lower {
                var sum: CGFloat = 0
                for b in lower..<upper { sum += spectrum[b] }
                target = min(1, Double(sum) / Double(upper - lower) * spectrumGain * 1.6)
            }
            if target > peakLevel { peakLevel = target; peakNote = k }
            let tau = target > notes[k] ? 0.06 : 0.22
            notes[k] += (target - notes[k]) * (1 - exp(-dt / tau))
        }

        huePhase += dt * (0.01 + 0.02 * energy + 0.04 * beatReactivity * envelope)
        snapshot = NeonFrame(
            travel: gridTravel + extraTravel,
            roll: roll,
            tumble: tumble,
            lit: lit,
            flash: beatReactivity * envelope,
            energy: energy,
            notes: notes,
            peakNote: peakNote,
            // The primary color wanders the first third of the gradient and
            // back, so the tunnel keeps one signature color like the clip.
            hue: 0.35 * (1 - abs(2 * huePhase.truncatingRemainder(dividingBy: 1) - 1))
        )
        return snapshot
    }
}

#Preview {
    NeonVisualizerView(spectrum: Array(repeating: 0.5, count: 64), volume: 0.6, theme: .ocean, sensitivity: 1.0)
        .frame(width: 500, height: 500)
        .background(Color.black)
}
