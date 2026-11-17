import SwiftUI

/// Hexagonal box-truss tunnel, after the bundled watermarked preview clip:
/// a corridor of wireframe boxes — each layer a ring of six boxes built from
/// an inner and an outer hexagon joined by radial struts and longitudinal
/// rails — with every layer twisted a little further than the last, so the
/// corridor spirals toward a glowing core. The boxes are steel tubes trimmed
/// with neon strips: the tubes only show when the stage is lit, the neon
/// always glows. Layers fly two per beat once a tempo is known (a
/// volume-driven cruise until then) and the corridor rolls one turn per 32
/// beats.
///
/// The music runs the clip's two lighting layers. Rhythm drives the cool
/// layer: on every beat the whole stage floods with the theme's primary
/// color — lighting the steel and turning the cool neon white-hot — and
/// then drops to black, the clip's lit/dark strobe, with flashes held to the
/// 3-per-second strobe cap; every beat also launches a fully lit double
/// hexagon down the corridor. Notes drive the warm layer: boxes on the
/// side walls are outlined in the theme's contrasting colors (one on the
/// left, another on the right, with an accent mixed in, as in the clip) and
/// burn with the pitch region they sit in — bass along the floor of the
/// screen, treble across the top, mirrored left and right — so between
/// beats the melody paints the dark corridor, and the loudest band burns
/// white-hot. Kicks punch the corridor toward the viewer and swell the core,
/// snares light the rails and jolt the roll, and hats spark a scatter of
/// box corners.
struct TunnelVisualizerView: View {
    var spectrum: [CGFloat]
    var volume: CGFloat
    var theme: ColorTheme
    var sensitivity: Double
    var isActive: Bool = true
    var beat = BeatAnalysis()
    /// 0 keeps the volume-only look; 1 applies the full beat effects.
    var beatReactivity: Double = 0
    /// Kicks punch the corridor, snares light the rails, hats spark corners.
    var drumReactivity = DrumReactivity.off

    @State private var system = TunnelSystem()

    /// Box layers in flight along the tunnel, one spacing apart.
    static let ringCount = 24
    /// Camera-space depth of the nearest layer, and the gap between layers.
    private static let nearDepth = 0.30
    private static let spacing = 0.56
    /// How long each box is along the tunnel; the rest of the spacing is the
    /// gap to the next layer, which doubles the outlines as in the clip.
    private static let boxDepth = 0.42
    /// Tube ends nearer than this are clipped so the projection stays finite.
    private static let clipDepth = 0.10
    /// The corridor twists this far (radians) from one layer to the next.
    private static let twistPerRing = 0.21
    /// The boxes sit between these two hexagon radii.
    private static let innerRadius = 1.0
    private static let outerRadius = 1.55
    /// Radius of a steel tube in world units; neon strips are half as wide.
    private static let tubeRadius = 0.030
    /// How far down the tunnel a beat ring appears, in world depth.
    private static let beatRingDepth = 7.0
    /// The same distance in layer spacings, for `TunnelSystem`'s spawns.
    static var beatRingSteps: Double { (beatRingDepth - nearDepth) / spacing }
    /// Opacity steps the tubes and strips are batched into, about 1.7x
    /// apart, so the dark phase can sit as far below the lit phase as it
    /// does in the clip.
    private static let levelOpacities: [Double] = [0.07, 0.12, 0.21, 0.36, 0.62, 1.0]
    private static let levelRatio = log(1.72)
    /// Cool strips get shades of the primary color toward white; warm boxes
    /// a left color, a right color and an accent.
    private static let coolShades = 4
    private static let warmColors = 3
    private static let hexagon: [(x: Double, y: Double)] = (0..<6).map { i in
        (x: cos(Double(i) * .pi / 3), y: sin(Double(i) * .pi / 3))
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
            let accents = TunnelDrumAccents(
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

    private func draw(in context: GraphicsContext, size: CGSize, frame: TunnelFrame, accents: TunnelDrumAccents, palette: ThemePalette) {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0 else { return }
        let s = size.visualizerScale
        // The vanishing point wanders slowly, so the tunnel seems to curve.
        let center = CGPoint(
            x: w / 2 + CGFloat(sin(frame.travel * 0.13)) * w * 0.02,
            y: h / 2 + CGFloat(cos(frame.travel * 0.11)) * h * 0.02
        )
        // A hexagon of radius 1 at depth 1 spans the short side; kicks widen
        // the field of view so every layer jumps toward the viewer.
        let punch = 1 + 0.08 * accents.kick + 0.03 * frame.flash
        let focal = 0.5 * min(w, h) * CGFloat(punch)
        let colors = TunnelColors(palette: palette, hue: frame.hue)
        var glow = context
        glow.blendMode = .plusLighter
        var solid = context
        solid.blendMode = .normal

        drawFlood(in: glow, size: size, center: center, frame: frame, colors: colors)
        drawCorridor(glow: glow, solid: solid, center: center, focal: focal, scale: s, frame: frame, accents: accents, colors: colors)
        drawCore(in: glow, center: center, short: min(w, h), scale: s, frame: frame, accents: accents, colors: colors)
    }

    /// The clip's flood: on the lit beat the whole stage washes over in the
    /// primary color, brightest toward the core, then drains back to black.
    private func drawFlood(in glow: GraphicsContext, size: CGSize, center: CGPoint, frame: TunnelFrame, colors: TunnelColors) {
        let lit = min(1, frame.lit)
        guard lit > 0.01 else { return }
        let base = colors.primary
        let radius = hypot(size.width, size.height) / 2 * 1.05
        glow.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: base.towardWhite(0.55).color.opacity(0.95 * lit), location: 0),
                    .init(color: base.towardWhite(0.12).color.opacity(0.85 * lit), location: 0.25),
                    .init(color: base.scaled(0.55).color.opacity(0.75 * lit), location: 1),
                ]),
                center: center, startRadius: 0, endRadius: radius
            )
        )
    }

    /// What a tube is part of; each kind carries neon strips at its own rate.
    private enum Member {
        case innerRing, outerRing, strut, rail, outerRail

        /// Chance a tube of this kind carries a neon strip on a cool box.
        var neonChance: Double {
            switch self {
            case .innerRing: return 0.55
            case .outerRing: return 0.4
            case .strut, .rail, .outerRail: return 0.3
            }
        }
    }

    /// One box's neon trim: cool strips, or a warm outline in one color.
    private struct BoxTrim {
        var isWarm: Bool
        var warmIndex: Int
    }

    /// Every box layer in flight, far to near. Each layer is a ring of six
    /// boxes between an inner and an outer hexagon, front and back, joined
    /// by radial struts and longitudinal rails. Each tube becomes a tapered
    /// steel quad, wider at the nearer end, and some carry a neon strip.
    /// Quads are batched by color and opacity step so the whole corridor is
    /// a few dozen fills instead of one per tube.
    private func drawCorridor(glow: GraphicsContext, solid: GraphicsContext, center: CGPoint, focal: CGFloat, scale s: CGFloat, frame: TunnelFrame, accents: TunnelDrumAccents, colors: TunnelColors) {
        let levels = Self.levelOpacities.count
        var steelBody = [Path](repeating: Path(), count: levels)
        var steelSheen = [Path](repeating: Path(), count: levels)
        var buckets = [TunnelBucket](repeating: TunnelBucket(), count: (Self.coolShades + Self.warmColors) * levels)
        var sparks = Path()
        let minTube = 0.5 * s
        let maxTube = 9 * s
        let minStrip = 0.45 * s
        let maxStrip = 6 * s
        let sparkRadius = CGFloat(1.4 + 2.4 * accents.hat) * s
        let showSparks = accents.hat > 0.02
        let lit = min(1, frame.lit)
        // The steel only shows in the flood; the dark phase is pure black.
        let steelLit = lit * Self.smoothstep(0.04, 0.35, lit)
        // Snares jolt the roll and push the rails toward white.
        let roll = frame.roll + 0.32 * accents.snare
        let count = Self.ringCount
        // Starts one layer behind the near plane so the nearest layer fades
        // out completely before it is dropped.
        let first = Int(frame.travel.rounded(.down))

        func project(_ p: TunnelPoint) -> CGPoint {
            CGPoint(x: center.x + CGFloat(p.x / p.z) * focal, y: center.y + CGFloat(p.y / p.z) * focal)
        }
        /// Layer `k`'s rotation: twisted a little further than the layer
        /// before it, with a stable per-layer jitter.
        func spin(ofRing k: Int) -> Double {
            roll + (Double(k) * Self.twistPerRing).truncatingRemainder(dividingBy: 2 * .pi) + (Self.hash(k, 41) - 0.5) * 0.08
        }
        func corners(spin: Double, radius: Double, depth z: Double) -> [TunnelPoint] {
            let c = cos(spin)
            let sn = sin(spin)
            return Self.hexagon.map { unit in
                TunnelPoint(x: (unit.x * c - unit.y * sn) * radius, y: (unit.x * sn + unit.y * c) * radius, z: z)
            }
        }
        func clipped(_ a: TunnelPoint, _ b: TunnelPoint) -> (TunnelPoint, TunnelPoint)? {
            if a.z < Self.clipDepth && b.z < Self.clipDepth { return nil }
            var p0 = a
            var p1 = b
            if p0.z < Self.clipDepth { p0 = p0.lerp(to: p1, (Self.clipDepth - p0.z) / (p1.z - p0.z)) }
            if p1.z < Self.clipDepth { p1 = p1.lerp(to: p0, (Self.clipDepth - p1.z) / (p0.z - p1.z)) }
            return (p0, p1)
        }
        func level(for alpha: Double) -> Int {
            min(levels - 1, max(0, Int((log(alpha / Self.levelOpacities[0]) / Self.levelRatio).rounded())))
        }
        func halfWidth(_ radius: Double, _ z: Double, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            min(upper, max(lower, CGFloat(radius / z) * focal))
        }

        /// Adds one tube between two camera-space points: steel if the stage
        /// is lit, plus a neon strip along part of it if this tube has one.
        func addTube(_ a: TunnelPoint, _ b: TunnelPoint, ring k: Int, salt: Int, member: Member, trim: BoxTrim, fade: Double, beatGlow: Double = 0) {
            guard let tube = clipped(a, b) else { return }
            let p0 = tube.0
            let p1 = tube.1
            let z = (p0.z + p1.z) / 2
            let fog = exp(-max(0, z - 0.6) / 3.2)

            let steelAlpha = fade * fog * steelLit
            if steelAlpha > 0.03 {
                let q0 = project(p0)
                let q1 = project(p1)
                let w0 = halfWidth(Self.tubeRadius, p0.z, minTube, maxTube)
                let w1 = halfWidth(Self.tubeRadius, p1.z, minTube, maxTube)
                let index = level(for: steelAlpha)
                TunnelBucket.addQuad(to: &steelBody[index], q0, q1, w0, w1)
                TunnelBucket.addQuad(to: &steelSheen[index], q0, q1, w0 * 0.4, w1 * 0.4)
            }

            // Where along the tube its neon strip runs, if it has one.
            let t0: Double
            let t1: Double
            if beatGlow > 0 {
                t0 = 0.03
                t1 = 0.97
            } else if trim.isWarm {
                // Warm boxes are outlined almost edge to edge.
                guard Self.hash(k, salt) < 0.6 else { return }
                t0 = 0.03 + 0.12 * Self.hash(k, salt + 1)
                t1 = 0.97 - 0.12 * Self.hash(k, salt + 2)
            } else {
                guard Self.hash(k, salt) < member.neonChance else { return }
                t0 = 0.04 + 0.45 * Self.hash(k, salt + 1)
                t1 = min(0.96, t0 + 0.2 + 0.55 * Self.hash(k, salt + 2))
            }
            guard let strip = clipped(a.lerp(to: b, t0), a.lerp(to: b, t1)) else { return }
            let n0 = strip.0
            let n1 = strip.1
            let q0 = project(n0)
            let q1 = project(n1)
            let w0 = halfWidth(0.5 * Self.tubeRadius, n0.z, minStrip, maxStrip)
            let w1 = halfWidth(0.5 * Self.tubeRadius, n1.z, minStrip, maxStrip)

            // The pitch region this strip crosses: 0 straight down (bass) to
            // 1 straight up (treble).
            let mx = Double((q0.x + q1.x) / 2 - center.x)
            let my = Double((q0.y + q1.y) / 2 - center.y)
            let note = frame.note(at: atan2(abs(mx), my) / .pi)
            let peakBoost = note.isPeak ? 1.0 : 0.0

            let colorIndex: Int
            var alpha: Double
            if trim.isWarm && beatGlow == 0 {
                // Warm boxes hold the dark phase and are flooded over when lit.
                alpha = fade * fog * (0.3 + 0.7 * note.energy) * (1 - 0.6 * lit) * (1 + 0.3 * peakBoost)
                colorIndex = Self.coolShades + trim.warmIndex
            } else {
                // Distant strips whiten toward the core, as in the clip.
                let depthWhite = 0.25 * min(1, z / 6)
                var whiteness = 0.05 + 0.3 * lit + 0.6 * beatGlow
                whiteness += depthWhite + 0.2 * peakBoost
                alpha = fade * fog * (0.16 + 0.84 * lit + 0.8 * beatGlow)
                if member == .rail || member == .outerRail {
                    alpha *= 1 + 0.9 * accents.snare
                    whiteness += 0.7 * accents.snare
                }
                colorIndex = min(Self.coolShades - 1, Int(whiteness * Double(Self.coolShades)))
            }
            alpha = min(1, alpha)
            guard alpha > 0.03 else { return }
            buckets[colorIndex * levels + level(for: alpha)].add(q0, q1, w0, w1)
        }

        for offset in stride(from: count - 1, through: 0, by: -1) {
            let k = first + offset
            // Steps from the near plane: below 0 is flying past the viewer,
            // `count - 1` is just being born in the core.
            let steps = Double(k) - frame.travel
            let z = Self.nearDepth + steps * Self.spacing
            let fadeIn = min(1, (Double(count - 1) - steps) / 4)
            let fadeOut = Self.smoothstep(Self.nearDepth - 0.1, Self.nearDepth + 0.3, z)
            let fade = fadeIn * fadeOut
            guard fade > 0.01 else { continue }
            let beatGlow = frame.beatRings.first(where: { $0.layer == k })?.strength ?? 0

            let angle = spin(ofRing: k)
            let backZ = z + Self.boxDepth
            let frontInner = corners(spin: angle, radius: Self.innerRadius, depth: z)
            let frontOuter = corners(spin: angle, radius: Self.outerRadius, depth: z)
            let backInner = corners(spin: angle, radius: Self.innerRadius, depth: backZ)
            let backOuter = corners(spin: angle, radius: Self.outerRadius, depth: backZ)

            for j in 0..<6 {
                let n = (j + 1) % 6
                // Boxes on the side walls may be outlined warm: left and
                // right get different colors, with an accent mixed in.
                let faceAngle = angle + (Double(j) + 0.5) * .pi / 3
                let band = Self.smoothstep(0.55, 0.85, abs(cos(faceAngle)))
                let warmPick = Self.hash(k, 610 + j)
                let trim = BoxTrim(
                    isWarm: Self.hash(k, 600 + j) < 0.4 * band,
                    warmIndex: warmPick < 0.2 ? 2 : (cos(faceAngle) < 0 ? 0 : 1)
                )
                addTube(frontInner[j], frontInner[n], ring: k, salt: 100 + j * 8, member: .innerRing, trim: trim, fade: fade, beatGlow: beatGlow)
                addTube(frontOuter[j], frontOuter[n], ring: k, salt: 160 + j * 8, member: .outerRing, trim: trim, fade: fade, beatGlow: beatGlow)
                addTube(frontInner[j], frontOuter[j], ring: k, salt: 220 + j * 8, member: .strut, trim: trim, fade: fade)
                addTube(backInner[j], backInner[n], ring: k, salt: 280 + j * 8, member: .innerRing, trim: trim, fade: fade)
                addTube(backOuter[j], backOuter[n], ring: k, salt: 340 + j * 8, member: .outerRing, trim: trim, fade: fade)
                addTube(backInner[j], backOuter[j], ring: k, salt: 400 + j * 8, member: .strut, trim: trim, fade: fade)
                addTube(frontInner[j], backInner[j], ring: k, salt: 460 + j * 8, member: .rail, trim: trim, fade: fade)
                addTube(frontOuter[j], backOuter[j], ring: k, salt: 520 + j * 8, member: .outerRail, trim: trim, fade: fade)
                // Each hat sparks a fresh scatter of box corners.
                if showSparks && fade > 0.2 && accents.hatHits.scatter(k &* 8 &+ j) < 0.08 {
                    let q = project(frontInner[j])
                    sparks.addEllipse(in: CGRect(x: q.x - sparkRadius, y: q.y - sparkRadius, width: sparkRadius * 2, height: sparkRadius * 2))
                }
            }
        }

        // Steel: a dark body that shades whatever is behind it, then a
        // light sheen down the middle so the tubes read as round.
        let bodyColor = colors.primary.scaled(0.22).color
        let sheenColor = colors.primary.towardWhite(0.45).color
        for index in 0..<levels where !steelBody[index].isEmpty {
            solid.fill(steelBody[index], with: .color(bodyColor.opacity(0.7 * Self.levelOpacities[index])))
        }
        for index in 0..<levels where !steelSheen[index].isEmpty {
            glow.fill(steelSheen[index], with: .color(sheenColor.opacity(0.5 * Self.levelOpacities[index])))
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
                core = tint.towardWhite(0.45)
            }
            // The faintest steps skip their halos; they wouldn't show.
            if level >= 2 {
                glow.fill(bucket.haloWide, with: .color(tint.color.opacity(0.14 * opacity)))
                glow.fill(bucket.haloNear, with: .color(tint.color.opacity(0.30 * opacity)))
            }
            glow.fill(bucket.body, with: .color(tint.color.opacity(0.85 * opacity)))
            glow.fill(bucket.core, with: .color(core.color.opacity(min(1, 0.95 * opacity))))
        }

        if !sparks.isEmpty {
            glow.fill(sparks, with: .color(.white.opacity(min(1, 0.3 + accents.hat))))
        }
    }

    /// The hot core at the vanishing point: a glow that holds through the
    /// dark phase, swells on kicks and lit beats, and streams small
    /// hexagons outward, one per layer flown.
    private func drawCore(in glow: GraphicsContext, center: CGPoint, short: CGFloat, scale s: CGFloat, frame: TunnelFrame, accents: TunnelDrumAccents, colors: TunnelColors) {
        let swell = 1 + 0.45 * accents.kick + 0.2 * frame.flash + 0.1 * frame.energy
        let radius = short * 0.06 * CGFloat(swell)
        let lit = min(1, frame.lit)
        let haloColor = colors.cool[2].color
        let halo = radius * 4
        glow.fill(
            Path(ellipseIn: CGRect(x: center.x - halo, y: center.y - halo, width: halo * 2, height: halo * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: haloColor.opacity(0.5 + 0.4 * lit), location: 0),
                    .init(color: haloColor.opacity(0.12 + 0.15 * lit), location: 0.3),
                    .init(color: .clear, location: 1),
                ]),
                center: center, startRadius: 0, endRadius: halo
            )
        )

        let roll = frame.roll + 0.32 * accents.snare
        let lineColor = colors.cool[2].color
        for j in 0..<3 {
            let phase = (frame.travel + Double(j) / 3).truncatingRemainder(dividingBy: 1)
            let fade = sin(.pi * phase)
            let r = radius * CGFloat(0.3 + 1.1 * phase)
            let spin = roll + phase * Self.twistPerRing
            var hex = Path()
            for (i, unit) in Self.hexagon.enumerated() {
                let p = CGPoint(
                    x: center.x + CGFloat(unit.x * cos(spin) - unit.y * sin(spin)) * r,
                    y: center.y + CGFloat(unit.x * sin(spin) + unit.y * cos(spin)) * r
                )
                if i == 0 { hex.move(to: p) } else { hex.addLine(to: p) }
            }
            hex.closeSubpath()
            glow.stroke(hex, with: .color(lineColor.opacity(0.2 * fade * (0.5 + 0.5 * lit))), lineWidth: 6 * s)
            glow.stroke(hex, with: .color(lineColor.opacity(fade * (0.6 + 0.4 * lit))), lineWidth: 1.6 * s)
            glow.stroke(hex, with: .color(.white.opacity(0.8 * fade * (0.5 + 0.5 * lit))), lineWidth: 0.7 * s)
        }

        let hot = radius * 0.6
        glow.fill(
            Path(ellipseIn: CGRect(x: center.x - hot, y: center.y - hot, width: hot * 2, height: hot * 2)),
            with: .radialGradient(Gradient(colors: [.white.opacity(0.5 + 0.4 * lit), .clear]), center: center, startRadius: 0, endRadius: hot)
        )
    }

    // MARK: - Helpers

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// A stable pseudo-random 0..<1 for feature `salt` of layer `ring`, so a
    /// layer keeps its trim for its whole flight and the next one through
    /// the same slot gets a new one.
    static func hash(_ ring: Int, _ salt: Int) -> Double {
        var x = (UInt64(bitPattern: Int64(ring)) &* 0x9E37_79B9_7F4A_7C15) ^ (UInt64(bitPattern: Int64(salt)) &* 0xBF58_476D_1CE4_E5B9)
        x ^= x >> 31
        x = x &* 0x94D0_49BB_1331_11EB
        x ^= x >> 29
        return Double(x >> 11) / Double(1 << 53)
    }
}

private extension ThemePalette.RGB {
    /// This color darkened toward black by `factor` (1 keeps it).
    func scaled(_ factor: Double) -> ThemePalette.RGB {
        ThemePalette.RGB(r: r * factor, g: g * factor, b: b * factor)
    }
}

/// A point in camera space: x right, y down, z into the screen.
private struct TunnelPoint {
    var x: Double
    var y: Double
    var z: Double

    func lerp(to other: TunnelPoint, _ t: Double) -> TunnelPoint {
        TunnelPoint(x: x + (other.x - x) * t, y: y + (other.y - y) * t, z: z + (other.z - z) * t)
    }
}

/// Neon quads for one color and opacity step, in four passes from soft halo
/// to white-hot core. Every quad winds the same way, so overlaps fill once.
private struct TunnelBucket {
    var haloWide = Path()
    var haloNear = Path()
    var body = Path()
    var core = Path()
    var isEmpty = true

    mutating func add(_ a: CGPoint, _ b: CGPoint, _ widthA: CGFloat, _ widthB: CGFloat) {
        guard hypot(b.x - a.x, b.y - a.y) > 0.01 else { return }
        Self.addQuad(to: &haloWide, a, b, widthA * 3.4, widthB * 3.4)
        Self.addQuad(to: &haloNear, a, b, widthA * 2.0, widthB * 2.0)
        Self.addQuad(to: &body, a, b, widthA, widthB)
        Self.addQuad(to: &core, a, b, widthA * 0.45, widthB * 0.45)
        isEmpty = false
    }

    /// A quad from `a` to `b`, `wa` and `wb` wide on either side at each end.
    static func addQuad(to path: inout Path, _ a: CGPoint, _ b: CGPoint, _ wa: CGFloat, _ wb: CGFloat) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.01 else { return }
        let nx = -dy / length
        let ny = dx / length
        path.move(to: CGPoint(x: a.x + nx * wa, y: a.y + ny * wa))
        path.addLine(to: CGPoint(x: b.x + nx * wb, y: b.y + ny * wb))
        path.addLine(to: CGPoint(x: b.x - nx * wb, y: b.y - ny * wb))
        path.addLine(to: CGPoint(x: a.x - nx * wa, y: a.y - ny * wa))
        path.closeSubpath()
    }
}

/// The frame's colors: the primary color and its shades toward white for
/// the flood, steel and cool strips, and three contrasting stops of the
/// theme gradient for the warm boxes (left, right and an accent).
private struct TunnelColors {
    let primary: ThemePalette.RGB
    let cool: [ThemePalette.RGB]
    let warm: [ThemePalette.RGB]

    init(palette: ThemePalette, hue: Double) {
        let base = palette.sample(hue)
        primary = base
        cool = [0, 0.3, 0.6, 0.85].map { base.towardWhite($0) }
        // Spread across the far side of the gradient from the primary.
        warm = [0.35, 0.65, 0.5].map { offset in
            let u = hue + offset
            return palette.sample(1 - abs(2 * u.truncatingRemainder(dividingBy: 1) - 1))
        }
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

/// A fully lit layer launched on a beat, by its absolute layer index, flying
/// with the corridor until it passes the viewer.
private struct TunnelBeatRing {
    var layer: Int
    var strength: Double
}

/// Immutable draw inputs for one frame, advanced by `TunnelSystem`.
private struct TunnelFrame {
    /// Layers flown past the viewer so far; the fraction is the progress
    /// toward the next.
    var travel = 0.0
    var roll = 0.0
    /// Flood level: the beat's lit/dark strobe, or a volume glow at 0 beat
    /// reactivity.
    var lit = 0.2
    /// Rate-limited beat flash, already scaled by beat reactivity.
    var flash = 0.0
    var energy = 0.0
    /// Smoothed note energy from bass to treble.
    var notes = [Double](repeating: 0, count: TunnelSystem.noteBins)
    /// Note bin with the loudest spectrum slice right now, or -1 in quiet.
    var peakNote = -1
    /// Position of the primary color along the theme gradient, 0-0.35.
    var hue = 0.0
    var beatRings: [TunnelBeatRing] = []

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

/// The tunnel's motion and lighting state: beat-synced flight and roll, the
/// lit/dark strobe held to the strobe cap, beat rings in flight, and
/// smoothed note energies. A class so it can advance inside a
/// `TimelineView` update without invalidating SwiftUI state.
private final class TunnelSystem {
    static let noteBins = 12
    /// Layers flown per beat once synced to the tempo; the clip races.
    private static let ringsPerBeat = 2.0
    /// One full roll every 32 beats once synced to the tempo.
    private static let rollPerBeat = 2 * Double.pi / 32
    /// The lit phase holds briefly at full, then drains, as in the clip.
    private static let litHold: TimeInterval = 0.08
    private static let litDecay: TimeInterval = 0.14
    private static let bassAttack: TimeInterval = 0.04
    private static let bassRelease: TimeInterval = 0.4
    private static let maxBeatRings = 16

    private let travelPhase = BeatSyncedPhase()
    private let rollPhase = BeatSyncedPhase()
    private var notes = [Double](repeating: 0, count: noteBins)
    private var bass = 0.0
    private var calmLit = 0.2
    private var flashTime: TimeInterval = -.infinity
    private var flashStrength = 0.0
    private var lastBeatCount: Int?
    private var beatRings: [TunnelBeatRing] = []
    private var lastTime: TimeInterval?
    private var huePhase = 0.0
    private var snapshot = TunnelFrame()

    func advance(to time: TimeInterval, now: TimeInterval, beat: BeatAnalysis, spectrum: [CGFloat], volume: Double, sensitivity: Double, beatReactivity: Double, isActive: Bool) -> TunnelFrame {
        // Clamped so resuming after a pause continues instead of jumping.
        let dt = lastTime.map { min(0.1, max(0, time - $0)) } ?? 1.0 / 60
        lastTime = time
        guard isActive, dt > 0 else { return snapshot }

        let energy = min(1, max(0, volume))
        let synced = beat.bpm > 0 ? beatReactivity : 0
        // Two layers per beat once a tempo is known; until then, cruise
        // between 1 and 5 layers per second with the volume. Integrated, so
        // gaining or losing the tempo changes speed without a jump.
        let travel = travelPhase.advance(
            to: time,
            wallRate: 1 + 4 * energy,
            gridPhase: beat.clock.beatPhase(at: now),
            gridRate: Self.ringsPerBeat,
            nominalGridSpeed: beat.clock.beatsPerSecond,
            reactivity: synced
        )
        let roll = rollPhase.advance(
            to: time,
            wallRate: 0.12 + 0.18 * energy,
            gridPhase: beat.clock.beatPhase(at: now),
            gridRate: Self.rollPerBeat,
            nominalGridSpeed: beat.clock.beatsPerSecond,
            reactivity: synced
        )

        // Every beat lights a whole layer far down the corridor; the lit/dark
        // strobe accepts a new beat only past the strobe cap.
        if let lastBeatCount, beat.beatCount != lastBeatCount {
            let layer = Int((travel + TunnelVisualizerView.beatRingSteps).rounded())
            if beatRings.last?.layer != layer {
                beatRings.append(TunnelBeatRing(layer: layer, strength: min(1, beatReactivity * (0.5 + 0.5 * Double(beat.beatStrength)))))
            }
            if beatRings.count > Self.maxBeatRings {
                beatRings.removeFirst(beatRings.count - Self.maxBeatRings)
            }
            if beat.lastBeatTime - flashTime >= PerformanceState.strobeMinimumInterval {
                flashTime = beat.lastBeatTime
                flashStrength = Double(beat.beatStrength)
            }
        }
        lastBeatCount = beat.beatCount
        beatRings.removeAll { Double($0.layer) - travel < 0 }
        let age = max(0, now - flashTime)
        let envelope = (age < Self.litHold ? 1 : exp(-(age - Self.litHold) / Self.litDecay)) * (0.5 + 0.5 * flashStrength)

        let bassTarget = Double(min(1, max(0, beat.bassEnvelope(at: now))))
        let bassTau = bassTarget > bass ? Self.bassAttack : Self.bassRelease
        bass += (bassTarget - bass) * (1 - exp(-dt / bassTau))

        // Without beats the flood glows gently with the volume; with them it
        // drops to black between flashes, like the clip's dark frames.
        let calmTarget = 0.12 + 0.35 * energy + 0.25 * bass
        calmLit += (calmTarget - calmLit) * (1 - exp(-dt / 0.12))
        let beatLit = 0.03 + 0.1 * bass + 0.97 * envelope
        let lit = min(1.1, (1 - beatReactivity) * calmLit + beatReactivity * beatLit)

        // Notes: bin k owns spectrum slice k, bass to treble; quick to rise,
        // slower to fall so a held note keeps its boxes lit.
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
        snapshot = TunnelFrame(
            travel: travel,
            roll: roll,
            lit: lit,
            flash: beatReactivity * envelope,
            energy: energy,
            notes: notes,
            peakNote: peakNote,
            // The primary color wanders the first third of the gradient and
            // back, so the tunnel keeps one signature color like the clip.
            hue: 0.35 * (1 - abs(2 * huePhase.truncatingRemainder(dividingBy: 1) - 1)),
            beatRings: beatRings
        )
        return snapshot
    }
}

#Preview {
    TunnelVisualizerView(spectrum: Array(repeating: 0.5, count: 64), volume: 0.6, theme: .tokyoNight, sensitivity: 1.0)
        .frame(width: 500, height: 500)
        .background(Color.black)
}
