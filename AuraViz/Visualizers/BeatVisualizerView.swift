import SwiftUI

/// Beat mode: the stage is just the chosen background image, filling the
/// screen — either keeping its proportions (cropped to cover) or stretched to
/// the stage's exact shape, per `fit`. Each beat shakes the image, a sharp
/// damped jolt in a new direction with a small twist and zoom punch. It also floods the image
/// with the next of the theme's colors, which keeps the picture's light and
/// dark but takes the color's hue, then fades back to the original picture.
/// Hits keep to the 3-per-second strobe cap like the other modes' flashes.
///
/// Kicks add their own shake on top, snares brighten the color flood and hats
/// add a fine jitter. Sustained bass — a drop's long sub notes, which barely
/// register as transients — also drives the look directly: while the smoothed
/// bass level stays high the image holds a trembling push-in and keeps the
/// color flooded, instead of sitting still between hits. Under all of that
/// the slow `DriftCamera` keeps the picture breathing, zooming and wandering
/// gently on its own. At 0 beat reactivity the image takes no hits, only
/// that drift and a faint volume-driven tint. Without
/// an image the stage shows a dark wash of the theme colors, so the shake and
/// color still read.
struct BeatVisualizerView: View {
    /// The background picture; nil until one is chosen.
    var image: CGImage?
    /// Keep the picture's proportions (cropping the overhang) or stretch it.
    var fit: BeatBackgroundFit = .fill
    var volume: CGFloat
    var theme: ColorTheme
    var isActive: Bool = true
    var beat = BeatAnalysis()
    /// 0 keeps the volume-only look; 1 applies the full beat effects.
    var beatReactivity: Double = 0
    /// Kicks add shake, snares brighten the flood, hats jitter.
    var drumReactivity = DrumReactivity.off

    /// Shared so every stage layer, in the preview and the output, shakes
    /// and recolors together, and a crossfade doesn't show two images.
    private static let hits = BeatHits()
    private static let bass = BassFollower()

    var body: some View {
        // Near-black stops would turn the picture black, so they're skipped.
        let colors = theme.colors(brighterThan: 0.12)
        let backdrop = theme.orbColors
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive)) { timeline in
            let now = BeatClock.time(for: timeline.date)
            let hit = Self.hits.latest(in: beat)
            let bassLevel = Self.bass.advance(to: now, target: isActive ? Double(beat.bassEnvelope(at: now)) : 0)
            let look = BeatLook(
                now: now,
                hit: hit,
                beat: beat,
                bassLevel: bassLevel,
                volume: Double(volume),
                beatReactivity: beatReactivity,
                drums: drumReactivity.scaled(by: beatReactivity),
                isActive: isActive
            )
            let camera = DriftCamera.pose(at: now, isActive: isActive)
            GeometryReader { proxy in
                let size = proxy.size
                let short = max(1, min(size.width, size.height))
                let aspect = max(size.width, size.height) / short
                let color = colors.isEmpty ? Color.white : colors[look.colorIndex % colors.count]
                ZStack {
                    // The slow drift camera inside the shake: drifted, the
                    // picture still covers the stage, so the shake's cover
                    // zoom keeps hiding the edges on top of it.
                    picture(size: size, backdrop: backdrop)
                        .driftCamera(camera)
                        .scaleEffect(look.coverScale(aspect: aspect))
                        .rotationEffect(.radians(look.rotation))
                        .offset(x: look.offset.width * short, y: look.offset.height * short)
                    // Hue and saturation from the theme color, light and dark
                    // from the picture.
                    Rectangle()
                        .fill(color.opacity(BeatLook.maximumTint * look.tint))
                        .blendMode(.color)
                    // Lifts the shadows too, so a dark image still turns the color.
                    Rectangle()
                        .fill(color.opacity(look.glow))
                        .blendMode(.screen)
                }
                .frame(width: size.width, height: size.height)
                // Keeps the tint blends inside the image, not on what's behind it.
                .compositingGroup()
                .clipped()
            }
        }
        .allowsHitTesting(false)
        // The background control already names the image.
        .accessibilityHidden(true)
    }

    /// The image filling the stage, or a dark theme wash until one is chosen.
    /// Either way its rect at rest is at least the stage, so the cover zoom
    /// hides the edges through the shake.
    @ViewBuilder
    private func picture(size: CGSize, backdrop: [Color]) -> some View {
        if let image {
            let resizable = Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
            switch fit {
            case .fill:
                // Keeps the proportions; the overhang is clipped by the stage.
                resizable
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
            case .stretch:
                // Exactly the stage's shape, so nothing is cropped.
                resizable
                    .frame(width: size.width, height: size.height)
            }
        } else {
            LinearGradient(colors: backdrop.isEmpty ? [.gray] : backdrop, startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(0.35)
                .background(Color.black)
                .frame(width: size.width, height: size.height)
        }
    }
}

/// The latest beat hit as Beat mode sees it.
struct BeatHit {
    var time: TimeInterval = -.infinity
    /// 0.1-1, how hard the beat hit.
    var strength = 0.0
    /// Counts accepted hits; picks the shake direction and the color.
    var index = 0
}

/// Beats accepted for Beat mode, held to the strobe cap. A class so it can
/// advance inside a `TimelineView` update without invalidating SwiftUI state;
/// reading the same analysis twice (several layers per frame) changes nothing.
private final class BeatHits {
    private var hit = BeatHit()
    private var lastBeatCount: Int?

    func latest(in beat: BeatAnalysis) -> BeatHit {
        if let lastBeatCount, beat.beatCount != lastBeatCount,
           beat.lastBeatTime - hit.time >= PerformanceState.strobeMinimumInterval {
            hit = BeatHit(time: beat.lastBeatTime, strength: Double(beat.beatStrength), index: hit.index &+ 1)
        }
        lastBeatCount = beat.beatCount
        return hit
    }
}

/// Smoothed bass level for the drop drive: fast in when a drop lands, slow
/// out, so the held color flood ripples between kicks instead of flashing at
/// the beat rate (see `PerformanceState.strobeMinimumInterval`). A class so
/// it can advance inside a `TimelineView` update without invalidating SwiftUI
/// state; several layers advancing in the same frame see dt ≈ 0.
private final class BassFollower {
    private static let attackTime: TimeInterval = 0.05
    private static let releaseTime: TimeInterval = 0.45

    private var level = 0.0
    private var lastTime: TimeInterval?

    func advance(to now: TimeInterval, target raw: Double) -> Double {
        defer { lastTime = now }
        guard let lastTime else { return level }
        let target = min(1, max(0, raw.isFinite ? raw : 0))
        // Clamped so resuming after a pause continues instead of jumping.
        let dt = min(0.1, max(0, now - lastTime))
        let tau = target > level ? Self.attackTime : Self.releaseTime
        level += (target - level) * (1 - exp(-dt / tau))
        return level
    }
}

/// How the image sits at one moment: its shake, twist and zoom, and how far
/// it has turned which theme color.
struct BeatLook {
    /// Most the shake moves the image, as a fraction of the stage's shorter side.
    static let maximumShake = 0.055
    /// Most the shake twists the image, in radians (about 1.5°).
    static let maximumRotation = 0.026
    /// Extra zoom on a full-strength beat, on top of what covers the shake.
    static let maximumPunch = 0.08
    /// Opacity of the color flood at the peak of a beat.
    static let maximumTint = 0.85
    /// How fast the shake dies away and how fast it shudders.
    static let shakeDecay: TimeInterval = 0.24
    static let shakeFrequency = 11.0
    /// The color holds at full briefly, then fades back to the picture.
    static let tintHold: TimeInterval = 0.08
    static let tintDecay: TimeInterval = 0.45
    /// Smoothed bass below this counts as quiet, so breakdowns stay still.
    static let bassGate = 0.15
    /// Tremor amplitude at full sustained bass, in beat-shake units.
    static let bassWeight = 0.65

    /// Shift as a fraction of the stage's shorter side.
    var offset = CGSize.zero
    var rotation = 0.0
    /// Bound on the shake's size, 0 at rest; sets the cover zoom.
    var shakeBound = 0.0
    var punch = 0.0
    /// 0-1, how far the image has turned the color.
    var tint = 0.0
    /// Opacity of the screen-blended lift.
    var glow = 0.0
    /// Which theme color the image turns.
    var colorIndex = 0

    init(now: TimeInterval, hit: BeatHit, beat: BeatAnalysis, bassLevel: Double, volume: Double, beatReactivity: Double, drums: DrumReactivity, isActive: Bool) {
        // At rest, the plain picture, while audio is stopped.
        guard isActive else { return }
        let reactivity = min(1, max(0, beatReactivity))
        let strength = 0.3 + 0.7 * hit.strength
        let beatAge = max(0, now - hit.time)
        let beatShake = reactivity * strength * exp(-beatAge / Self.shakeDecay)
        let kickAge = beat.kick.hitAge(at: now)
        let kickShake = 0.85 * drums.kick * beat.kick.pulse(at: now)
        let hatJitter = drums.hat * beat.hat.pulse(at: now)

        // Sustained bass: a gated, contrast-expanded read of the smoothed
        // bass level. It holds a trembling push-in and keeps the color
        // flooded for as long as a drop's sub lasts, between and beyond the
        // transient hits above. The kick envelope feeds the tremor only —
        // motion, not light — so rolling kicks still shake the picture
        // while the smoothed level is steady.
        let gatedBass = max(0, (min(1, max(0, bassLevel.isFinite ? bassLevel : 0)) - Self.bassGate) / (1 - Self.bassGate))
        let bassOnly = pow(gatedBass, 1.35)
        let drop = reactivity * bassOnly
        let kickLevel = min(1, max(0, Double(beat.kick.envelope(at: now))))
        let dropShake = Self.bassWeight * max(drop, 0.85 * drums.kick * pow(kickLevel, 1.2))

        // Before the first hit the age is infinite and cos(∞) is NaN, which
        // even a zero amplitude wouldn't cancel, so a spent shake is skipped.
        let still = (x: 0.0, y: 0.0, twist: 0.0)
        let a = beatShake > 1e-4 ? Self.shake(age: beatAge, seed: hit.index) : still
        let k = kickShake > 1e-4 ? Self.shake(age: kickAge, seed: beat.kick.hitCount &+ 7919) : still
        // The tremor runs on frame time, re-aimed by each beat, so it keeps
        // shuddering through a held sub note with no new transients.
        let b = dropShake > 1e-4 ? Self.shake(age: now, seed: beat.beatCount &+ 31_337) : still
        let jitterX = 0.15 * hatJitter * (2 * beat.hat.scatter(0) - 1)
        let jitterY = 0.15 * hatJitter * (2 * beat.hat.scatter(1) - 1)
        offset = CGSize(
            width: Self.maximumShake * (beatShake * a.x + kickShake * k.x + dropShake * b.x + jitterX),
            height: Self.maximumShake * (beatShake * a.y + kickShake * k.y + dropShake * b.y + jitterY)
        )
        rotation = Self.maximumRotation * (beatShake * a.twist + kickShake * k.twist + dropShake * b.twist)
        shakeBound = beatShake + kickShake + dropShake + 0.15 * hatJitter
        punch = Self.maximumPunch * (beatShake + 0.5 * kickShake + 0.9 * drop)

        let envelope = beatAge < Self.tintHold ? 1 : exp(-(beatAge - Self.tintHold) / Self.tintDecay)
        let calmTint = 0.3 * min(1, max(0, volume))
        let beatTint = strength * envelope
        let reactiveTint = min(1, max(beatTint, bassOnly))
        tint = min(1, (1 - reactivity) * calmTint + reactivity * reactiveTint)
        let snareFlash = drums.snare * beat.snare.pulse(at: now)
        glow = min(0.65, 0.35 * tint + 0.35 * snareFlash + 0.2 * drop)
        colorIndex = reactivity > 0 ? hit.index : 0
    }

    /// The zoom that keeps the image covering a stage `aspect` times as long
    /// as it is short through the whole shake, plus the beat punch. The image
    /// already covers the stage at rest, so it is 1 when still. A twist of θ
    /// needs `1 + aspect·sin θ`, a shift of d (in short sides) needs `2d`.
    func coverScale(aspect: CGFloat) -> CGFloat {
        let twist = CGFloat(sin(Self.maximumRotation * shakeBound)) * aspect
        let shift = CGFloat(2 * Self.maximumShake * 1.35 * shakeBound)
        return 1 + twist + shift + CGFloat(punch)
    }

    /// A unit shake `age` seconds after a hit: an instant jolt along the
    /// hit's own direction that shudders back, with a little cross-wobble so
    /// it doesn't read as a straight line. Each component stays within ±1.35.
    static func shake(age: TimeInterval, seed: Int) -> (x: Double, y: Double, twist: Double) {
        let angle = 2 * .pi * hash(seed, 1)
        let phaseX = 2 * .pi * hash(seed, 2)
        let phaseY = 2 * .pi * hash(seed, 3)
        let phaseTwist = 2 * .pi * hash(seed, 4)
        let jolt = cos(2 * .pi * shakeFrequency * age)
        return (
            x: cos(angle) * jolt + 0.35 * sin(2 * .pi * 17 * age + phaseX),
            y: sin(angle) * jolt + 0.35 * sin(2 * .pi * 13 * age + phaseY),
            twist: sin(2 * .pi * 7 * age + phaseTwist)
        )
    }

    /// A stable pseudo-random 0..<1 for feature `salt` of hit `seed`.
    static func hash(_ seed: Int, _ salt: Int) -> Double {
        var x = (UInt64(bitPattern: Int64(seed)) &* 0x9E37_79B9_7F4A_7C15) ^ (UInt64(bitPattern: Int64(salt)) &* 0xBF58_476D_1CE4_E5B9)
        x ^= x >> 31
        x = x &* 0x94D0_49BB_1331_11EB
        x ^= x >> 29
        return Double(x >> 11) / Double(1 << 53)
    }
}

#Preview {
    BeatVisualizerView(image: nil, volume: 0.6, theme: .cyberpunk)
        .frame(width: 500, height: 500)
        .background(Color.black)
}
