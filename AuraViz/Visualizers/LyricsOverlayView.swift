import AppKit
import SwiftUI

/// Big kinetic type over the stage: lyrics, a track title or a shout-out,
/// wrapped to fill the middle of the stage. Each character swells and
/// thickens with the smoothed RMS volume on a wave that sweeps through the
/// text (once per bar at full beat reactivity), and every kick ripples out
/// from the middle, punching the characters up to black weight. Colored along
/// the theme's gradient. Kick punches keep to the 3-per-second strobe cap,
/// like the lasers.
///
/// Takes the manager unobserved and reads it per tick, so audio frames don't
/// redraw the text faster than its own timeline.
struct LyricsOverlay: View {
    let audio: AudioEngineManager
    var text: String
    var theme: ColorTheme
    var isActive: Bool

    /// Shared so every stage layer, in the preview and the output, draws the
    /// text in the same state and a crossfade doesn't show two copies.
    private static let motion = LyricsMotion()
    /// Display weights from silence to a full punch.
    private static let weights: [Font.Weight] = [.regular, .medium, .semibold, .bold, .heavy, .black]
    /// How long a kick takes to ripple from the middle to the farthest character.
    private static let rippleDuration: TimeInterval = 0.12
    private static let maximumScale = 1.4

    @State private var layout = LyricsLayoutCache()

    var body: some View {
        let palette = LyricsPalette(theme: theme)
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive)) { timeline in
            let now = BeatClock.time(for: timeline.date)
            let pulse = Self.motion.advance(to: now, audio: audio, isActive: isActive)
            Canvas { context, size in
                draw(in: context, size: size, now: now, pulse: pulse, palette: palette)
            }
        }
        .allowsHitTesting(false)
        // The lyrics field in the controls already reads the text.
        .accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext, size: CGSize, now: TimeInterval, pulse: LyricsPulse, palette: LyricsPalette) {
        guard let layout = layout.layout(for: text, size: size, context: context) else { return }
        let fontSize = layout.fontSize
        let globalKick = pulse.kick(at: now)
        context.drawLayer { layer in
            // A tight dark shadow keeps the type legible over bright beams,
            // then a theme glow that blooms with the kick.
            layer.addFilter(.shadow(color: .black.opacity(0.55), radius: fontSize * 0.05, y: fontSize * 0.02))
            layer.addFilter(.shadow(color: palette.color(at: 0.5).opacity(0.3 + 0.2 * pulse.level + 0.3 * globalKick), radius: fontSize * (0.1 + 0.1 * globalKick)))
            for glyph in layout.glyphs {
                let wave = 0.5 + 0.5 * sin(2 * .pi * (pulse.wave - glyph.position))
                let kick = pulse.kick(at: now - glyph.rippleDistance * Self.rippleDuration)
                let swell = pulse.level * (0.45 + 0.55 * wave)
                let intensity = min(1, 0.15 + 0.6 * swell + 0.7 * kick)
                let scale = min(Self.maximumScale, 0.92 + 0.22 * swell + 0.3 * kick)
                let weight = Self.weights[Int((intensity * Double(Self.weights.count - 1)).rounded())]

                var resolved = layer.resolve(Text(glyph.character).font(.system(size: fontSize, weight: weight, design: .rounded)))
                resolved.shading = .color(palette.color(at: glyph.position, heat: 0.4 * kick).opacity(0.8 + 0.2 * intensity))
                var glyphContext = layer
                glyphContext.translateBy(x: glyph.center.x, y: glyph.center.y - CGFloat(kick) * fontSize * 0.08)
                glyphContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                glyphContext.draw(resolved, at: .zero, anchor: .center)
            }
        }
    }
}

/// The audio-driven motion shared by every lyrics layer at one instant.
private struct LyricsPulse {
    private static let kickDecay: TimeInterval = 0.18

    /// Smoothed RMS volume, 0...1.
    var level = 0.0
    /// Sweep phase through the text; 1.0 = one pass.
    var wave = 0.0
    var reactivity = 0.0
    var kickTime: TimeInterval = -.infinity
    var kickStrength = 0.0

    /// The kick punch at `time`, scaled by the beat reactivity; 0 before the
    /// kick reaches it.
    func kick(at time: TimeInterval) -> Double {
        let age = time - kickTime
        guard age >= 0 else { return 0 }
        return reactivity * exp(-age / Self.kickDecay) * (0.4 + 0.6 * kickStrength)
    }
}

/// Smoothed level, beat-synced sweep and rate-limited kicks. A class so it
/// can advance inside a `TimelineView` update without invalidating SwiftUI
/// state.
private final class LyricsMotion {
    private static let attackTime: TimeInterval = 0.05
    private static let releaseTime: TimeInterval = 0.35

    private let sweep = BeatSyncedPhase()
    private var pulse = LyricsPulse()
    private var lastBeatCount: Int?
    private var lastTime: TimeInterval?
    private var wasActive = false

    func advance(to now: TimeInterval, audio: AudioEngineManager, isActive: Bool) -> LyricsPulse {
        // Several layers in two windows advance per frame; only the first
        // call at a new time moves the motion.
        if let lastTime, now <= lastTime, isActive == wasActive { return pulse }
        // Clamped so resuming after a pause continues instead of jumping.
        let dt = lastTime.map { min(0.1, max(0, now - $0)) } ?? 0
        lastTime = now
        wasActive = isActive
        guard isActive else {
            // At rest while audio is stopped.
            pulse.level = 0
            pulse.kickTime = -.infinity
            return pulse
        }

        let beat = audio.beat
        pulse.reactivity = audio.beatReactivity
        pulse.wave = sweep.advance(
            to: now,
            wallRate: 0.35,
            gridPhase: beat.clock.barPhase(at: now),
            gridRate: 1,
            nominalGridSpeed: beat.clock.beatsPerSecond / 4,
            reactivity: pulse.reactivity
        )
        if let lastBeatCount, beat.beatCount != lastBeatCount,
           beat.lastBeatTime - pulse.kickTime >= PerformanceState.strobeMinimumInterval {
            pulse.kickTime = beat.lastBeatTime
            pulse.kickStrength = Double(beat.beatStrength)
        }
        lastBeatCount = beat.beatCount

        let target = Double(min(1, max(0, audio.volume)))
        let tau = target > pulse.level ? Self.attackTime : Self.releaseTime
        pulse.level += (target - pulse.level) * (1 - exp(-dt / tau))
        return pulse
    }
}

/// Where each character sits, at the largest size that fits the stage.
private struct LyricsLayout {
    struct Glyph {
        var character: String
        var center: CGPoint
        /// Reading order through the text, 0...1.
        var position: Double
        /// Distance from the middle of the text block, 0...1.
        var rippleDistance: Double
    }

    /// Share of the stage the text may fill, leaving room to swell.
    private static let widthFraction: CGFloat = 0.8
    private static let heightFraction: CGFloat = 0.6
    /// A single short word shouldn't fill the whole height.
    private static let maximumHeightShare: CGFloat = 0.3
    private static let minimumFontSize: CGFloat = 8
    /// Characters are measured at this size, at the weight in the middle of
    /// the swell, and the layout scales to the fitted size.
    private static let referenceSize: CGFloat = 100
    private static let lineSpacing: CGFloat = 0.92
    private static let tracking: CGFloat = 0.04

    var fontSize: CGFloat
    var glyphs: [Glyph]

    init?(text: String, size: CGSize, context: GraphicsContext) {
        let words = text.split(whereSeparator: \.isWhitespace).map { $0.map(String.init) }
        guard !words.isEmpty, size.width > 0, size.height > 0 else { return nil }

        let reference = Self.referenceSize
        var widths: [String: CGFloat] = [:]
        func width(of character: String) -> CGFloat {
            if let width = widths[character] { return width }
            let font = Font.system(size: reference, weight: .heavy, design: .rounded)
            let width = context.resolve(Text(character).font(font)).measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width
                + Self.tracking * reference
            widths[character] = width
            return width
        }
        let wordWidths = words.map { $0.reduce(0) { $0 + width(of: $1) } }
        let spaceWidth = 0.28 * reference
        let lineHeight = context.resolve(Text("Hg").font(.system(size: reference, weight: .heavy, design: .rounded)))
            .measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).height * Self.lineSpacing

        // Greedy wrap into lines no wider than `maxWidth` reference points.
        func wrap(maxWidth: CGFloat) -> [[Int]] {
            var lines: [[Int]] = []
            var lineWidth: CGFloat = 0
            for (index, wordWidth) in wordWidths.enumerated() {
                if let last = lines.indices.last, lineWidth + spaceWidth + wordWidth <= maxWidth {
                    lines[last].append(index)
                    lineWidth += spaceWidth + wordWidth
                } else {
                    lines.append([index])
                    lineWidth = wordWidth
                }
            }
            return lines
        }
        let availableWidth = size.width * Self.widthFraction
        let availableHeight = size.height * Self.heightFraction
        func fits(_ scale: CGFloat) -> Bool {
            let maxWidth = availableWidth / scale
            guard wordWidths.allSatisfy({ $0 <= maxWidth }) else { return false }
            return CGFloat(wrap(maxWidth: maxWidth).count) * lineHeight * scale <= availableHeight
        }

        // Fewer, wider lines fit at smaller scales, so the fit is monotonic.
        var low = Self.minimumFontSize / reference
        var high = max(low, size.height * Self.maximumHeightShare / reference)
        if fits(high) {
            low = high
        } else {
            for _ in 0..<24 {
                let mid = (low + high) / 2
                if fits(mid) { low = mid } else { high = mid }
            }
        }
        let scale = low
        fontSize = reference * scale

        let lines = wrap(maxWidth: availableWidth / scale)
        let characterCount = words.reduce(0) { $0 + $1.count }
        let blockHeight = CGFloat(lines.count) * lineHeight * scale
        var blockWidth: CGFloat = 0
        var glyphs: [Glyph] = []
        glyphs.reserveCapacity(characterCount)
        for (lineIndex, line) in lines.enumerated() {
            let lineWidth = (line.reduce(0) { $0 + wordWidths[$1] } + spaceWidth * CGFloat(line.count - 1)) * scale
            blockWidth = max(blockWidth, lineWidth)
            let y = size.height / 2 + (CGFloat(lineIndex) - CGFloat(lines.count - 1) / 2) * lineHeight * scale
            var x = (size.width - lineWidth) / 2
            for (wordOrder, wordIndex) in line.enumerated() {
                if wordOrder > 0 { x += spaceWidth * scale }
                for character in words[wordIndex] {
                    let characterWidth = width(of: character) * scale
                    glyphs.append(Glyph(
                        character: character,
                        center: CGPoint(x: x + characterWidth / 2, y: y),
                        position: characterCount > 1 ? Double(glyphs.count) / Double(characterCount - 1) : 0.5,
                        rippleDistance: 0
                    ))
                    x += characterWidth
                }
            }
        }
        // Normalized to the block's half-diagonal so the ripple takes the
        // same time to cross one word or four lines.
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        let reach = max(1, hypot(blockWidth, blockHeight) / 2)
        for index in glyphs.indices {
            let center = glyphs[index].center
            glyphs[index].rippleDistance = Double(min(1, hypot(center.x - middle.x, center.y - middle.y) / reach))
        }
        self.glyphs = glyphs
    }
}

/// Keeps the last layout, so it is only rebuilt when the text or the stage
/// size changes. A class so the canvas can fill it while drawing.
private final class LyricsLayoutCache {
    private var text: String?
    private var size: CGSize = .zero
    private var layout: LyricsLayout?

    func layout(for text: String, size: CGSize, context: GraphicsContext) -> LyricsLayout? {
        if text != self.text || size != self.size {
            self.text = text
            self.size = size
            layout = LyricsLayout(text: text, size: size, context: context)
        }
        return layout
    }
}

/// The theme's brighter colors as sRGB components, so the type can be
/// colored anywhere along the gradient and legible on the dark stage.
private struct LyricsPalette {
    private var stops: [(red: Double, green: Double, blue: Double)]

    init(theme: ColorTheme) {
        stops = theme.colors(brighterThan: 0.3).map { color in
            let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
            return (Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))
        }
    }

    /// The gradient at `position` (0...1), mixed toward white by `heat`.
    func color(at position: Double, heat: Double = 0) -> Color {
        guard let first = stops.first else { return .white }
        var stop = first
        if stops.count > 1 {
            let x = min(1, max(0, position)) * Double(stops.count - 1)
            let index = min(stops.count - 2, Int(x))
            let f = x - Double(index)
            let a = stops[index]
            let b = stops[index + 1]
            stop = (a.red + (b.red - a.red) * f, a.green + (b.green - a.green) * f, a.blue + (b.blue - a.blue) * f)
        }
        let h = min(1, max(0, heat))
        return Color(red: stop.red + (1 - stop.red) * h, green: stop.green + (1 - stop.green) * h, blue: stop.blue + (1 - stop.blue) * h)
    }
}
