import AppKit
import SwiftUI

/// Contents of the "AuraViz Output" window: only the visualizer, edge to edge
/// on black, with no controls or HUD.
struct OutputView: View {
    @EnvironmentObject var audio: AudioEngineManager
    @EnvironmentObject var performance: PerformanceState
    @EnvironmentObject var output: OutputWindowController

    var body: some View {
        VisualizerStage(audio: audio, mode: performance.mode, theme: performance.theme, framesPerSecond: performance.circleFramesPerSecond)
            .frame(minWidth: 320, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
            .background(Color.black)
            .overlay(StageEffectsOverlay())
            .ignoresSafeArea()
            .background(WindowAccessor { output.attach($0) })
    }
}

/// A display the output can be sent to.
struct OutputDisplay: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

/// Drives the output window from AppKit: tracks attached displays, moves the
/// window to the chosen one in native full screen, leaves full screen on Esc
/// and hides the cursor over the output after 2 s without movement.
final class OutputWindowController: ObservableObject {
    static let windowID = "output"
    private static let cursorIdleDelay: TimeInterval = 2
    private static let escapeKeyCode: UInt16 = 53

    @Published private(set) var displays: [OutputDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var isOpen = false

    private weak var window: NSWindow?
    private var presentWhenAttached = false
    /// Set while leaving full screen on one display to re-enter it on another.
    private var pendingScreen: NSScreen?
    private var windowObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var cursorTimer: Timer?
    private var lastMouseLocation = NSPoint(x: -1, y: -1)
    private var lastMouseMove: TimeInterval = 0
    private var cursorHidden = false

    init() {
        refreshDisplays()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDisplays()
        }
    }

    var selectedDisplayName: String {
        displays.first { $0.id == selectedDisplayID }?.name ?? "the main display"
    }

    /// Shows the output full screen on the selected display. Call together
    /// with `openWindow(id: windowID)`: if the window isn't up yet, it is
    /// presented as soon as it attaches.
    func presentOutput() {
        if let window {
            present(window)
        } else {
            presentWhenAttached = true
        }
    }

    /// Leaves full screen if the output is in it, otherwise presents it full
    /// screen on the selected display. Needs the output window to be open.
    func toggleFullScreen() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            present(window)
        }
    }

    func attach(_ window: NSWindow) {
        guard window !== self.window else { return }
        detach()
        self.window = window
        isOpen = true
        window.title = "AuraViz Output"
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)

        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.detach()
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                self?.finishScreenChange()
            },
        ]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode,
                  let window = self?.window, event.window === window,
                  window.styleMask.contains(.fullScreen) else { return event }
            window.toggleFullScreen(nil)
            return nil
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.hideIdleCursor()
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer

        if presentWhenAttached {
            presentWhenAttached = false
            // Let SwiftUI finish placing the new window before moving it.
            DispatchQueue.main.async { [weak self, weak window] in
                if let self, let window { self.present(window) }
            }
        }
    }

    private func detach() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        cursorTimer?.invalidate()
        cursorTimer = nil
        pendingScreen = nil
        window = nil
        isOpen = false
    }

    // MARK: - Full screen placement

    private func present(_ window: NSWindow) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == selectedDisplayID }) ?? NSScreen.main else { return }
        window.makeKeyAndOrderFront(nil)
        if window.styleMask.contains(.fullScreen) {
            guard window.screen?.displayID != screen.displayID else { return }
            // A full-screen window can't change displays: leave full screen,
            // then re-enter on the new display from didExitFullScreen.
            pendingScreen = screen
            window.toggleFullScreen(nil)
        } else {
            enterFullScreen(window, on: screen)
        }
    }

    private func finishScreenChange() {
        guard let window, let screen = pendingScreen else { return }
        pendingScreen = nil
        enterFullScreen(window, on: screen)
    }

    private func enterFullScreen(_ window: NSWindow, on screen: NSScreen) {
        // Native full screen takes over the display the window is on, so
        // center the window on the target display first.
        let area = screen.visibleFrame
        let size = NSSize(width: min(window.frame.width, area.width), height: min(window.frame.height, area.height))
        window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: true)
        DispatchQueue.main.async {
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
    }

    // MARK: - Displays

    private func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            let pixels = screen.convertRectToBacking(screen.frame).size
            return OutputDisplay(id: id, name: "\(screen.localizedName) — \(Int(pixels.width))×\(Int(pixels.height))")
        }
        if !displays.contains(where: { $0.id == selectedDisplayID }) {
            // Prefer a secondary display (projector, LED wall) over the one
            // with the menu bar.
            selectedDisplayID = (displays.dropFirst().first ?? displays.first)?.id
        }
    }

    // MARK: - Cursor

    /// Polled rather than driven by mouse-moved events, which only reach the
    /// key window; the output is usually not key while the control window is.
    private func hideIdleCursor() {
        guard let window, window.isVisible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let location = NSEvent.mouseLocation
        if location != lastMouseLocation {
            lastMouseLocation = location
            lastMouseMove = now
            cursorHidden = false
            return
        }
        // AppKit only hides the cursor for the active app.
        guard !cursorHidden, now - lastMouseMove >= Self.cursorIdleDelay, NSApp.isActive,
              NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0) == window.windowNumber else { return }
        // AppKit shows it again on the next mouse movement.
        NSCursor.setHiddenUntilMouseMoves(true)
        cursorHidden = true
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Reports the NSWindow hosting a SwiftUI view once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { WindowReportingView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        let onWindow: (NSWindow) -> Void

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Deferred so callers can publish state outside SwiftUI's view update.
            DispatchQueue.main.async { [onWindow] in onWindow(window) }
        }
    }
}
