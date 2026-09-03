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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audio)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
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
        }
    }
}
