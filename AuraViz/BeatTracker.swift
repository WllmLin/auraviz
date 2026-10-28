import CoreGraphics
import Foundation

/// The tempo grid as of the last analysis. Phase is extrapolated from the
/// anchor so visuals can animate at display rate between audio frames.
/// Times use `ProcessInfo.systemUptime` seconds (see `BeatClock.now`).
struct BeatClock {
    var anchorTime: TimeInterval = 0
    var anchorPhase: Double = 0
    var beatsPerSecond: Double = 2

    /// Continuously increasing beat count; 1.0 = one beat.
    func beatPhase(at time: TimeInterval) -> Double {
        anchorPhase + max(0, time - anchorTime) * beatsPerSecond
    }

    /// Continuously increasing bar count; 1.0 = four beats.
    func barPhase(at time: TimeInterval) -> Double {
        beatPhase(at: time) / 4
    }

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Converts a `TimelineView` date to the clock's time base.
    static func time(for date: Date) -> TimeInterval {
        now + date.timeIntervalSinceNow
    }
}

/// Drum voices, told apart by the band their transient lands in.
enum DrumInstrument: String, CaseIterable, Identifiable, Codable {
    case kick = "Kick"
    case snare = "Snare"
    case hat = "Hat"

    var id: String { rawValue }

    /// Analysis band in Hz: the kick's low thump, the snare's mid crack (body
    /// overtones, stick and wires) and the hat's high sizzle.
    var band: ClosedRange<Double> {
        switch self {
        case .kick: return 40...150
        case .snare: return 250...5_000
        case .hat: return 6_000...16_000
        }
    }

    /// Shortest gap between two detected hits.
    var minimumInterval: TimeInterval {
        switch self {
        case .kick, .snare: return 0.1
        // Room for 16ths at 175 BPM.
        case .hat: return 0.06
        }
    }

    /// Decay of the hit pulse and the activity envelope.
    var releaseTime: TimeInterval {
        switch self {
        case .kick: return 0.15
        case .snare: return 0.12
        case .hat: return 0.07
        }
    }

    var icon: String {
        switch self {
        case .kick: return "circle.circle.fill"
        case .snare: return "burst.fill"
        case .hat: return "sparkle"
        }
    }

    var character: String {
        switch self {
        case .kick: return "low thump"
        case .snare: return "mid crack"
        case .hat: return "high sizzle"
        }
    }
}

/// One drum voice as of the last analysis. Like the beat, hits are counted so
/// views that animate between published frames can watch `hitCount` and
/// `lastHitTime` without missing one.
struct DrumHits {
    var instrument: DrumInstrument
    var hitCount = 0
    var lastHitTime: TimeInterval = -.infinity
    /// 0.1-1, how far the last hit rose above the band's recent flux.
    var strength: CGFloat = 0
    /// Transient activity in the band relative to its recent peak, 0-1:
    /// instant attack, exponential release. Follows open hats and rolls that
    /// don't separate into hits.
    var envelope: CGFloat = 0
    var analysisTime: TimeInterval = 0

    /// The envelope decayed to `time`, for animating between analyses.
    func envelope(at time: TimeInterval) -> CGFloat {
        envelope * CGFloat(exp(-max(0, time - analysisTime) / instrument.releaseTime))
    }

    /// Seconds since the last hit; infinite before the first one.
    func hitAge(at time: TimeInterval) -> TimeInterval {
        max(0, time - lastHitTime)
    }

    /// 0-1 pulse on each hit, decaying over the voice's release time and
    /// scaled by how hard it hit.
    func pulse(at time: TimeInterval) -> Double {
        exp(-hitAge(at: time) / instrument.releaseTime) * (0.4 + 0.6 * Double(strength))
    }

    /// A stable pseudo-random 0..<1 for element `index` that changes with every
    /// hit, so each hit can light a different scatter of elements.
    func scatter(_ index: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15
            ^ UInt64(truncatingIfNeeded: hitCount) &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 31
        x = x &* 0x94D0_49BB_1331_11EB
        x ^= x >> 29
        return Double(x >> 11) / Double(1 << 53)
    }
}

/// How strongly a visualizer answers each drum voice, each 0-1. Visualizers
/// multiply these by the master beat reactivity, so 0 there still means
/// volume-only visuals.
struct DrumReactivity: Codable, Equatable {
    static let range: ClosedRange<Double> = 0...1
    static let off = DrumReactivity(kick: 0, snare: 0, hat: 0)

    var kick = 1.0
    var snare = 1.0
    var hat = 1.0

    subscript(instrument: DrumInstrument) -> Double {
        get {
            switch instrument {
            case .kick: return kick
            case .snare: return snare
            case .hat: return hat
            }
        }
        set {
            switch instrument {
            case .kick: kick = newValue
            case .snare: snare = newValue
            case .hat: hat = newValue
            }
        }
    }

    func clamped() -> DrumReactivity {
        DrumReactivity(kick: kick.clamped(to: Self.range), snare: snare.clamped(to: Self.range), hat: hat.clamped(to: Self.range))
    }

    /// The effect amounts a visualizer applies under the master reactivity.
    func scaled(by beatReactivity: Double) -> DrumReactivity {
        DrumReactivity(kick: kick * beatReactivity, snare: snare * beatReactivity, hat: hat * beatReactivity)
    }
}

extension DrumReactivity {
    /// Missing values fall back to full reactivity.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kick = try container.decodeIfPresent(Double.self, forKey: .kick) ?? 1
        snare = try container.decodeIfPresent(Double.self, forKey: .snare) ?? 1
        hat = try container.decodeIfPresent(Double.self, forKey: .hat) ?? 1
    }
}

struct BeatAnalysis {
    /// True on the published frame that includes a beat detection (frames are
    /// coalesced to display rate). Views that animate between published frames
    /// should watch `beatCount` / `lastBeatTime` instead.
    var isBeat = false
    var beatCount = 0
    var lastBeatTime: TimeInterval = -.infinity
    var beatStrength: CGFloat = 0
    /// 0 until a tempo has been detected or tapped. Includes `tempoNudge`.
    var bpm: Double = 0
    /// BPM added to the detected tempo with the nudge keys; 0 when not nudged.
    var tempoNudge: Double = 0
    var onsetFlux: CGFloat = 0
    /// Unsmoothed low-band level: instant attack, exponential release.
    var bassEnvelope: CGFloat = 0
    var analysisTime: TimeInterval = 0
    var clock = BeatClock()
    /// Per-voice onsets, independent of the beat grid: the beat above is the
    /// tempo-validated pulse, these fire on every hit in their band.
    var kick = DrumHits(instrument: .kick)
    var snare = DrumHits(instrument: .snare)
    var hat = DrumHits(instrument: .hat)

    subscript(instrument: DrumInstrument) -> DrumHits {
        switch instrument {
        case .kick: return kick
        case .snare: return snare
        case .hat: return hat
        }
    }

    /// The bass envelope decayed to `time`, for animating between analyses.
    func bassEnvelope(at time: TimeInterval) -> CGFloat {
        bassEnvelope * CGFloat(exp(-max(0, time - analysisTime) / BeatTracker.bassReleaseTime))
    }

    /// Seconds since the last detected beat; infinite before the first one.
    func beatAge(at time: TimeInterval) -> TimeInterval {
        max(0, time - lastBeatTime)
    }

    /// Kick flash that decays over ~150 ms, scaled by how hard the beat hit.
    func flash(at time: TimeInterval) -> Double {
        exp(-beatAge(at: time) / 0.15) * (0.4 + 0.6 * Double(beatStrength))
    }
}

/// An animation phase that crossfades between steady wall-clock motion and the
/// beat grid. It is integrated frame to frame rather than blended from absolute
/// values, so it stays continuous while the reactivity slider moves or the
/// tempo changes. A class so it can advance inside a `TimelineView` update
/// without invalidating SwiftUI state.
final class BeatSyncedPhase {
    private var value: Double?
    private var lastTime: TimeInterval = 0
    private var lastGridPhase: Double = 0

    /// - Parameters:
    ///   - time: Frame time in seconds. The phase starts at `time * wallRate`,
    ///     so a reactivity of 0 reproduces plain `time * wallRate` motion.
    ///   - wallRate: Phase per second at reactivity 0.
    ///   - gridPhase: Beat or bar phase at `time`.
    ///   - gridRate: Phase per unit of `gridPhase` at reactivity 1.
    ///   - nominalGridSpeed: Expected `gridPhase` units per second. Caps
    ///     forward jumps, such as a tap re-aligning the downbeat, so the
    ///     motion glides instead of snapping.
    func advance(
        to time: TimeInterval,
        wallRate: Double,
        gridPhase: Double,
        gridRate: Double,
        nominalGridSpeed: Double,
        reactivity: Double
    ) -> Double {
        defer {
            lastTime = time
            lastGridPhase = gridPhase
        }
        guard let current = value else {
            value = time * wallRate
            return time * wallRate
        }
        // Clamped so resuming after a pause continues instead of jumping.
        let dt = min(0.25, max(0, time - lastTime))
        let gridStep = min(max(0, gridPhase - lastGridPhase), dt * nominalGridSpeed * 3)
        let next = current + (1 - reactivity) * wallRate * dt + reactivity * gridRate * gridStep
        value = next
        return next
    }
}

/// A drum voice's hit pulse for effects that brighten a large area. Hits
/// closer than `PerformanceState.strobeMinimumInterval` to the last accepted
/// one are skipped, holding the effect to the 3 Hz strobe cap however fast
/// the drummer plays. A class so it can advance inside a `TimelineView`
/// update without invalidating SwiftUI state.
final class RateLimitedDrumPulse {
    private var hitTime: TimeInterval = -.infinity
    private var strength = 0.0
    private var lastHitCount: Int?

    func advance(to time: TimeInterval, hits: DrumHits) -> Double {
        if let lastHitCount, hits.hitCount != lastHitCount,
           hits.lastHitTime - hitTime >= PerformanceState.strobeMinimumInterval {
            hitTime = hits.lastHitTime
            strength = Double(hits.strength)
        }
        lastHitCount = hits.hitCount
        return exp(-max(0, time - hitTime) / hits.instrument.releaseTime) * (0.4 + 0.6 * strength)
    }
}

/// Low-band onset detection, inter-onset-interval tempo estimation and a
/// phase-locked beat grid, plus per-band kick / snare / hat onsets. Used only
/// from the audio processing queue; all storage is preallocated so the
/// per-frame path does not allocate.
final class BeatTracker {
    static let bassReleaseTime: TimeInterval = 0.12

    // Onset detection
    private let energyHistoryDuration: TimeInterval = 1.0
    private let thresholdDeviations: Float = 1.0
    private let minimumEnergyRatio: Float = 1.4
    private let minimumBassLevel: Float = 0.05
    private let refractoryInterval: TimeInterval = 0.25
    private let fluxScale: Float = 5
    // Short hops catch a kick while it is still entering the FFT window, so the
    // strength keeps tracking the rising energy for about one window length.
    private let strengthPeakWindow: TimeInterval = 0.1

    // Must hold `energyHistoryDuration` at the fastest analysis rate
    // (512-sample hops at 48 kHz are ~94 analyses per second).
    private let energyCapacity = 256
    private var energyHistory = [Float](repeating: 0, count: 256)
    private var energyTimes = [TimeInterval](repeating: 0, count: 256)
    private var energyWriteIndex = 0
    private var energyCount = 0
    private var previousEnergy: Float = 0
    private var previousBands = [Float](repeating: 0, count: 64)
    private var hasPreviousBands = false
    private var bassEnvelope: Float = 0
    private var lastAnalysisTime: TimeInterval = 0
    private var lastBeatTime: TimeInterval = -.infinity
    private var lastBeatStrength: Float = 0
    private var onsetBaselineEnergy: Float = 0
    private var beatCount = 0

    // Drum voices: power rise over each voice's FFT bins. A kick's beater
    // click reaches the snare band, a snare's body the kick band and its
    // wires the hat band. While one voice hits, a neighbor only counts a hit
    // if its rise beats that leakage, as a ratio of the two voices' rises
    // (level-independent, since both scale with the gain).
    private let kickClickInSnare: Float = 8e-4
    private let snareBodyInKick: Float = 40
    private let snareWiresInHat: Float = 1
    private var kickDetector = DrumOnsetDetector(instrument: .kick)
    private var snareDetector = DrumOnsetDetector(instrument: .snare)
    private var hatDetector = DrumOnsetDetector(instrument: .hat)
    // Power of the previous frame's bins, for the rise.
    private var previousPower = [Float](repeating: 0, count: 2048)
    private var hasPreviousPower = false
    private var drumSampleRate: Double = 0
    // Rises are measured against the program level: mean bin power followed
    // fast up and slowly down (the auto gain's time constants), so detection
    // doesn't depend on the source level, sensitivity or auto gain.
    private let programAttackTime: TimeInterval = 0.15
    private let programReleaseTime: TimeInterval = 9
    /// About -100 dB per bin; silence never becomes the reference.
    private let minimumProgramPower: Float = 1e-10
    private var programPower: Float = 0
    private let drumReferenceHopDuration: TimeInterval = 512.0 / 48_000

    // Tempo: pairwise onset intervals vote into a one-octave log histogram
    // (90-180 BPM), so intervals of 1, 2 and 4 beats reinforce the same bin.
    private let minimumBPM = 70.0
    private let maximumBPM = 180.0
    private let histogramBaseBPM = 90.0
    private let histogramBins = 120
    private let tempoWindow: TimeInterval = 10
    private let minimumPairInterval: TimeInterval = 0.3
    private let maximumPairInterval: TimeInterval = 2.7
    private let onsetCapacity = 48
    private var onsetTimes = [TimeInterval](repeating: 0, count: 48)
    private var onsetStrengths = [Float](repeating: 0, count: 48)
    private var onsetWriteIndex = 0
    private var onsetCount = 0
    private var tempoHistogram = [Float](repeating: 0, count: 120)
    private var voteKernel = [Float](repeating: 0, count: 9)
    private var bpm: Double = 0
    /// Offset the user nudged the tempo by. Detection keeps smoothing towards
    /// the estimate plus this, so a fine adjustment isn't drifted back out; a
    /// new tempo or a tap clears it.
    private var tempoNudge: Double = 0
    private var pendingBPM: Double = 0
    private var pendingBPMVotes = 0
    private var manualHoldUntil: TimeInterval = 0
    private var needsPhaseSnap = false

    // Phase: corrections are slewed by briefly speeding up or slowing down the
    // grid, so the published phase never jumps backwards.
    private let maximumRateCorrection = 0.25
    private var phaseAnchorTime: TimeInterval = 0
    private var phaseAnchorValue: Double = 0
    private var phaseRate: Double = 2
    private var phaseBaseRate: Double = 2
    private var pendingPhaseCorrection: Double = 0
    private var offGridError: Double = 0
    private var offGridCount = 0

    // Tap tempo
    private let tapCapacity = 8
    private let tapResetInterval: TimeInterval = 2
    private let manualHoldDuration: TimeInterval = 15
    private var tapTimes = [TimeInterval](repeating: 0, count: 8)
    private var tapCount = 0
    private var lastTapTime: TimeInterval = -.infinity

    // Analysis times come from a sample counter mapped onto host time, so
    // bursty buffer delivery does not jitter inter-onset intervals.
    private var sampleClock: TimeInterval = 0
    private var clockOffset: TimeInterval = 0
    private var hasClockOffset = false

    init() {
        let sigma: Float = 1.5
        for index in voteKernel.indices {
            let offset = Float(index - voteKernel.count / 2)
            voteKernel[index] = exp(-(offset * offset) / (2 * sigma * sigma))
        }
    }

    /// Clears per-stream signal state when capture (re)starts. The tempo
    /// estimate and beat grid are kept so a resumed track stays in sync.
    func resetSignalState() {
        sampleClock = 0
        hasClockOffset = false
        energyWriteIndex = 0
        energyCount = 0
        previousEnergy = 0
        hasPreviousBands = false
        hasPreviousPower = false
        programPower = 0
        bassEnvelope = 0
        lastAnalysisTime = 0
        kickDetector.resetSignalState()
        snareDetector.resetSignalState()
        hatDetector.resetSignalState()
    }

    // MARK: - Analysis

    /// - Parameters:
    ///   - bassEnergy: Sum of squared FFT magnitudes in the ~40-150 Hz bins.
    ///   - bassLevel: The same band as a 0-1 display level.
    ///   - bands: Unsmoothed per-band levels for spectral flux.
    ///   - magnitudes: Unscaled FFT bin magnitudes, DC first, for the drum
    ///     voices.
    ///   - advancedSampleCount: New samples since the previous analysis.
    func analyze(
        bassEnergy: Float,
        bassLevel: Float,
        bands: [Float],
        magnitudes: [Float],
        advancedSampleCount: Int,
        sampleRate: Double,
        arrivalTime: TimeInterval
    ) -> BeatAnalysis {
        let now = audioTime(
            advancedSampleCount: advancedSampleCount,
            sampleRate: sampleRate,
            arrivalTime: arrivalTime
        )
        let elapsed = lastAnalysisTime > 0 ? max(0, now - lastAnalysisTime) : 0
        lastAnalysisTime = now

        bassEnvelope = max(bassLevel, bassEnvelope * Float(exp(-elapsed / Self.bassReleaseTime)))

        var flux: Float = 0
        let bandCount = min(bands.count, previousBands.count)
        if hasPreviousBands {
            for index in 0..<bandCount {
                flux += max(0, bands[index] - previousBands[index])
            }
            flux /= Float(max(1, bandCount))
        }
        for index in 0..<bandCount {
            previousBands[index] = bands[index]
        }
        hasPreviousBands = true

        // Local statistics over the last second, excluding this frame.
        var historySum: Float = 0
        var historyCount = 0
        for offset in 0..<energyCount {
            let index = (energyWriteIndex - 1 - offset + energyCapacity) % energyCapacity
            guard now - energyTimes[index] <= energyHistoryDuration else { break }
            historySum += energyHistory[index]
            historyCount += 1
        }
        var isBeat = false
        if historyCount >= 4 {
            let mean = historySum / Float(historyCount)
            var squaredDeviation: Float = 0
            for offset in 0..<historyCount {
                let index = (energyWriteIndex - 1 - offset + energyCapacity) % energyCapacity
                let deviation = energyHistory[index] - mean
                squaredDeviation += deviation * deviation
            }
            let deviation = sqrt(squaredDeviation / Float(historyCount))
            let threshold = max(mean + thresholdDeviations * deviation, mean * minimumEnergyRatio)

            if bassEnergy > threshold,
               bassEnergy > previousEnergy,
               bassLevel > minimumBassLevel,
               now - lastBeatTime >= refractoryInterval {
                isBeat = true
                onsetBaselineEnergy = max(mean, Float.leastNormalMagnitude)
                lastBeatStrength = onsetStrength(forEnergy: bassEnergy)
                lastBeatTime = now
                beatCount += 1
            }
        }
        let timeSinceBeat = now - lastBeatTime
        if !isBeat, onsetCount > 0, timeSinceBeat >= 0, timeSinceBeat < strengthPeakWindow,
           bassEnergy > previousEnergy {
            let strength = onsetStrength(forEnergy: bassEnergy)
            if strength > lastBeatStrength {
                lastBeatStrength = strength
                onsetStrengths[onsetIndex(0)] = strength
            }
        }

        energyHistory[energyWriteIndex] = bassEnergy
        energyTimes[energyWriteIndex] = now
        energyWriteIndex = (energyWriteIndex + 1) % energyCapacity
        energyCount = min(energyCapacity, energyCount + 1)
        previousEnergy = bassEnergy

        analyzeDrums(
            magnitudes: magnitudes,
            advancedSampleCount: advancedSampleCount,
            sampleRate: sampleRate,
            now: now,
            elapsed: elapsed
        )

        advancePhase(to: now)
        if isBeat {
            recordOnset(at: now, strength: lastBeatStrength)
            if let estimate = estimateTempo(now: now) {
                applyTempoEstimate(estimate, now: now)
            }
            alignPhase(toOnsetStrength: lastBeatStrength)
        }

        return snapshot(
            isBeat: isBeat,
            onsetFlux: min(1, flux * fluxScale),
            analysisTime: now
        )
    }

    /// Registers a tap at `time` (`BeatClock.now`). The first tap after a pause
    /// marks a downbeat; two or more taps set the tempo and hold it against
    /// large automatic changes for a while.
    func tap(at time: TimeInterval) -> BeatAnalysis {
        advancePhase(to: time)

        if tapCount == 0 || time - lastTapTime > tapResetInterval {
            tapCount = 0
            phaseAnchorValue = (phaseAnchorValue / 4).rounded(.up) * 4
            pendingPhaseCorrection = 0
        } else {
            let predicted = phaseAnchorValue + pendingPhaseCorrection
            pendingPhaseCorrection -= predicted - predicted.rounded()
        }

        tapTimes[tapCount % tapCapacity] = time
        tapCount += 1
        lastTapTime = time

        if tapCount >= 2 {
            let usedTaps = min(tapCount, tapCapacity)
            let oldestTap = tapTimes[(tapCount - usedTaps) % tapCapacity]
            let interval = (time - oldestTap) / Double(usedTaps - 1)
            if interval > 0 {
                bpm = foldIntoTempoRange(60 / interval)
                tempoNudge = 0
                pendingBPMVotes = 0
                needsPhaseSnap = false
                manualHoldUntil = time + manualHoldDuration
            }
        }
        updatePhaseRate()

        return snapshot(isBeat: false, onsetFlux: 0, analysisTime: lastAnalysisTime)
    }

    /// Fine-adjusts the current tempo by `delta` BPM at `time` (`BeatClock.now`)
    /// without moving the beat phase. Does nothing until a tempo is known.
    func nudgeTempo(by delta: Double, at time: TimeInterval) -> BeatAnalysis {
        if bpm > 0 {
            advancePhase(to: time)
            let nudged = min(maximumBPM, max(minimumBPM, bpm + delta))
            // Hundredths, so repeated 0.1 steps add back up to exactly 0.
            tempoNudge = ((tempoNudge + nudged - bpm) * 100).rounded() / 100
            bpm = nudged
            updatePhaseRate()
        }
        return snapshot(isBeat: false, onsetFlux: 0, analysisTime: lastAnalysisTime)
    }

    // MARK: - Drums

    private func analyzeDrums(
        magnitudes: [Float],
        advancedSampleCount: Int,
        sampleRate: Double,
        now: TimeInterval,
        elapsed: TimeInterval
    ) {
        let binCount = min(magnitudes.count, previousPower.count)
        if sampleRate != drumSampleRate {
            // Bins are sampleRate / (2 * count) apart.
            let binWidth = sampleRate / Double(2 * magnitudes.count)
            kickDetector.setBins(binWidth: binWidth, binCount: binCount)
            snareDetector.setBins(binWidth: binWidth, binCount: binCount)
            hatDetector.setBins(binWidth: binWidth, binCount: binCount)
            drumSampleRate = sampleRate
            hasPreviousPower = false
        }

        var kick: Float = 0
        var snare: Float = 0
        var hat: Float = 0
        if hasPreviousPower {
            // Rises grow with the new audio between frames, so they're scaled
            // to a 512-sample hop at 48 kHz. Sub-linearly: once a hop spans a
            // whole hit (the microphone path analyzes 4096-sample buffers),
            // the rise stops growing with it.
            let hopDuration = Double(max(1, advancedSampleCount)) / sampleRate
            let reference = max(programPower, minimumProgramPower) * Float(pow(hopDuration / drumReferenceHopDuration, 0.75))
            kick = kickDetector.onsetFunction(magnitudes, previousPower: previousPower, reference: reference)
            snare = snareDetector.onsetFunction(magnitudes, previousPower: previousPower, reference: reference)
            hat = hatDetector.onsetFunction(magnitudes, previousPower: previousPower, reference: reference)
        }
        var totalPower: Float = 0
        for bin in 0..<binCount {
            let power = magnitudes[bin] * magnitudes[bin]
            previousPower[bin] = power
            totalPower += power
        }
        hasPreviousPower = true
        let level = totalPower / Float(max(1, binCount))
        if programPower == 0 {
            programPower = level
        } else {
            let time = level > programPower ? programAttackTime : programReleaseTime
            programPower += (level - programPower) * Float(1 - exp(-elapsed / time))
        }

        // Every voice's threshold comes from its own history before this
        // frame, so all three are measured before any is updated.
        let kickExcess = kickDetector.measure(onset: kick, now: now)
        let snareExcess = snareDetector.measure(onset: snare, now: now)
        _ = hatDetector.measure(onset: hat, now: now)
        kickDetector.update(
            onset: kick, now: now, elapsed: elapsed,
            isMasked: snareExcess > 1 && kick < snare * snareBodyInKick
        )
        snareDetector.update(
            onset: snare, now: now, elapsed: elapsed,
            isMasked: kickExcess > 1 && snare < kick * kickClickInSnare
        )
        hatDetector.update(
            onset: hat, now: now, elapsed: elapsed,
            isMasked: snareExcess > 1 && hat < snare * snareWiresInHat
        )
    }

    // MARK: - Tempo

    private func recordOnset(at time: TimeInterval, strength: Float) {
        onsetTimes[onsetWriteIndex] = time
        onsetStrengths[onsetWriteIndex] = strength
        onsetWriteIndex = (onsetWriteIndex + 1) % onsetCapacity
        onsetCount = min(onsetCapacity, onsetCount + 1)
    }

    /// Ring index of the `offset`-th most recent onset.
    private func onsetIndex(_ offset: Int) -> Int {
        (onsetWriteIndex - 1 - offset + onsetCapacity) % onsetCapacity
    }

    private func estimateTempo(now: TimeInterval) -> Double? {
        var recentCount = 0
        while recentCount < onsetCount, now - onsetTimes[onsetIndex(recentCount)] <= tempoWindow {
            recentCount += 1
        }
        guard recentCount >= 6 else { return nil }

        for bin in 0..<histogramBins {
            tempoHistogram[bin] = 0
        }
        let kernelRadius = voteKernel.count / 2
        var totalWeight: Float = 0
        for newer in 0..<recentCount {
            let newerIndex = onsetIndex(newer)
            for older in (newer + 1)..<max(newer + 1, recentCount) {
                let olderIndex = onsetIndex(older)
                let interval = onsetTimes[newerIndex] - onsetTimes[olderIndex]
                if interval < minimumPairInterval { continue }
                if interval > maximumPairInterval { break }

                let position = octavePosition(ofInterval: interval)
                let weight = pairWeight(newerIndex, olderIndex, now: now)
                let centerBin = Int((position * Double(histogramBins)).rounded())
                for kernelIndex in voteKernel.indices {
                    let bin = (centerBin + kernelIndex - kernelRadius + histogramBins * 2) % histogramBins
                    tempoHistogram[bin] += voteKernel[kernelIndex] * weight
                }
                totalWeight += weight
            }
        }
        guard totalWeight > 0 else { return nil }

        var peakBin = 0
        for bin in 1..<histogramBins where tempoHistogram[bin] > tempoHistogram[peakBin] {
            peakBin = bin
        }
        // Require a reasonable share of the votes to agree before trusting it.
        guard tempoHistogram[peakBin] / totalWeight > 0.15 else { return nil }

        // Refine the period with a least-squares fit of every pair interval to
        // a whole number of beats. Onset times are quantized to the analysis
        // hop, so the long intervals across the window give the precision; the
        // first pass uses shorter intervals so beat multiples are unambiguous.
        var period = 60 / (histogramBaseBPM * pow(2, Double(peakBin) / Double(histogramBins)))
        for pass in 0..<2 {
            let maximumInterval = pass == 0 ? 4.0 : tempoWindow
            var weightedIntervals = 0.0
            var weightedBeats = 0.0
            for newer in 0..<recentCount {
                let newerIndex = onsetIndex(newer)
                for older in (newer + 1)..<max(newer + 1, recentCount) {
                    let olderIndex = onsetIndex(older)
                    let interval = onsetTimes[newerIndex] - onsetTimes[olderIndex]
                    if interval < minimumPairInterval { continue }
                    if interval > maximumInterval { break }

                    let beats = (interval / period).rounded()
                    guard beats >= 1, abs(interval - beats * period) < max(0.06 * period, 0.05) else { continue }
                    let weight = Double(pairWeight(newerIndex, olderIndex, now: now))
                    weightedIntervals += weight * beats * interval
                    weightedBeats += weight * beats * beats
                }
            }
            if weightedBeats > 0 {
                period = weightedIntervals / weightedBeats
            }
        }
        var tempo = 60 / period
        if tempo >= histogramBaseBPM * 2 { tempo /= 2 }
        if tempo < histogramBaseBPM { tempo *= 2 }

        // The histogram cannot tell 75 from 150. Where both are in range, pick
        // the half tempo only if consecutive onsets mostly land two beats apart.
        if tempo / 2 >= minimumBPM {
            let beatInterval = 60 / tempo
            var singleBeatGaps = 0
            var doubleBeatGaps = 0
            for newer in 0..<(recentCount - 1) {
                let gap = onsetTimes[onsetIndex(newer)] - onsetTimes[onsetIndex(newer + 1)]
                if abs(gap / beatInterval - 1) < 0.12 {
                    singleBeatGaps += 1
                } else if abs(gap / (2 * beatInterval) - 1) < 0.12 {
                    doubleBeatGaps += 1
                }
            }
            if doubleBeatGaps >= 3, Double(doubleBeatGaps) > Double(singleBeatGaps) * 1.5 {
                tempo /= 2
            }
        }
        return min(maximumBPM, max(minimumBPM, tempo))
    }

    /// Position of an interval's tempo within the histogram octave, in [0, 1).
    private func octavePosition(ofInterval interval: TimeInterval) -> Double {
        let octaves = log2(60 / interval / histogramBaseBPM)
        return octaves - floor(octaves)
    }

    private func pairWeight(_ newerIndex: Int, _ olderIndex: Int, now: TimeInterval) -> Float {
        let recency = Float(exp(-(now - onsetTimes[olderIndex]) / (tempoWindow * 0.6)))
        return (onsetStrengths[newerIndex] * onsetStrengths[olderIndex]).squareRoot() * recency
    }

    /// Small deviations are smoothed in; a different tempo (new track, or an
    /// octave flip) must be estimated repeatedly before it replaces the current one.
    private func applyTempoEstimate(_ estimate: Double, now: TimeInterval) {
        if bpm > 0, abs(estimate / bpm - 1) < 0.04 {
            let target = min(maximumBPM, max(minimumBPM, estimate + tempoNudge))
            bpm += (target - bpm) * 0.2
            pendingBPMVotes = 0
            return
        }
        guard now >= manualHoldUntil else { return }

        if pendingBPMVotes > 0, abs(estimate / pendingBPM - 1) < 0.03 {
            pendingBPMVotes += 1
            pendingBPM += (estimate - pendingBPM) * 0.5
        } else {
            pendingBPM = estimate
            pendingBPMVotes = 1
        }
        if pendingBPMVotes >= (bpm > 0 ? 6 : 3) {
            bpm = pendingBPM
            tempoNudge = 0
            pendingBPMVotes = 0
            needsPhaseSnap = true
        }
    }

    private func foldIntoTempoRange(_ tempo: Double) -> Double {
        var folded = tempo
        while folded < minimumBPM { folded *= 2 }
        while folded > maximumBPM { folded /= 2 }
        return folded
    }

    // MARK: - Phase

    /// Moves the phase anchor to `time`, consuming whatever part of the pending
    /// correction the adjusted rate has applied since the last anchor.
    private func advancePhase(to time: TimeInterval) {
        let anchorTime = max(time, phaseAnchorTime)
        let elapsed = anchorTime - phaseAnchorTime
        let applied = (phaseRate - phaseBaseRate) * elapsed
        if pendingPhaseCorrection > 0 {
            pendingPhaseCorrection = max(0, pendingPhaseCorrection - applied)
        } else {
            pendingPhaseCorrection = min(0, pendingPhaseCorrection - applied)
        }
        phaseAnchorValue += phaseRate * elapsed
        phaseAnchorTime = anchorTime
        updatePhaseRate()
    }

    private func updatePhaseRate() {
        let baseRate = (bpm > 0 ? bpm : 120) / 60
        // Spend the pending correction over about half a beat, within limits.
        let limit = baseRate * maximumRateCorrection
        let correction = min(limit, max(-limit, pendingPhaseCorrection * 2 * baseRate))
        phaseBaseRate = baseRate
        phaseRate = baseRate + correction
    }

    /// Called with the phase anchored at the onset time.
    private func alignPhase(toOnsetStrength strength: Float) {
        guard bpm > 0 else { return }
        let predicted = phaseAnchorValue + pendingPhaseCorrection
        let error = predicted - predicted.rounded()

        if needsPhaseSnap {
            needsPhaseSnap = false
            offGridCount = 0
            pendingPhaseCorrection -= error
        } else if abs(error) <= 0.2 {
            offGridCount = 0
            pendingPhaseCorrection -= error * 0.35 * Double(0.5 + 0.5 * strength)
        } else {
            // A run of onsets with the same offset means the grid is on the
            // wrong beat position rather than the music being syncopated.
            var drift = error - offGridError
            drift -= drift.rounded()
            offGridCount = offGridCount > 0 && abs(drift) < 0.12 ? offGridCount + 1 : 1
            offGridError = error
            if offGridCount >= 4 {
                offGridCount = 0
                pendingPhaseCorrection -= error
            }
        }
        updatePhaseRate()
    }

    // MARK: - Helpers

    /// Measured against the energy history from before the onset.
    private func onsetStrength(forEnergy energy: Float) -> Float {
        min(1, max(0.1, log2(energy / onsetBaselineEnergy) / 2))
    }

    private func audioTime(
        advancedSampleCount: Int,
        sampleRate: Double,
        arrivalTime: TimeInterval
    ) -> TimeInterval {
        sampleClock += Double(advancedSampleCount) / sampleRate
        // Late delivery only ever adds delay, so track the earliest arrival and
        // creep upwards slowly for clock drift. Re-anchor after a stall.
        let candidate = arrivalTime - sampleClock
        if !hasClockOffset || candidate < clockOffset || candidate - clockOffset > 0.25 {
            clockOffset = candidate
            hasClockOffset = true
        } else {
            clockOffset += (candidate - clockOffset) * 0.002
        }
        return sampleClock + clockOffset
    }

    private func snapshot(
        isBeat: Bool,
        onsetFlux: Float,
        analysisTime: TimeInterval
    ) -> BeatAnalysis {
        BeatAnalysis(
            isBeat: isBeat,
            beatCount: beatCount,
            lastBeatTime: lastBeatTime,
            beatStrength: CGFloat(lastBeatStrength),
            bpm: bpm,
            tempoNudge: tempoNudge,
            onsetFlux: CGFloat(onsetFlux),
            bassEnvelope: CGFloat(bassEnvelope),
            analysisTime: analysisTime,
            clock: BeatClock(
                anchorTime: phaseAnchorTime,
                anchorPhase: phaseAnchorValue,
                beatsPerSecond: phaseRate
            ),
            kick: kickDetector.hits(analysisTime: lastAnalysisTime),
            snare: snareDetector.hits(analysisTime: lastAnalysisTime),
            hat: hatDetector.hits(analysisTime: lastAnalysisTime)
        )
    }
}

/// Onset detection for one drum voice. The detection function is the rise
/// in power across the voice's FFT bins since the previous frame, so steady
/// tones and the noise floor stay quiet. Snares and hats are noise, which
/// lifts most of their bins at once, while a sung or played note lifts only
/// its harmonics; for those voices the rise is weighted by the share of bins
/// that rose. Rises are relative to the program level, so a hit is a rising
/// detection function above a fixed floor and well above its median over
/// the last second, which the other voices' hits barely move. Used only from
/// the audio processing queue; all storage is preallocated.
struct DrumOnsetDetector {
    let instrument: DrumInstrument

    private static let historyDuration: TimeInterval = 1.0
    // Holds `historyDuration` at ~94 analyses per second.
    private static let historyCapacity = 256
    private static let medianRatio: Float = 4
    /// A bin counts as rising above this power ratio (about 1 dB), unless
    /// it's still 60 dB under the program level: between the harmonics of a
    /// clean synth, rounding noise rises too.
    private static let risingRatio: Float = 1.26
    private static let minimumBinLevel: Float = 1e-6
    /// Snare and hat onsets count from this share of rising bins and at full
    /// weight from `hitBreadth`.
    private static let noiseBreadth: Float = 0.6
    private static let hitBreadth: Float = 0.9
    /// A hit keeps entering the FFT window for a few hops; strength tracks
    /// the rising onset for this long after it.
    private static let strengthPeakWindow: TimeInterval = 0.06
    /// The envelope is the onset over a peak that falls off this slowly.
    private static let peakReleaseTime: TimeInterval = 3

    private var bins = 0..<0
    private var history = [Float](repeating: 0, count: 256)
    private var historyTimes = [TimeInterval](repeating: 0, count: 256)
    private var medianScratch = [Float](repeating: 0, count: 256)
    private var writeIndex = 0
    private var count = 0
    private var previousOnset: Float = 0
    private var median: Float = 0
    private var threshold: Float = .infinity
    private var peakOnset: Float = 0
    private var envelope: Float = 0
    private var hitCount = 0
    private var lastHitTime: TimeInterval = -.infinity
    private var strength: Float = 0

    /// Mean power rise per bin, relative to the program level, a hit must
    /// reach. Leakage from the other voices (a kick's click in the snare band,
    /// a snare's wires in the hat band) and the noise floor stay below it.
    private let minimumOnset: Float

    init(instrument: DrumInstrument) {
        self.instrument = instrument
        switch instrument {
        case .kick: minimumOnset = 15
        case .snare: minimumOnset = 0.04
        case .hat: minimumOnset = 3e-4
        }
    }

    /// Keeps the hit count and last hit, so a restarted stream doesn't
    /// replay a hit to views that watch the count.
    mutating func resetSignalState() {
        writeIndex = 0
        count = 0
        previousOnset = 0
        median = 0
        threshold = .infinity
        peakOnset = 0
        envelope = 0
    }

    mutating func setBins(binWidth: Double, binCount: Int) {
        let lower = min(binCount, max(1, Int((instrument.band.lowerBound / binWidth).rounded())))
        let upper = min(binCount, Int((instrument.band.upperBound / binWidth).rounded()) + 1)
        bins = lower..<max(lower, upper)
    }

    /// The voice's detection function for this frame.
    /// - Parameter reference: The program level as mean power per bin,
    ///   scaled to the analysis hop.
    func onsetFunction(_ magnitudes: [Float], previousPower: [Float], reference: Float) -> Float {
        guard !bins.isEmpty else { return 0 }
        let minimumBinPower = reference * Self.minimumBinLevel
        var rise: Float = 0
        var risingBins = 0
        for bin in bins {
            let power = magnitudes[bin] * magnitudes[bin]
            let previous = previousPower[bin]
            rise += max(0, power - previous)
            if power > previous * Self.risingRatio, power > minimumBinPower { risingBins += 1 }
        }
        let onset = rise / Float(bins.count) / reference
        guard instrument != .kick else { return onset }
        // About a third of a noise floor's bins rise from frame to frame by
        // chance and a note change lifts up to about 0.75; a snare or hat
        // hit lifts nearly all of them.
        let breadth = Float(risingBins) / Float(bins.count)
        let weight = min(1, max(0, (breadth - Self.noiseBreadth) / (Self.hitBreadth - Self.noiseBreadth)))
        return onset * weight * weight
    }

    /// Updates the threshold from the history before this frame and returns
    /// how far `onset` exceeds it (above 1 is a hit, unmasked).
    mutating func measure(onset: Float, now: TimeInterval) -> Float {
        var used = 0
        for offset in 0..<count {
            let index = historyIndex(offset)
            guard now - historyTimes[index] <= Self.historyDuration else { break }
            medianScratch[used] = history[index]
            used += 1
        }
        guard used >= 4 else {
            threshold = .infinity
            return 0
        }
        median = Self.select(used / 2, in: &medianScratch, count: used)
        threshold = max(median * Self.medianRatio, minimumOnset)
        return onset / threshold
    }

    /// Detects a hit against the threshold from `measure`, unless a
    /// neighboring voice's hit masks this one, and records the frame.
    mutating func update(onset: Float, now: TimeInterval, elapsed: TimeInterval, isMasked: Bool) {
        if !isMasked, onset > threshold, onset > previousOnset, now - lastHitTime >= instrument.minimumInterval {
            hitCount += 1
            lastHitTime = now
            strength = hitStrength(forOnset: onset)
        } else if now - lastHitTime < Self.strengthPeakWindow, onset > previousOnset {
            strength = max(strength, hitStrength(forOnset: onset))
        }

        peakOnset = max(onset, peakOnset * Float(exp(-elapsed / Self.peakReleaseTime)), minimumOnset * 4)
        let level = min(1, max(0, (onset - median) / max(peakOnset - median, minimumOnset)))
        envelope = max(level, envelope * Float(exp(-elapsed / instrument.releaseTime)))

        history[writeIndex] = onset
        historyTimes[writeIndex] = now
        writeIndex = (writeIndex + 1) % Self.historyCapacity
        count = min(Self.historyCapacity, count + 1)
        previousOnset = onset
    }

    func hits(analysisTime: TimeInterval) -> DrumHits {
        DrumHits(
            instrument: instrument,
            hitCount: hitCount,
            lastHitTime: lastHitTime,
            strength: CGFloat(strength),
            envelope: CGFloat(envelope),
            analysisTime: analysisTime
        )
    }

    /// Ring index of the `offset`-th most recent frame.
    private func historyIndex(_ offset: Int) -> Int {
        (writeIndex - 1 - offset + Self.historyCapacity) % Self.historyCapacity
    }

    /// 0.1 at the threshold, 1 about 12 dB over it.
    private func hitStrength(forOnset onset: Float) -> Float {
        min(1, max(0.1, 0.1 + log2(onset / threshold) / 4.5))
    }

    /// The `k`-th smallest of `values[0..<count]`, partially reordering them
    /// (quickselect, so the median costs no allocation or full sort).
    private static func select(_ k: Int, in values: inout [Float], count: Int) -> Float {
        var low = 0
        var high = count - 1
        while low < high {
            let pivot = values[(low + high) / 2]
            var i = low
            var j = high
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j {
                    values.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if k <= j {
                high = j
            } else if k >= i {
                low = i
            } else {
                break
            }
        }
        return values[k]
    }
}
