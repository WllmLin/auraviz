import SwiftUI

/// Beat-driven particle fountain: every beat fires a burst of sparks from the
/// center, sized by how hard the beat hit. Particles drift outward with drag,
/// take theme colors, and fade out; high-frequency energy makes them jitter
/// and twinkle. Kicks swell the glow at the core, every snare fires a crisp
/// ring of sparks and every hat makes a scatter of sparks glint. Between beats
/// a volume-driven shimmer keeps the mode alive.
struct ParticleVisualizerView: View {
    var spectrum: [CGFloat]
    var volume: CGFloat
    var theme: ColorTheme
    var sensitivity: Double
    var isActive: Bool = true
    var beat = BeatAnalysis()
    /// 0 keeps the volume-only look; 1 applies the full beat effects.
    var beatReactivity: Double = 0
    /// Kicks swell the core glow, snares fire spark rings, hats glint sparks.
    var drumReactivity = DrumReactivity.off

    @State private var system = ParticleSystem()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let now = BeatClock.time(for: timeline.date)
            let highEnergy = Self.highFrequencyEnergy(spectrum)
            let drums = drumReactivity.scaled(by: beatReactivity)
            // Bound to `_` so the `@ViewBuilder` closure still ends in the Canvas.
            let _ = system.advance(
                to: t,
                beat: beat,
                volume: Double(volume),
                sensitivity: sensitivity,
                beatReactivity: beatReactivity,
                snareReactivity: drums.snare,
                isActive: isActive
            )
            let flash = isActive ? beatReactivity * beat.flash(at: now) : 0
            let kick = isActive ? drums.kick * beat.kick.pulse(at: now) : 0
            let glint = isActive ? drums.hat * beat.hat.pulse(at: now) : 0
            let palette = theme.gradient
            Canvas { context, size in
                draw(in: context, size: size, time: t, highEnergy: highEnergy, flash: flash, kick: kick, glint: glint, palette: palette)
            }
        }
        .background(Color.clear)
    }

    private func draw(in context: GraphicsContext, size: CGSize, time t: Double, highEnergy: Double, flash: Double, kick: Double, glint: Double, palette: [Color]) {
        guard !palette.isEmpty else { return }
        let w = size.width
        let h = size.height
        let s = size.visualizerScale
        let center = CGPoint(x: w / 2, y: h / 2)
        var glow = context
        glow.blendMode = .plusLighter

        // Soft glow at the emission point, breathing with the volume and kicks.
        let energy = Double(min(1, max(0, volume)))
        let glowRadius = min(w, h) * 0.22 * (1 + 0.25 * flash + 0.3 * kick)
        if glowRadius > 1 {
            glow.fill(
                Path(ellipseIn: CGRect(x: center.x - glowRadius, y: center.y - glowRadius, width: glowRadius * 2, height: glowRadius * 2)),
                with: .radialGradient(
                    Gradient(colors: [palette[0].opacity(0.25 + 0.2 * energy + 0.3 * flash + 0.2 * kick), Color.clear]),
                    center: center, startRadius: 0, endRadius: glowRadius
                )
            )
        }

        // Sparkle displacement from the highs; deterministic per particle so it
        // jitters without any per-frame random state.
        let jitterAmp = min(1, highEnergy * 2) * 12 * s
        let count = system.aliveCount
        for i in 0..<count {
            let p = system.particles[i]
            let lifeFrac = max(0, 1 - p.age / p.life)
            let fade = lifeFrac * lifeFrac
            guard fade > 0.004 else { continue }
            let twinkle = 1 + min(1, highEnergy * 2) * 0.7 * sin(p.seed + t * 31)
            let jx = sin(p.seed * 1.71 + t * 23) * jitterAmp
            let jy = cos(p.seed * 2.13 + t * 19) * jitterAmp
            let r = max(0.4 * s, p.size * s * twinkle * (0.45 + 0.55 * lifeFrac))
            let rect = CGRect(
                x: center.x + CGFloat(p.x) * s + CGFloat(jx) - r,
                y: center.y + CGFloat(p.y) * s + CGFloat(jy) - r,
                width: r * 2, height: r * 2
            )
            glow.fill(Path(ellipseIn: rect), with: .color(palette[p.colorIndex % palette.count].opacity(min(1, fade))))
            // Fresh sparks get a white-hot core.
            if lifeFrac > 0.85 {
                let core = rect.insetBy(dx: r * 0.45, dy: r * 0.45)
                glow.fill(Path(ellipseIn: core), with: .color(.white.opacity(fade)))
            }
            // Each hat makes a fresh fifth of the sparks glint.
            if glint > 0.01 && beat.hat.scatter(p.id) < 0.2 {
                let flare = rect.insetBy(dx: -r * 0.6, dy: -r * 0.6)
                glow.fill(Path(ellipseIn: flare), with: .color(.white.opacity(min(1, glint * (0.3 + 0.7 * fade)))))
            }
        }
    }

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

/// One spark. Positions are offsets from the view center in unscaled points,
/// so a resize never strands or teleports live particles.
private struct Particle {
    var x: Double = 0
    var y: Double = 0
    var vx: Double = 0
    var vy: Double = 0
    var age: Double = 0
    var life: Double = 1
    var size: Double = 2
    var colorIndex: Int = 0
    var seed: Double = 0
    /// Spawn order, for picking which sparks a hat glints.
    var id: Int = 0
}

/// Fixed pool of particles with swap-remove packing: live particles occupy
/// `particles[0..<aliveCount]`. Spawning past capacity steals the slot under a
/// rotating cursor. A class so it can advance inside a `TimelineView` update
/// without invalidating SwiftUI state. All storage is preallocated; the
/// per-frame path never grows an array or touches the allocator.
private final class ParticleSystem {
    static let maxParticles = 2000
    /// Largest burst on the hardest beat at full reactivity.
    private static let maxBurst = 220
    /// Smallest beat burst, before reactivity scaling.
    private static let minBurst = 10
    /// Ambient sparks per second at full volume, between beats.
    private static let ambientRate = 90.0
    /// Velocity decay per second: v *= exp(-drag * dt).
    private static let drag = 1.8
    /// Sparks in a snare ring on the hardest hit at full reactivity.
    private static let maxRing = 72

    private(set) var particles = [Particle](repeating: Particle(), count: maxParticles)
    private(set) var aliveCount = 0

    private var lastTime: TimeInterval?
    private var lastBeatCount: Int?
    private var lastSnareCount: Int?
    private var nextID = 0
    private var stealCursor = 0
    private var ambientCarry = 0.0
    private var rngState: UInt64 = 0x1234_5678_9ABC_DEF1

    func advance(to time: TimeInterval, beat: BeatAnalysis, volume: Double, sensitivity: Double, beatReactivity: Double, snareReactivity: Double, isActive: Bool) {
        let dt: Double
        if let lastTime {
            // Clamped so resuming after a pause continues instead of jumping.
            dt = min(0.05, max(0, time - lastTime))
        } else {
            dt = 1.0 / 60
        }
        lastTime = time
        guard isActive else { return }

        integrate(dt: dt)

        if let lastBeatCount, beat.beatCount != lastBeatCount {
            let strength = Double(beat.beatStrength)
            let reactivityMix = 0.15 + 0.85 * beatReactivity
            let count = Int((Double(Self.minBurst) + Double(Self.maxBurst - Self.minBurst) * strength) * reactivityMix)
            spawnBurst(count: count, strength: strength, sensitivity: sensitivity, gentle: false)
        }
        lastBeatCount = beat.beatCount

        if let lastSnareCount, beat.snare.hitCount != lastSnareCount, snareReactivity > 0 {
            let strength = Double(beat.snare.strength)
            let count = Int(Double(Self.maxRing) * (0.4 + 0.6 * strength) * min(1, snareReactivity * 1.4))
            spawnRing(count: count, strength: strength, sensitivity: sensitivity)
        }
        lastSnareCount = beat.snare.hitCount

        ambientCarry += min(1, max(0, volume)) * Self.ambientRate * dt
        let ambient = Int(ambientCarry)
        if ambient > 0 {
            ambientCarry -= Double(ambient)
            spawnBurst(count: min(ambient, 12), strength: 0.15, sensitivity: sensitivity, gentle: true)
        }
    }

    private func integrate(dt: Double) {
        let decay = exp(-Self.drag * dt)
        var i = 0
        while i < aliveCount {
            particles[i].age += dt
            if particles[i].age >= particles[i].life {
                aliveCount -= 1
                particles[i] = particles[aliveCount]
            } else {
                particles[i].x += particles[i].vx * dt
                particles[i].y += particles[i].vy * dt
                particles[i].vx *= decay
                particles[i].vy *= decay
                i += 1
            }
        }
    }

    private func spawnBurst(count: Int, strength: Double, sensitivity: Double, gentle: Bool) {
        let speedScale = 0.6 + 0.4 * min(2.2, max(0.3, sensitivity))
        for _ in 0..<count {
            let slot = claimSlot()
            let angle = nextRandom() * 2 * .pi
            let radius = nextRandom() * 6
            let speed: Double
            if gentle {
                speed = (25 + 55 * nextRandom()) * speedScale
            } else {
                speed = (50 + 260 * nextRandom()) * (0.5 + strength) * speedScale
            }
            particles[slot] = Particle(
                x: cos(angle) * radius,
                y: sin(angle) * radius,
                vx: cos(angle) * speed,
                vy: sin(angle) * speed,
                age: 0,
                life: 1.2 + 1.6 * nextRandom(),
                size: (1.2 + 2.6 * nextRandom()) * (0.7 + 0.6 * strength),
                colorIndex: Int(nextRandom() * 4096),
                seed: nextRandom() * 1000,
                id: nextSparkID()
            )
        }
    }

    /// Evenly spaced sparks at one speed and color, so they read as a ring
    /// expanding from the center rather than a burst.
    private func spawnRing(count: Int, strength: Double, sensitivity: Double) {
        guard count > 0 else { return }
        let speed = (150 + 120 * strength) * (0.6 + 0.4 * min(2.2, max(0.3, sensitivity)))
        let offset = nextRandom() * 2 * .pi
        let colorIndex = Int(nextRandom() * 4096)
        for k in 0..<count {
            let slot = claimSlot()
            let angle = offset + Double(k) / Double(count) * 2 * .pi
            particles[slot] = Particle(
                x: cos(angle) * 4,
                y: sin(angle) * 4,
                vx: cos(angle) * speed,
                vy: sin(angle) * speed,
                age: 0,
                life: 0.9 + 0.3 * nextRandom(),
                size: 1.4 + 1.2 * strength,
                colorIndex: colorIndex,
                seed: nextRandom() * 1000,
                id: nextSparkID()
            )
        }
    }

    /// A free slot, or the one under the steal cursor once the pool is full.
    private func claimSlot() -> Int {
        if aliveCount < Self.maxParticles {
            aliveCount += 1
            return aliveCount - 1
        }
        let slot = stealCursor
        stealCursor += 1
        if stealCursor >= Self.maxParticles { stealCursor = 0 }
        return slot
    }

    private func nextSparkID() -> Int {
        nextID &+= 1
        return nextID
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
