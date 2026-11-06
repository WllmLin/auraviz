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
    /// What the quit guard checks; set by the app's windows once the shared
    /// state exists.
    private weak var audio: AudioEngineManager?
    private weak var output: OutputWindowController?
    /// Closing the last window is deliberate, so only Quit itself is guarded.
    private var isClosingLastWindow = false

    func guardQuit(audio: AudioEngineManager, output: OutputWindowController) {
        self.audio = audio
        self.output = output
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        isClosingLastWindow = true
        return true
    }

    /// Asks before quitting mid-show: while the output window is open or
    /// audio capture is on, a stray ⌘Q would cut the visuals.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        defer { isClosingLastWindow = false }
        let isOutputOpen = output?.isOpen ?? false
        let isCapturing = audio.map { $0.isRunning || $0.isStarting } ?? false
        guard !isClosingLastWindow, isOutputOpen || isCapturing else { return .terminateNow }
        return confirmQuit(isOutputOpen: isOutputOpen, isCapturing: isCapturing) ? .terminateNow : .terminateCancel
    }

    private func confirmQuit(isOutputOpen: Bool, isCapturing: Bool) -> Bool {
        let live: String
        if isOutputOpen && isCapturing {
            live = "The output window is open and audio capture is on."
        } else if isOutputOpen {
            live = "The output window is open."
        } else {
            live = "Audio capture is on."
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit AuraViz?"
        alert.informativeText = "\(live) Quitting stops the visuals. Press ⌘Q again to quit."
        // Cancel comes first so Return and Esc keep the show running; a
        // deliberate second ⌘Q confirms.
        alert.addButton(withTitle: "Cancel")
        let quit = alert.addButton(withTitle: "Quit")
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        quit.hasDestructiveAction = true
        // Quit from the Dock arrives while another app is frontmost.
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }
}

@main
struct AuraVizApp: App {
    init() {
        // Bundled overlay fonts must exist before the first view measures text.
        FontRegistrar.registerBundledFonts()
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var audio = AudioEngineManager()
    @StateObject private var performance = PerformanceState()
    @StateObject private var output = OutputWindowController()
    @StateObject private var presets = PresetStore()
    @StateObject private var imageOverlays = ImageOverlayStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audio)
                .environmentObject(performance)
                .environmentObject(output)
                .environmentObject(presets)
                .environmentObject(imageOverlays)
                .preferredColorScheme(.dark)
                .onAppear { appDelegate.guardQuit(audio: audio, output: output) }
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
            PerformanceCommands(audio: audio, performance: performance, output: output, imageOverlays: imageOverlays)
            CommandMenu("Presets") {
                PresetsMenuContent(audio: audio, performance: performance, presets: presets)
            }
        }

        Window("AuraViz Output", id: OutputWindowController.windowID) {
            OutputView()
                .environmentObject(audio)
                .environmentObject(performance)
                .environmentObject(output)
                .environmentObject(imageOverlays)
                .preferredColorScheme(.dark)
                // Window restoration can bring the output back on its own.
                .onAppear { appDelegate.guardQuit(audio: audio, output: output) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
    }
}
