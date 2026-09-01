import Foundation
import AVFoundation
import Accelerate
import Combine
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

enum InputMode: String, CaseIterable, Identifiable {
    case systemAudio = "System Audio"
    case microphone = "Microphone"

    var id: String { rawValue }
}

final class AudioEngineManager: NSObject, ObservableObject {
    @Published var spectrum: [CGFloat] = Array(repeating: 0.05, count: 64)
    @Published var waveform: [CGFloat] = Array(repeating: 0, count: 256)
    @Published var volume: CGFloat = 0
    @Published var dominantFrequency: Double = 0
    @Published var isRunning = false
    @Published var isStarting = false
    @Published var captureError: String?
    @Published var inputMode: InputMode = .systemAudio {
        didSet {
            guard inputMode != oldValue else { return }
            switchInput()
        }
    }

    @Published var sensitivity: Double = 1.0 // 0.3...2.2
    @Published var smoothing: Double = 0.75 // 0...0.92
    @Published var micPermissionGranted = false
    @Published var systemAudioPermissionGranted = false

    private var microphoneEngine: AVAudioEngine?
    private var systemAudioStream: SCStream?
    private var systemAudioStartTask: Task<Void, Never>?
    private var captureRequestID = UUID()
    private let audioProcessingQueue = DispatchQueue(
        label: "com.auraviz.system-audio",
        qos: .userInteractive
    )
    private var systemSampleAccumulator: [Float] = []

    private let fftSize = 4096
    private let log2n: vDSP_Length = 12 // 2^12 = 4096
    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    private var smoothedSpectrum: [Float] = Array(repeating: 0, count: 64)

    override init() {
        super.init()
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

    func resetVisualizationControls() {
        sensitivity = 1.0
        smoothing = 0.75
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
            systemSampleAccumulator.removeAll(keepingCapacity: true)
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
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
                configuration.queueDepth = 3
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

        var channelSums = [Float](repeating: 0, count: frameCount)
        var channelCounts = [Int](repeating: 0, count: frameCount)
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0

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
                        for frame in 0..<availableFrames {
                            for channel in 0..<channels {
                                channelSums[frame] += samples[frame * channels + channel]
                                channelCounts[frame] += 1
                            }
                        }
                    } else if isFloat, format.mBitsPerChannel == 64 {
                        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
                        let samples = data.assumingMemoryBound(to: Double.self)
                        let availableFrames = min(frameCount, sampleCount / channels)
                        for frame in 0..<availableFrames {
                            for channel in 0..<channels {
                                channelSums[frame] += Float(samples[frame * channels + channel])
                                channelCounts[frame] += 1
                            }
                        }
                    } else if isSignedInteger, format.mBitsPerChannel == 16 {
                        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                        let samples = data.assumingMemoryBound(to: Int16.self)
                        let availableFrames = min(frameCount, sampleCount / channels)
                        for frame in 0..<availableFrames {
                            for channel in 0..<channels {
                                channelSums[frame] += Float(samples[frame * channels + channel]) / 32_768
                                channelCounts[frame] += 1
                            }
                        }
                    } else if isSignedInteger, format.mBitsPerChannel == 32 {
                        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                        let samples = data.assumingMemoryBound(to: Int32.self)
                        let availableFrames = min(frameCount, sampleCount / channels)
                        for frame in 0..<availableFrames {
                            for channel in 0..<channels {
                                channelSums[frame] += Float(samples[frame * channels + channel]) / Float(Int32.max)
                                channelCounts[frame] += 1
                            }
                        }
                    }
                }
            }
        } catch {
            return
        }

        let monoSamples = channelSums.enumerated().map { index, sum in
            let count = channelCounts[index]
            return count > 0 ? sum / Float(count) : 0
        }

        systemSampleAccumulator.append(contentsOf: monoSamples)
        let hopSize = fftSize / 4
        while systemSampleAccumulator.count >= fftSize {
            processSamples(
                Array(systemSampleAccumulator.prefix(fftSize)),
                sampleRate: format.mSampleRate
            )
            systemSampleAccumulator.removeFirst(hopSize)
        }
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

    private func processSamples(_ samples: [Float], sampleRate: Double) {
        let frameCount = samples.count
        guard frameCount > 0, sampleRate > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameCount))
        let adjustedRMS = max(rms * Float(sensitivity), 0.000_001)
        let rmsDB = 20 * log10(adjustedRMS)
        let linearLevel = min(1, max(0, (rmsDB + 60) / 48))
        let visualVolume = CGFloat(pow(linearLevel, 0.72))

        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(frameCount))
        var signal = [Float](repeating: 0, count: fftSize)
        let copyCount = min(frameCount, fftSize)
        for index in 0..<copyCount {
            signal[index] = (samples[index] - mean) * window[index]
        }

        let halfN = fftSize / 2
        var real = [Float](repeating: 0, count: halfN)
        var imaginary = [Float](repeating: 0, count: halfN)
        for index in 0..<halfN {
            real[index] = signal[2 * index]
            imaginary[index] = signal[2 * index + 1]
        }
        var magnitudes = [Float](repeating: 0, count: halfN)

        guard let fftSetup else { return }
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imaginaryPointer.baseAddress!
                )
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                var scale = Float(2.0 / Float(fftSize))
                vDSP_vsmul(split.realp, 1, &scale, split.realp, 1, vDSP_Length(halfN))
                vDSP_vsmul(split.imagp, 1, &scale, split.imagp, 1, vDSP_Length(halfN))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }
        magnitudes[0] = 0

        let binWidth = sampleRate / Double(fftSize)
        let minFrequency = max(35.0, binWidth)
        let maxFrequency = min(16_000.0, sampleRate * 0.5 - binWidth)
        guard maxFrequency > minFrequency else { return }
        let logMinFrequency = log(minFrequency)
        let logFrequencyRange = log(maxFrequency) - logMinFrequency

        var bands = [Float](repeating: 0, count: 64)
        for index in 0..<64 {
            let lowFrequency = exp(logMinFrequency + Double(index) / 64 * logFrequencyRange)
            let highFrequency = exp(logMinFrequency + Double(index + 1) / 64 * logFrequencyRange)
            let lowBin = min(halfN - 1, max(1, Int(floor(lowFrequency / binWidth))))
            let highBin = min(halfN - 1, max(lowBin, Int(ceil(highFrequency / binWidth))))
            var sumSquares: Float = 0
            var peak: Float = 0
            for bin in lowBin...highBin {
                sumSquares += magnitudes[bin] * magnitudes[bin]
                peak = max(peak, magnitudes[bin])
            }
            let bandRMS = sqrt(sumSquares / Float(highBin - lowBin + 1))
            let magnitude = max(0.000_001, (bandRMS * 0.45 + peak * 0.55) * Float(sensitivity))
            let frequencyCompensation = Float(index) / 63 * 9
            let decibels = 20 * log10(magnitude) + frequencyCompensation
            let normalizedDB = min(1, max(0, (decibels + 72) / 54))
            bands[index] = pow(normalizedDB, 0.72)
        }

        var spreadBands = bands
        for index in 0..<64 {
            let left = bands[max(0, index - 1)]
            let right = bands[min(63, index + 1)]
            spreadBands[index] = max(
                bands[index],
                bands[index] * 0.64 + (left + right) * 0.18
            )
        }

        for index in 0..<64 {
            let target = spreadBands[index]
            let current = smoothedSpectrum[index]
            let alpha = target > current
                ? min(0.55, Float(smoothing) * 0.55)
                : min(0.96, 0.55 + Float(smoothing) * 0.43)
            smoothedSpectrum[index] = current * alpha + target * (1 - alpha)
        }

        var visualWaveform = [CGFloat](repeating: 0, count: 256)
        let waveformStep = Double(copyCount) / 256
        for index in 0..<256 {
            let sampleIndex = min(copyCount - 1, Int(Double(index) * waveformStep))
            let value = (samples[sampleIndex] - mean) * Float(sensitivity) * 2.5
            visualWaveform[index] = CGFloat(min(1, max(-1, value)))
        }

        let lowestDominantBin = max(1, Int(minFrequency / binWidth))
        let highestDominantBin = min(halfN - 1, Int(maxFrequency / binWidth))
        var dominantBin = lowestDominantBin
        if lowestDominantBin <= highestDominantBin {
            for bin in lowestDominantBin...highestDominantBin where magnitudes[bin] > magnitudes[dominantBin] {
                dominantBin = bin
            }
        }
        let frequency = magnitudes[dominantBin] > 0.000_001
            ? Double(dominantBin) * binWidth
            : 0
        let visualSpectrum = smoothedSpectrum.map { CGFloat($0) }

        DispatchQueue.main.async { [weak self] in
            self?.spectrum = visualSpectrum
            self?.waveform = visualWaveform
            self?.volume = visualVolume
            self?.dominantFrequency = frequency
        }
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
