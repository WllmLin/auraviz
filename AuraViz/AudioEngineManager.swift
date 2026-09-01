import Foundation
import AVFoundation
import Accelerate
import Combine

enum InputMode: String, CaseIterable, Identifiable {
    case microphone = "Microphone"
    case synth = "Synth"
    var id: String { rawValue }
}

final class AudioEngineManager: ObservableObject {
    @Published var spectrum: [CGFloat] = Array(repeating: 0.05, count: 64)
    @Published var waveform: [CGFloat] = Array(repeating: 0, count: 256)
    @Published var volume: CGFloat = 0
    @Published var isRunning: Bool = false
    @Published var inputMode: InputMode = .synth {
        didSet { switchInput() }
    }
    // Synth controls (exposed to UI)
    @Published var synthVolume: Double = 0.6 // 0..1
    @Published var synthFrequency: Double = 180 // Hz 20..800
    @Published var synthComplexity: Double = 0.5 // 0..1 adds harmonics
    @Published var sensitivity: Double = 1.0 // 0.2..2.0
    @Published var smoothing: Double = 0.75 // 0..0.95

    @Published var micPermissionGranted: Bool = false

    private var engine: AVAudioEngine?
    private var displayLink: Timer?
    private var synthPhase: Double = 0
    private var cancellables = Set<AnyCancellable>()

    // FFT
    private let fftSize = 1024
    private let log2n: vDSP_Length = 10 // 2^10 = 1024
    private var fftSetup: vDSP.FFT<DSPSplitComplex>?
    private var window: [Float] = []

    // For decaying peaks (used by Y2K) - exposed for visuals via spectrum
    // internal smoothing buffers
    private var smoothedSpectrum: [Float] = Array(repeating: 0, count: 64)

    init() {
        setupFFT()
        updateWindow()
        checkMicPermission()
        startSynth()
        // re-update window when fftSize changes? static
    }

    private func setupFFT() {
        if let setup = vDSP.FFT<DSPSplitComplex>(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) {
            fftSetup = setup
        }
        smoothedSpectrum = Array(repeating: 0, count: 64)
    }

    private func updateWindow() {
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    // MARK: - Public API
    func toggleRunning() {
        if isRunning { stop() } else { start() }
    }

    func start() {
        switch inputMode {
        case .synth:
            startSynth()
        case .microphone:
            startMicrophone()
        }
        isRunning = true
    }

    func stop() {
        stopMicrophone()
        stopSynthTimer()
        isRunning = false
    }

    func switchInput() {
        stopMicrophone()
        stopSynthTimer()
        if isRunning {
            start()
        } else {
            // if not running but switching to synth, start synth preview
            if inputMode == .synth { startSynth() }
        }
    }

    func checkMicPermission() {
#if os(macOS)
        // AVCapture for macOS permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micPermissionGranted = true
        default:
            micPermissionGranted = false
        }
#else
        micPermissionGranted = true
#endif
    }

    func requestMicPermission() {
#if os(macOS)
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.micPermissionGranted = granted
                if granted && self?.inputMode == .microphone {
                    self?.startMicrophone()
                }
            }
        }
#endif
    }

    // MARK: - Synth
    private func startSynth() {
        stopSynthTimer()
        // 60 fps synth
        displayLink = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.tickSynth()
        }
        RunLoop.main.add(displayLink!, forMode: .common)
        isRunning = true
    }

    private func stopSynthTimer() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func tickSynth() {
        // time delta approximate 1/60
        let dt = 1.0/60.0
        // phase increment: 2pi * freq * dt , but we map freq to visual speed
        let baseFreq = synthFrequency // 20..800
        synthPhase += 2 * .pi * (baseFreq / 220.0) * dt * 6.0 // scaled for visual
        if synthPhase > 1000 * .pi { synthPhase.formTruncatingRemainder(dividingBy: 2 * .pi) }

        // generate waveform (256 points) as sum of sines
        var wave: [CGFloat] = []
        wave.reserveCapacity(256)
        for i in 0..<256 {
            let t = Double(i) / 256.0 * 2 * .pi * 3.0 + synthPhase
            var v = sin(t) * synthVolume
            // add harmonics based on complexity
            if synthComplexity > 0.1 {
                v += sin(t*2.0 + synthPhase*0.7) * synthVolume * synthComplexity * 0.6
                v += sin(t*3.0 + synthPhase*1.3) * synthVolume * synthComplexity * 0.3
                v += sin(t*0.5) * synthVolume * 0.15
            }
            // add slight noise
            v += (Double.random(in: -0.02...0.02) * synthVolume * 0.1)
            wave.append(CGFloat(v))
        }

        // generate spectrum: 64 bands with shape centered around frequency
        // Map synthFrequency (20..800) to band peak position 0..64
        // Use log mapping: 20 Hz -> band 0, 800 Hz -> band 55
        let logMin = log(20.0)
        let logMax = log(800.0)
        let logF = log(max(20, baseFreq))
        let normalized = (logF - logMin) / (logMax - logMin) // 0..1
        let peakBand = normalized * 52 + 4 // keep edges
        var newSpec = [Float](repeating: 0, count: 64)
        for i in 0..<64 {
            let dist = abs(Double(i) - peakBand)
            let width = 8.0 - synthComplexity * 5.0
            let exponent = -(dist * dist) / (2 * width * width)
            let bell = exp(exponent)
            var mag: Float = Float(bell) * Float(synthVolume)
            let bassExp = exp(-Double(i) * 0.18)
            let bass: Float = Float(bassExp) * Float(synthVolume) * 0.25
            mag += bass
            if synthComplexity > 0.5 {
                let hsBase = Float(synthComplexity) * 0.18
                let rnd = Float.random(in: 0.7...1.0)
                let hs = hsBase * rnd
                let shimmerExp = exp(-abs(Double(i) - peakBand * 1.8) / 12.0)
                mag += hs * Float(shimmerExp)
            }
            mag *= Float.random(in: 0.85...1.08)
            mag = min(1, max(0, mag))
            newSpec[i] = mag
        }

        // Apply sensitivity and smoothing
        let smoothFactor = Float(smoothing)
        for i in 0..<64 {
            let target = newSpec[i] * Float(sensitivity)
            let cur = smoothedSpectrum[i]
            // exponential smoothing
            let smoothed = cur * smoothFactor + target * (1 - smoothFactor)
            smoothedSpectrum[i] = min(1, smoothed)
        }

        let vol = CGFloat(synthVolume) * (0.85 + 0.15 * CGFloat(sin(synthPhase * 0.5)))
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.spectrum = self.smoothedSpectrum.map { CGFloat($0) }
            self.waveform = wave
            self.volume = vol
        }
    }

    // MARK: - Microphone
    private func startMicrophone() {
        stopSynthTimer()
        checkMicPermission()
        guard micPermissionGranted else {
            // fallback to synth tick but show 0
            startSynth()
            return
        }
        let eng = AVAudioEngine()
        engine = eng
        let input = eng.inputNode
        let format = input.outputFormat(forBus: 0)
        // Ensure we have a format
        guard format.sampleRate > 0 else {
            startSynth()
            return
        }
        // Set up tap
        // Remove existing tap
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: UInt32(fftSize), format: format) { [weak self] buffer, time in
            self?.processMicBuffer(buffer)
        }
        do {
            try eng.start()
            isRunning = true
        } catch {
            print("AudioEngine start failed: \(error)")
            // fallback
            startSynth()
        }
    }

    private func stopMicrophone() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        if frameCount == 0 { return }

        // Prepare signal windowed
        let n = fftSize
        var signal = [Float](repeating: 0, count: n)
        let copyCount = min(frameCount, n)
        for i in 0..<copyCount {
            signal[i] = channelData[i] * window[i]
        }
        // compute RMS volume
        var rms: Float = 0
        vDSP_rmsqv(signal, 1, &rms, vDSP_Length(n))
        let vol = CGFloat(min(1, rms * 8 * Float(sensitivity))) // scale

        // FFT processing
        // Use vDSP.FFT for real signal: pack as split complex via interleaving
        // Steps: create arrays for real/imag of size n/2
        let halfN = n / 2
        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN {
            real[i] = signal[2*i]
            imag[i] = signal[2*i+1]
        }
        var outputReal = [Float](repeating: 0, count: halfN)
        var outputImag = [Float](repeating: 0, count: halfN)
        var mags = [Float](repeating: 0, count: halfN)

        guard let fft = fftSetup else { return }
        // Use safe buffer pointers to avoid temporary-pointer diagnostics
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                outputReal.withUnsafeMutableBufferPointer { outRealPtr in
                    outputImag.withUnsafeMutableBufferPointer { outImagPtr in
                        var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                        var outSplit = DSPSplitComplex(realp: outRealPtr.baseAddress!, imagp: outImagPtr.baseAddress!)
                        fft.forward(input: split, output: &outSplit)
                        vDSP_zvabs(&outSplit, 1, &mags, 1, vDSP_Length(halfN))
                    }
                }
            }
        }
        // Normalize mags (divide by n)
        var scale = Float(1.0 / Float(n))
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(halfN))
        // Apply log scale? For visualization we map to 64 bands with log spacing
        // Create 64 bands from 512 freq bins (halfN =512) with logarithmic grouping
        var bands = [Float](repeating: 0, count: 64)
        // Log-spaced: each band covers increasing bins
        for i in 0..<64 {
            // simpler linear-log: map i to bin range
            let low = Int(pow(Double(i)/64.0, 0.7) * Double(halfN-1))
            let high = Int(pow(Double(i+1)/64.0, 0.7) * Double(halfN-1))
            let lo = min(max(low, 0), halfN-1)
            let hi = min(max(high, lo+1), halfN-1)
            var sum: Float = 0
            var maxV: Float = 0
            for b in lo...hi {
                sum += mags[b]
                maxV = max(maxV, mags[b])
            }
            let avg = sum / Float(hi-lo+1)
            // blend avg and max, apply sensitivity and scale
            var val = (avg * 0.6 + maxV * 0.4) * 18.0 * Float(sensitivity)
            // compress with log
            val = log1p(val * 5) / log1p(5) // normalize 0..1 approx
            bands[i] = min(1, max(0, val))
        }

        // Smoothing
        for i in 0..<64 {
            let target = bands[i]
            let cur = smoothedSpectrum[i]
            let alpha = Float(smoothing)
            smoothedSpectrum[i] = cur * alpha + target * (1 - alpha)
        }

        // Waveform: downsample signal to 256
        var wave = [CGFloat](repeating: 0, count: 256)
        let step = Double(n) / 256.0
        for i in 0..<256 {
            let idx = Int(Double(i) * step)
            wave[i] = CGFloat(signal[idx]) * CGFloat(sensitivity) * 2.5
        }

        DispatchQueue.main.async { [weak self] in
            self?.spectrum = self?.smoothedSpectrum.map { CGFloat($0) } ?? []
            self?.waveform = wave
            self?.volume = vol
        }
    }
}
