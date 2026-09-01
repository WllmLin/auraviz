import SwiftUI

struct Y2KBarVisualizerView: View {
    var spectrum: [CGFloat]
    var volume: CGFloat
    var theme: ColorTheme
    var sensitivity: Double
    @State private var peaks: [CGFloat] = Array(repeating: 0, count: 32)

    var barCount: Int { 32 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0/60.0)) { timeline in
            let _ = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(in: context, size: size)
            }
        }
        .background(Color.clear)
        .onAppear { peaks = Array(repeating: 0, count: barCount) }
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        let topPadding: CGFloat = 18
        let bottomPadding: CGFloat = 54
        let visHeight = h - topPadding - bottomPadding
        let visTop = topPadding
        let gap: CGFloat = 6
        let totalGap = gap * CGFloat(barCount + 1)
        let barW = (w - totalGap) / CGFloat(barCount)
        let maxBarH = visHeight * 0.92
        let baseY = visTop + visHeight

        // orbs
        let orb1Grad = Gradient(colors: [theme.gradient.first!.opacity(0.35), Color.clear])
        context.fill(Path(ellipseIn: CGRect(x: w*0.12, y: h*0.08, width: w*0.45, height: h*0.55)), with: .radialGradient(orb1Grad, center: CGPoint(x: w*0.3, y: h*0.3), startRadius: 0, endRadius: w*0.4))
        let orb2Grad = Gradient(colors: [theme.gradient.last!.opacity(0.30), Color.clear])
        context.fill(Path(ellipseIn: CGRect(x: w*0.48, y: h*0.12, width: w*0.5, height: h*0.6)), with: .radialGradient(orb2Grad, center: CGPoint(x: w*0.7, y: h*0.35), startRadius: 0, endRadius: w*0.4))

        // grid
        let gridColor = Color.white.opacity(0.07)
        var gridPath = Path()
        for y in stride(from: visTop, through: baseY, by: 28) {
            gridPath.move(to: CGPoint(x: gap, y: y))
            gridPath.addLine(to: CGPoint(x: w - gap, y: y))
        }
        for x in stride(from: gap, through: w - gap, by: (w / 12)) {
            gridPath.move(to: CGPoint(x: x, y: visTop))
            gridPath.addLine(to: CGPoint(x: x, y: baseY))
        }
        context.stroke(gridPath, with: .color(gridColor), lineWidth: 0.7)
        let frameRect = CGRect(x: gap/2, y: visTop - 8, width: w - gap, height: visHeight + 16)
        let framePath = Path(roundedRect: frameRect, cornerRadius: 14)
        context.stroke(framePath, with: .color(.white.opacity(0.12)), lineWidth: 1)
        context.fill(framePath, with: .color(.black.opacity(0.18)))

        let grad = Gradient(colors: theme.gradient)
        for i in 0..<barCount {
            let specIdx = Int(Double(i)/Double(barCount) * Double(spectrum.count))
            let amp = spectrum[min(specIdx, spectrum.count-1)]
            let targetH = CGFloat(amp) * maxBarH * CGFloat(sensitivity) * 0.95 + volume * 14 + 6
            let barH = min(maxBarH, max(8, targetH))
            let x = gap + CGFloat(i) * (barW + gap)
            let y = baseY - barH
            let barRect = CGRect(x: x, y: y, width: barW, height: barH)
            let barPath = Path(roundedRect: barRect, cornerRadius: barW*0.32)
            // bar fill
            context.fill(barPath, with: .linearGradient(grad, startPoint: CGPoint(x: x, y: y), endPoint: CGPoint(x: x, y: baseY)))
            // highlight
            let hiH = barH * 0.38
            let hiRect = CGRect(x: x+1, y: y+1, width: barW-2, height: hiH)
            let hiPath = Path(roundedRect: hiRect, cornerRadius: barW*0.22)
            context.fill(hiPath, with: .linearGradient(Gradient(colors: [.white.opacity(0.62), .white.opacity(0.14), .clear]), startPoint: CGPoint(x:x, y:y), endPoint: CGPoint(x:x, y:y+hiH)))
            var edge = Path()
            edge.move(to: CGPoint(x: x+1, y: y+2))
            edge.addLine(to: CGPoint(x: x+1, y: y+barH-2))
            context.stroke(edge, with: .color(.white.opacity(0.22)), lineWidth: 1)
            if barH > 12 {
                let peakH: CGFloat = 4
                let peakY = y - 8
                let peakRect = CGRect(x: x, y: max(visTop-4, peakY), width: barW, height: peakH)
                let capGrad = Gradient(colors: [.white, Color(white:0.85), .white])
                let capPath = Path(roundedRect: peakRect, cornerRadius: 2)
                context.fill(capPath, with: .linearGradient(capGrad, startPoint: CGPoint(x:x, y: peakY), endPoint: CGPoint(x:x+barW, y: peakY)))
                context.stroke(capPath, with: .color(.white.opacity(0.5)), lineWidth: 0.6)
            }
            // reflection
            let reflH = barH * 0.42
            let reflRect = CGRect(x: x, y: baseY + 6, width: barW, height: reflH)
            let reflPath = Path(roundedRect: reflRect, cornerRadius: barW*0.22)
            context.fill(reflPath, with: .linearGradient(Gradient(colors: [theme.gradient[1].opacity(0.28), Color.clear]), startPoint: CGPoint(x:x, y:baseY+6), endPoint: CGPoint(x:x, y:baseY+6+reflH)))
        }

        // ledge
        let ledgeRect = CGRect(x: gap/2, y: baseY + 4, width: w - gap, height: 18)
        let ledgePath = Path(roundedRect: ledgeRect, cornerRadius: 6)
        let ledgeGrad = Gradient(colors: [Color(white:0.92), Color(white:0.68), Color(white:0.88), Color(white:0.62)])
        context.fill(ledgePath, with: .linearGradient(ledgeGrad, startPoint: CGPoint(x:0, y:ledgeRect.minY), endPoint: CGPoint(x:0, y:ledgeRect.maxY)))
        context.stroke(ledgePath, with: .color(.white.opacity(0.45)), lineWidth: 0.8)
        for sx in [ledgeRect.minX + 10, ledgeRect.maxX - 10] {
            let screwRect = CGRect(x: sx - 4, y: ledgeRect.midY - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: screwRect), with: .radialGradient(Gradient(colors: [Color(white:0.75), Color(white:0.35)]), center: CGPoint(x:screwRect.midX, y:screwRect.midY), startRadius: 0, endRadius: 4))
        }
        // scanlines
        let scanColor = Color.white.opacity(0.025)
        var scanPath = Path()
        var yy: CGFloat = visTop
        while yy < baseY {
            scanPath.move(to: CGPoint(x: gap, y: yy))
            scanPath.addLine(to: CGPoint(x: w - gap, y: yy))
            yy += 4
        }
        context.stroke(scanPath, with: .color(scanColor), lineWidth: 0.7)
    }
}
