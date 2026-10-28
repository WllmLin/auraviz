import AppKit
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// Contents of the "AuraViz Output" window: only the visualizer, edge to edge
/// on black, with no controls or HUD.
struct OutputView: View {
    @EnvironmentObject var audio: AudioEngineManager
    @EnvironmentObject var output: OutputWindowController

    var body: some View {
        PerformanceStage(audio: audio)
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
/// and hides the cursor over the output after 2 s without movement. Keeps
/// the displays awake while the output is full screen.
final class OutputWindowController: ObservableObject {
    static let windowID = "output"
    private static let cursorIdleDelay: TimeInterval = 2
    private static let escapeKeyCode: UInt16 = 53

    @Published private(set) var displays: [OutputDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var isOpen = false
    /// The latest screenshot attempt, for the control window's shutter feedback.
    @Published private(set) var snapshot: OutputSnapshot?

    private weak var window: NSWindow?
    private var isCapturing = false
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
    private var displaySleepActivity: NSObjectProtocol?

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
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                self?.preventDisplaySleep()
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                self?.allowDisplaySleep()
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
        allowDisplaySleep()
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

    // MARK: - Display sleep

    private func preventDisplaySleep() {
        guard displaySleepActivity == nil else { return }
        displaySleepActivity = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled, reason: "AuraViz output is full screen")
    }

    private func allowDisplaySleep() {
        guard let displaySleepActivity else { return }
        ProcessInfo.processInfo.endActivity(displaySleepActivity)
        self.displaySleepActivity = nil
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

    // MARK: - Screenshot

    /// Grabs the output window's current frame as shown, strobe, blackout and
    /// transitions included, and saves it to the Desktop as a timestamped PNG.
    /// Only publishes `snapshot`; nothing is drawn on the output.
    func captureFrame() {
        guard !isCapturing else { return }
        guard let window, window.isVisible else {
            reportSnapshot(url: nil, message: "Open the output to take a screenshot")
            return
        }
        isCapturing = true
        let windowID = CGWindowID(window.windowNumber)
        let date = Date()
        Task { @MainActor [weak self] in
            do {
                let image = try await Self.captureImage(ofWindow: windowID)
                // PNG-encoding a 4K frame takes long enough to drop output frames.
                let url = try await Task.detached(priority: .utility) {
                    try Self.writePNG(image, takenAt: date)
                }.value
                self?.reportSnapshot(url: url, message: "Saved \(url.lastPathComponent) to the Desktop")
            } catch {
                let message: String
                if !CGPreflightScreenCaptureAccess() {
                    _ = CGRequestScreenCaptureAccess()
                    message = "Allow AuraViz in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
                } else {
                    message = "Screenshot failed: \(error.localizedDescription)"
                }
                self?.reportSnapshot(url: nil, message: message)
            }
            self?.isCapturing = false
        }
    }

    private func reportSnapshot(url: URL?, message: String) {
        snapshot = OutputSnapshot(id: (snapshot?.id ?? 0) + 1, url: url, message: message)
    }

    private static func captureImage(ofWindow windowID: CGWindowID) async throws -> CGImage {
        let content: SCShareableContent
        if #available(macOS 14.4, *) {
            content = try await SCShareableContent.currentProcess
        } else {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The output window isn't on screen."])
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Writes "AuraViz <date> at <time>.png" to the Desktop, numbering it if
    /// two shots land in the same second.
    private static func writePNG(_ image: CGImage, takenAt date: Date) throws -> URL {
        let desktop = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "AuraViz \(formatter.string(from: date))"
        var url = desktop.appendingPathComponent("\(stem).png")
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = desktop.appendingPathComponent("\(stem) (\(copy)).png")
            copy += 1
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}

/// One screenshot attempt: the saved PNG, or nil if it failed, and what to
/// tell the performer.
struct OutputSnapshot: Equatable {
    let id: Int
    let url: URL?
    let message: String
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
