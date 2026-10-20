import AppKit
import SwiftUI

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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audio)
                .environmentObject(performance)
                .environmentObject(output)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About AuraViz") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "AuraViz",
                        .applicationVersion: "1.0 • Aesthetic Visualizer",
                        .credits: NSAttributedString(string: "Circle • Waves • Bars\nBuilt with SwiftUI + ScreenCaptureKit + Accelerate")
                    ])
                }
            }
            PerformanceCommands(audio: audio, performance: performance, output: output)
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
