import SwiftUI

struct CircularVisualizerView: View {
    var spectrum: [CGFloat]
    var volume: CGFloat
    var theme: ColorTheme
    var sensitivity: Double
    var framesPerSecond: Int = 30
    var isActive: Bool = true
    var beat = BeatAnalysis()
    /// 0 keeps the volume-only look; 1 applies the full beat effects.
    var beatReactivity: Double = 0

    @State private var barRotation = BeatSyncedPhase()

    var body: some View {
        let palette = NeonPalette(theme: theme)
        TimelineView(.animation(minimumInterval: 1.0 / Double(max(1, framesPerSecond)), paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let now = BeatClock.time(for: timeline.date)
            let beatAge = beat.beatAge(at: now)
            let flash = beatFlash(at: now)
            let beatPhase = beat.clock.beatPhase(at: now)
            // One full turn per 4 bars at full reactivity.
            let rotation = barRotation.advance(
                to: t,
                wallRate: 0.18,
                gridPhase: beat.clock.barPhase(at: now),
                gridRate: .pi / 2,
                nominalGridSpeed: beat.clock.beatsPerSecond / 4,
                reactivity: beatReactivity
            )
            let punch = beatPunch(age: beatAge)
            let glowBoost = beatGlow(at: now, age: beatAge)
            Canvas { context, size in
                let w = size.width
                let h = size.height
                let center = CGPoint(x: w/2, y: h/2)
                let s = size.visualizerScale
                // Fit the whole composition (core + bars + orbit + ticks) inside
                // the smaller dimension so the circle is never clipped top/bottom.
                let available = min(w, h) / 2 - 18 * s
                guard available > 40 else { return }
                let baseRadius = available * 0.38
                // Kick-driven breathing; a gentler volume swell keeps the
                // detailed core readable instead of constantly resizing.
                let pulse = 1.0 + Double(volume) * 0.18 + flash * 0.06 + punch + sin(t*2.2)*0.015
                let radius = baseRadius * pulse

                // soft glow behind
                let glowRadius = min(radius * 2.2, available * 1.05)
                let glowGradient = Gradient(colors: theme.gradient.map { $0.opacity(0.35 + 0.3 * glowBoost) } + [Color.clear])
                let glowRect = CGRect(x: center.x - glowRadius, y: center.y - glowRadius, width: glowRadius*2, height: glowRadius*2)
                context.fill(Path(ellipseIn: glowRect), with: .radialGradient(glowGradient, center: center, startRadius: radius, endRadius: glowRadius))

                drawNeonCore(in: context, center: center, radius: radius, baseRadius: baseRadius, scale: s, time: t, beatPhase: beatPhase, beatAge: beatAge, flash: flash, glowBoost: glowBoost, palette: palette)

                // radial bars
                let count = 72
                let barMax = available * 0.42
                for i in 0..<count {
                    let angle = (Double(i)/Double(count) * 2 * .pi) - .pi/2 + rotation
                    let amp = circularAmplitude(at: i, barCount: count)
                    let innerR = radius + 6 * s
                    // Clamp so high sensitivity saturates instead of clipping.
                    let maxLen = max(8 * s, available - innerR - 12 * s)
                    let len = min(barMax * Double(amp) * sensitivity * 0.95 + 6 * s, maxLen)
                    let outerR = innerR + len
                    let x1 = center.x + cos(angle) * innerR
                    let y1 = center.y + sin(angle) * innerR
                    let x2 = center.x + cos(angle) * outerR
                    let y2 = center.y + sin(angle) * outerR

                    // color per bar based on amplitude + index
                    let hueShift = Double(i)/Double(count)
                    let ampBoost = Double(amp)
                    let baseColor = theme.gradient[Int((hueShift*Double(theme.gradient.count-1)).rounded())]
                    // interpolate brightness with amp
                    let col = baseColor.opacity(0.75 + ampBoost*0.25)

                    var path = Path()
                    path.move(to: CGPoint(x: x1, y: y1))
                    path.addLine(to: CGPoint(x: x2, y: y2))
                    // glow
                    context.stroke(path, with: .color(col.opacity(0.22)), lineWidth: 9 * s)
                    context.stroke(path, with: .color(col), lineWidth: 3.2 * s)
                    // tip dot
                    let tipSize = (3.2 + CGFloat(amp)*3.0) * s
                    let tipRect = CGRect(x: x2 - tipSize/2, y: y2 - tipSize/2, width: tipSize, height: tipSize)
                    context.fill(Path(ellipseIn: tipRect), with: .color(.white.opacity(0.95)))
                    context.fill(Path(ellipseIn: tipRect.insetBy(dx: -2 * s, dy: -2 * s)), with: .color(col.opacity(0.35)))
                }

                // outer thin orbit ring — pinned just inside the view edge
                let orbitR = available - 8 * s
                let orbitPath = Path(ellipseIn: CGRect(x: center.x - orbitR, y: center.y - orbitR, width: orbitR*2, height: orbitR*2))
                context.stroke(orbitPath, with: .color(.white.opacity(0.08)), lineWidth: 0.8 * s)
                // ticks
                for i in 0..<count {
                    if i % 6 != 0 { continue }
                    let angle = Double(i)/Double(count) * 2 * Double.pi - Double.pi/2
                    let r1 = orbitR + 2 * s
                    let r2 = orbitR + (4 + Double(volume)*2) * s
                    let x1 = center.x + cos(angle)*r1
                    let y1 = center.y + sin(angle)*r1
                    let x2 = center.x + cos(angle)*r2
                    let y2 = center.y + sin(angle)*r2
                    var p = Path()
                    p.move(to: CGPoint(x: x1, y: y1))
                    p.addLine(to: CGPoint(x:x2, y:y2))
                    context.stroke(p, with: .color(.white.opacity(0.18)), lineWidth: s)
                }

                // volume ring arc at bottom? show volume text
            }
        }
        .background(Color.clear)
    }

    private func beatFlash(at time: TimeInterval) -> Double {
        isActive ? beat.flash(at: time) : 0
    }

    /// Radius punch on each beat: up to +8% at full reactivity, easing back
    /// out over ~150 ms.
    private func beatPunch(age: TimeInterval) -> Double {
        guard isActive, age < 0.15 else { return 0 }
        let p = age / 0.15
        return beatReactivity * 0.08 * (0.6 + 0.4 * Double(beat.beatStrength)) * (1 - p) * (1 - p)
    }

    /// Brief glow boost after each beat, as bright as the bass hit.
    private func beatGlow(at time: TimeInterval, age: TimeInterval) -> Double {
        guard isActive else { return 0 }
        return beatReactivity * Double(beat.bassEnvelope(at: time)) * exp(-age / 0.2)
    }

    /// LED-tunnel core: tempo-synced rings flowing out of a bright eye, a
    /// spectrum-driven dot meter, a segmented LED ring and a white-hot neon rim
    /// that flares on every kick.
    private func drawNeonCore(in context: GraphicsContext, center: CGPoint, radius: Double, baseRadius: Double, scale s: Double, time t: Double, beatPhase: Double, beatAge: Double, flash: Double, glowBoost: Double, palette: NeonPalette) {
        func circle(_ r: Double) -> Path {
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r*2, height: r*2))
        }
        var glow = context
        glow.blendMode = .plusLighter
        let energy = Double(min(1, max(0, volume)))

        // dark lens so the neon reads against the aurora background
        context.fill(circle(radius), with: .radialGradient(Gradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.6)]), center: center, startRadius: 0, endRadius: radius))

        // tunnel rings — one ring is born per beat and accelerates outward
        let ringCount = 6
        let tunnelInner = radius * 0.08
        let tunnelOuter = radius * 0.50
        for k in 0..<ringCount {
            let p = ((Double(k) + beatPhase) / Double(ringCount)).truncatingRemainder(dividingBy: 1)
            let r = tunnelInner + (tunnelOuter - tunnelInner) * p * p
            let fade = sin(p * .pi)
            glow.stroke(circle(r), with: .color(palette.tunnel(p).opacity(fade * (0.35 + 0.25 * energy + 0.4 * flash))), lineWidth: (0.8 + 2.2 * p) * s)
        }
        // dashed boundary of the tunnel, crawling slowly
        context.stroke(circle(radius * 0.52), with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: s, dash: [2 * s, 4 * s], dashPhase: t * 6 * s))

        // bright eye
        let eyeR = radius * (0.045 + 0.035 * flash)
        glow.fill(circle(eyeR * 3.5), with: .radialGradient(Gradient(colors: [palette.hot.opacity(0.7), Color.clear]), center: center, startRadius: 0, endRadius: eyeR * 3.5))
        context.fill(circle(eyeR), with: .color(.white.opacity(0.95)))

        // kick shockwave from the eye to the rim
        let shockDuration = 0.4
        if isActive && beatAge < shockDuration {
            let p = beatAge / shockDuration
            let r = radius * (0.10 + 0.86 * (1 - pow(1 - p, 3)))
            glow.stroke(circle(r), with: .color(palette.rim.opacity((1 - p) * (0.25 + 0.5 * Double(beat.beatStrength)))), lineWidth: (1 + 3 * (1 - p)) * s)
        }

        // dot meter — three rows per column light up from the inside out with
        // that column's frequency energy; a gap every 8th column segments it
        let dotSize = max(1.6, radius * 0.028)
        let columns = dotCount(circleRadius: baseRadius * 0.64, spacing: 6 * s, range: 36...120)
        let gridRotation = -t * 0.12
        var litDots = Path()
        var dimDots = Path()
        for c in 0..<columns where c % 8 != 7 {
            let amp = Double(circularAmplitude(at: c, barCount: columns)) * sensitivity
            let angle = Double(c) / Double(columns) * 2 * .pi + gridRotation
            for row in 0..<3 {
                let rr = radius * (0.58 + 0.065 * Double(row))
                let rect = CGRect(x: center.x + cos(angle) * rr - dotSize/2, y: center.y + sin(angle) * rr - dotSize/2, width: dotSize, height: dotSize)
                if amp > 0.3 + 0.2 * Double(row) {
                    litDots.addEllipse(in: rect)
                } else {
                    dimDots.addEllipse(in: rect)
                }
            }
        }
        context.fill(dimDots, with: .color(palette.grid.opacity(0.16)))
        glow.fill(litDots, with: .color(palette.grid.opacity(0.95)))

        context.stroke(circle(radius * 0.78), with: .color(.white.opacity(0.18)), lineWidth: 0.8 * s)

        // segmented LED ring — brightness bucketed so each level is one fill
        let ledR = radius * 0.86
        let ledCount = dotCount(circleRadius: baseRadius * 0.86, spacing: 5.5 * s, range: 48...180)
        let ledRotation = t * 0.2
        let ledSize = max(1.8, radius * 0.032)
        var ledLevels = Array(repeating: Path(), count: 4)
        var hotCores = Path()
        for i in 0..<ledCount where i % 6 != 5 {
            let amp = min(1, Double(circularAmplitude(at: i, barCount: ledCount)) * sensitivity)
            let level = min(3, Int(amp * 4))
            let angle = Double(i) / Double(ledCount) * 2 * .pi + ledRotation
            let x = center.x + cos(angle) * ledR
            let y = center.y + sin(angle) * ledR
            ledLevels[level].addEllipse(in: CGRect(x: x - ledSize/2, y: y - ledSize/2, width: ledSize, height: ledSize))
            if level == 3 {
                hotCores.addEllipse(in: CGRect(x: x - ledSize/4, y: y - ledSize/4, width: ledSize/2, height: ledSize/2))
            }
        }
        context.fill(ledLevels[0], with: .color(palette.led.opacity(0.18)))
        for level in 1...3 {
            glow.fill(ledLevels[level], with: .color(palette.led.opacity(0.25 + 0.25 * Double(level))))
        }
        glow.fill(hotCores, with: .color(.white.opacity(0.9)))

        context.stroke(circle(radius * 0.92), with: .color(palette.led.opacity(0.3)), lineWidth: 0.8 * s)

        // neon rim — stacked strokes fake a bloom around a white-hot line
        let rimPath = circle(radius * 0.97)
        let intensity = 0.55 + 0.3 * energy + 0.45 * flash + 0.6 * glowBoost
        glow.stroke(rimPath, with: .color(palette.rim.opacity(0.10 * intensity)), lineWidth: radius * 0.22)
        glow.stroke(rimPath, with: .color(palette.rim.opacity(0.22 * intensity)), lineWidth: radius * 0.10)
        glow.stroke(rimPath, with: .color(palette.rim.opacity(0.55 * intensity)), lineWidth: radius * 0.04)
        glow.stroke(rimPath, with: .color(.white.opacity(min(1, 0.6 + 0.4 * intensity))), lineWidth: max(1.2 * s, radius * 0.012))
    }

    /// Dot count for a ring, derived from the un-pulsed radius so the
    /// spectrum mapping stays stable while the core breathes.
    private func dotCount(circleRadius: Double, spacing: Double, range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, Int(2 * .pi * circleRadius / spacing)))
    }

    /// Folds the spectrum twice around the ring, then blends local frequency
    /// detail with the overall level. A frequency is therefore represented on
    /// opposite sides of the circle and every bar still responds to the beat.
    private func circularAmplitude(at index: Int, barCount: Int) -> CGFloat {
        guard !spectrum.isEmpty, barCount > 0 else { return 0 }

        let phase = Double(index) / Double(barCount) * 4.0
        let cycle = phase.truncatingRemainder(dividingBy: 2.0)
        let foldedPosition = cycle <= 1.0 ? cycle : 2.0 - cycle
        let spectrumPosition = foldedPosition * Double(spectrum.count - 1)
        let lowerIndex = Int(floor(spectrumPosition))
        let upperIndex = min(spectrum.count - 1, lowerIndex + 1)
        let fraction = CGFloat(spectrumPosition - Double(lowerIndex))
        let interpolated = spectrum[lowerIndex] * (1 - fraction) + spectrum[upperIndex] * fraction

        var neighborhood: CGFloat = 0
        var weightTotal: CGFloat = 0
        for offset in -2...2 {
            let sampleIndex = min(spectrum.count - 1, max(0, lowerIndex + offset))
            let weight = CGFloat(3 - abs(offset))
            neighborhood += spectrum[sampleIndex] * weight
            weightTotal += weight
        }
        neighborhood /= max(1, weightTotal)

        let detailedEnergy = max(interpolated, neighborhood * 0.9)
        let compressedEnergy = pow(min(1, max(0, detailedEnergy)), 0.72)
        let sharedPulse = min(1, max(0, volume))
        return min(1, compressedEnergy * 0.82 + sharedPulse * 0.30)
    }
}

/// Neon roles picked from a theme: dark gradient stops (black, deep navy) are
/// skipped and the rest ranked by luminance, so the rim always gets the
/// brightest color.
private struct NeonPalette {
    private typealias RGB = (r: Double, g: Double, b: Double)

    let rim: Color
    let grid: Color
    let led: Color
    let hot: Color
    private let rimRGB: RGB
    private let hotRGB: RGB

    init(theme: ColorTheme) {
        let colors: [RGB] = theme.gradient.compactMap { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        func luminance(_ c: RGB) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
        let ranked = colors.sorted { luminance($0) > luminance($1) }
        let bright = ranked.filter { luminance($0) > 0.2 }
        let vivid = bright.isEmpty ? (ranked.isEmpty ? [(1, 1, 1)] : ranked) : bright
        func color(_ c: RGB) -> Color { Color(red: c.r, green: c.g, blue: c.b) }

        rimRGB = vivid[0]
        hotRGB = (0.4 * rimRGB.r + 0.6, 0.4 * rimRGB.g + 0.6, 0.4 * rimRGB.b + 0.6)
        rim = color(rimRGB)
        grid = color(vivid[min(1, vivid.count - 1)])
        led = color(vivid[min(2, vivid.count - 1)])
        hot = color(hotRGB)
    }

    /// White-hot at the tunnel's center, fading into the rim color outward.
    func tunnel(_ p: Double) -> Color {
        Color(red: hotRGB.r + (rimRGB.r - hotRGB.r) * p,
              green: hotRGB.g + (rimRGB.g - hotRGB.g) * p,
              blue: hotRGB.b + (rimRGB.b - hotRGB.b) * p)
    }
}

#Preview {
    CircularVisualizerView(spectrum: Array(repeating: 0.5, count: 64), volume: 0.6, theme: .aurora, sensitivity: 1.0)
        .frame(width: 500, height: 500)
        .background(Color.black)
}
