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

struct BeatAnalysis {
    /// True on the published frame that includes a beat detection (frames are
    /// coalesced to display rate). Views that animate between published frames
    /// should watch `beatCount` / `lastBeatTime` instead.
    var isBeat = false
    var beatCount = 0
    var lastBeatTime: TimeInterval = -.infinity
    var beatStrength: CGFloat = 0
    /// 0 until a tempo has been detected or tapped.
    var bpm: Double = 0
    var onsetFlux: CGFloat = 0
    /// Unsmoothed low-band level: instant attack, exponential release.
    var bassEnvelope: CGFloat = 0
    var analysisTime: TimeInterval = 0
    var clock = BeatClock()

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

/// Low-band onset detection, inter-onset-interval tempo estimation and a
/// phase-locked beat grid. Used only from the audio processing queue; all
/// storage is preallocated so the per-frame path does not allocate.
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
        bassEnvelope = 0
        lastAnalysisTime = 0
    }

    // MARK: - Analysis

    /// - Parameters:
    ///   - bassEnergy: Sum of squared FFT magnitudes in the ~40-150 Hz bins.
    ///   - bassLevel: The same band as a 0-1 display level.
    ///   - bands: Unsmoothed per-band levels for spectral flux.
    ///   - advancedSampleCount: New samples since the previous analysis.
    func analyze(
        bassEnergy: Float,
        bassLevel: Float,
        bands: [Float],
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
                pendingBPMVotes = 0
                needsPhaseSnap = false
                manualHoldUntil = time + manualHoldDuration
            }
        }
        updatePhaseRate()

        return snapshot(isBeat: false, onsetFlux: 0, analysisTime: lastAnalysisTime)
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
            bpm += (estimate - bpm) * 0.2
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
            onsetFlux: CGFloat(onsetFlux),
            bassEnvelope: CGFloat(bassEnvelope),
            analysisTime: analysisTime,
            clock: BeatClock(
                anchorTime: phaseAnchorTime,
                anchorPhase: phaseAnchorValue,
                beatsPerSecond: phaseRate
            )
        )
    }
}
