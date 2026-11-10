import SwiftUI

/// Spiral particle galaxy: sparks stream outward from a glowing core along
/// three logarithmic spiral arms while the whole field turns slowly, locked to
/// the tempo once one is detected (a full turn every 32 beats). Colors run
/// along the theme gradient from the core to the rim, and every spark is drawn
/// as a short motion trail so the field reads as one flowing shape instead of
/// loose dots. A layer of slow star dust adds depth behind it.
///
/// The music shapes the field instead of scattering it: the spectrum swells
/// the arms by radius (bass near the core, highs at the rim), each beat sends
/// a bright shockwave out through the arms and surges the flow and spin,
/// kicks swell the core and breathe the whole galaxy, snares fire a crisp
/// white ring through the sparks, and hats glint a scatter of them.
struct ParticleVisualizerView: View {
    var spectrum: [CGFloat]
    var volume: CGFloat
    var theme: ColorTheme
    var sensitivity: Double
    var isActive: Bool = true
    var beat = BeatAnalysis()
    /// 0 keeps the volume-only look; 1 applies the full beat effects.
    var beatReactivity: Double = 0
    /// Kicks swell the core, snares fire a spark ring, hats glint sparks.
    var drumReactivity = DrumReactivity.off

    @State private var system = ParticleSystem()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let now = BeatClock.time(for: timeline.date)
            let drums = drumReactivity.scaled(by: beatReactivity)
            // Bound to `_` so the `@ViewBuilder` closure still ends in the Canvas.
            let _ = system.advance(
                to: t,
                now: now,
                beat: beat,
                spectrum: spectrum,
                volume: Double(volume),
                beatReactivity: beatReactivity,
                theme: theme,
                isActive: isActive
            )
            let highEnergy = Self.highFrequencyEnergy(spectrum)
            Canvas { context, size in
                draw(in: context, size: size, time: t, now: now, drums: drums, highEnergy: highEnergy)
            }
        }
        .background(Color.clear)
    }

    // MARK: - Drawing

    private static let brightnessLevels = 4
    private static let levelWidths: [CGFloat] = [0.9, 1.25, 1.7, 2.3]
    private static let levelOpacities: [Double] = [0.2, 0.42, 0.68, 0.95]
    /// Seconds of motion each spark's trail covers.
    private static let trailTime = 0.15

    private func draw(in context: GraphicsContext, size: CGSize, time t: Double, now: Double, drums: DrumReactivity, highEnergy: Double) {
        let colors = system.colors
        guard colors.count == ParticleSystem.colorSteps + 1, size.width > 0, size.height > 0 else { return }
        let w = size.width
        let h = size.height
        let s = size.visualizerScale
        let center = CGPoint(x: w / 2, y: h / 2)
        // Galaxy radius: the geometric mean of the sides, so it fills a
        // widescreen output sideways while the arms fade out before they clip.
        let unit = 0.5 * sqrt(w * h)
        var glow = context
        glow.blendMode = .plusLighter

        let energy = min(1, max(0, Double(volume)))
        let kick = isActive ? drums.kick * beat.kick.pulse(at: now) : 0
        let glint = isActive ? drums.hat * beat.hat.pulse(at: now) : 0
        let surge = isActive ? system.surge : 0
        let pump = 1 + 0.045 * kick
        let spectrumGain = 0.6 + 0.4 * min(2.2, max(0.3, sensitivity))

        // Beat shockwave: a bright band racing from the core to the rim.
        let beatAge = beat.beatAge(at: now)
        let waveRadius = beatAge / 0.6
        let waveAmp = isActive && beatAge < 1.2
            ? beatReactivity * exp(-beatAge / 0.45) * (0.4 + 0.6 * Double(beat.beatStrength))
            : 0
        // Snare crack: a thinner, faster, white-hot ring.
        let snareAge = beat.snare.hitAge(at: now)
        let snareRadius = 0.08 + snareAge / 0.45
        let snareAmp = isActive && snareAge < 1
            ? drums.snare * exp(-snareAge / 0.3) * (0.4 + 0.6 * Double(beat.snare.strength))
            : 0

        drawDust(in: glow, center: center, unit: unit, maxRadius: hypot(w, h) / 2 / unit, scale: s, time: t, energy: energy)

        // Core glow, breathing with the volume, beats and kicks.
        let coreRadius = unit * (0.3 + 0.08 * energy) * (1 + 0.35 * kick + 0.15 * surge)
        glow.fill(
            Path(ellipseIn: CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: system.coreColor.opacity(0.26 + 0.2 * energy + 0.25 * kick), location: 0),
                    .init(color: system.coreColor.opacity(0.07 + 0.05 * kick), location: 0.45),
                    .init(color: .clear, location: 1)
                ]),
                center: center, startRadius: 0, endRadius: coreRadius
            )
        )
        let hotRadius = unit * 0.06 * (1 + 0.6 * kick)
        glow.fill(
            Path(ellipseIn: CGRect(x: center.x - hotRadius, y: center.y - hotRadius, width: hotRadius * 2, height: hotRadius * 2)),
            with: .radialGradient(
                Gradient(colors: [.white.opacity(0.55 + 0.35 * kick + 0.1 * energy), .clear]),
                center: center, startRadius: 0, endRadius: hotRadius
            )
        )

        // Sparks, batched into one path per color step and brightness level so
        // the whole field is a few dozen strokes instead of one per spark.
        let levels = Self.brightnessLevels
        let colorSteps = ParticleSystem.colorSteps
        var paths = [Path](repeating: Path(), count: (colorSteps + 1) * levels)
        var glints = Path()
        let flowStep = system.flowRate * Self.trailTime
        let spinStep = system.spinRate * Self.trailTime
        let armStep = 2 * Double.pi / Double(ParticleSystem.arms)
        let inner = ParticleSystem.innerRadius
        let twist = ParticleSystem.twist
        let glintRadius = 1.8 * s

        for i in system.particles.indices {
            let p = system.particles[i]
            let fadeIn = min(1, p.u / 0.06)
            let fade = fadeIn * fadeIn * pow(1 - p.u, 1.15)
            guard fade > 0.01 else { continue }

            let r = inner + (1 - inner) * p.u
            let swell = 1 + 0.16 * spectrumGain * system.profile(at: r)
            let wave = waveAmp > 0.001 ? waveAmp * exp(-Self.square((r - waveRadius) / 0.08)) : 0
            let crack = snareAmp > 0.001 ? snareAmp * exp(-Self.square((r - snareRadius) / 0.045)) : 0

            let radius = (r * swell + 0.05 * wave + 0.025 * crack) * pump
            // Arms trail behind the spin; the lane spreads each arm wider
            // toward the rim.
            let angle = Double(p.arm) * armStep + system.spin - twist * r + p.lane * (0.1 + 0.32 * r)
            let tailR = inner + (1 - inner) * max(0, p.u - flowStep * p.speed)
            let tailRadius = radius - (r - tailR) * swell * pump
            let tailAngle = angle - spinStep + twist * (r - tailR)

            let twinkle = 1 + 0.3 * highEnergy * sin(p.seed + t * 7)
            let base = fade * p.gain * (0.42 + 0.5 * energy) * twinkle
            let brightness = min(1, base + (0.9 * wave + 0.85 * crack) * fadeIn)
            guard brightness > 0.04 else { continue }

            let level = min(levels - 1, Int(brightness * Double(levels)))
            let colorIndex: Int
            if crack > 0.35 {
                colorIndex = colorSteps
            } else {
                let u = min(1, max(0, r * 0.95 + p.lane * 0.06))
                colorIndex = min(colorSteps - 1, Int(u * Double(colorSteps)))
            }
            let head = CGPoint(x: center.x + CGFloat(cos(angle) * radius) * unit,
                               y: center.y + CGFloat(sin(angle) * radius) * unit)
            let tail = CGPoint(x: center.x + CGFloat(cos(tailAngle) * tailRadius) * unit,
                               y: center.y + CGFloat(sin(tailAngle) * tailRadius) * unit)
            paths[colorIndex * levels + level].move(to: tail)
            paths[colorIndex * levels + level].addLine(to: head)

            // Each hat makes a fresh scatter of sparks glint.
            if glint > 0.02 && fade > 0.15 && beat.hat.scatter(i) < 0.12 {
                glints.addEllipse(in: CGRect(x: head.x - glintRadius, y: head.y - glintRadius, width: glintRadius * 2, height: glintRadius * 2))
            }
        }

        for c in 0...colorSteps {
            for level in 0..<levels {
                let path = paths[c * levels + level]
                guard !path.isEmpty else { continue }
                glow.stroke(path, with: .color(colors[c].opacity(Self.levelOpacities[level])),
                            style: StrokeStyle(lineWidth: Self.levelWidths[level] * s, lineCap: .round))
                // Soft bloom around the brightest sparks.
                if level == levels - 1 {
                    glow.stroke(path, with: .color(colors[c].opacity(0.14)),
                                style: StrokeStyle(lineWidth: 6 * s, lineCap: .round))
                }
            }
        }

        if snareAmp > 0.01 && snareRadius < 1.1 {
            let ringRadius = CGFloat(snareRadius * pump) * unit
            glow.stroke(
                Path(ellipseIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)),
                with: .color(colors[colorSteps].opacity(0.35 * snareAmp * (1 - snareRadius / 1.1))),
                lineWidth: 1.2 * s
            )
        }

        if !glints.isEmpty {
            glow.fill(glints, with: .color(.white.opacity(min(1, glint))))
        }
    }

    /// Faint star dust turning slower than the arms, nearer motes faster, for
    /// parallax depth. Two paths so the motes can twinkle slowly.
    private func drawDust(in glow: GraphicsContext, center: CGPoint, unit: CGFloat, maxRadius: CGFloat, scale s: CGFloat, time t: Double, energy: Double) {
        var dim = Path()
        var bright = Path()
        for d in system.dust {
            let angle = d.angle + system.spin * 0.3 * d.depth
            let radius = CGFloat(d.radius) * maxRadius * unit
            let x = center.x + CGFloat(cos(angle)) * radius
            let y = center.y + CGFloat(sin(angle)) * radius
            let r = CGFloat(0.5 + 0.6 * d.depth) * s
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            if sin(d.seed + t * 1.1) > 0.3 {
                bright.addEllipse(in: rect)
            } else {
                dim.addEllipse(in: rect)
            }
        }
        glow.fill(dim, with: .color(system.dustColor.opacity(0.16 + 0.1 * energy)))
        glow.fill(bright, with: .color(system.dustColor.opacity(0.38 + 0.2 * energy)))
    }

    private static func square(_ x: Double) -> Double { x * x }

    /// Mean level of the upper half of the spectrum, matching the wave view's
    /// "high" region. Read-only over the slice; allocates nothing.
    private static func highFrequencyEnergy(_ spectrum: [CGFloat]) -> Double {
        guard spectrum.count > 32 else { return 0 }
        let hi = spectrum[32...]
        var sum: CGFloat = 0
        for v in hi { sum += v }
        return min(1, Double(sum / CGFloat(hi.count)) * 2)
    }
}

/// One spark streaming out along a spiral arm.
private struct Particle {
    var arm = 0
    /// Progress from the core (0) to the rim (1).
    var u = 0.0
    /// Offset across the arm, -1...1, concentrated near the arm's spine.
    var lane = 0.0
    /// Flow speed multiplier.
    var speed = 1.0
    /// Brightness multiplier, for variety within the arm.
    var gain = 1.0
    var seed = 0.0
}

/// One background mote. Radius is a fraction of the stage's half-diagonal.
private struct Dust {
    var radius = 0.0
    var angle = 0.0
    /// 0.4...1; nearer motes turn faster and draw larger.
    var depth = 1.0
    var seed = 0.0
}

/// The galaxy's state: a fixed set of sparks whose flow progress, spin and
/// smoothed spectrum profile advance each frame. A class so it can advance
/// inside a `TimelineView` update without invalidating SwiftUI state. All
/// storage is preallocated; the per-frame path never grows an array.
private final class ParticleSystem {
    static let streamCount = 1200
    static let dustCount = 240
    static let arms = 3
    /// Radians the arms wind from the core to the rim.
    static let twist = 2.4
    static let innerRadius = 0.035
    /// Theme gradient steps for the sparks; one extra white-hot color follows.
    static let colorSteps = 8
    private static let profileCount = 24
    /// Flow progress per second at rest: a spark takes ~14 s to cross.
    private static let baseFlow = 0.07
    /// One full turn every 32 beats once synced to the tempo.
    private static let spinPerBeat = 2 * Double.pi / 32

    private(set) var particles: [Particle]
    private(set) var dust: [Dust]
    private var profileValues = [Double](repeating: 0, count: profileCount)

    private(set) var spin = 0.0
    /// Radians per second over the last frame, for the trail length.
    private(set) var spinRate = 0.0
    /// Flow progress per second over the last frame, before each spark's speed.
    private(set) var flowRate = baseFlow
    /// 0-1 beat surge, scaled by the beat reactivity.
    private(set) var surge = 0.0

    private(set) var colors: [Color] = []
    private(set) var coreColor = Color.white
    private(set) var dustColor = Color.white
    private var paletteTheme: ColorTheme?

    private let spinPhase = BeatSyncedPhase()
    private var extraSpin = 0.0
    private var hasSpin = false
    private var lastTime: TimeInterval?
    private var rngState: UInt64 = 0x1234_5678_9ABC_DEF1

    init() {
        particles = [Particle](repeating: Particle(), count: Self.streamCount)
        dust = [Dust](repeating: Dust(), count: Self.dustCount)
        for i in particles.indices {
            particles[i] = makeParticle(arm: i % Self.arms, u: nextRandom())
        }
        for i in dust.indices {
            dust[i] = Dust(
                radius: 0.05 + 0.95 * sqrt(nextRandom()),
                angle: nextRandom() * 2 * .pi,
                depth: 0.4 + 0.6 * nextRandom(),
                seed: nextRandom() * 100
            )
        }
    }

    func advance(to time: TimeInterval, now: TimeInterval, beat: BeatAnalysis, spectrum: [CGFloat], volume: Double, beatReactivity: Double, theme: ColorTheme, isActive: Bool) {
        updatePalette(theme)
        let dt: Double
        if let lastTime {
            // Clamped so resuming after a pause continues instead of jumping.
            dt = min(0.05, max(0, time - lastTime))
        } else {
            dt = 1.0 / 60
        }
        lastTime = time
        guard isActive, dt > 0 else { return }

        let energy = min(1, max(0, volume))
        surge = beatReactivity * exp(-beat.beatAge(at: now) / 0.35) * (0.4 + 0.6 * Double(beat.beatStrength))
        flowRate = Self.baseFlow * (0.6 + 0.8 * energy) * (1 + 2 * surge)

        let base = spinPhase.advance(
            to: time,
            wallRate: 0.12 + 0.18 * energy,
            gridPhase: beat.clock.beatPhase(at: now),
            gridRate: Self.spinPerBeat,
            nominalGridSpeed: beat.clock.beatsPerSecond,
            reactivity: beat.bpm > 0 ? beatReactivity : 0
        )
        // Each beat gives the spin a little extra push.
        extraSpin += 0.9 * surge * dt
        let next = base + extraSpin
        spinRate = hasSpin ? min(3, max(0, (next - spin) / dt)) : 0.15
        spin = next
        hasSpin = true

        // Smoothed so the arms swell instead of flicker.
        let follow = 1 - exp(-dt / 0.09)
        let bins = min(spectrum.count, 48)
        for k in 0..<Self.profileCount {
            var target = 0.0
            let lower = k * bins / Self.profileCount
            let upper = min(spectrum.count, max(lower + 1, (k + 1) * bins / Self.profileCount))
            if upper > lower {
                var sum: CGFloat = 0
                for b in lower..<upper { sum += spectrum[b] }
                target = min(1.5, Double(sum) / Double(upper - lower))
            }
            profileValues[k] += (target - profileValues[k]) * follow
        }

        for i in particles.indices {
            particles[i].u += flowRate * particles[i].speed * dt
            if particles[i].u >= 1 {
                particles[i] = makeParticle(arm: particles[i].arm, u: particles[i].u.truncatingRemainder(dividingBy: 1))
            }
        }
    }

    /// The smoothed spectrum level at galaxy radius `r` in 0...1: bass at the
    /// core, highs at the rim.
    func profile(at r: Double) -> Double {
        let position = min(1, max(0, r)) * Double(Self.profileCount - 1)
        let lower = min(Self.profileCount - 2, Int(position))
        let f = position - Double(lower)
        return profileValues[lower] * (1 - f) + profileValues[lower + 1] * f
    }

    private func makeParticle(arm: Int, u: Double) -> Particle {
        // Sum of three uniforms: most sparks hug the arm's spine; one in five
        // strays wide to haze the gaps between the arms.
        var lane = (nextRandom() + nextRandom() + nextRandom() - 1.5) / 1.5
        if nextRandom() < 0.2 { lane *= 3 }
        return Particle(
            arm: arm,
            u: u,
            lane: lane,
            speed: 0.8 + 0.4 * nextRandom(),
            gain: 0.6 + 0.6 * nextRandom(),
            seed: nextRandom() * 100
        )
    }

    private func updatePalette(_ theme: ColorTheme) {
        guard theme != paletteTheme else { return }
        paletteTheme = theme
        let palette = ThemePalette(theme: theme)
        colors = (0..<Self.colorSteps).map { palette.sample(Double($0) / Double(Self.colorSteps - 1)).color }
        colors.append(palette.sample(0.5).towardWhite(0.75).color)
        coreColor = palette.sample(0).color
        dustColor = palette.sample(0.6).towardWhite(0.5).color
    }

    /// xorshift64* — cheap deterministic randoms with no shared-state locking.
    private func nextRandom() -> Double {
        var x = rngState
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        rngState = x
        return Double((x &* 0x2545_F491_4F6C_DD1D) >> 11) / Double(1 << 53)
    }
}

#Preview {
    ParticleVisualizerView(spectrum: Array(repeating: 0.5, count: 64), volume: 0.6, theme: .aurora, sensitivity: 1.0)
        .frame(width: 500, height: 500)
        .background(Color.black)
}
