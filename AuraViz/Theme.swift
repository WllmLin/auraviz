import SwiftUI

enum VisualMode: String, CaseIterable, Identifiable {
    case circle = "Circle"
    case waves = "Waves"
    case y2k = "Y2K Bars"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .circle: return "circle.dashed"
        case .waves: return "waveform.path.ecg"
        case .y2k: return "chart.bar.fill"
        }
    }
}

enum ColorTheme: String, CaseIterable, Identifiable {
    case aurora = "Aurora"
    case sunset = "Sunset"
    case ocean = "Ocean"
    case y2k = "Y2K Chrome"
    case mono = "Mono"
    case stockholm = "Stockholm"
    case tokyoNight = "Tokyo Night"
    case chrome = "Chrome"

    var id: String { rawValue }

    var gradient: [Color] {
        switch self {
        case .aurora: return [Color(red: 0.62, green: 0.35, blue: 1.0), Color(red: 1.0, green: 0.35, blue: 0.65), Color(red: 0.20, green: 0.85, blue: 1.0)]
        case .sunset: return [Color(red: 1.0, green: 0.45, blue: 0.20), Color(red: 1.0, green: 0.30, blue: 0.65), Color(red: 0.70, green: 0.35, blue: 1.0)]
        case .ocean: return [Color(red: 0.15, green: 0.70, blue: 0.90), Color(red: 0.20, green: 0.40, blue: 0.95), Color(red: 0.12, green: 0.18, blue: 0.55)]
        case .y2k: return [Color(red: 0.80, green: 0.95, blue: 1.0), Color(red: 0.45, green: 0.85, blue: 1.0), Color(red: 1.0, green: 0.45, blue: 0.95), Color(red: 1.0, green: 0.85, blue: 0.35)]
        case .mono: return [Color.white, Color(white: 0.75), Color(white: 0.5)]
        case .stockholm:
            return [
                Color(red: 0.84, green: 0.91, blue: 0.91),
                Color(red: 0.43, green: 0.63, blue: 0.68),
                Color(red: 0.91, green: 0.72, blue: 0.55),
                Color(red: 0.74, green: 0.45, blue: 0.40)
            ]
        case .tokyoNight:
            return [
                Color(red: 0.48, green: 0.64, blue: 0.97),
                Color(red: 0.73, green: 0.60, blue: 0.97),
                Color(red: 0.97, green: 0.46, blue: 0.56),
                Color(red: 0.49, green: 0.81, blue: 1.0)
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
        case .mono:
            return LinearGradient(colors: [Color.white, Color(white:0.6)], startPoint: .top, endPoint: .bottom)
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
            return LinearGradient(
                colors: [
                    Color(red: 0.49, green: 0.81, blue: 1.0),
                    Color(red: 0.48, green: 0.64, blue: 0.97),
                    Color(red: 0.73, green: 0.60, blue: 0.97),
                    Color(red: 1.0, green: 0.42, blue: 0.75)
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
