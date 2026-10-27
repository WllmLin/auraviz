import Foundation
import AVFoundation
import Accelerate
import Combine
import CoreGraphics
import CoreMedia
import os
import ScreenCaptureKit

enum InputMode: String, CaseIterable, Identifiable {
    case systemAudio = "System Audio"
    case microphone = "Microphone"

    var id: String { rawValue }
}

private struct AudioVisualizationFrame {
    var spectrum: [CGFloat] = Array(repeating: 0.05, count: 64)
    var waveform: [CGFloat] = Array(repeating: 0, count: 256)
    var volume: CGFloat = 0
    var dominantFrequency: Double = 0
    var autoGainDB: Double = 0
    var beat = BeatAnalysis()
}

/// Slow automatic gain control. Follows a peak-biased level of the broadband
/// RMS and of the band energy (fast rise, slow fall) and returns the gain that
/// brings each to a fixed target, so quiet and loud sources fill the same
/// visual range. Used only from the audio processing queue.
private struct AutoGainControl {
    // An exponential follower with these time constants settles near the top
    // few percent of the level distribution rather than on single transients.
    private static let attackTime: Float = 0.15
    private static let releaseTime: Float = 9
    // Targets put loud program material about where it sat at sensitivity
    // 1.0 without AGC (RMS peaks near -12 dBFS, band energy near -20 dB).
    private static let volumeTargetDB: Float = -12
    private static let spectrumTargetDB: Float = -20
    private static let maximumBoostDB: Float = 30
    private static let maximumCutDB: Float = 18
    // Below the noise floor the gain fades back to 0 dB, so hiss and room noise
    // look as quiet as they do without AGC. Levels far below the tracked peak
    // also count as a pause between tracks.
    private static let noiseFloorDB: Float = -60
    private static let relativeFloorDB: Float = 40
    private static let gateRangeDB: Float = 10
    private static let presenceAttackTime: Float = 0.03
    private static let presenceReleaseTime: Float = 0.3

    private var volumeReferenceDB: Float?
    private var spectrumReferenceDB: Float?
    private var presenceLevelDB: Float = -120
    private(set) var volumeGainDB: Float = 0
    private(set) var spectrumGainDB: Float = 0

    mutating func reset() {
        self = AutoGainControl()
    }

    /// - Parameters:
    ///   - rmsDB: Unscaled RMS of the analysis window, in dBFS.
    ///   - bandEnergyDB: Mean band power, including the display's frequency
    ///     compensation, in dB.
    ///   - duration: Seconds of new audio since the previous update.
    mutating func update(rmsDB: Float, bandEnergyDB: Float, duration: Float) {
        let presenceTime = rmsDB > presenceLevelDB ? Self.presenceAttackTime : Self.presenceReleaseTime
        presenceLevelDB += (rmsDB - presenceLevelDB) * (1 - exp(-duration / presenceTime))
        let floorDB = max(Self.noiseFloorDB, (volumeReferenceDB ?? -.infinity) - Self.relativeFloorDB)
        let gatePosition = min(1, max(0, (presenceLevelDB - floorDB) / Self.gateRangeDB))
        // Smoothstep, so levels just above the floor get only a little gain.
        let presence = gatePosition * gatePosition * (3 - 2 * gatePosition)
        // Fades never pull a reference below the level where the gate opens.
        // The targets differ by the usual band-energy-to-RMS offset.
        let openLevelDB = floorDB + Self.gateRangeDB

        if let volumeReferenceDB, let spectrumReferenceDB {
            self.volumeReferenceDB = Self.follow(
                volumeReferenceDB, toward: max(rmsDB, openLevelDB),
                target: Self.volumeTargetDB, duration: duration, presence: presence
            )
            self.spectrumReferenceDB = Self.follow(
                spectrumReferenceDB,
                toward: max(bandEnergyDB, openLevelDB + Self.spectrumTargetDB - Self.volumeTargetDB),
                target: Self.spectrumTargetDB, duration: duration, presence: presence
            )
        } else if presence >= 1 {
            // Start from the first clearly audible level instead of waiting a
            // full release time to adapt to a quiet source.
            volumeReferenceDB = Self.clampReference(presenceLevelDB, target: Self.volumeTargetDB)
            spectrumReferenceDB = Self.clampReference(bandEnergyDB, target: Self.spectrumTargetDB)
        }

        volumeGainDB = (Self.volumeTargetDB - (volumeReferenceDB ?? Self.volumeTargetDB)) * presence
        spectrumGainDB = (Self.spectrumTargetDB - (spectrumReferenceDB ?? Self.spectrumTargetDB)) * presence
    }

    private static func follow(
        _ reference: Float,
        toward level: Float,
        target: Float,
        duration: Float,
        presence: Float
    ) -> Float {
        let time = level > reference ? attackTime : releaseTime
        // Silence and noise must not drag the reference down between tracks.
        let rate = level > reference ? 1 : presence
        return clampReference(reference + (level - reference) * (1 - exp(-duration * rate / time)), target: target)
    }

    private static func clampReference(_ level: Float, target: Float) -> Float {
        min(target + maximumCutDB, max(target - maximumBoostDB, level))
    }
}

/// The newest analysis waiting for the main thread. The audio queue overwrites
/// it in place, so a busy main thread never builds up a backlog of frames.
private struct PendingVisualization {
    var frame = AudioVisualizationFrame()
    var publishScheduled = false
    var lastPublishTime: TimeInterval = -.infinity
    #if DEBUG
    var publishCount = 0
    #endif

    /// Returns the delay before the next publish, or nil if one is already queued.
    mutating func reservePublish(now: TimeInterval, minimumInterval: TimeInterval) -> TimeInterval? {
        guard !publishScheduled else { return nil }
        publishScheduled = true
        return max(0, lastPublishTime + minimumInterval - now)
    }
}

final class AudioEngineManager: NSObject, ObservableObject {
    @Published private var visualization = AudioVisualizationFrame()
    @Published var isRunning = false
    @Published var isStarting = false
    @Published var captureError: String?
    static let sensitivityRange: ClosedRange<Double> = 0.3...2.2
    static let smoothingRange: ClosedRange<Double> = 0...0.92
    static let beatReactivityRange: ClosedRange<Double> = 0...1

    @Published var inputMode: InputMode = .systemAudio {
        didSet {
            UserDefaults.standard.set(inputMode.rawValue, forKey: SettingsKey.inputMode)
            guard inputMode != oldValue else { return }
            switchInput()
        }
    }

    @Published var sensitivity: Double = 1.0 {
        didSet { UserDefaults.standard.set(sensitivity, forKey: SettingsKey.sensitivity) }
    }
    /// Normalizes volume and spectrum against the recent source level. While
    /// on, `sensitivity` acts as a trim on top of the automatic gain.
    @Published var autoGainEnabled = true {
        didSet { UserDefaults.standard.set(autoGainEnabled, forKey: SettingsKey.autoGainEnabled) }
    }
    @Published var smoothing: Double = 0.75 {
        didSet { UserDefaults.standard.set(smoothing, forKey: SettingsKey.smoothing) }
    }
    /// Scales every beat-synced visual effect; 0 = volume-only visuals.
    @Published var beatReactivity: Double = 0.6 {
        didSet { UserDefaults.standard.set(beatReactivity, forKey: SettingsKey.beatReactivity) }
    }
    /// Per-visualizer drum reactivity, keyed by `VisualMode.rawValue`. Modes
    /// without an entry use their defaults. Read through `drumReactivity(for:)`.
    @Published private var drumReactivityByMode: [String: DrumReactivity] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(drumReactivityByMode) {
                UserDefaults.standard.set(data, forKey: SettingsKey.drumReactivity)
            }
        }
    }
    @Published var micPermissionGranted = false
    @Published var systemAudioPermissionGranted = false

    var spectrum: [CGFloat] { visualization.spectrum }
    var waveform: [CGFloat] { visualization.waveform }
    var volume: CGFloat { visualization.volume }
    var dominantFrequency: Double { visualization.dominantFrequency }
    /// Volume gain currently applied by auto gain, excluding the trim; 0 when off.
    var autoGainDB: Double { visualization.autoGainDB }

    // Beat and tempo. For display-rate animation, read the clock inside a
    // TimelineView: `beatClock.beatPhase(at: BeatClock.time(for: timeline.date))`.
    var beat: BeatAnalysis { visualization.beat }
    var isBeat: Bool { visualization.beat.isBeat }
    var beatCount: Int { visualization.beat.beatCount }
    var lastBeatTime: TimeInterval { visualization.beat.lastBeatTime }
    var beatStrength: CGFloat { visualization.beat.beatStrength }
    var bpm: Double { visualization.beat.bpm }
    var onsetFlux: CGFloat { visualization.beat.onsetFlux }
    var bassEnvelope: CGFloat { visualization.beat.bassEnvelope }
    var beatClock: BeatClock { visualization.beat.clock }
    var beatPhase: Double { beatClock.beatPhase(at: BeatClock.now) }
    var barPhase: Double { beatClock.barPhase(at: BeatClock.now) }

    func bassEnvelope(at time: TimeInterval) -> CGFloat {
        visualization.beat.bassEnvelope(at: time)
    }

    // Drum voices, split by band: kick (low thump), snare (mid crack) and hat
    // (high sizzle). Watch `hitCount` like `beatCount`; `pulse(at:)` and
    // `envelope(at:)` animate between frames.
    var kick: DrumHits { visualization.beat.kick }
    var snare: DrumHits { visualization.beat.snare }
    var hat: DrumHits { visualization.beat.hat }

    func hits(for instrument: DrumInstrument) -> DrumHits {
        visualization.beat[instrument]
    }

    /// How strongly `mode` answers each drum voice, before the master beat
    /// reactivity scales it.
    func drumReactivity(for mode: VisualMode) -> DrumReactivity {
        drumReactivityByMode[mode.rawValue] ?? mode.defaultDrumReactivity
    }

    func setDrumReactivity(_ reactivity: DrumReactivity, for mode: VisualMode) {
        drumReactivityByMode[mode.rawValue] = reactivity.clamped()
    }

    private var microphoneEngine: AVAudioEngine?
    private var systemAudioStream: SCStream?
    private var systemAudioStartTask: Task<Void, Never>?
    private var captureRequestID = UUID()
    private let audioProcessingQueue = DispatchQueue(
        label: "com.auraviz.system-audio",
        qos: .userInitiated
    )

    private let fftSize = 4096
    private let fftHopSize = 512
    // Spectrum smoothing coefficients were tuned for one step per 1024 samples.
    // Scaling the exponent by hop / 1024 keeps attack and release times in
    // seconds independent of the hop size.
    private let smoothingReferenceHopSize = 1024
    private let log2n: vDSP_Length = 12 // 2^12 = 4096
    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    private var smoothedSpectrum: [Float] = Array(repeating: 0, count: 64)

    // Fixed storage keeps the real-time path from allocating and shifting an
    // ever-growing sample array for every overlapping FFT window.
    private var systemSampleRing = [Float](repeating: 0, count: 4096)
    private var systemRingWriteIndex = 0
    private var systemRingSampleCount = 0
    private var systemSamplesSinceAnalysis = 0
    private var hasAnalyzedSystemSamples = false
    private var systemRingSampleRate: Double = 0
    private var monoScratch: [Float] = []
    private var analysisFrame = [Float](repeating: 0, count: 4096)

    // FFT workspaces and logarithmic band boundaries are reused between
    // frames. Only the two arrays handed to SwiftUI are created per update.
    private var fftSignal = [Float](repeating: 0, count: 4096)
    private var fftReal = [Float](repeating: 0, count: 2048)
    private var fftImaginary = [Float](repeating: 0, count: 2048)
    private var fftMagnitudes = [Float](repeating: 0, count: 2048)
    private var fftBands = [Float](repeating: 0, count: 64)
    private var spreadBands = [Float](repeating: 0, count: 64)
    private var waveformScratch = [CGFloat](repeating: 0, count: 256)
    private var cachedBandSampleRate: Double = 0
    private var bandBinRanges: [(low: Int, high: Int)] = []
    private var lowestDominantBin = 1
    private var highestDominantBin = 1
    private var lowestBassBin = 1
    private var highestBassBin = 1
    private let beatTracker = BeatTracker()
    private var autoGain = AutoGainControl()
    // Display frequency compensation as a power factor, for the AGC band energy.
    private let bandCompensationPower: [Float] = (0..<64).map { pow(10, Float($0) / 63 * 9 / 10) }

    // Analysis runs at ~94 Hz; SwiftUI only needs display rate. The audio queue
    // writes into preallocated pending storage and at most one main-thread
    // publish is queued at a time.
    private let minimumPublishInterval: TimeInterval = 1.0 / 60
    private let pendingVisualization = OSAllocatedUnfairLock(uncheckedState: PendingVisualization())
    // Created once so scheduling a publish does not allocate a new block.
    private var publishBlock: @convention(block) () -> Void = {}

    #if DEBUG
    private static let analysisLogger = Logger(subsystem: "com.auraviz.app", category: "AudioAnalysis")
    private let debugStatsInterval: TimeInterval = 2
    private var debugStatsStartTime: TimeInterval = 0
    private var debugProcessCount = 0
    private var debugProcessNanoseconds: UInt64 = 0
    private var debugMaxProcessNanoseconds: UInt64 = 0
    private var debugStatsStartPublishCount = 0
    #endif

    override init() {
        super.init()
        restoreSettings()
        publishBlock = { [weak self] in
            self?.publishPendingVisualization()
        }
        setupFFT()
        updateWindow()
        checkPermissions()
    }

    deinit {
        systemAudioStartTask?.cancel()
        microphoneEngine?.stop()
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    private func restoreSettings() {
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: SettingsKey.inputMode).flatMap(InputMode.init(rawValue:)) {
            // Past the didSet: nothing is capturing yet, start() picks it up.
            _inputMode = Published(initialValue: mode)
        }
        sensitivity = defaults.double(forKey: SettingsKey.sensitivity, in: Self.sensitivityRange) ?? sensitivity
        autoGainEnabled = defaults.object(forKey: SettingsKey.autoGainEnabled) as? Bool ?? autoGainEnabled
        smoothing = defaults.double(forKey: SettingsKey.smoothing, in: Self.smoothingRange) ?? smoothing
        beatReactivity = defaults.double(forKey: SettingsKey.beatReactivity, in: Self.beatReactivityRange) ?? beatReactivity
        if let data = defaults.data(forKey: SettingsKey.drumReactivity),
           let stored = try? JSONDecoder().decode([String: DrumReactivity].self, from: data) {
            drumReactivityByMode = stored.mapValues { $0.clamped() }
        }
    }

    private func setupFFT() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    private func updateWindow() {
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    // MARK: - Public API

    func toggleRunning() {
        if isRunning || isStarting {
            stop()
        } else {
            start()
        }
    }

    func start() {
        captureError = nil
        audioProcessingQueue.async { [weak self] in
            self?.beatTracker.resetSignalState()
            self?.autoGain.reset()
        }
        switch inputMode {
        case .systemAudio:
            startSystemAudio()
        case .microphone:
            startMicrophone()
        }
    }

    func stop() {
        captureRequestID = UUID()
        systemAudioStartTask?.cancel()
        systemAudioStartTask = nil

        if let stream = systemAudioStream {
            systemAudioStream = nil
            Task {
                try? await stream.stopCapture()
            }
        }

        stopMicrophone()
        isRunning = false
        isStarting = false
    }

    /// Tap on each beat: the first tap after a pause marks a downbeat, further
    /// taps set the tempo and re-sync the beat grid.
    func tapTempo() {
        let tapTime = BeatClock.now
        audioProcessingQueue.async { [weak self] in
            guard let self else { return }
            let beat = self.beatTracker.tap(at: tapTime)
            let publishDelay = self.pendingVisualization.withLockUnchecked { state in
                state.frame.beat.bpm = beat.bpm
                state.frame.beat.clock = beat.clock
                return state.reservePublish(now: BeatClock.now, minimumInterval: self.minimumPublishInterval)
            }
            if let publishDelay {
                self.schedulePublish(after: publishDelay)
            }
        }
    }

    func resetVisualizationControls() {
        sensitivity = 1.0
        smoothing = 0.75
        beatReactivity = 0.6
        drumReactivityByMode = [:]
    }

    func requestSystemAudioPermission() {
        captureError = nil
        let granted = CGRequestScreenCaptureAccess()
        systemAudioPermissionGranted = granted || CGPreflightScreenCaptureAccess()

        if systemAudioPermissionGranted {
            start()
        } else {
            captureError = "Allow AuraViz in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        }
    }

    func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.micPermissionGranted = granted
                if granted, self.inputMode == .microphone {
                    self.startMicrophone()
                } else if !granted {
                    self.captureError = "Microphone access is required for microphone mode."
                }
            }
        }
    }

    private func switchInput() {
        let shouldRestart = isRunning || isStarting
        stop()
        captureError = nil
        if shouldRestart {
            start()
        }
    }

    private func checkPermissions() {
        systemAudioPermissionGranted = CGPreflightScreenCaptureAccess()
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - System audio

    private func startSystemAudio() {
        stopMicrophone()

        if !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            systemAudioPermissionGranted = granted || CGPreflightScreenCaptureAccess()
            guard systemAudioPermissionGranted else {
                isRunning = false
                isStarting = false
                captureError = "Allow AuraViz to record system audio, then press Start again."
                return
            }
        } else {
            systemAudioPermissionGranted = true
        }

        let requestID = UUID()
        captureRequestID = requestID
        isStarting = true
        isRunning = false
        audioProcessingQueue.sync {
            resetSystemSampleRing()
        }

        systemAudioStartTask?.cancel()
        systemAudioStartTask = Task { [weak self] in
            guard let self else { return }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                guard !Task.isCancelled, self.captureRequestID == requestID else { return }
                guard let display = content.displays.first else {
                    throw AudioCaptureError.noDisplay
                }

                let ownBundleID = Bundle.main.bundleIdentifier
                let excludedApplications = content.applications.filter {
                    $0.bundleIdentifier == ownBundleID
                }
                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: excludedApplications,
                    exceptingWindows: []
                )

                let configuration = SCStreamConfiguration()
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                configuration.queueDepth = 1
                configuration.showsCursor = false
                configuration.capturesAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                configuration.excludesCurrentProcessAudio = true

                let stream = SCStream(
                    filter: filter,
                    configuration: configuration,
                    delegate: self
                )
                try stream.addStreamOutput(
                    self,
                    type: .audio,
                    sampleHandlerQueue: self.audioProcessingQueue
                )

                guard !Task.isCancelled, self.captureRequestID == requestID else { return }
                await MainActor.run {
                    self.systemAudioStream = stream
                }
                try await stream.startCapture()

                guard !Task.isCancelled, self.captureRequestID == requestID else {
                    try? await stream.stopCapture()
                    return
                }
                await MainActor.run {
                    self.systemAudioPermissionGranted = true
                    self.captureError = nil
                    self.isStarting = false
                    self.isRunning = true
                }
            } catch {
                guard !Task.isCancelled, self.captureRequestID == requestID else { return }
                await MainActor.run {
                    self.systemAudioStream = nil
                    self.isStarting = false
                    self.isRunning = false
                    self.captureError = "System audio capture could not start: \(error.localizedDescription)"
                }
            }
        }
    }

    private func processSystemAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let formatPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return }

        let format = formatPointer.pointee
        guard format.mFormatID == kAudioFormatLinearPCM else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        if monoScratch.count < frameCount {
            monoScratch = [Float](repeating: 0, count: frameCount)
        } else {
            monoScratch.withUnsafeMutableBufferPointer { pointer in
                vDSP_vclr(pointer.baseAddress!, 1, vDSP_Length(frameCount))
            }
        }

        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        var availableFrameCount = frameCount
        var mixedChannelCount = 0

        do {
            try sampleBuffer.withAudioBufferList(
                flags: [.audioBufferListAssure16ByteAlignment]
            ) { bufferList, _ in
                for audioBuffer in bufferList {
                    guard let data = audioBuffer.mData else { continue }
                    let channels = max(1, Int(audioBuffer.mNumberChannels))

                    if isFloat, format.mBitsPerChannel == 32 {
                        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                        let samples = data.assumingMemoryBound(to: Float.self)
                        let availableFrames = min(frameCount, sampleCount / channels)
                        guard availableFrames > 0 else { continue }
                        availableFrameCount = min(availableFrameCount, availableFrames)
                        monoScratch.withUnsafeMutableBufferPointer { destination in
                            for channel in 0..<channels {
                                vDSP_vadd(
                                    samples.advanced(by: channel),
                                    vDSP_Stride(channels),
                                    destination.baseAddress!,
                                    1,
                                    destination.baseAddress!,
                                    1,
                                    vDSP_Length(availableFrames)
                                )
                            }
                        }
                        mixedChannelCount += channels
                    } else if isFloat, format.mBitsPerChannel == 64 {
                        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
                        let samples = data.assumingMemoryBound(to: Double.self)
                        let availableFrames = min(frameCount, sampleCount / channels)
                        guard availableFrames > 0 else { continue }
                        availableFrameCount = min(availableFrameCount, availableFrames)
                        for frame in 0..<availableFrames {
                            for channel in 0..<channels {
                                monoScratch[frame] += Float(samples[frame * channels + channel])
                            }
                        }
                        mixedChannelCount += channels
                    } else if isSignedInteger, format.mBitsPerChannel == 16 {
                        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                        let samples = data.assumingMemoryBound(to: Int16.self)
                        let availableFrames = min(frameCount, sampleCount / channels)
                        guard availableFrames > 0 else { continue }
                        availableFrameCount = min(availableFrameCount, availableFrames)
                        for frame in 0..<availableFrames {
                            for channel in 0..<channels {
                                monoScratch[frame] += Float(samples[frame * channels + channel]) / 32_768
                            }
                        }
                        mixedChannelCount += channels
                    } else if isSignedInteger, format.mBitsPerChannel == 32 {
                        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                        let samples = data.assumingMemoryBound(to: Int32.self)
                        let availableFrames = min(frameCount, sampleCount / channels)
                        guard availableFrames > 0 else { continue }
                        availableFrameCount = min(availableFrameCount, availableFrames)
                        for frame in 0..<availableFrames {
                            for channel in 0..<channels {
                                monoScratch[frame] += Float(samples[frame * channels + channel]) / Float(Int32.max)
                            }
                        }
                        mixedChannelCount += channels
                    }
                }
            }
        } catch {
            return
        }

        guard mixedChannelCount > 0, availableFrameCount > 0 else { return }
        var channelScale = 1 / Float(mixedChannelCount)
        monoScratch.withUnsafeMutableBufferPointer { pointer in
            vDSP_vsmul(
                pointer.baseAddress!,
                1,
                &channelScale,
                pointer.baseAddress!,
                1,
                vDSP_Length(availableFrameCount)
            )
        }
        monoScratch.withUnsafeBufferPointer { pointer in
            appendSystemSamples(
                UnsafeBufferPointer(start: pointer.baseAddress!, count: availableFrameCount),
                sampleRate: format.mSampleRate
            )
        }
    }

    private func resetSystemSampleRing() {
        systemRingWriteIndex = 0
        systemRingSampleCount = 0
        systemSamplesSinceAnalysis = 0
        hasAnalyzedSystemSamples = false
        systemRingSampleRate = 0
    }

    private func appendSystemSamples(
        _ samples: UnsafeBufferPointer<Float>,
        sampleRate: Double
    ) {
        guard let source = samples.baseAddress, !samples.isEmpty else { return }
        if systemRingSampleRate != sampleRate {
            resetSystemSampleRing()
            systemRingSampleRate = sampleRate
        }

        var sourceOffset = 0
        while sourceOffset < samples.count {
            let samplesNeeded = hasAnalyzedSystemSamples
                ? fftHopSize - systemSamplesSinceAnalysis
                : fftSize - systemRingSampleCount
            let copyCount = min(samplesNeeded, samples.count - sourceOffset)
            let firstCopyCount = min(copyCount, fftSize - systemRingWriteIndex)

            systemSampleRing.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!
                    .advanced(by: systemRingWriteIndex)
                    .update(from: source.advanced(by: sourceOffset), count: firstCopyCount)
                if firstCopyCount < copyCount {
                    destination.baseAddress!.update(
                        from: source.advanced(by: sourceOffset + firstCopyCount),
                        count: copyCount - firstCopyCount
                    )
                }
            }

            systemRingWriteIndex = (systemRingWriteIndex + copyCount) % fftSize
            systemRingSampleCount = min(fftSize, systemRingSampleCount + copyCount)
            sourceOffset += copyCount

            if hasAnalyzedSystemSamples {
                systemSamplesSinceAnalysis += copyCount
                if systemSamplesSinceAnalysis == fftHopSize {
                    analyzeCurrentSystemWindow(sampleRate: sampleRate, advancedSampleCount: fftHopSize)
                    systemSamplesSinceAnalysis = 0
                }
            } else if systemRingSampleCount == fftSize {
                analyzeCurrentSystemWindow(sampleRate: sampleRate, advancedSampleCount: fftSize)
                hasAnalyzedSystemSamples = true
                systemSamplesSinceAnalysis = 0
            }
        }
    }

    private func analyzeCurrentSystemWindow(sampleRate: Double, advancedSampleCount: Int) {
        let firstCopyCount = fftSize - systemRingWriteIndex
        analysisFrame.withUnsafeMutableBufferPointer { destination in
            systemSampleRing.withUnsafeBufferPointer { source in
                destination.baseAddress!.update(
                    from: source.baseAddress!.advanced(by: systemRingWriteIndex),
                    count: firstCopyCount
                )
                if systemRingWriteIndex > 0 {
                    destination.baseAddress!.advanced(by: firstCopyCount).update(
                        from: source.baseAddress!,
                        count: systemRingWriteIndex
                    )
                }
            }
        }
        processSamples(
            analysisFrame,
            sampleRate: sampleRate,
            smoothingFrameMultiplier: Float(fftHopSize) / Float(smoothingReferenceHopSize),
            advancedSampleCount: advancedSampleCount
        )
    }

    // MARK: - Microphone

    private func startMicrophone() {
        guard micPermissionGranted else {
            isRunning = false
            isStarting = false
            captureError = "Enable microphone access to use this input."
            return
        }

        let engine = AVAudioEngine()
        microphoneEngine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            captureError = "No microphone input is available."
            microphoneEngine = nil
            return
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: UInt32(fftSize), format: format) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
            let sampleRate = buffer.format.sampleRate
            self.audioProcessingQueue.async { [weak self] in
                self?.processSamples(samples, sampleRate: sampleRate)
            }
        }

        do {
            try engine.start()
            isStarting = false
            isRunning = true
            captureError = nil
        } catch {
            microphoneEngine = nil
            isRunning = false
            captureError = "Microphone capture could not start: \(error.localizedDescription)"
        }
    }

    private func stopMicrophone() {
        microphoneEngine?.inputNode.removeTap(onBus: 0)
        microphoneEngine?.stop()
        microphoneEngine = nil
    }

    // MARK: - Signal analysis

    private func processSamples(
        _ samples: [Float],
        sampleRate: Double,
        smoothingFrameMultiplier: Float = 1,
        advancedSampleCount: Int? = nil
    ) {
        #if DEBUG
        let processStartTime = DispatchTime.now().uptimeNanoseconds
        defer { recordProcessingTime(since: processStartTime) }
        #endif

        let frameCount = samples.count
        guard frameCount > 0, sampleRate > 0 else { return }
        let copyCount = min(frameCount, fftSize)
        let currentSensitivity = Float(sensitivity)
        let currentSmoothing = Float(smoothing)
        let autoGainActive = autoGainEnabled

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(copyCount))

        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(copyCount))
        for index in 0..<copyCount {
            fftSignal[index] = (samples[index] - mean) * window[index]
        }
        if copyCount < fftSize {
            fftSignal.withUnsafeMutableBufferPointer { pointer in
                vDSP_vclr(
                    pointer.baseAddress!.advanced(by: copyCount),
                    1,
                    vDSP_Length(fftSize - copyCount)
                )
            }
        }

        let halfN = fftSize / 2
        for index in 0..<halfN {
            fftReal[index] = fftSignal[2 * index]
            fftImaginary[index] = fftSignal[2 * index + 1]
        }

        guard let fftSetup else { return }
        fftReal.withUnsafeMutableBufferPointer { realPointer in
            fftImaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imaginaryPointer.baseAddress!
                )
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                var scale = Float(2.0 / Float(fftSize))
                vDSP_vsmul(split.realp, 1, &scale, split.realp, 1, vDSP_Length(halfN))
                vDSP_vsmul(split.imagp, 1, &scale, split.imagp, 1, vDSP_Length(halfN))
                vDSP_zvabs(&split, 1, &fftMagnitudes, 1, vDSP_Length(halfN))
            }
        }
        fftMagnitudes[0] = 0

        prepareFrequencyBands(sampleRate: sampleRate)
        guard bandBinRanges.count == fftBands.count else { return }
        var bandEnergy: Float = 0
        for index in fftBands.indices {
            let range = bandBinRanges[index]
            var sumSquares: Float = 0
            var peak: Float = 0
            for bin in range.low...range.high {
                sumSquares += fftMagnitudes[bin] * fftMagnitudes[bin]
                peak = max(peak, fftMagnitudes[bin])
            }
            let bandRMS = sqrt(sumSquares / Float(range.high - range.low + 1))
            let bandMagnitude = bandRMS * 0.45 + peak * 0.55
            fftBands[index] = bandMagnitude
            bandEnergy += bandMagnitude * bandMagnitude * bandCompensationPower[index]
        }

        // AGC keeps adapting while off so switching it on takes effect at once.
        // With it off both gains are exactly the sensitivity, as before.
        autoGain.update(
            rmsDB: 20 * log10(max(rms, 0.000_001)),
            bandEnergyDB: 10 * log10(max(bandEnergy / Float(fftBands.count), 0.000_000_000_001)),
            duration: Float(advancedSampleCount ?? frameCount) / Float(sampleRate)
        )
        var volumeGain = currentSensitivity
        var spectrumGain = currentSensitivity
        if autoGainActive {
            volumeGain *= pow(10, autoGain.volumeGainDB / 20)
            spectrumGain *= pow(10, autoGain.spectrumGainDB / 20)
        }

        let adjustedRMS = max(rms * volumeGain, 0.000_001)
        let rmsDB = 20 * log10(adjustedRMS)
        let linearLevel = min(1, max(0, (rmsDB + 60) / 48))
        let visualVolume = CGFloat(pow(linearLevel, 0.72))

        for index in fftBands.indices {
            let magnitude = max(0.000_001, fftBands[index] * spectrumGain)
            let frequencyCompensation = Float(index) / 63 * 9
            let decibels = 20 * log10(magnitude) + frequencyCompensation
            let normalizedDB = min(1, max(0, (decibels + 72) / 54))
            fftBands[index] = pow(normalizedDB, 0.72)
        }

        // Kick-drum band for beat detection, independent of the smoothed spectrum.
        var bassEnergy: Float = 0
        for bin in lowestBassBin...highestBassBin {
            bassEnergy += fftMagnitudes[bin] * fftMagnitudes[bin]
        }
        let bassRMS = sqrt(bassEnergy / Float(highestBassBin - lowestBassBin + 1))
        let bassDB = 20 * log10(max(0.000_001, bassRMS * spectrumGain))
        let bassLevel = min(1, max(0, (bassDB + 48) / 36))
        let beat = beatTracker.analyze(
            bassEnergy: bassEnergy,
            bassLevel: bassLevel,
            bands: fftBands,
            magnitudes: fftMagnitudes,
            advancedSampleCount: advancedSampleCount ?? frameCount,
            sampleRate: sampleRate,
            arrivalTime: BeatClock.now
        )

        for index in 0..<64 {
            let left = fftBands[max(0, index - 1)]
            let right = fftBands[min(63, index + 1)]
            spreadBands[index] = max(
                fftBands[index],
                fftBands[index] * 0.64 + (left + right) * 0.18
            )
        }

        for index in 0..<64 {
            let target = spreadBands[index]
            let current = smoothedSpectrum[index]
            let baseAlpha = target > current
                ? min(0.55, currentSmoothing * 0.55)
                : min(0.96, 0.55 + currentSmoothing * 0.43)
            // The multiplier scales each step to the samples it covers, so the
            // response time in seconds does not depend on the analysis rate.
            let alpha = pow(baseAlpha, smoothingFrameMultiplier)
            smoothedSpectrum[index] = current * alpha + target * (1 - alpha)
        }

        let waveformStep = Double(copyCount) / 256
        for index in 0..<256 {
            let sampleIndex = min(copyCount - 1, Int(Double(index) * waveformStep))
            let value = (samples[sampleIndex] - mean) * volumeGain * 2.5
            waveformScratch[index] = CGFloat(min(1, max(-1, value)))
        }

        var dominantBin = lowestDominantBin
        if lowestDominantBin <= highestDominantBin {
            for bin in lowestDominantBin...highestDominantBin where fftMagnitudes[bin] > fftMagnitudes[dominantBin] {
                dominantBin = bin
            }
        }
        let binWidth = sampleRate / Double(fftSize)
        let frequency = fftMagnitudes[dominantBin] > 0.000_001
            ? Double(dominantBin) * binWidth
            : 0

        storeLatestFrame(
            volume: visualVolume,
            dominantFrequency: frequency,
            autoGainDB: autoGainActive ? Double(autoGain.volumeGainDB) : 0,
            beat: beat
        )
    }

    // MARK: - Publishing

    /// Replaces the pending frame and queues a main-thread publish if none is
    /// waiting. Runs on the audio queue and does not allocate.
    private func storeLatestFrame(
        volume: CGFloat,
        dominantFrequency: Double,
        autoGainDB: Double,
        beat: BeatAnalysis
    ) {
        let publishDelay = pendingVisualization.withLockUnchecked { state in
            for index in 0..<64 {
                state.frame.spectrum[index] = CGFloat(smoothedSpectrum[index])
            }
            state.frame.waveform.withUnsafeMutableBufferPointer { destination in
                waveformScratch.withUnsafeBufferPointer { source in
                    destination.baseAddress!.update(from: source.baseAddress!, count: 256)
                }
            }
            state.frame.volume = volume
            state.frame.dominantFrequency = dominantFrequency
            state.frame.autoGainDB = autoGainDB
            // Frames that never reach the screen must not swallow a beat.
            let unpublishedBeat = state.frame.beat.isBeat
            let unpublishedFlux = state.frame.beat.onsetFlux
            state.frame.beat = beat
            state.frame.beat.isBeat = beat.isBeat || unpublishedBeat
            state.frame.beat.onsetFlux = max(beat.onsetFlux, unpublishedFlux)
            return state.reservePublish(now: BeatClock.now, minimumInterval: minimumPublishInterval)
        }
        if let publishDelay {
            schedulePublish(after: publishDelay)
        }
    }

    private func schedulePublish(after delay: TimeInterval) {
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: publishBlock)
        } else {
            DispatchQueue.main.async(execute: publishBlock)
        }
    }

    private func publishPendingVisualization() {
        let frame = pendingVisualization.withLockUnchecked { state in
            // Copy into fresh storage so the audio queue keeps sole ownership of
            // the pending arrays and never triggers a copy-on-write.
            var frame = state.frame
            frame.spectrum = state.frame.spectrum.withUnsafeBufferPointer { Array($0) }
            frame.waveform = state.frame.waveform.withUnsafeBufferPointer { Array($0) }
            state.frame.beat.isBeat = false
            state.frame.beat.onsetFlux = 0
            state.publishScheduled = false
            state.lastPublishTime = BeatClock.now
            #if DEBUG
            state.publishCount += 1
            #endif
            return frame
        }
        visualization = frame
    }

    #if DEBUG
    /// Logs the average processSamples() cost and the analysis and publish rates
    /// every couple of seconds. View with Xcode's console or
    /// `log stream --predicate 'subsystem == "com.auraviz.app"'`.
    private func recordProcessingTime(since startTime: UInt64) {
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startTime
        debugProcessCount += 1
        debugProcessNanoseconds += elapsedNanoseconds
        debugMaxProcessNanoseconds = max(debugMaxProcessNanoseconds, elapsedNanoseconds)

        let now = BeatClock.now
        let windowDuration = now - debugStatsStartTime
        guard windowDuration >= debugStatsInterval else { return }

        let publishCount = pendingVisualization.withLockUnchecked { $0.publishCount }
        // Skip the first window and any window that spans a capture pause.
        if debugStatsStartTime > 0, windowDuration < debugStatsInterval * 2 {
            let averageMicroseconds = Double(debugProcessNanoseconds) / Double(debugProcessCount) / 1_000
            let maximumMicroseconds = Double(debugMaxProcessNanoseconds) / 1_000
            let analysisRate = Double(debugProcessCount) / windowDuration
            let publishRate = Double(publishCount - debugStatsStartPublishCount) / windowDuration
            let coreLoad = Double(debugProcessNanoseconds) / 1_000_000_000 / windowDuration * 100
            Self.analysisLogger.notice(
                "processSamples avg \(averageMicroseconds, format: .fixed(precision: 1), privacy: .public) µs, max \(maximumMicroseconds, format: .fixed(precision: 1), privacy: .public) µs, \(analysisRate, format: .fixed(precision: 1), privacy: .public) analyses/s (\(coreLoad, format: .fixed(precision: 2), privacy: .public)% of a core), published \(publishRate, format: .fixed(precision: 1), privacy: .public) frames/s"
            )
        }

        debugStatsStartTime = now
        debugStatsStartPublishCount = publishCount
        debugProcessCount = 0
        debugProcessNanoseconds = 0
        debugMaxProcessNanoseconds = 0
    }
    #endif

    private func prepareFrequencyBands(sampleRate: Double) {
        guard sampleRate != cachedBandSampleRate else { return }

        let halfN = fftSize / 2
        let binWidth = sampleRate / Double(fftSize)
        let minFrequency = max(35.0, binWidth)
        let maxFrequency = min(16_000.0, sampleRate * 0.5 - binWidth)
        guard maxFrequency > minFrequency else {
            bandBinRanges.removeAll(keepingCapacity: true)
            cachedBandSampleRate = sampleRate
            return
        }

        let logMinFrequency = log(minFrequency)
        let logFrequencyRange = log(maxFrequency) - logMinFrequency
        bandBinRanges.removeAll(keepingCapacity: true)
        for index in 0..<64 {
            let lowFrequency = exp(logMinFrequency + Double(index) / 64 * logFrequencyRange)
            let highFrequency = exp(logMinFrequency + Double(index + 1) / 64 * logFrequencyRange)
            let lowBin = min(halfN - 1, max(1, Int(floor(lowFrequency / binWidth))))
            let highBin = min(halfN - 1, max(lowBin, Int(ceil(highFrequency / binWidth))))
            bandBinRanges.append((low: lowBin, high: highBin))
        }
        lowestDominantBin = max(1, Int(minFrequency / binWidth))
        highestDominantBin = min(halfN - 1, Int(maxFrequency / binWidth))
        lowestBassBin = min(halfN - 1, max(1, Int((40 / binWidth).rounded())))
        highestBassBin = min(halfN - 1, max(lowestBassBin, Int((150 / binWidth).rounded())))
        cachedBandSampleRate = sampleRate
    }
}

extension AudioEngineManager: SCStreamOutput, SCStreamDelegate {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else { return }
        processSystemAudioBuffer(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self, weak stream] in
            guard let self, let stream, self.systemAudioStream === stream else { return }
            self.systemAudioStream = nil
            self.isStarting = false
            self.isRunning = false
            self.captureError = "System audio capture stopped: \(error.localizedDescription)"
        }
    }
}

private enum AudioCaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display is available for system audio capture."
        }
    }
}
