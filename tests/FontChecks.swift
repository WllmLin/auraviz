import AppKit
import Foundation
import SwiftUI

// Focused checks for the bundled overlay font pack (AuraViz/FontCatalog.swift).
// Built and run by tests/run_font_checks.sh; exits non-zero on any failure.

@main
struct FontChecks {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL"): \(message)")
        if !condition { failures += 1 }
    }

    static func main() {
        // AuraViz/Resources/Fonts, relative to this source file (tests/).
        let fontsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                 // tests/
            .deletingLastPathComponent()                 // repo root
            .appendingPathComponent("AuraViz/Resources/Fonts", isDirectory: true)

        let bundled = OverlayFont.allCases.filter { $0 != .systemRounded }
        check(!bundled.isEmpty, "catalog offers bundled fonts besides System Rounded")

        // Every bundled case ships its .ttf in the app resources.
        var urls: [URL] = []
        for font in bundled {
            guard let fileName = font.fileName else {
                check(false, "\(font.rawValue) declares a bundled font file")
                continue
            }
            let url = fontsDir.appendingPathComponent("\(fileName).ttf")
            check(FileManager.default.fileExists(atPath: url.path),
                  "\(font.rawValue) file exists at AuraViz/Resources/Fonts/\(fileName).ttf")
            urls.append(url)
        }

        // Registration makes every declared face resolvable by PostScript name.
        FontRegistrar.register(fontsAt: urls)
        for font in bundled {
            for name in font.postScriptNames {
                check(NSFont(name: name, size: 20) != nil,
                      "\(name) resolves after registration")
            }
            check(font.isAvailable, "\(font.rawValue) reports available after registration")
        }
        check(OverlayFont.systemRounded.isAvailable, "System Rounded is always available")

        // Persisted raw values round-trip; an unknown value resolves to nil so
        // the performance state can fall back instead of trapping.
        for font in OverlayFont.allCases {
            check(OverlayFont(rawValue: font.rawValue) == font,
                  "\(font.rawValue) raw value round-trips")
        }
        check(OverlayFont(rawValue: "No Such Font") == nil,
              "unknown raw value falls back (nil)")

        // Weight mapping: Orbitron thickens across the overlay's weight ramp,
        // single-weight display faces stay on their only face, System defers
        // to the system font.
        let ramp: [Font.Weight] = [.regular, .medium, .semibold, .bold, .heavy, .black]
        let orbitronFaces = ramp.compactMap { OverlayFont.orbitron.postScriptName(forWeight: $0) }
        check(orbitronFaces.count == ramp.count && Set(orbitronFaces).count > 1,
              "Orbitron maps the weight ramp to distinct faces (\(orbitronFaces))")
        for font in [OverlayFont.bebasNeue, .anton, .bungee] {
            let faces = Set(ramp.compactMap { font.postScriptName(forWeight: $0) })
            check(faces.count == 1, "\(font.rawValue) is single-weight (\(faces))")
        }
        check(OverlayFont.systemRounded.postScriptName(forWeight: .black) == nil,
              "System Rounded has no bundled PostScript name")

        print(failures == 0 ? "\nAll font checks passed." : "\n\(failures) font check(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }
}
