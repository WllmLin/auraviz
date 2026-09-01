import SwiftUI

@main
struct AuraVizApp: App {
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
                        .credits: NSAttributedString(string: "Circle • Waves • Y2K Bars\nBuilt with SwiftUI + Accelerate + AVAudioEngine")
                    ])
                }
            }
        }
    }
}
