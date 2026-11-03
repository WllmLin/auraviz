import AppKit
import CoreText
import os
import SwiftUI

/// The display fonts the stage can set its overlay text in: the system
/// rounded font AuraViz always used, plus a small OFL pack bundled in
/// `Resources/Fonts` (see the `OFL-*.txt` licenses beside them) and
/// registered at launch by `FontRegistrar`.
enum OverlayFont: String, CaseIterable, Identifiable, Codable {
    case systemRounded = "System Rounded"
    case orbitron = "Orbitron"
    case bebasNeue = "Bebas Neue"
    case anton = "Anton"
    case bungee = "Bungee"

    var id: String { rawValue }

    /// Bundled file name without extension; nil for the system font.
    var fileName: String? {
        switch self {
        case .systemRounded: return nil
        case .orbitron: return "Orbitron"
        case .bebasNeue: return "BebasNeue-Regular"
        case .anton: return "Anton-Regular"
        case .bungee: return "Bungee-Regular"
        }
    }

    /// Every face the bundled file provides. Orbitron is a variable font
    /// whose named instances cover the overlay's whole weight ramp; the
    /// other display faces are single-weight.
    var postScriptNames: [String] {
        switch self {
        case .systemRounded: return []
        case .orbitron:
            return ["Orbitron-Regular", "Orbitron-Medium", "Orbitron-SemiBold",
                    "Orbitron-Bold", "Orbitron-ExtraBold", "Orbitron-Black"]
        case .bebasNeue: return ["BebasNeue-Regular"]
        case .anton: return ["Anton-Regular"]
        case .bungee: return ["Bungee-Regular"]
        }
    }

    /// The face closest to `weight`, or nil for the system font.
    func postScriptName(forWeight weight: Font.Weight) -> String? {
        switch self {
        case .systemRounded:
            return nil
        case .orbitron:
            switch weight {
            case .ultraLight, .thin, .light, .regular: return "Orbitron-Regular"
            case .medium: return "Orbitron-Medium"
            case .semibold: return "Orbitron-SemiBold"
            case .bold: return "Orbitron-Bold"
            case .heavy: return "Orbitron-ExtraBold"
            default: return "Orbitron-Black"
            }
        case .bebasNeue, .anton, .bungee:
            return postScriptNames.first
        }
    }

    /// True when the bundled face has registered. The system font always is.
    var isAvailable: Bool {
        guard let name = postScriptNames.first else { return true }
        return NSFont(name: name, size: 12) != nil
    }

    /// This font at an absolute overlay size. Falls back to the system
    /// rounded font when the bundled face is missing (e.g. in previews,
    /// which skip launch registration), so the overlay never goes blank.
    func swiftUIFont(size: CGFloat, weight: Font.Weight) -> Font {
        if let name = postScriptName(forWeight: weight),
           NSFont(name: name, size: size) != nil {
            return .custom(name, fixedSize: size)
        }
        return .system(size: size, weight: weight, design: .rounded)
    }
}

/// Registers the bundled fonts for this process at launch, so both windows
/// can use them without the user installing anything. `build.sh` also sets
/// `ATSApplicationFontsPath`, which makes macOS register `Resources/Fonts`
/// on its own; re-registering here is harmless and covers Xcode builds,
/// whose generated Info.plist has no such key.
enum FontRegistrar {
    private static let logger = Logger(subsystem: "com.auraviz.app", category: "Fonts")
    private static var didRegisterBundled = false

    /// Font files in the bundle's `Fonts` subdirectory (folder-reference and
    /// `build.sh` builds), falling back to the Resources root (flat copies).
    static func bundledFontURLs(bundle: Bundle = .main) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        for subdirectory in ["Fonts", nil] {
            for ext in ["ttf", "otf"] {
                for url in bundle.urls(forResourcesWithExtension: ext, subdirectory: subdirectory) ?? []
                where seen.insert(url.lastPathComponent).inserted {
                    found.append(url)
                }
            }
        }
        return found
    }

    /// Registers every bundled font once. Call from the app's initializer,
    /// before any view measures overlay text.
    static func registerBundledFonts(bundle: Bundle = .main) {
        guard !didRegisterBundled else { return }
        didRegisterBundled = true
        let urls = bundledFontURLs(bundle: bundle)
        if urls.isEmpty {
            logger.error("No bundled fonts found; overlay falls back to the system font")
        }
        register(fontsAt: urls)
    }

    /// Process-scope registration: the fonts exist only inside AuraViz and
    /// only while it runs. A face macOS already registered (via
    /// `ATSApplicationFontsPath`) is not an error.
    static func register(fontsAt urls: [URL]) {
        for url in urls {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { continue }
            if let error = error?.takeRetainedValue() {
                let alreadyRegistered = CFErrorGetDomain(error) == (kCTFontManagerErrorDomain as CFString)
                    && CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue
                if !alreadyRegistered {
                    logger.error("Couldn't register \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }
}
