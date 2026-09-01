import SwiftUI

struct CircularVisualizerView: View {
    var spectrum: [CGFloat]
    var volume: CGFloat
    var theme: ColorTheme
    var sensitivity: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0/60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let w = size.width
                let h = size.height
                let center = CGPoint(x: w/2, y: h/2)
                let baseRadius = min(w, h) * 0.22
                let pulse = 1.0 + Double(volume) * 0.35 + sin(t*2.2)*0.04
                let radius = baseRadius * pulse

                // soft glow behind
                let glowRadius = radius * 2.8
                let glowGradient = Gradient(colors: theme.gradient.map { $0.opacity(0.35) } + [Color.clear])
                let glowRect = CGRect(x: center.x - glowRadius, y: center.y - glowRadius, width: glowRadius*2, height: glowRadius*2)
                context.fill(Path(ellipseIn: glowRect), with: .radialGradient(glowGradient, center: center, startRadius: radius, endRadius: glowRadius))
                // inner dot aura blur
                let innerGlow = Gradient(colors: [theme.gradient.first!.opacity(0.9), theme.gradient.last!.opacity(0.2), Color.clear])
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius*0.95, y: center.y - radius*0.95, width: radius*1.9, height: radius*1.9)), with: .radialGradient(innerGlow, center: center, startRadius: 0, endRadius: radius))

                // center core circle - glassy
                let coreRadius = radius * 0.78
                let coreRect = CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius*2, height: coreRadius*2)
                let corePath = Path(ellipseIn: coreRect)
                context.fill(corePath, with: .radialGradient(Gradient(colors: [Color.white.opacity(0.92), Color.white.opacity(0.25), Color.black.opacity(0.55)]), center: CGPoint(x: center.x - coreRadius*0.25, y: center.y - coreRadius*0.35), startRadius: 0, endRadius: coreRadius))
                // thin ring around core
                context.stroke(corePath, with: .color(.white.opacity(0.35)), lineWidth: 1.2)
                // inner highlight
                let hiRadius = coreRadius * 0.55
                let hiRect = CGRect(x: center.x - hiRadius, y: center.y - hiRadius, width: hiRadius*2, height: hiRadius*2)
                context.stroke(Path(ellipseIn: hiRect), with: .color(.white.opacity(0.15)), lineWidth: 18)
                // blur via layer

                // radial bars
                let count = 72
                let barMax = min(w,h) * 0.28
                for i in 0..<count {
                    let angle = (Double(i)/Double(count) * 2 * .pi) - .pi/2 + t*0.18 // slow rotation
                    let amp = circularAmplitude(at: i, barCount: count)
                    let len = barMax * Double(amp) * sensitivity * 0.95 + 8
                    let innerR = radius + 6
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
                    context.stroke(path, with: .color(col.opacity(0.22)), lineWidth: 9)
                    context.stroke(path, with: .color(col), lineWidth: 3.2)
                    // tip dot
                    let tipSize: CGFloat = 3.2 + CGFloat(amp)*3.0
                    let tipRect = CGRect(x: x2 - tipSize/2, y: y2 - tipSize/2, width: tipSize, height: tipSize)
                    context.fill(Path(ellipseIn: tipRect), with: .color(.white.opacity(0.95)))
                    context.fill(Path(ellipseIn: tipRect.insetBy(dx: -2, dy: -2)), with: .color(col.opacity(0.35)))
                }

                // outer thin orbit ring
                let orbitR = radius + barMax + 14
                let orbitPath = Path(ellipseIn: CGRect(x: center.x - orbitR, y: center.y - orbitR, width: orbitR*2, height: orbitR*2))
                context.stroke(orbitPath, with: .color(.white.opacity(0.08)), lineWidth: 0.8)
                // ticks
                for i in 0..<count {
                    if i % 6 != 0 { continue }
                    let angle = Double(i)/Double(count) * 2 * Double.pi - Double.pi/2
                    let r1 = orbitR + 2
                    let r2 = orbitR + 6 + Double(volume)*4
                    let x1 = center.x + cos(angle)*r1
                    let y1 = center.y + sin(angle)*r1
                    let x2 = center.x + cos(angle)*r2
                    let y2 = center.y + sin(angle)*r2
                    var p = Path()
                    p.move(to: CGPoint(x: x1, y: y1))
                    p.addLine(to: CGPoint(x:x2, y:y2))
                    context.stroke(p, with: .color(.white.opacity(0.18)), lineWidth: 1)
                }

                // volume ring arc at bottom? show volume text
            }
        }
        .background(Color.clear)
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

#Preview {
    CircularVisualizerView(spectrum: Array(repeating: 0.5, count: 64), volume: 0.6, theme: .aurora, sensitivity: 1.0)
        .frame(width: 500, height: 500)
        .background(Color.black)
}
