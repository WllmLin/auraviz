import AppKit
import SwiftUI

enum AppVersion {
    /// CFBundleShortVersionString, e.g. "1.0".
    static let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    /// CFBundleVersion; build.sh stamps it as "<yyyymmdd>.<short git sha>".
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    static let display = "\(marketing) (\(build))"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AuraVizApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var audio = AudioEngineManager()
    @StateObject private var performance = PerformanceState()
    @StateObject private var output = OutputWindowController()
    @StateObject private var presets = PresetStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audio)
                .environmentObject(performance)
                .environmentObject(output)
                .environmentObject(presets)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(ContentView.defaultWindowSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About AuraViz") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "AuraViz",
                        .applicationVersion: "\(AppVersion.marketing) • Aesthetic Visualizer",
                        .version: AppVersion.build,
                        .credits: NSAttributedString(string: "Circle • Waves • Bars\nBuilt with SwiftUI + ScreenCaptureKit + Accelerate")
                    ])
                }
            }
            PerformanceCommands(audio: audio, performance: performance, output: output)
            CommandMenu("Presets") {
                PresetsMenuContent(audio: audio, performance: performance, presets: presets)
            }
        }

        Window("AuraViz Output", id: OutputWindowController.windowID) {
            OutputView()
                .environmentObject(audio)
                .environmentObject(performance)
                .environmentObject(output)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
    }
}
