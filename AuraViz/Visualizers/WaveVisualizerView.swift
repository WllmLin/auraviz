import SwiftUI

struct WaveVisualizerView: View {
    var spectrum: [CGFloat]
    var waveform: [CGFloat]
    var volume: CGFloat
    var theme: ColorTheme
    var sensitivity: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0/60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let w = size.width
                let h = size.height
                let centerY = h * 0.52
                let g = theme.gradient

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

                // compute band averages
                let low = spectrum.prefix(8).reduce(0, +)/8
                let mid = spectrum.dropFirst(8).prefix(16).reduce(0, +)/16
                let high = spectrum.dropFirst(24).prefix(20).reduce(0, +)/20
                // Also incorporate waveform? waveform driven central wave

                // Draw 3 layered waves with fill + glow
                let layers: [(Color, CGFloat, Double, CGFloat)] = [
                    (g[0], centerY, 0.55, low),
                    (g.count>1 ? g[1] : g[0], centerY+6, 0.42, mid),
                    (g.last ?? g[0], centerY-6, 0.35, high)
                ]
                for (idx, layer) in layers.enumerated() {
                    let (col, baseY, freqMul, ampFactor) = layer
                    let amplitude = (28 + CGFloat(ampFactor)*110 * CGFloat(sensitivity) + volume*30) * (0.9 + CGFloat(idx)*0.12)
                    let freq = CGFloat(0.016 + Double(idx)*0.004) * CGFloat(1.0 + freqMul)

                    var path = Path()
                    var fillPath = Path()
                    let points = 180
                    for i in 0...points {
                        let x = CGFloat(i)/CGFloat(points) * w
                        // wave = sin(x*freq + t) * amp * envelope + secondary sin for complexity
                        let phase = t * (1.6 + Double(idx)*0.7)
                        let envelope = sin(CGFloat(i)/CGFloat(points) * .pi) // fade edges
                        let y1 = sin(x * freq + CGFloat(phase)) * amplitude * envelope
                        let y2 = sin(x * freq * 1.9 + CGFloat(phase*1.3)) * amplitude * 0.35 * envelope
                        let y3 = waveform.isEmpty ? 0 : waveform[Int(Double(i)/Double(points)*Double(waveform.count-1))] * 14 * envelope
                        let y = baseY + y1 + y2 + y3 * (idx==1 ? 1 : 0.3)
                        if i==0 {
                            path.move(to: CGPoint(x: x, y: y))
                            fillPath.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                            fillPath.addLine(to: CGPoint(x:x, y:y))
                        }
                    }
                    // close fill path to bottom
                    fillPath.addLine(to: CGPoint(x: w, y: h+20))
                    fillPath.addLine(to: CGPoint(x: 0, y: h+20))
                    fillPath.closeSubpath()

                    // glow fill
                    let fillGrad = Gradient(colors: [col.opacity(0.45), col.opacity(0.08), Color.clear])
                    context.fill(fillPath, with: .linearGradient(fillGrad, startPoint: CGPoint(x:0, y: baseY - amplitude), endPoint: CGPoint(x:0, y: h)))

                    // stroke with shadow for glow
                    context.stroke(path, with: .color(col.opacity(0.28)), lineWidth: 12)
                    context.stroke(path, with: .color(col), lineWidth: 2.4)
                    // white core highlight
                    context.stroke(path, with: .color(.white.opacity(0.55)), lineWidth: 1.0)
                }

                // center horizontal shine line
                var shine = Path()
                shine.move(to: CGPoint(x:0, y: centerY))
                shine.addLine(to: CGPoint(x:w, y:centerY))
                context.stroke(shine, with: .color(.white.opacity(0.06)), lineWidth: 1)

                // volume-linked orb at center
                let orbR = 14 + volume*18
                let orbGrad = Gradient(colors: [Color.white.opacity(0.9), theme.gradient[0].opacity(0.9)])
                let orbRect = CGRect(x: w/2 - orbR, y: centerY - orbR, width: orbR*2, height: orbR*2)
                context.fill(Path(ellipseIn: orbRect), with: .radialGradient(orbGrad, center: CGPoint(x:w/2, y:centerY), startRadius: 0, endRadius: orbR))
                context.stroke(Path(ellipseIn: orbRect.insetBy(dx: -6, dy: -6)), with: .color(theme.gradient[0].opacity(0.25)), lineWidth: 10)
            }
        }
        .background(Color.clear)
    }
}
