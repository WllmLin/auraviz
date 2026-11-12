import SwiftUI

/// Hexagonal neon cage tunnel, after the bundled watermarked preview clip:
/// hexagonal rings built from broken neon bars, tied together by six
/// longitudinal corner rails and diagonal zigzag braces so the corridor
/// reads as a cage of triangular panels spiraling to a white-hot core.
/// Rings fly one per beat once a tempo is known (a volume-driven cruise
/// until then), the whole cage rolls one turn per 32 beats, and every bar
/// is drawn additively with a soft halo, a colored body and a white-hot
/// core.
///
/// The music runs the clip's two lighting layers. Rhythm drives the cool
/// layer: on every beat the tunnel floods with the theme's primary color
/// and then drops to near-black, the clip's lit/dark strobe, with flashes
/// held to the 3-per-second strobe cap, and every beat launches a bright
/// hexagonal ring down the tunnel. Notes drive the warm layer: about a
/// third of the bars (most of the diagonals) take the theme's contrasting
/// colors and light only when the pitch region they cross is sounding —
/// bass along the floor of the screen, treble across the top, mirrored
/// left and right — so between beats the melody paints the dark tunnel,
/// and the loudest band burns white-hot. Kicks punch the cage toward the
/// viewer and swell the core, snares light the corner rails and jolt the
/// roll, and hats spark a scatter of ring corners.
struct TunnelVisualizerView: View {
    var spectrum: [CGFloat]
    var volume: CGFloat
    var theme: ColorTheme
    var sensitivity: Double
    var isActive: Bool = true
    var beat = BeatAnalysis()
    /// 0 keeps the volume-only look; 1 applies the full beat effects.
    var beatReactivity: Double = 0
    /// Kicks punch the cage, snares light the rails, hats spark corners.
    var drumReactivity = DrumReactivity.off

    @State private var system = TunnelSystem()

    /// Rings in flight along the tunnel, one spacing apart.
    static let ringCount = 40
    /// Camera-space depth of the nearest ring, and the gap between rings.
    private static let nearDepth = 0.35
    private static let spacing = 0.26
    /// Bar ends nearer than this are clipped so the projection stays finite.
    private static let clipDepth = 0.12
    /// The tunnel twists this far (radians) from one ring to the next.
    private static let twistPerRing = 0.02
    /// How far down the tunnel a beat ring appears, in world depth.
    private static let beatRingDepth = 6.0
    /// The same distance in ring spacings, for `TunnelSystem`'s spawns.
    static var beatRingSteps: Double { (beatRingDepth - nearDepth) / spacing }
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
            x: w / 2 + CGFloat(sin(frame.travel * 0.13)) * w * 0.03,
            y: h / 2 + CGFloat(cos(frame.travel * 0.11)) * h * 0.03
        )
        let reach = hypot(w, h) / 2
        // A ring of radius 1 at depth 1 spans the short side; kicks widen
        // the field of view so every ring jumps toward the viewer.
        let punch = 1 + 0.08 * accents.kick + 0.03 * frame.flash
        let focal = 0.5 * min(w, h) * CGFloat(punch)
        let colors = TunnelColors(palette: palette, hue: frame.hue)
        var glow = context
        glow.blendMode = .plusLighter

        drawWash(in: glow, center: center, reach: reach, frame: frame, colors: colors)
        drawCage(in: glow, center: center, focal: focal, scale: s, frame: frame, accents: accents, colors: colors)
        drawBeatRings(in: glow, center: center, focal: focal, scale: s, frame: frame, accents: accents, colors: colors)
        drawCore(in: glow, center: center, short: min(w, h), scale: s, frame: frame, accents: accents, colors: colors)
    }

    /// The clip's flood: on the lit beat the whole stage washes over in the
    /// primary color, then drains back to black with the cool layer.
    private func drawWash(in glow: GraphicsContext, center: CGPoint, reach: CGFloat, frame: TunnelFrame, colors: TunnelColors) {
        let color = colors.cool[1].color
        let inner = min(1, 0.08 * frame.lit + 0.24 * frame.flash + 0.04 * frame.energy)
        let outer = min(1, 0.05 * frame.lit + 0.14 * frame.flash)
        let radius = reach * 1.1
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

    /// What a bar is part of; diagonals lean warm (note-driven) and rails
    /// answer snares, so the kinds light differently.
    private enum BarKind {
        case ring, rail, diagonal
    }

    /// Every ring in flight, far to near, tied to the next by corner rails
    /// and diagonal braces. Each ring edge is split into one to three neon
    /// dashes in 3D, and each dash becomes a tapered quad, wider at the
    /// nearer end. Quads are batched by color and opacity step so the whole
    /// cage is a few dozen fills instead of one per bar.
    private func drawCage(in glow: GraphicsContext, center: CGPoint, focal: CGFloat, scale s: CGFloat, frame: TunnelFrame, accents: TunnelDrumAccents, colors: TunnelColors) {
        let levels = Self.levelOpacities.count
        var buckets = [TunnelBucket](repeating: TunnelBucket(), count: (Self.coolShades + Self.warmColors) * levels)
        var sparks = Path()
        let minHalfWidth = 0.45 * s
        let maxHalfWidth = 7 * s
        let sparkRadius = CGFloat(1.2 + 2.2 * accents.hat) * s
        let showSparks = accents.hat > 0.02
        // Snares jolt the roll and push the rails toward white.
        let roll = frame.roll + 0.32 * accents.snare
        let count = Self.ringCount
        let first = Int(frame.travel.rounded(.down)) + 1

        func project(_ p: TunnelPoint) -> CGPoint {
            CGPoint(x: center.x + CGFloat(p.x / p.z) * focal, y: center.y + CGFloat(p.y / p.z) * focal)
        }
        /// The six corners of ring `k` at depth `z`: a hexagon with a stable
        /// per-ring radius, center offset and spin jitter, twisted a little
        /// further than the ring before it.
        func corners(ofRing k: Int, depth z: Double) -> [TunnelPoint] {
            let spin = roll + (Double(k) * Self.twistPerRing).truncatingRemainder(dividingBy: 2 * .pi) + (Self.hash(k, 41) - 0.5) * 0.06
            let radius = 0.94 + 0.20 * Self.hash(k, 42)
            let ox = (Self.hash(k, 43) - 0.5) * 0.14
            let oy = (Self.hash(k, 44) - 0.5) * 0.14
            return Self.hexagon.map { unit in
                TunnelPoint(
                    x: (unit.x * cos(spin) - unit.y * sin(spin)) * radius + ox,
                    y: (unit.x * sin(spin) + unit.y * cos(spin)) * radius + oy,
                    z: z
                )
            }
        }
        func depth(atSteps steps: Double) -> Double {
            Self.nearDepth + steps * Self.spacing
        }

        // Ring corners are shared by the ring's own edges and the rails and
        // diagonals to the next ring, so they are computed once, one ring
        // past the far end for the last set of ties.
        var allCorners: [[TunnelPoint]] = []
        allCorners.reserveCapacity(count + 1)
        for k in first...(first + count) {
            allCorners.append(corners(ofRing: k, depth: depth(atSteps: Double(k) - frame.travel)))
        }

        /// Adds one neon bar between two camera-space points to its bucket.
        func addBar(_ a: TunnelPoint, _ b: TunnelPoint, ring k: Int, salt: Int, kind: BarKind, fade: Double) {
            var p0 = a
            var p1 = b
            if p0.z < Self.clipDepth && p1.z < Self.clipDepth { return }
            if p0.z < Self.clipDepth { p0 = p0.lerp(to: p1, (Self.clipDepth - p0.z) / (p1.z - p0.z)) }
            if p1.z < Self.clipDepth { p1 = p1.lerp(to: p0, (Self.clipDepth - p1.z) / (p0.z - p1.z)) }
            let q0 = project(p0)
            let q1 = project(p1)
            let barWidth = 0.022 + 0.016 * Self.hash(k, salt + 7)
            let w0 = min(maxHalfWidth, max(minHalfWidth, CGFloat(0.5 * barWidth / p0.z) * focal))
            let w1 = min(maxHalfWidth, max(minHalfWidth, CGFloat(0.5 * barWidth / p1.z) * focal))

            // The pitch region this bar crosses: 0 straight down (bass) to
            // 1 straight up (treble).
            let mx = Double((q0.x + q1.x) / 2 - center.x)
            let my = Double((q0.y + q1.y) / 2 - center.y)
            let note = frame.note(at: atan2(abs(mx), my) / .pi)
            let peakBoost = note.isPeak ? 1.0 : 0.0
            let z = (p0.z + p1.z) / 2
            let fog = min(1, 0.3 + 0.7 * exp(-(z - 0.5) / 3.5))
            // Distant bars whiten toward the core, as in the clip.
            let depthWhite = 0.25 * min(1, z / 7)
            let warmChance = (kind == .diagonal ? 0.55 : 0.22) * min(1.5, max(0.3, 1.6 - z / 6))
            let warm = Self.hash(k, salt + 3) < warmChance

            let colorIndex: Int
            let alpha: Double
            if warm {
                // Warm bars hold the dark phase and are flooded over when lit.
                alpha = fade * fog * (0.06 + 0.94 * note.energy) * (1 - 0.65 * min(1, frame.lit)) * (1 + 0.25 * peakBoost)
                colorIndex = Self.coolShades + min(Self.warmColors - 1, Int(Self.hash(k, salt + 4) * Double(Self.warmColors)))
            } else {
                var litAlpha = fade * fog * frame.lit * (0.6 + 0.4 * note.energy + 0.3 * peakBoost)
                var whiteness = depthWhite + 0.45 * note.energy + 0.35 * peakBoost
                if kind == .rail {
                    litAlpha *= 0.75 + 0.9 * accents.snare
                    whiteness += 0.7 * accents.snare
                }
                alpha = litAlpha
                colorIndex = min(Self.coolShades - 1, Int(whiteness * Double(Self.coolShades)))
            }
            guard alpha > 0.035 else { return }
            let level = min(levels - 1, max(0, Int((log(alpha / Self.levelOpacities[0]) / Self.levelRatio).rounded())))
            buckets[colorIndex * levels + level].add(q0, q1, w0, w1)
        }

        for offset in stride(from: count - 1, through: 0, by: -1) {
            let k = first + offset
            // Steps from the near plane: 0 has just flown past the viewer,
            // `count` is just being born in the core.
            let steps = Double(k) - frame.travel
            let z = depth(atSteps: steps)
            let fadeIn = min(1, (Double(count) - steps) / 3)
            let fadeOut = Self.smoothstep(Self.nearDepth, Self.nearDepth + 0.25, z)
            let fade = fadeIn * fadeOut
            guard fade > 0.01 else { continue }
            let ringCorners = allCorners[offset]
            let next = allCorners[offset + 1]
            // The ring's own center, so an inset twin outline shrinks toward
            // it instead of toward the tunnel axis.
            let ringCenter = TunnelPoint(
                x: ringCorners.reduce(0) { $0 + $1.x } / 6,
                y: ringCorners.reduce(0) { $0 + $1.y } / 6,
                z: z
            )

            let insets = Self.hash(k, 14) < 0.55 ? [1.0, 0.86] : [1.0]
            for (ring, inset) in insets.enumerated() {
                let points = ringCorners.map { ringCenter.lerp(to: $0, inset) }
                for i in 0..<6 {
                    let salt = 64 + (ring * 8 + i) * 8
                    guard Self.hash(k, salt) >= 0.12 else { continue }
                    let a = points[i]
                    let b = points[(i + 1) % 6]
                    let pattern = Self.hash(k, salt + 1)
                    let dashCount = pattern < 0.3 ? 1 : (pattern < 0.7 ? 2 : 3)
                    let gap = 0.05 + 0.08 * Self.hash(k, salt + 2)
                    let jitter1 = (Self.hash(k, salt + 5) - 0.5) * 0.16
                    let jitter2 = (Self.hash(k, salt + 6) - 0.5) * 0.16
                    for dash in 0..<dashCount {
                        let t0 = Self.dashBoundary(dash, of: dashCount, jitter1: jitter1, jitter2: jitter2) + (dash == 0 ? 0.02 : gap)
                        let t1 = Self.dashBoundary(dash + 1, of: dashCount, jitter1: jitter1, jitter2: jitter2) - (dash == dashCount - 1 ? 0.02 : gap)
                        guard t1 > t0 else { continue }
                        addBar(a.lerp(to: b, t0), a.lerp(to: b, t1), ring: k, salt: salt, kind: .ring, fade: fade)
                    }
                }
            }

            for j in 0..<6 {
                addBar(ringCorners[j], next[j], ring: k, salt: 200 + j * 8, kind: .rail, fade: fade)
                // Diagonal braces zigzag to the next ring's next corner,
                // closing the triangular panels of the cage.
                if Self.hash(k, 300 + j * 8) < 0.55 {
                    addBar(ringCorners[j], next[(j + 1) % 6], ring: k, salt: 300 + j * 8, kind: .diagonal, fade: fade)
                }
                if Self.hash(k, 350 + j * 8) < 0.35 {
                    addBar(ringCorners[j], next[(j + 5) % 6], ring: k, salt: 350 + j * 8, kind: .diagonal, fade: fade)
                }
                // Short stray dashes ride some rails, as in the clip.
                if Self.hash(k, 400 + j * 8) < 0.5 {
                    let t0 = Self.hash(k, 401 + j * 8) * 0.7
                    let t1 = t0 + 0.18 + 0.2 * Self.hash(k, 402 + j * 8)
                    addBar(ringCorners[j].lerp(to: next[j], t0), ringCorners[j].lerp(to: next[j], t1), ring: k, salt: 400 + j * 8, kind: .diagonal, fade: fade)
                }
                // Each hat sparks a fresh scatter of ring corners.
                if showSparks && fade > 0.2 && accents.hatHits.scatter(k &* 8 &+ j) < 0.08 {
                    let q = project(ringCorners[j])
                    sparks.addEllipse(in: CGRect(x: q.x - sparkRadius, y: q.y - sparkRadius, width: sparkRadius * 2, height: sparkRadius * 2))
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
                glow.fill(bucket.haloWide, with: .color(tint.color.opacity(0.10 * opacity)))
                glow.fill(bucket.haloNear, with: .color(tint.color.opacity(0.24 * opacity)))
            }
            glow.fill(bucket.body, with: .color(tint.color.opacity(0.8 * opacity)))
            glow.fill(bucket.core, with: .color(core.color.opacity(min(1, 0.95 * opacity))))
        }

        if !sparks.isEmpty {
            glow.fill(sparks, with: .color(.white.opacity(min(1, 0.3 + accents.hat))))
        }
    }

    /// Beat rings — white-hot hexagons in a bloom of the primary color,
    /// launched down the tunnel on every beat and flying with the cage.
    private func drawBeatRings(in glow: GraphicsContext, center: CGPoint, focal: CGFloat, scale s: CGFloat, frame: TunnelFrame, accents: TunnelDrumAccents, colors: TunnelColors) {
        guard beatReactivity > 0 else { return }
        let roll = frame.roll + 0.32 * accents.snare
        let rim = colors.cool[Self.coolShades - 1].color
        for beatRing in frame.beatRings {
            let steps = beatRing.position - frame.travel
            let z = Self.nearDepth + steps * Self.spacing
            guard steps > 0.2, steps < Double(Self.ringCount) else { continue }
            let born = min(1, steps / 2)
            let fades = min(1, (Double(Self.ringCount) - steps) / 6)
            let alpha = min(1, born * fades * beatReactivity * (0.5 + 0.5 * beatRing.strength))
            guard alpha > 0.01 else { continue }
            let r = focal / CGFloat(z)
            let spin = roll + (beatRing.position * Self.twistPerRing).truncatingRemainder(dividingBy: 2 * .pi)
            var hex = Path()
            for (i, unit) in Self.hexagon.enumerated() {
                let p = CGPoint(
                    x: center.x + CGFloat(unit.x * cos(spin) - unit.y * sin(spin)) * r,
                    y: center.y + CGFloat(unit.x * sin(spin) + unit.y * cos(spin)) * r
                )
                if i == 0 { hex.move(to: p) } else { hex.addLine(to: p) }
            }
            hex.closeSubpath()
            let lineWidth = min(9 * s, s * CGFloat(1.2 + 3.5 / z))
            glow.stroke(hex, with: .color(rim.opacity(alpha * 0.18)), lineWidth: lineWidth * 6)
            glow.stroke(hex, with: .color(rim.opacity(alpha * 0.45)), lineWidth: lineWidth * 2.5)
            glow.stroke(hex, with: .color(.white.opacity(alpha)), lineWidth: lineWidth)
        }
    }

    /// The hot hexagonal core at the vanishing point: a glow that swells on
    /// kicks and lit beats, with small hexagons streaming out of it one per
    /// beat, matching the rings' flight.
    private func drawCore(in glow: GraphicsContext, center: CGPoint, short: CGFloat, scale s: CGFloat, frame: TunnelFrame, accents: TunnelDrumAccents, colors: TunnelColors) {
        let swell = 1 + 0.45 * accents.kick + 0.2 * frame.flash + 0.1 * frame.energy
        let radius = short * 0.075 * CGFloat(swell)
        let lit = min(1, frame.lit)
        let haloColor = colors.cool[2].color
        let halo = radius * 4
        glow.fill(
            Path(ellipseIn: CGRect(x: center.x - halo, y: center.y - halo, width: halo * 2, height: halo * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: haloColor.opacity(0.16 + 0.22 * lit), location: 0),
                    .init(color: haloColor.opacity(0.05 + 0.08 * lit), location: 0.35),
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
            let r = radius * CGFloat(0.25 + 0.95 * phase)
            var hex = Path()
            for (i, unit) in Self.hexagon.enumerated() {
                let p = CGPoint(
                    x: center.x + CGFloat(unit.x * cos(roll) - unit.y * sin(roll)) * r,
                    y: center.y + CGFloat(unit.x * sin(roll) + unit.y * cos(roll)) * r
                )
                if i == 0 { hex.move(to: p) } else { hex.addLine(to: p) }
            }
            hex.closeSubpath()
            glow.stroke(hex, with: .color(lineColor.opacity(0.18 * fade * (0.5 + 0.5 * lit))), lineWidth: 6 * s)
            glow.stroke(hex, with: .color(lineColor.opacity(fade * (0.55 + 0.45 * lit))), lineWidth: 1.6 * s)
            glow.stroke(hex, with: .color(.white.opacity(0.8 * fade * (0.4 + 0.6 * lit))), lineWidth: 0.7 * s)
        }

        let hot = radius * 0.45
        glow.fill(
            Path(ellipseIn: CGRect(x: center.x - hot, y: center.y - hot, width: hot * 2, height: hot * 2)),
            with: .radialGradient(Gradient(colors: [.white.opacity(0.18 + 0.22 * lit), .clear]), center: center, startRadius: 0, endRadius: hot)
        )
    }

    // MARK: - Helpers

    /// Where dash boundary `j` of `count` falls along an edge, jittered so
    /// the breaks don't line up from ring to ring.
    private static func dashBoundary(_ j: Int, of count: Int, jitter1: Double, jitter2: Double) -> Double {
        if j == 0 { return 0 }
        if j == count { return 1 }
        return Double(j) / Double(count) + (j == 1 ? jitter1 : jitter2)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// A stable pseudo-random 0..<1 for feature `salt` of ring `ring`, so a
    /// ring keeps its shape for its whole flight and the next one through
    /// the same slot gets a new one.
    static func hash(_ ring: Int, _ salt: Int) -> Double {
        var x = (UInt64(bitPattern: Int64(ring)) &* 0x9E37_79B9_7F4A_7C15) ^ (UInt64(bitPattern: Int64(salt)) &* 0xBF58_476D_1CE4_E5B9)
        x ^= x >> 31
        x = x &* 0x94D0_49BB_1331_11EB
        x ^= x >> 29
        return Double(x >> 11) / Double(1 << 53)
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

/// Quads for one color and opacity step, in four passes from soft halo to
/// white-hot core. Every quad winds the same way, so overlaps fill once.
private struct TunnelBucket {
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
        Self.addQuad(to: &haloWide, a, b, nx, ny, widthA * 3.2, widthB * 3.2)
        Self.addQuad(to: &haloNear, a, b, nx, ny, widthA * 1.9, widthB * 1.9)
        Self.addQuad(to: &body, a, b, nx, ny, widthA, widthB)
        Self.addQuad(to: &core, a, b, nx, ny, widthA * 0.42, widthB * 0.42)
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
private struct TunnelColors {
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
private struct TunnelDrumAccents {
    var kick: Double
    var snare: Double
    var hat: Double
    /// Picks which corners spark on the current hat.
    var hatHits: DrumHits
}

/// A bright ring launched on a beat, in absolute ring-spacing steps along
/// the tunnel, flying with the cage until it passes the viewer.
private struct TunnelBeatRing {
    var position: Double
    var strength: Double
}

/// Immutable draw inputs for one frame, advanced by `TunnelSystem`.
private struct TunnelFrame {
    /// Rings flown past the viewer so far; the fraction is the progress
    /// toward the next.
    var travel = 0.0
    var roll = 0.0
    /// Cool layer level: the beat's lit/dark strobe, or a volume glow at 0
    /// beat reactivity.
    var lit = 0.3
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
    /// Rings flown per beat once synced to the tempo.
    private static let ringsPerBeat = 1.0
    /// One full roll every 32 beats once synced to the tempo.
    private static let rollPerBeat = 2 * Double.pi / 32
    /// The lit phase holds briefly at full, then drains, as in the clip.
    private static let litHold: TimeInterval = 0.07
    private static let litDecay: TimeInterval = 0.16
    private static let bassAttack: TimeInterval = 0.04
    private static let bassRelease: TimeInterval = 0.4
    private static let maxBeatRings = 16

    private let travelPhase = BeatSyncedPhase()
    private let rollPhase = BeatSyncedPhase()
    private var notes = [Double](repeating: 0, count: noteBins)
    private var bass = 0.0
    private var calmLit = 0.3
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
        // One ring per beat once a tempo is known; until then, cruise
        // between 0.5 and 4 rings per second with the volume. Integrated,
        // so gaining or losing the tempo changes speed without a jump.
        let travel = travelPhase.advance(
            to: time,
            wallRate: 0.5 + 3.5 * energy,
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

        // Every beat launches a bright ring ahead of the viewer; the
        // lit/dark strobe accepts a new beat only past the strobe cap.
        if let lastBeatCount, beat.beatCount != lastBeatCount {
            beatRings.append(TunnelBeatRing(position: travel + TunnelVisualizerView.beatRingSteps, strength: Double(beat.beatStrength)))
            if beatRings.count > Self.maxBeatRings {
                beatRings.removeFirst(beatRings.count - Self.maxBeatRings)
            }
            if beat.lastBeatTime - flashTime >= PerformanceState.strobeMinimumInterval {
                flashTime = beat.lastBeatTime
                flashStrength = Double(beat.beatStrength)
            }
        }
        lastBeatCount = beat.beatCount
        beatRings.removeAll { $0.position - travel < 0 }
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
