import AppKit
import SwiftUI

/// Kaleidoscope tunnel, after the reference clip: eight mirrored wedges
/// around a white-hot center star, drawn in neon outline on black. Wedge
/// rings are born at the center and fly outward — one zoom cycle per bar
/// once a tempo is known, a volume-driven drift until then — while the
/// whole mandala turns slowly, one turn per 32 beats. Thin rays run along
/// every wedge edge and center (sixteen in all), a thick note bar rides
/// each wedge, and the colors cycle through the theme's gradient as the
/// rings expand, violet to magenta to cyan in the Aurora theme.
///
/// The music drives the lighting, not just the motion: each wedge owns one
/// octave-spaced slice of the 64-band spectrum (bass wedges answer low
/// notes, treble wedges high ones), so a note lights the wedge that carries
/// its pitch and the loudest band's wedge burns white-hot. Kicks pump the
/// mandala and flash the star, capped at the 3-per-second strobe limit so
/// fast kicks can't strobe the stage; snares flip the mirror by half a
/// wedge and throw the outlines white; hats glint the wedge tips.
struct KaleidoscopeVisualizerView: View {
    var spectrum: [CGFloat]
    var volume: CGFloat
    var theme: ColorTheme
    var sensitivity: Double
    var isActive: Bool = true
    var beat = BeatAnalysis()
    /// 0 keeps the volume-only look; 1 applies the full beat effects.
    var beatReactivity: Double = 0
    /// Kicks pump the mandala, snares flip the mirror, hats glint the tips.
    var drumReactivity = DrumReactivity.off

    @State private var system = KaleidoscopeSystem()

    /// Mirrored wedges around the center; sixteen rays with the centers.
    private static let sectors = 8
    /// Wedge rings in flight at once, spaced a third of a zoom cycle apart.
    private static let ringCount = 3

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
            let accents = KaleidoscopeDrumAccents(
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

    private func draw(in context: GraphicsContext, size: CGSize, frame: KaleidoscopeFrame, accents: KaleidoscopeDrumAccents, palette: ThemePalette) {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0 else { return }
        let s = size.visualizerScale
        let center = CGPoint(x: w / 2, y: h / 2)
        // The mandala is round: it fills the short side and bleeds off the
        // long one, like the clip, instead of stretching into an ellipse.
        let reach = hypot(w, h) / 2
        let sector = 2 * Double.pi / Double(Self.sectors)
        // Snares swing the mirror half a wedge over and back.
        let rotation = frame.rotation + accents.snare * sector / 2
        let pump = 1 + 0.06 * accents.kick + 0.04 * frame.flash
        let level = min(1.15, 0.30 + 0.45 * frame.energy + 0.30 * frame.bass + 0.45 * frame.flash)
        var glow = context
        glow.blendMode = .plusLighter

        drawHaze(in: glow, center: center, reach: reach, frame: frame, palette: palette)
        drawRays(in: glow, center: center, reach: reach, scale: s, rotation: rotation, sector: sector, frame: frame, level: level, palette: palette)
        for ring in 0..<Self.ringCount {
            drawRing(ring, in: glow, center: center, reach: reach, scale: s, rotation: rotation, sector: sector, pump: pump, frame: frame, accents: accents, palette: palette)
        }
        drawCenter(in: glow, center: center, reach: reach, scale: s, rotation: rotation, frame: frame, accents: accents, palette: palette)
    }

    /// Soft color wash behind the wedges, breathing with the bass the way
    /// the clip's purple and teal halos swell between its dark frames.
    private func drawHaze(in glow: GraphicsContext, center: CGPoint, reach: CGFloat, frame: KaleidoscopeFrame, palette: ThemePalette) {
        let radius = reach * CGFloat(0.55 + 0.2 * frame.bass)
        let color = palette.sample(frame.colorCycle).color
        glow.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: color.opacity(0.16 + 0.20 * frame.bass + 0.15 * frame.flash), location: 0),
                    .init(color: color.opacity(0.05), location: 0.55),
                    .init(color: .clear, location: 1),
                ]),
                center: center, startRadius: 0, endRadius: radius
            )
        )
    }

    /// Sixteen thin rays: one along each wedge boundary and one along each
    /// wedge center, white-hot at the core and fading into the haze. Their
    /// brightness follows the note energy of the wedges they separate.
    private func drawRays(in glow: GraphicsContext, center: CGPoint, reach: CGFloat, scale s: CGFloat, rotation: Double, sector: Double, frame: KaleidoscopeFrame, level: Double, palette: ThemePalette) {
        let inner = reach * 0.02
        for k in 0..<Self.sectors {
            let boundary = rotation + Double(k) * sector - sector / 2
            let mid = rotation + Double(k) * sector
            let energy = frame.wedgeEnergies[k]
            let color = palette.sample((Double(k) / Double(Self.sectors) + frame.colorCycle).truncatingRemainder(dividingBy: 1)).color
            let core = palette.sample(Double(k) / Double(Self.sectors)).towardWhite(0.55).color
            for (angle, brightness) in [(boundary, 0.55 + 0.45 * energy), (mid, 0.4 + 0.6 * energy)] {
                let end = CGPoint(x: center.x + CGFloat(cos(angle)) * reach * 1.05, y: center.y + CGFloat(sin(angle)) * reach * 1.05)
                let start = CGPoint(x: center.x + CGFloat(cos(angle)) * inner, y: center.y + CGFloat(sin(angle)) * inner)
                var ray = Path()
                ray.move(to: start)
                ray.addLine(to: end)
                func shading(_ c: Color, _ a: Double) -> GraphicsContext.Shading {
                    .linearGradient(Gradient(colors: [c.opacity(min(1, a)), c.opacity(min(1, a) * 0.10)]), startPoint: start, endPoint: end)
                }
                let alpha = min(1, level * brightness)
                glow.stroke(ray, with: shading(color, alpha * 0.10), lineWidth: 14 * s)
                glow.stroke(ray, with: shading(color, alpha * 0.32), lineWidth: 4 * s)
                glow.stroke(ray, with: shading(core, alpha * 0.85), lineWidth: 1.1 * s)
            }
        }
    }

    /// One expanding ring of eight mirrored wedges. Progress runs 0 at the
    /// center to 1 past the corners; the radius accelerates outward so the
    /// ring reads as flying at the viewer, and it fades in and out at the
    /// ends of the flight, as in the clip.
    private func drawRing(_ ring: Int, in glow: GraphicsContext, center: CGPoint, reach: CGFloat, scale s: CGFloat, rotation: Double, sector: Double, pump: Double, frame: KaleidoscopeFrame, accents: KaleidoscopeDrumAccents, palette: ThemePalette) {
        let progress = (frame.zoom + Double(ring) / Double(Self.ringCount)).truncatingRemainder(dividingBy: 1)
        let flight = pow(progress, 1.35)
        let outer = reach * CGFloat(1.18 * flight * pump)
        guard outer > 6 * s else { return }
        let inner = outer * 0.42
        let fade = pow(max(0, sin(.pi * min(1, progress * 1.04))), 1.2)
        guard fade > 0.02 else { return }
        // Fixed wedge widths; the note bars inside carry the energy.
        let halfInner = sector * 0.46
        let halfOuter = sector * 0.33

        for k in 0..<Self.sectors {
            let mid = rotation + Double(k) * sector
            let energy = frame.wedgeEnergies[k]
            let isPeak = k == frame.peakWedge
            let base = palette.sample((progress * 0.7 + Double(k) * 0.04 + frame.colorCycle).truncatingRemainder(dividingBy: 1))
            let rgb = accents.snare > 0.01 ? base.towardWhite(0.45 * accents.snare) : base
            let color = rgb.color
            let hot = rgb.towardWhite(isPeak ? 0.75 : 0.45).color
            let alpha = min(1, fade * (0.35 + 0.45 * frame.energy + 0.55 * energy + 0.4 * frame.flash))

            // Trapezoid outline with a clipped point, mirrored per wedge:
            // neighbors lean their bars opposite ways across the boundary.
            let outline = wedgePath(center: center, mid: mid, inner: inner, outer: outer, halfInner: halfInner, halfOuter: halfOuter)
            glow.stroke(outline, with: .color(color.opacity(alpha * 0.16)), lineWidth: 9 * s * CGFloat(0.4 + flight))
            glow.stroke(outline, with: .color(color.opacity(alpha * 0.85)), lineWidth: (1.1 + 1.3 * flight) * s)
            glow.stroke(outline, with: .color(hot.opacity(alpha * (isPeak ? 0.9 : 0.35))), lineWidth: 0.7 * s)

            // The note bar: a thick radial capsule whose reach and width
            // follow its wedge's band, slanted across the wedge center so
            // mirrored neighbors form the clip's chevrons.
            let slant = (k % 2 == 0 ? 1.0 : -1.0) * sector * 0.06
            let barStart = point(center: center, angle: mid - slant, radius: inner * 0.92)
            let barEndRadius = inner + (outer - inner) * CGFloat(0.55 + 0.45 * energy)
            let barEnd = point(center: center, angle: mid + slant, radius: barEndRadius)
            var bar = Path()
            bar.move(to: barStart)
            bar.addLine(to: barEnd)
            let barWidth = (4 + 11 * energy + 7 * flight) * s
            glow.stroke(bar, with: .linearGradient(Gradient(colors: [color.opacity(alpha * 0.22), color.opacity(alpha * 0.05)]), startPoint: barStart, endPoint: barEnd), lineWidth: barWidth * 2.6)
            glow.stroke(bar, with: .linearGradient(Gradient(colors: [hot.opacity(alpha), color.opacity(alpha * 0.75)]), startPoint: barStart, endPoint: barEnd), lineWidth: barWidth)
            glow.stroke(bar, with: .color(.white.opacity(alpha * (isPeak ? 0.95 : 0.55))), lineWidth: max(0.8 * s, barWidth * 0.22))

            // Hat glints: a fresh scatter of wedge tips sparkles per hit.
            if accents.hat > 0.02 && accents.hatHits.scatter(ring * Self.sectors + k) < 0.35 {
                let tip = point(center: center, angle: mid, radius: outer * 1.05)
                let r = (1.6 + 2.4 * accents.hat) * s
                glow.fill(Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(min(1, accents.hat * alpha + 0.2))))
            }
        }
    }

    /// The clip's signature: a small white star where every ray meets,
    /// swelling on kicks and on the rate-limited beat flash.
    private func drawCenter(in glow: GraphicsContext, center: CGPoint, reach: CGFloat, scale s: CGFloat, rotation: Double, frame: KaleidoscopeFrame, accents: KaleidoscopeDrumAccents, palette: ThemePalette) {
        let swell = 1 + 0.45 * frame.flash + 0.35 * accents.kick + 0.15 * frame.energy
        let outer = reach * CGFloat(0.075 * swell)
        let halo = outer * 3.2
        let color = palette.sample(frame.colorCycle).towardWhite(0.35).color
        glow.fill(
            Path(ellipseIn: CGRect(x: center.x - halo, y: center.y - halo, width: halo * 2, height: halo * 2)),
            with: .radialGradient(Gradient(colors: [color.opacity(0.35 + 0.3 * frame.flash), .clear]), center: center, startRadius: 0, endRadius: halo)
        )
        let star = starPath(center: center, outer: outer, inner: outer * 0.42, rotation: rotation)
        glow.stroke(star, with: .color(color.opacity(0.35)), lineWidth: 7 * s)
        glow.fill(star, with: .color(.white.opacity(min(1, 0.75 + 0.25 * frame.flash))))
        let core = outer * 0.30
        glow.fill(Path(ellipseIn: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2)), with: .color(.white))
    }

    private func point(center: CGPoint, angle: Double, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
    }

    /// Trapezoid with a shallow point on its outer edge, as in the clip.
    private func wedgePath(center: CGPoint, mid: Double, inner: CGFloat, outer: CGFloat, halfInner: Double, halfOuter: Double) -> Path {
        var path = Path()
        path.move(to: point(center: center, angle: mid - halfInner, radius: inner))
        path.addLine(to: point(center: center, angle: mid - halfOuter, radius: outer))
        path.addLine(to: point(center: center, angle: mid, radius: outer * 1.07))
        path.addLine(to: point(center: center, angle: mid + halfOuter, radius: outer))
        path.addLine(to: point(center: center, angle: mid + halfInner, radius: inner))
        path.closeSubpath()
        return path
    }

    private func starPath(center: CGPoint, outer: CGFloat, inner: CGFloat, rotation: Double) -> Path {
        var path = Path()
        let points = Self.sectors * 2
        for i in 0..<points {
            let angle = rotation + Double(i) * .pi / Double(Self.sectors)
            let radius = i % 2 == 0 ? outer : inner
            let p = point(center: center, angle: angle, radius: radius)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}

/// One frame's drum accents, already scaled by the reactivity, each 0-1.
private struct KaleidoscopeDrumAccents {
    var kick: Double
    var snare: Double
    var hat: Double
    /// Picks which wedge tips glint on the current hat.
    var hatHits: DrumHits
}

/// Immutable draw inputs for one frame, advanced by `KaleidoscopeSystem`.
private struct KaleidoscopeFrame {
    var rotation = 0.0
    /// Total zoom cycles; rings take the fractional part per ring offset.
    var zoom = 0.0
    /// Slow 0-1 cycle through the theme gradient.
    var colorCycle = 0.0
    var energy = 0.0
    /// Smoothed low band, 0-1.
    var bass = 0.0
    /// Rate-limited beat flash, already scaled by beat reactivity.
    var flash = 0.0
    /// Smoothed note energy per wedge, bass to treble around the mandala.
    var wedgeEnergies = [Double](repeating: 0, count: 8)
    /// Wedge carrying the loudest spectrum band right now.
    var peakWedge = 0
}

/// The mandala's motion and note state: beat-synced rotation and zoom,
/// smoothed per-wedge spectrum energies, a smoothed bass level and a beat
/// flash held to the strobe cap. A class so it can advance inside a
/// `TimelineView` update without invalidating SwiftUI state.
private final class KaleidoscopeSystem {
    private static let wedgeCount = 8
    /// One full turn every 32 beats once synced to the tempo.
    private static let rotationPerBeat = 2 * Double.pi / 32
    private static let flashDecay: TimeInterval = 0.15
    private static let bassAttack: TimeInterval = 0.04
    private static let bassRelease: TimeInterval = 0.4

    private let rotationPhase = BeatSyncedPhase()
    private let zoomPhase = BeatSyncedPhase()
    private var wedgeEnergies = [Double](repeating: 0, count: wedgeCount)
    private var bass = 0.0
    private var flashTime: TimeInterval = -.infinity
    private var flashStrength = 0.0
    private var lastBeatCount: Int?
    private var lastTime: TimeInterval?
    private var colorPhase = 0.0
    private var snapshot = KaleidoscopeFrame()

    func advance(to time: TimeInterval, now: TimeInterval, beat: BeatAnalysis, spectrum: [CGFloat], volume: Double, sensitivity: Double, beatReactivity: Double, isActive: Bool) -> KaleidoscopeFrame {
        // Clamped so resuming after a pause continues instead of jumping.
        let dt = lastTime.map { min(0.1, max(0, time - $0)) } ?? 1.0 / 60
        lastTime = time
        guard isActive, dt > 0 else { return snapshot }

        let energy = min(1, max(0, volume))
        let synced = beat.bpm > 0 ? beatReactivity : 0
        let rotation = rotationPhase.advance(
            to: time,
            wallRate: 0.10 + 0.14 * energy,
            gridPhase: beat.clock.beatPhase(at: now),
            gridRate: Self.rotationPerBeat,
            nominalGridSpeed: beat.clock.beatsPerSecond,
            reactivity: synced
        )
        // One full zoom cycle per bar: a ring is born at the center on the
        // downbeat and leaves past the corners by the next one.
        let zoom = zoomPhase.advance(
            to: time,
            wallRate: 0.08 + 0.22 * energy,
            gridPhase: beat.clock.barPhase(at: now),
            gridRate: 1,
            nominalGridSpeed: beat.clock.beatsPerSecond / 4,
            reactivity: synced
        )

        // Beat flash, accepting a new beat only past the strobe cap.
        if let lastBeatCount, beat.beatCount != lastBeatCount,
           beat.lastBeatTime - flashTime >= PerformanceState.strobeMinimumInterval {
            flashTime = beat.lastBeatTime
            flashStrength = Double(beat.beatStrength)
        }
        lastBeatCount = beat.beatCount
        let rawFlash = exp(-max(0, now - flashTime) / Self.flashDecay) * (0.4 + 0.6 * flashStrength)

        let bassTarget = Double(min(1, max(0, beat.bassEnvelope(at: now))))
        let tau = bassTarget > bass ? Self.bassAttack : Self.bassRelease
        bass += (bassTarget - bass) * (1 - exp(-dt / tau))

        // Notes: wedge k owns spectrum slice k, bass to treble, smoothed so
        // the bars swell instead of flickering; the loudest slice peaks.
        let spectrumGain = 0.6 + 0.4 * min(2.2, max(0.3, sensitivity))
        let follow = 1 - exp(-dt / 0.09)
        var peakWedge = snapshot.peakWedge
        var peakLevel = -1.0
        for k in 0..<Self.wedgeCount {
            let lower = k * spectrum.count / Self.wedgeCount
            let upper = max(lower + 1, (k + 1) * spectrum.count / Self.wedgeCount)
            var target = 0.0
            if !spectrum.isEmpty, upper > lower {
                var sum: CGFloat = 0
                for b in lower..<min(upper, spectrum.count) { sum += spectrum[b] }
                target = min(1, Double(sum) / Double(min(upper, spectrum.count) - lower) * spectrumGain * 1.6)
            }
            if target > peakLevel { peakLevel = target; peakWedge = k }
            wedgeEnergies[k] += (target - wedgeEnergies[k]) * follow
        }

        colorPhase += dt * (0.02 + 0.04 * energy + 0.06 * rawFlash)
        snapshot = KaleidoscopeFrame(
            rotation: rotation,
            zoom: zoom,
            colorCycle: colorPhase.truncatingRemainder(dividingBy: 1),
            energy: energy,
            bass: bass,
            flash: beatReactivity * rawFlash,
            wedgeEnergies: wedgeEnergies,
            peakWedge: peakWedge
        )
        return snapshot
    }
}

/// The theme's gradient as RGB for interpolation, skipping near-black stops
/// that would vanish on the dark stage. Shared by the Kaleidoscope and Particles modes.
struct ThemePalette {
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
    KaleidoscopeVisualizerView(spectrum: Array(repeating: 0.5, count: 64), volume: 0.6, theme: .aurora, sensitivity: 1.0)
        .frame(width: 500, height: 500)
        .background(Color.black)
}



