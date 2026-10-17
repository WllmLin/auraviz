import SwiftUI

/// One frozen spectrum snapshot used to draw fading "echo" trails behind the live wave.
private struct WaveEchoFrame {
    var low: [CGFloat]
    var mid: [CGFloat]
    var high: [CGFloat]
    var volume: CGFloat
}

struct WaveVisualizerView: View {
    var spectrum: [CGFloat]
    /// Retained for API compatibility; the curve shape now comes from `spectrum` regions.
    var waveform: [CGFloat]
    var volume: CGFloat
    var theme: ColorTheme
    var sensitivity: Double
    var isActive: Bool = true

    /// Last ~30 published spectrum frames (oldest first), driving the fading echo lines.
    @State private var echoHistory: [WaveEchoFrame] = []

    private static let historyLimit = 30
    private static let maxEchoesDrawn = 10
    private static let echoStride = 3
    private static let lowRange = 0..<12
    private static let midRange = 12..<32
    private static let highRange = 32..<64
    private static let curvePoints = 180
    private static let echoPoints = 90

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(in: &context, size: size, time: t)
            }
        }
        .background(Color.clear)
        .onChange(of: spectrum) { _, newSpectrum in
            pushEchoFrame(spectrum: newSpectrum, volume: volume)
        }
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, time t: Double) {
        let w = size.width
        let h = size.height
        let centerY = h * 0.52
        let g = theme.gradient
        let maxAmplitude = h * 0.42

        // background subtle grid
        let gridColor = Color.white.opacity(0.04)
        let gridSpacing: CGFloat = 28
        var gridPath = Path()
        for x in stride(from: 0, through: w, by: gridSpacing) {
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: h))
        }
        for y in stride(from: 0, through: h, by: gridSpacing) {
            gridPath.move(to: CGPoint(x: 0, y: y))
            gridPath.addLine(to: CGPoint(x: w, y: y))
        }
        context.stroke(gridPath, with: .color(gridColor), lineWidth: 0.6)

        // Each layer owns one spectrum region; its curve is that region's bands
        // mapped across the width (mirrored around center) via Catmull-Rom.
        let slices = [
            Self.regionSlice(spectrum, Self.lowRange),
            Self.regionSlice(spectrum, Self.midRange),
            Self.regionSlice(spectrum, Self.highRange),
        ]
        let colors = [g[0], g.count > 1 ? g[1] : g[0], g.last ?? g[0]]
        let baseYs = [centerY, centerY + 6, centerY - 6]

        // Fading echo trails behind the live wave.
        drawEchoes(in: &context, width: w, baseYs: baseYs, colors: colors, maxAmplitude: maxAmplitude)

        // Live layered waves with fill + glow + white core.
        for idx in 0..<3 {
            let col = colors[idx]
            let baseY = baseYs[idx]
            let slice = slices[idx]
            let amplitude = amplitude(for: slice, volume: volume, layerIndex: idx, maxAmplitude: maxAmplitude)
            let path = wavePath(
                slice: slice, baseY: baseY, amplitude: amplitude,
                width: w, points: Self.curvePoints, time: t, layerIndex: idx
            )

            var fillPath = path
            fillPath.addLine(to: CGPoint(x: w, y: h + 20))
            fillPath.addLine(to: CGPoint(x: 0, y: h + 20))
            fillPath.closeSubpath()

            // glow fill
            let fillGrad = Gradient(colors: [col.opacity(0.45), col.opacity(0.08), Color.clear])
            context.fill(fillPath, with: .linearGradient(fillGrad, startPoint: CGPoint(x: 0, y: baseY - amplitude), endPoint: CGPoint(x: 0, y: h)))

            // stroke with shadow for glow
            context.stroke(path, with: .color(col.opacity(0.28)), lineWidth: 12)
            context.stroke(path, with: .color(col), lineWidth: 2.4)
            // white core highlight
            context.stroke(path, with: .color(.white.opacity(0.55)), lineWidth: 1.0)
        }

        // center horizontal shine line
        var shine = Path()
        shine.move(to: CGPoint(x: 0, y: centerY))
        shine.addLine(to: CGPoint(x: w, y: centerY))
        context.stroke(shine, with: .color(.white.opacity(0.06)), lineWidth: 1)

        // volume-linked orb at center
        let orbR = 14 + volume * 18
        let orbGrad = Gradient(colors: [Color.white.opacity(0.9), theme.gradient[0].opacity(0.9)])
        let orbRect = CGRect(x: w / 2 - orbR, y: centerY - orbR, width: orbR * 2, height: orbR * 2)
        context.fill(Path(ellipseIn: orbRect), with: .radialGradient(orbGrad, center: CGPoint(x: w / 2, y: centerY), startRadius: 0, endRadius: orbR))
        context.stroke(Path(ellipseIn: orbRect.insetBy(dx: -6, dy: -6)), with: .color(theme.gradient[0].opacity(0.25)), lineWidth: 10)
    }

    /// Past spectrum shapes as thin fading strokes (no fill/glow), oldest faintest
    /// and sunk slightly lower for a sense of motion.
    private func drawEchoes(in context: inout GraphicsContext, width w: CGFloat, baseYs: [CGFloat], colors: [Color], maxAmplitude: CGFloat) {
        let picks = echoPicks()
        guard !picks.isEmpty else { return }
        for (j, frame) in picks.enumerated() {
            let frac = Double(j + 1) / Double(picks.count + 1) // 0 = oldest, 1 = newest
            let alpha = 0.04 + 0.20 * pow(frac, 1.5)
            let drift = CGFloat(picks.count - j) * 0.9
            let frameSlices = [frame.low, frame.mid, frame.high]
            for idx in 0..<3 {
                let slice = frameSlices[idx]
                let path = wavePath(
                    slice: slice, baseY: baseYs[idx],
                    amplitude: amplitude(for: slice, volume: frame.volume, layerIndex: idx, maxAmplitude: maxAmplitude),
                    width: w, points: Self.echoPoints, time: nil, layerIndex: idx, yDrift: drift
                )
                context.stroke(path, with: .color(colors[idx].opacity(alpha)), lineWidth: 1.1)
            }
        }
    }

    // MARK: - Curve construction

    /// Builds one layer's curve: the region's bands sampled by distance from
    /// center (mirrored), scaled by amplitude, faded at the edges. A small
    /// idle sine is added only when `time` is provided (live wave, not echoes).
    private func wavePath(slice: [CGFloat], baseY: CGFloat, amplitude: CGFloat, width w: CGFloat, points: Int, time t: Double?, layerIndex idx: Int, yDrift: CGFloat = 0) -> Path {
        var path = Path()
        guard w > 0, points > 0 else { return path }
        // Smooth the bands first, then smooth along x after sampling, so the
        // curve reads as soft hills instead of jagged spikes.
        let smooth = Self.smoothSlice(slice)
        var shapes = [CGFloat](repeating: 0, count: points + 1)
        for i in 0...points {
            let x = CGFloat(i) / CGFloat(points) * w
            let distanceFromCenter = abs(x - w / 2) / (w / 2) // 0 at center, 1 at edges
            shapes[i] = Self.spectrumShape(slice: smooth, distanceFromCenter: distanceFromCenter)
        }
        shapes = Self.smoothCurve(shapes)
        for i in 0...points {
            let x = CGFloat(i) / CGFloat(points) * w
            let envelope = sin(CGFloat(i) / CGFloat(points) * .pi) // fade edges
            var y = baseY + yDrift - shapes[i] * amplitude * envelope
            if let t {
                y += Self.idleOffset(x: x, time: t, layer: idx) * envelope
            }
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    /// Sample the band region at a mirrored position: the region's first band
    /// sits at the center, its last band at the edges, smoothly interpolated.
    private static func spectrumShape(slice: [CGFloat], distanceFromCenter d: CGFloat) -> CGFloat {
        guard slice.count > 1 else { return max(0, slice.first ?? 0) }
        let pos = max(0, min(1, d)) * CGFloat(slice.count - 1)
        return max(0, catmullRom(slice, position: pos))
    }

    /// Uniform Catmull-Rom through `p` at fractional index `pos`.
    /// The start index reflects so the mirrored curve has zero slope at center
    /// (no pointed cusp at the orb), and the result is clamped to the
    /// segment's endpoint range so loud bands can't throw overshoot spikes.
    private static func catmullRom(_ p: [CGFloat], position pos: CGFloat) -> CGFloat {
        guard !p.isEmpty else { return 0 }
        guard p.count > 1 else { return p[0] }
        let clamped = max(0, min(CGFloat(p.count - 1), pos))
        let i = min(p.count - 2, Int(floor(clamped)))
        let f = clamped - CGFloat(i)
        func at(_ k: Int) -> CGFloat {
            if k < 0 { return p[min(1, p.count - 1)] } // reflect at start
            return p[min(p.count - 1, k)]
        }
        let p0 = at(i - 1)
        let p1 = p[i]
        let p2 = p[i + 1]
        let p3 = at(i + 2)
        let f2 = f * f
        let f3 = f2 * f
        let raw = 0.5 * ((2 * p1) + (-p0 + p2) * f + (2 * p0 - 5 * p1 + 4 * p2 - p3) * f2 + (-p0 + 3 * p1 - 3 * p2 + p3) * f3)
        return min(max(p1, p2), max(min(p1, p2), raw))
    }

    /// 3-tap binomial smoothing of one band region (clamped ends). Tames
    /// per-band jitter before interpolation.
    private static func smoothSlice(_ s: [CGFloat]) -> [CGFloat] {
        guard s.count > 2 else { return s }
        var out = s
        for i in 0..<s.count {
            let a = s[max(0, i - 1)], b = s[i], c = s[min(s.count - 1, i + 1)]
            out[i] = (a + 2 * b + c) / 4
        }
        return out
    }

    /// 5-tap binomial smoothing along x with mirrored ends. The symmetric
    /// kernel preserves the curve's mirror symmetry while removing jagged edges.
    private static func smoothCurve(_ v: [CGFloat]) -> [CGFloat] {
        guard v.count > 4 else { return v }
        let n = v.count
        func at(_ k: Int) -> CGFloat {
            if k < 0 { return v[min(n - 1, -k)] }
            if k >= n { return v[max(0, 2 * n - 2 - k)] }
            return v[k]
        }
        var out = v
        for i in 0..<n {
            out[i] = (at(i - 2) + 4 * at(i - 1) + 6 * v[i] + 4 * at(i + 1) + at(i + 2)) / 16
        }
        return out
    }

    /// Gentle sine drift so the view stays alive during silence. Deliberately
    /// small (~±7.5 px) next to the spectrum-driven displacement.
    private static func idleOffset(x: CGFloat, time t: Double, layer idx: Int) -> CGFloat {
        let p1 = t * (1.4 + Double(idx) * 0.35) + Double(idx) * 1.7
        let p2 = t * 0.9 - Double(idx) * 0.9
        return sin(x * 0.008 + CGFloat(p1)) * 5.0 + sin(x * 0.021 + CGFloat(p2)) * 2.5
    }

    private func amplitude(for slice: [CGFloat], volume: CGFloat, layerIndex idx: Int, maxAmplitude: CGFloat) -> CGFloat {
        let mean = slice.isEmpty ? 0 : slice.reduce(0, +) / CGFloat(slice.count)
        let raw = (30 + mean * 130 * CGFloat(sensitivity) + volume * 25) * (0.9 + CGFloat(idx) * 0.12)
        return min(raw, max(0, maxAmplitude))
    }

    private static func regionSlice(_ spectrum: [CGFloat], _ range: Range<Int>) -> [CGFloat] {
        range.compactMap { $0 < spectrum.count ? spectrum[$0] : nil }
    }

    // MARK: - Echo history

    private func pushEchoFrame(spectrum: [CGFloat], volume: CGFloat) {
        echoHistory.append(WaveEchoFrame(
            low: Self.regionSlice(spectrum, Self.lowRange),
            mid: Self.regionSlice(spectrum, Self.midRange),
            high: Self.regionSlice(spectrum, Self.highRange),
            volume: volume
        ))
        if echoHistory.count > Self.historyLimit {
            echoHistory.removeFirst(echoHistory.count - Self.historyLimit)
        }
    }

    /// Evenly spaced past frames (every Nth, newest included), oldest first.
    private func echoPicks() -> [WaveEchoFrame] {
        let recent = Array(echoHistory.suffix(Self.historyLimit))
        guard !recent.isEmpty else { return [] }
        var picks: [WaveEchoFrame] = []
        for (idx, frame) in recent.enumerated() {
            if (recent.count - 1 - idx) % Self.echoStride == 0 {
                picks.append(frame)
            }
        }
        if picks.count > Self.maxEchoesDrawn {
            picks = Array(picks.suffix(Self.maxEchoesDrawn))
        }
        return picks
    }
}
