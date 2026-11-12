import AppKit
import SwiftUI

enum VisualMode: String, CaseIterable, Identifiable, Codable {
    case circle = "Circle"
    case waves = "Waves"
    case y2k = "Bars"
    case tunnel = "Tunnel"
    case neon = "Neon"
    case kaleidoscope = "Kaleidoscope"
    var id: String { rawValue }

    /// A mode from its stored raw value, mapping retired modes to their
    /// replacements: "Laser" became Kaleidoscope and "Particles" became Neon.
    init?(storedValue: String) {
        switch storedValue {
        case "Laser": self = .kaleidoscope
        case "Particles": self = .neon
        default: self.init(rawValue: storedValue)
        }
    }

    var icon: String {
        switch self {
        case .circle: return "circle.dashed"
        case .waves: return "waveform.path.ecg"
        case .y2k: return "chart.bar.fill"
        case .tunnel: return "hexagon"
        case .neon: return "cube.transparent"
        case .kaleidoscope: return "flower"
        }
    }

    /// What each mode does with the drums, tuned so its signature effect
    /// leads: Circle kicks a shockwave, snares flare the rim and hats twinkle
    /// the LED ring; Waves lifts its low, mid and high layers; Bars bounce on
    /// kicks, gloss on snares and glint their caps on hats; Tunnel breathes on
    /// kicks, lights its rails on snares and sparks its corners on hats; Neon
    /// punches its frames on kicks, jolts its roll on snares and glints its
    /// bar ends on hats; Kaleidoscope pumps its mandala on kicks, flips its
    /// mirror on snares and glints its wedge tips on hats.
    var defaultDrumReactivity: DrumReactivity {
        switch self {
        case .circle: return DrumReactivity(kick: 1, snare: 0.8, hat: 0.7)
        case .waves: return DrumReactivity(kick: 0.8, snare: 0.6, hat: 0.8)
        case .y2k: return DrumReactivity(kick: 0.7, snare: 0.7, hat: 0.8)
        case .tunnel: return DrumReactivity(kick: 1, snare: 0.7, hat: 0.6)
        case .neon: return DrumReactivity(kick: 1, snare: 0.8, hat: 0.8)
        case .kaleidoscope: return DrumReactivity(kick: 1, snare: 0.8, hat: 0.7)
        }
    }
}

enum ColorTheme: String, CaseIterable, Identifiable, Codable {
    case aurora = "Aurora"
    case sunset = "Sunset"
    case ocean = "Ocean"
    case y2k = "Y2K Chrome"
    case stockholm = "Stockholm"
    case tokyoNight = "Tokyo Night"
    case cyberpunk = "Cyberpunk"
    case chrome = "Chrome"

    var id: String { rawValue }

    var gradient: [Color] {
        switch self {
        case .aurora: return [Color(red: 0.62, green: 0.35, blue: 1.0), Color(red: 1.0, green: 0.35, blue: 0.65), Color(red: 0.20, green: 0.85, blue: 1.0)]
        case .sunset: return [Color(red: 1.0, green: 0.45, blue: 0.20), Color(red: 1.0, green: 0.30, blue: 0.65), Color(red: 0.70, green: 0.35, blue: 1.0)]
        case .ocean: return [Color(red: 0.15, green: 0.70, blue: 0.90), Color(red: 0.20, green: 0.40, blue: 0.95), Color(red: 0.12, green: 0.18, blue: 0.55)]
        case .y2k: return [Color(red: 0.80, green: 0.95, blue: 1.0), Color(red: 0.45, green: 0.85, blue: 1.0), Color(red: 1.0, green: 0.45, blue: 0.95), Color(red: 1.0, green: 0.85, blue: 0.35)]
        case .stockholm:
            return [
                Color(red: 0.84, green: 0.91, blue: 0.91),
                Color(red: 0.43, green: 0.63, blue: 0.68),
                Color(red: 0.91, green: 0.72, blue: 0.55),
                Color(red: 0.74, green: 0.45, blue: 0.40)
            ]
        case .tokyoNight:
            // color-hex.com palette 91636 "Tokyo night": #00ffd2 #ff4499 #000000 #0a0047 #004687
            // (black is the canvas — the app background already provides it)
            return [
                Color(red: 0.00, green: 1.00, blue: 0.82),
                Color(red: 0.00, green: 0.27, blue: 0.53),
                Color(red: 1.00, green: 0.27, blue: 0.60),
                Color(red: 0.04, green: 0.00, blue: 0.28)
            ]
        case .cyberpunk:
            // #6ECBF5 #586AE2 #C252E1 #E0D9F6 (deep base #2A2356 anchors the bar gradient below)
            return [
                Color(red: 0.43, green: 0.80, blue: 0.96),
                Color(red: 0.35, green: 0.42, blue: 0.89),
                Color(red: 0.76, green: 0.32, blue: 0.88),
                Color(red: 0.88, green: 0.85, blue: 0.96)
            ]
        case .chrome:
            return [
                Color.black,
                Color(white: 0.48),
                Color.white,
                Color(white: 0.70)
            ]
        }
    }

    /// A row of dots, one per `gradient` stop, for the theme menu. Menu items only
    /// render text and images, so the dots are drawn into a non-template image.
    /// Gradients are constants, so each swatch is built once and cached instead
    /// of recreated every time SwiftUI rebuilds the menu items.
    var swatchImage: NSImage { Self.swatchCache[self]! }

    private static let swatchCache: [ColorTheme: NSImage] =
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makeSwatchImage()) })

    private func makeSwatchImage() -> NSImage {
        let colors = gradient.map { NSColor($0) }
        // 10pt reads against the menu's 13pt text at a glance, muted stops included.
        let dot: CGFloat = 10, gap: CGFloat = 3
        let size = NSSize(width: CGFloat(colors.count) * dot + CGFloat(colors.count - 1) * gap, height: dot)
        let image = NSImage(size: size, flipped: false) { rect in
            // Lay out from the rect AppKit hands the handler (its contract), so
            // the dots stay round and inside the image at any backing scale.
            let diameter = rect.height
            let spacing = colors.count > 1 ? (rect.width - CGFloat(colors.count) * diameter) / CGFloat(colors.count - 1) : 0
            for (i, color) in colors.enumerated() {
                let dotRect = NSRect(x: rect.minX + CGFloat(i) * (diameter + spacing),
                                     y: rect.minY, width: diameter, height: diameter)
                let circle = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.5, dy: 0.5))
                color.setFill()
                circle.fill()
                // Ring so dark stops (Chrome's black, Tokyo Night's navy) stay
                // visible on the dark menu: 1pt at 55% white, kept inside the
                // dot by the 0.5pt inset above. At 35%/0.5pt it washed out.
                NSColor.white.withAlphaComponent(0.55).setStroke()
                circle.lineWidth = 1
                circle.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    var barGradient: LinearGradient {
        switch self {
        case .y2k:
            return LinearGradient(colors: [Color(red:0.95, green:0.97, blue:1.0), Color(red:0.40, green:0.80, blue:1.0), Color(red:0.85, green:0.35, blue:1.0), Color(red:1.0, green:0.75, blue:0.25)], startPoint: .top, endPoint: .bottom)
        case .aurora:
            return LinearGradient(colors: [Color(red:0.9, green:0.6, blue:1.0), Color(red:0.62, green:0.35, blue:1.0), Color(red:0.2, green:0.85, blue:1.0)], startPoint: .top, endPoint: .bottom)
        case .sunset:
            return LinearGradient(colors: [Color.yellow, Color.orange, Color(red:1, green:0.3, blue:0.6)], startPoint: .top, endPoint: .bottom)
        case .ocean:
            return LinearGradient(colors: [Color(red:0.5, green:0.95, blue:1), Color(red:0.2, green:0.5, blue:1)], startPoint: .top, endPoint: .bottom)
        case .stockholm:
            return LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.93, blue: 0.87),
                    Color(red: 0.43, green: 0.63, blue: 0.68),
                    Color(red: 0.74, green: 0.45, blue: 0.40)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .tokyoNight:
            // palette 91636: mint #00ffd2 → blue #004687 → pink #ff4499 → deep navy #0a0047
            return LinearGradient(
                colors: [
                    Color(red: 0.00, green: 1.00, blue: 0.82),
                    Color(red: 0.00, green: 0.27, blue: 0.53),
                    Color(red: 1.00, green: 0.27, blue: 0.60),
                    Color(red: 0.04, green: 0.00, blue: 0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .cyberpunk:
            // pale lavender #E0D9F6 → cyan #6ECBF5 → indigo #586AE2 → magenta #C252E1 → base #2A2356
            return LinearGradient(
                colors: [
                    Color(red: 0.88, green: 0.85, blue: 0.96),
                    Color(red: 0.43, green: 0.80, blue: 0.96),
                    Color(red: 0.35, green: 0.42, blue: 0.89),
                    Color(red: 0.76, green: 0.32, blue: 0.88),
                    Color(red: 0.16, green: 0.14, blue: 0.34)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .chrome:
            return LinearGradient(
                stops: [
                    .init(color: .white, location: 0),
                    .init(color: Color(white: 0.42), location: 0.28),
                    .init(color: .black, location: 0.52),
                    .init(color: Color(white: 0.72), location: 0.76),
                    .init(color: .white, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

struct GlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.85)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                }
            )
            .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 10)
    }
}

extension View {
    func glassCard() -> some View { modifier(GlassBackground()) }
}

let auraBackgroundGradient = LinearGradient(colors: [Color(red:0.06, green:0.06, blue:0.10), Color(red:0.10, green:0.08, blue:0.16), Color(red:0.04, green:0.09, blue:0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
