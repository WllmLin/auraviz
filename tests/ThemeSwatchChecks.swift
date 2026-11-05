import AppKit
import Foundation
import SwiftUI

// Focused checks for the theme-menu gradient swatches (ColorTheme.swatchImage
// in AuraViz/Theme.swift, shown by ContentView's theme menu). Built and run by
// tests/run_theme_swatch_checks.sh; exits non-zero on any failure.

// Theme.swift's VisualMode returns DrumReactivity (real type in BeatTracker.swift,
// which is not standalone-compilable); this stand-in has the same initializer so
// Theme.swift compiles alone. The checks below exercise ColorTheme only.
struct DrumReactivity: Codable, Equatable {
    var kick: Double
    var snare: Double
    var hat: Double
}

@main
struct ThemeSwatchChecks {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL"): \(message)")
        if !condition { failures += 1 }
    }

    /// Renders `image` at 2x over an opaque backdrop and returns the bitmap.
    static func render(_ image: NSImage, backdrop: NSColor) -> NSBitmapImageRep? {
        let scale: CGFloat = 2
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        backdrop.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func srgb(_ color: NSColor?) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let c = color?.usingColorSpace(.sRGB) else { return nil }
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    static func approx(_ a: (r: CGFloat, g: CGFloat, b: CGFloat), _ b: (r: CGFloat, g: CGFloat, b: CGFloat), tolerance: CGFloat = 0.04) -> Bool {
        abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
    }

    static func main() {
        for theme in ColorTheme.allCases {
            let name = theme.rawValue

            // The prompt's contract: one dot per gradient stop, 3-4 stops.
            check((3...4).contains(theme.gradient.count),
                  "\(name) gradient has 3-4 stops (\(theme.gradient.count))")

            let image = theme.swatchImage
            check(!image.isTemplate, "\(name) swatch is not a template image (dots keep their colors)")

            // Gradients are static, so the swatch must be built once and reused,
            // not recreated every time SwiftUI (re)builds the menu items.
            check(theme.swatchImage === image, "\(name) swatch image is cached (stable identity)")

            // Render over magenta (no theme uses it as a stop backdrop clash) and
            // scan the middle row: expect one blob per stop, in gradient order.
            guard let rep = render(image, backdrop: .magenta) else {
                check(false, "\(name) swatch renders to a bitmap")
                continue
            }
            let midY = rep.pixelsHigh / 2
            var runs: [(start: Int, end: Int)] = []
            var runStart: Int?
            for x in 0..<rep.pixelsWide {
                let isBackdrop = rep.colorAt(x: x, y: midY).map { srgb($0).map { approx($0, (1, 0, 1)) } ?? false } ?? false
                if !isBackdrop, runStart == nil { runStart = x }
                if isBackdrop, let s = runStart { runs.append((s, x - 1)); runStart = nil }
            }
            if let s = runStart { runs.append((s, rep.pixelsWide - 1)) }
            check(runs.count == theme.gradient.count,
                  "\(name) swatch shows one dot per gradient stop (\(runs.count) blobs for \(theme.gradient.count) stops)")

            for (i, run) in runs.enumerated() where i < theme.gradient.count {
                let centerX = (run.start + run.end) / 2
                guard let got = srgb(rep.colorAt(x: centerX, y: midY)),
                      let want = srgb(NSColor(theme.gradient[i])) else {
                    check(false, "\(name) dot \(i) color is readable")
                    continue
                }
                check(approx(got, want),
                      "\(name) dot \(i) matches gradient stop (got \(got), want \(want))")
                // Dots are round: blob width ≈ image height at the same scale.
                let width = CGFloat(run.end - run.start + 1)
                check(abs(width - CGFloat(rep.pixelsHigh)) <= 4,
                      "\(name) dot \(i) is round (width \(width)px vs height \(rep.pixelsHigh)px at 2x)")
            }
        }

        // Dark stops must stay visible on the (always dark) menu: Chrome's black
        // dot rendered over black needs a clearly lighter outline ring.
        if let rep = render(ColorTheme.chrome.swatchImage, backdrop: .black) {
            let midY = rep.pixelsHigh / 2
            // First dot spans roughly the first `pixelsHigh` columns.
            let center = srgb(rep.colorAt(x: rep.pixelsHigh / 2, y: midY))
            var brightestEdge: CGFloat = 0
            for x in 0..<rep.pixelsHigh {
                if let c = srgb(rep.colorAt(x: x, y: midY)) {
                    brightestEdge = max(brightestEdge, (c.r + c.g + c.b) / 3)
                }
            }
            let centerLuma = center.map { ($0.r + $0.g + $0.b) / 3 } ?? 1
            check(centerLuma < 0.1, "Chrome first dot is the black gradient stop (center luma \(centerLuma))")
            check(brightestEdge > 0.35,
                  "Chrome black dot has a visible outline on a dark menu (brightest edge luma \(brightestEdge))")
        } else {
            check(false, "Chrome swatch renders over black")
        }

        print(failures == 0 ? "\nAll theme swatch checks passed." : "\n\(failures) theme swatch check(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }
}
