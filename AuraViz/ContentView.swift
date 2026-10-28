import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audio: AudioEngineManager
    @EnvironmentObject var performance: PerformanceState
    @EnvironmentObject var output: OutputWindowController
    @EnvironmentObject var presets: PresetStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showControls = true
    @State private var isNarrowLayout = false
    @State private var isFullscreen = false
    @State private var hostWindow = WeakWindow()
    @State private var newPresetName = ""
    @FocusState private var isLyricsFieldFocused: Bool

    var body: some View {
        ZStack {
            // background mesh
            auraBackgroundGradient
                .ignoresSafeArea()
            if isFullscreen {
                fullscreenLayout
            } else {
                windowedLayout
            }
        }
        // Here, not on the output, so the shutter never shows to the audience.
        .overlay { SnapshotFeedback(snapshot: output.snapshot) }
        .overlay {
            if performance.isShowingShortcuts {
                ShortcutCheatSheet(isPresented: $performance.isShowingShortcuts)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: performance.isShowingShortcuts)
        .alert("Save Preset", isPresented: $performance.isNamingPreset) {
            TextField("Name", text: $newPresetName)
            Button("Save") {
                presets.save(name: newPresetName, audio: audio, performance: performance)
                newPresetName = ""
            }
            Button("Cancel", role: .cancel) { newPresetName = "" }
        } message: {
            Text("Saves the mode, theme, circle FPS, sensitivity, auto gain, smoothing, beat reactivity and the mode's drum reactivity. Saving under an existing name replaces that preset.")
        }
        .frame(minWidth: Self.minWindowSize.width, maxWidth: .infinity, minHeight: Self.minWindowSize.height, maxHeight: .infinity)
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.narrowLayoutWidth } action: { isNarrowLayout = $0 }
        .background(WindowAccessor { hostWindow.window = $0 })
        .onAppear {
            if !audio.isRunning { audio.start() }
            // macOS can make the only text field first responder when the
            // window opens, which would silence the shortcuts until clicked away.
            DispatchQueue.main.async { isLyricsFieldFocused = false }
        }
        // Single-key shortcuts stand down while the lyrics field has focus.
        .onChange(of: isLyricsFieldFocused) { _, isFocused in
            performance.isEditingLyrics = isFocused
        }
        // Only this window's full screen; the output window toggles its own.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if note.object as? NSWindow === hostWindow.window { isFullscreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if note.object as? NSWindow === hostWindow.window { isFullscreen = false }
        }
    }

    // MARK: - Layouts

    static let minWindowSize = CGSize(width: 760, height: 560)
    static let defaultWindowSize = CGSize(width: 1280, height: 820)
    /// Below this window width the sliders wrap into two rows.
    private static let narrowLayoutWidth: CGFloat = 1080

    private var windowedLayout: some View {
        VStack(spacing: 12) {
            headerView

            // Visualizer Card — flexible height so the circle gets all leftover space
            visualizerCard
                .frame(minHeight: 220, maxHeight: .infinity)
                .layoutPriority(1)
                .padding(.horizontal, 18)

            // Controls — collapsible
            if showControls {
                controlsPanel
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                collapsedControlsBar
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showControls)
    }

    private var fullscreenLayout: some View {
        ZStack {
            // Full-bleed visualizer, no card chrome
            visualizerContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            VStack {
                // Slim floating HUD
                HStack {
                    liveBadge
                    tempoButton
                    if audio.autoGainEnabled {
                        autoGainBadge
                    }
                    if performance.isBlackedOut {
                        blackoutBadge
                    }
                    if let queuedLook = performance.queuedLook {
                        queuedBadge(queuedLook)
                    }
                    Spacer()
                    if performance.mode == .circle {
                        fpsButton
                    }
                    chromeButton(icon: showControls ? "chevron.down" : "sliders.horizontal.3", help: showControls ? "Hide controls (H)" : "Show controls (H)") {
                        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                    }
                    .keyboardShortcut(hideControlsShortcut)
                    shortcutsButton
                    chromeButton(icon: "arrow.down.right.and.arrow.up.left", help: "Exit full screen") {
                        toggleFullscreen()
                    }
                }
                .padding(16)
                Spacer()
                if showControls {
                    controlsPanel
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    // Floating play/pause when controls hidden
                    HStack {
                        Spacer()
                        Button(action: { audio.toggleRunning() }) {
                            ZStack {
                                Circle().fill(.ultraThinMaterial).frame(width: 44, height: 44).overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                                Image(systemName: (audio.isRunning || audio.isStarting) ? "pause.fill" : "play.fill")
                                    .foregroundStyle(.white)
                                    .font(.system(size: 16, weight: .bold))
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(20)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showControls)
    }

    // MARK: - Header

    private var headerView: some View {
        // Widest first; ViewThatFits shows the first one that fits the window.
        ViewThatFits(in: .horizontal) {
            header(.regular)
            header(.condensed)
            header(.iconic)
            header(.compact)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private func header(_ density: HeaderDensity) -> some View {
        HStack(spacing: 12) {
            brand(density)
            Spacer(minLength: 12)
            modePicker(showsLabels: density < .compact)
            themeMenu(showsName: density < .iconic)
            presetsMenu(showsTitle: density < .iconic)
            outputButton(showsTitle: density < .iconic)
            // collapse controls
            chromeButton(icon: showControls ? "chevron.down" : "chevron.up", help: showControls ? "Hide controls (H)" : "Show controls (H)") {
                withAnimation(.easeInOut(duration: 0.22)) { showControls.toggle() }
            }
            .keyboardShortcut(hideControlsShortcut)
            shortcutsButton
            // fullscreen
            chromeButton(icon: "arrow.up.left.and.arrow.down.right", help: "Enter full screen") {
                toggleFullscreen()
            }
        }
    }

    private func brand(_ density: HeaderDensity) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: performance.theme.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                    .shadow(color: performance.theme.gradient.first!.opacity(0.5), radius: 10, x: 0, y: 4)
                Image(systemName: "waveform.path.badge.mic")
                    .foregroundStyle(.white)
                    .font(.system(size: 16, weight: .semibold))
            }
            if density < .compact {
                VStack(alignment: .leading, spacing: 1) {
                    Text("AURA_VIZ")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.white)
                    if density < .condensed {
                        Text("AESTHETIC AUDIO VISUALIZER  •  macOS")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AuraViz")
        .accessibilityValue("Version \(AppVersion.display)")
        .help("AuraViz \(AppVersion.display)")
    }

    private func modePicker(showsLabels: Bool) -> some View {
        // Shows the queued mode while a quantized switch waits for its beat.
        Picker("Mode", selection: Binding(
            get: { performance.targetLook.mode },
            set: { performance.switchMode(to: $0, clock: audio.transitionClock) }
        )) {
            ForEach(VisualMode.allCases) { m in
                Group {
                    if showsLabels {
                        Label(m.rawValue, systemImage: m.icon)
                    } else {
                        Image(systemName: m.icon)
                            .accessibilityLabel(m.rawValue)
                    }
                }
                .help(m.rawValue)
                .tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func themeMenu(showsName: Bool) -> some View {
        Menu {
            ForEach(ColorTheme.allCases) { th in
                Button(th.rawValue) { performance.theme = th }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(LinearGradient(colors: performance.theme.gradient, startPoint: .leading, endPoint: .trailing)).frame(width: 14, height: 14)
                if showsName {
                    Text(performance.theme.rawValue).font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Theme: \(performance.theme.rawValue)")
        .accessibilityLabel("Theme")
        .accessibilityValue(performance.theme.rawValue)
    }

    // MARK: - Visualizer

    private var visualizerCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.04), lineWidth: 1)
                .padding(1)

            visualizerContent
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            // top HUD
            VStack {
                HStack {
                    liveBadge
                    tempoButton
                    if audio.autoGainEnabled {
                        autoGainBadge
                    }
                    if performance.isBlackedOut {
                        blackoutBadge
                    }
                    if let queuedLook = performance.queuedLook {
                        queuedBadge(queuedLook)
                    }
                    Spacer()
                    if performance.mode == .circle {
                        fpsButton
                    }
                }
                .padding(14)
                Spacer()
            }

            // play/pause floating
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: { audio.toggleRunning() }) {
                        ZStack {
                            Circle().fill(.ultraThinMaterial).frame(width: 44, height: 44).overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                            Image(systemName: (audio.isRunning || audio.isStarting) ? "pause.fill" : "play.fill")
                                .foregroundStyle(.white)
                                .font(.system(size: 16, weight: .bold))
                                .offset(x: (audio.isRunning || audio.isStarting) ? 0 : 1)
                        }
                        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
            }
        }
    }

    private var visualizerContent: some View {
        PerformanceStage(audio: audio)
            .overlay(StageEffectsOverlay())
            // Clicking the stage finishes editing the lyrics.
            .contentShape(Rectangle())
            .onTapGesture { isLyricsFieldFocused = false }
    }

    private func presetsMenu(showsTitle: Bool) -> some View {
        Menu {
            PresetsMenuContent(audio: audio, performance: performance, presets: presets)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack").font(.system(size: 11, weight: .bold))
                if showsTitle {
                    Text("Presets").font(.system(size: 12, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Save, recall and delete presets")
        .accessibilityLabel("Presets")
    }

    /// Opens the output window full screen on the chosen display; the arrow
    /// picks the display (and closes the output while it is open).
    private func outputButton(showsTitle: Bool) -> some View {
        Menu {
            Picker("Display", selection: $output.selectedDisplayID) {
                ForEach(output.displays) { display in
                    Text(display.name).tag(Optional(display.id))
                }
            }
            .pickerStyle(.inline)
            if output.isOpen {
                Divider()
                Button("Close Output") { dismissWindow(id: OutputWindowController.windowID) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "display").font(.system(size: 11, weight: .bold))
                if showsTitle {
                    Text("Open Output").font(.system(size: 12, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        } primaryAction: {
            output.presentOutput()
            openWindow(id: OutputWindowController.windowID)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Open the output full screen on \(output.selectedDisplayName). Esc in the output leaves full screen.")
        .accessibilityLabel("Open Output")
    }

    // MARK: - HUD pieces

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(audio.isRunning ? Color.green : (audio.isStarting ? Color.orange : Color.red))
                .frame(width: 7, height: 7)
                .shadow(color: audio.isRunning ? .green : (audio.isStarting ? .orange : .red), radius: 6)
            Text(audio.isStarting ? "CONNECTING" : (audio.isRunning ? "LIVE" : "PAUSED"))
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.85))
            Text("•  \(audio.inputMode.rawValue.uppercased())").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
    }

    private var tempoButton: some View {
        Button {
            audio.tapTempo()
        } label: {
            HStack(spacing: 6) {
                BeatFlashDot(
                    lastBeatTime: audio.lastBeatTime,
                    strength: audio.beatStrength,
                    color: performance.theme.gradient.first!,
                    isActive: audio.isRunning
                )
                Text(audio.bpm > 0 ? String(format: "%.0f BPM", audio.bpm) : "--- BPM")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Click or press B on each beat to tap the tempo")
        .accessibilityLabel("Tempo")
        .accessibilityValue(audio.bpm > 0 ? String(format: "%.0f beats per minute", audio.bpm) : "Detecting")
        .accessibilityHint("Tap on each beat to set the tempo")
    }

    private var autoGainBadge: some View {
        Text("AGC")
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .tracking(1)
            .foregroundStyle(.white.opacity(audio.isRunning ? 0.85 : 0.45))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
            .help(String(format: "Auto gain is on (%+.0f dB). Sensitivity is a trim on top.", audio.autoGainDB))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Auto gain on")
            .accessibilityValue(String(format: "%+.0f decibels", audio.autoGainDB))
    }

    private var blackoutBadge: some View {
        Button {
            performance.isBlackedOut = false
        } label: {
            Text("BLACKOUT")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.red.opacity(0.45), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("The stage is blacked out. Click or press Space to bring it back.")
        .accessibilityLabel("Blackout on")
        .accessibilityHint("Brings the stage back")
    }

    /// A quantized switch waiting for its beat or bar; clicking lands it now.
    private func queuedBadge(_ look: StageLook) -> some View {
        Button {
            performance.showQueuedLookNow()
        } label: {
            Text("CUED \(look.mode.rawValue.uppercased()) · NEXT \(performance.transitionQuantize.rawValue.uppercased())")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(performance.theme.gradient.first!.opacity(0.45), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Switching to \(look.mode.rawValue) on the next \(performance.transitionQuantize.rawValue.lowercased()). Click to switch now.")
        .accessibilityLabel("\(look.mode.rawValue) cued for the next \(performance.transitionQuantize.rawValue.lowercased())")
        .accessibilityHint("Switches now")
    }

    private var shortcutsButton: some View {
        chromeButton(icon: "questionmark", help: "Keyboard shortcuts (⌘/)") {
            performance.isShowingShortcuts.toggle()
        }
        .accessibilityLabel("Keyboard shortcuts")
    }

    private var fpsButton: some View {
        Button {
            performance.circleFramesPerSecond = performance.circleFramesPerSecond == 30 ? 60 : 30
        } label: {
            Label("\(performance.circleFramesPerSecond) FPS", systemImage: "speedometer")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Switch circle to \(performance.circleFramesPerSecond == 30 ? 60 : 30) FPS")
        .accessibilityLabel("Circle frame rate")
        .accessibilityValue("\(performance.circleFramesPerSecond) frames per second")
        .accessibilityHint("Switches to \(performance.circleFramesPerSecond == 30 ? 60 : 30) frames per second")
    }

    private func chromeButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Controls

    private var controlsPanel: some View {
        VStack(spacing: 14) {
            // Input row
            HStack(spacing: 14) {
                Picker("Input", selection: $audio.inputMode) {
                    ForEach(InputMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                if audio.inputMode == .microphone {
                    if !audio.micPermissionGranted {
                        Button("Enable Microphone") { audio.requestMicPermission() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.pink)
                    } else {
                        inputStatusBadge(
                            icon: "mic.fill",
                            title: audio.isRunning ? "Microphone Active" : "Microphone Ready",
                            color: .pink
                        )
                    }
                } else {
                    if !audio.systemAudioPermissionGranted && !audio.isStarting {
                        Button("Enable System Audio") { audio.requestSystemAudioPermission() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.cyan)
                    } else {
                        inputStatusBadge(
                            icon: "speaker.wave.3.fill",
                            title: audio.isStarting ? "Connecting…" : (audio.isRunning ? "System Audio Active" : "System Audio Ready"),
                            color: .cyan
                        )
                    }
                }

                Spacer()
                levelMeter
                Button((audio.isRunning || audio.isStarting) ? "Stop" : "Start") {
                    audio.toggleRunning()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let captureError = audio.captureError {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(captureError)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                }
            }

            Divider().overlay(.white.opacity(0.08))

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                if isNarrowLayout {
                    GridRow { sensitivityControl; smoothingControl }
                    GridRow { beatReactivityControl; resetControl }
                    GridRow { drumControl(.kick); drumControl(.snare) }
                    GridRow { drumControl(.hat); drumsCaption }
                } else {
                    GridRow { sensitivityControl; smoothingControl; beatReactivityControl; resetControl }
                    GridRow { drumControl(.kick); drumControl(.snare); drumControl(.hat); drumsCaption }
                }
            }

            Divider().overlay(.white.opacity(0.08))

            transitionControl

            lyricsControl
        }
        .padding(16)
        .glassCard()
    }

    /// How mode switches and preset recalls hand over, and whether they wait
    /// for the beat grid.
    private var transitionControl: some View {
        HStack(spacing: 10) {
            Label("Transition", systemImage: "rectangle.righthalf.inset.filled.arrow.right")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Picker("Transition", selection: $performance.transition) {
                ForEach(StageTransition.allCases) { style in
                    Text(style.rawValue).tag(style).help(style.help)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("How mode switches and preset recalls hand over: \(performance.transition.help.lowercased())")
            Spacer(minLength: 12)
            Label("Quantize", systemImage: "metronome")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Picker("Quantize", selection: $performance.transitionQuantize) {
                ForEach(TransitionQuantize.allCases) { quantize in
                    Text(quantize.rawValue).tag(quantize)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Wait for the next beat or bar to switch. Needs a tempo: detected, or tapped with B. Without one, switches happen at once.")
        }
    }

    private var lyricsControl: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $performance.isLyricsEnabled.animation(.easeInOut(duration: 0.3))) {
                Label("Lyrics", systemImage: "textformat.size").font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Show the text as kinetic type over the stage and output (L)")
            TextField("Lyrics, track title or shout-out", text: $performance.lyricsText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .focused($isLyricsFieldFocused)
                .onSubmit { isLyricsFieldFocused = false }
                .onExitCommand { isLyricsFieldFocused = false }
                .help("Return or Esc finishes editing. Performance shortcuts are off while you type.")
        }
    }

    private var sensitivityControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(audio.autoGainEnabled ? "Trim" : "Sensitivity", systemImage: "eye.fill").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                Toggle(isOn: $audio.autoGainEnabled) {
                    Text("Auto Gain").font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .toggleStyle(.button)
                .controlSize(.mini)
                .help("Automatic gain control: adapts to quiet and loud sources so both fill the visuals")
                Spacer()
                Text(String(format: "%.1fx", audio.sensitivity)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            }
            Slider(value: $audio.sensitivity, in: AudioEngineManager.sensitivityRange)
                .tint(.orange)
                .help(audio.autoGainEnabled ? "Trim on top of auto gain; 1.0x is neutral" : "Input sensitivity")
        }
    }

    private var smoothingControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Smoothing", systemImage: "water.waves").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(String(format: "%.0f%%", audio.smoothing*100)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            }
            Slider(value: $audio.smoothing, in: AudioEngineManager.smoothingRange)
                .tint(.purple)
        }
    }

    private var beatReactivityControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Beat reactivity", systemImage: "metronome.fill").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(String(format: "%.0f%%", audio.beatReactivity*100)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            }
            Slider(value: $audio.beatReactivity, in: AudioEngineManager.beatReactivityRange)
                .tint(.pink)
                .help("Scales beat-synced motion, punches and flashes; 0 reacts to volume only")
        }
    }

    /// One drum voice's reactivity for the current mode, with a dot that
    /// flashes on each detected hit.
    private func drumControl(_ instrument: DrumInstrument) -> some View {
        let mode = performance.mode
        let value = Binding(
            get: { audio.drumReactivity(for: mode)[instrument] },
            set: { newValue in
                var reactivity = audio.drumReactivity(for: mode)
                reactivity[instrument] = newValue
                audio.setDrumReactivity(reactivity, for: mode)
            }
        )
        let hits = audio.hits(for: instrument)
        let tint = Self.drumTint(instrument)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                BeatFlashDot(lastBeatTime: hits.lastHitTime, strength: hits.strength, color: tint, isActive: audio.isRunning)
                Label(instrument.rawValue, systemImage: instrument.icon).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(String(format: "%.0f%%", value.wrappedValue * 100)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            }
            Slider(value: value, in: DrumReactivity.range)
                .tint(tint)
                .help("How strongly \(mode.rawValue) reacts to the \(instrument.rawValue.lowercased())'s \(instrument.character); scaled by beat reactivity")
                .accessibilityLabel("\(instrument.rawValue) reactivity for \(mode.rawValue)")
        }
    }

    private static func drumTint(_ instrument: DrumInstrument) -> Color {
        switch instrument {
        case .kick: return .red
        case .snare: return .yellow
        case .hat: return .mint
        }
    }

    private var drumsCaption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("DRUMS · \(performance.mode.rawValue.uppercased())")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.7))
            Text("Set per visualizer. Dots flash on detected hits.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(2)
        }
    }

    private var resetControl: some View {
        HStack(spacing: 8) {
            Button {
                audio.resetVisualizationControls()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise").font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
            Text("PLAY AUDIO IN ANY APP")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
    }

    private var collapsedControlsBar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { showControls = true }
            } label: {
                Label("Show controls", systemImage: "chevron.up")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Show controls (H)")
            Spacer()
            levelMeter
            Button((audio.isRunning || audio.isStarting) ? "Stop" : "Start") {
                audio.toggleRunning()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassCard()
    }

    // MARK: - Helpers

    /// H, except while a text field takes the keyboard.
    private var hideControlsShortcut: KeyboardShortcut? {
        performance.isTypingText ? nil : KeyboardShortcut("h", modifiers: [])
    }

    private func toggleFullscreen() {
        (hostWindow.window ?? NSApp.keyWindow)?.toggleFullScreen(nil)
    }

    private func inputStatusBadge(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private var levelMeter: some View {
        HStack(spacing: 7) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.white.opacity(0.55))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12)).frame(height: 6)
                    Capsule()
                        .fill(LinearGradient(colors: performance.theme.gradient, startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * audio.volume, height: 6)
                }
            }
            .frame(width: 90, height: 6)
        }
    }
}

/// How much the header shows, roomiest first.
private enum HeaderDensity: Int, Comparable {
    case regular    // everything
    case condensed  // no subtitle
    case iconic     // theme, presets and output drop their titles
    case compact    // modes as icons, no wordmark

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Weak handle to the control window, so it can tell its own full-screen
/// notifications from the output window's without retaining the window.
private final class WeakWindow {
    weak var window: NSWindow?
}

/// Flashes on each detected beat and fades out over ~150 ms.
private struct BeatFlashDot: View {
    var lastBeatTime: TimeInterval
    var strength: CGFloat
    var color: Color
    var isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive)) { timeline in
            let age = max(0, BeatClock.time(for: timeline.date) - lastBeatTime)
            let flash = isActive ? exp(-age / 0.15) * (0.4 + 0.6 * Double(strength)) : 0
            Circle()
                .fill(color.opacity(0.25 + 0.75 * flash))
                .frame(width: 7, height: 7)
                .scaleEffect(1 + 0.6 * flash)
                .shadow(color: color.opacity(flash), radius: 6 * flash)
        }
        .frame(width: 12, height: 12)
    }
}

/// Shutter feedback for an output screenshot: a soft flash over the control
/// window and a toast naming the file (or why it failed) for 3 s.
private struct SnapshotFeedback: View {
    var snapshot: OutputSnapshot?
    @State private var toast: OutputSnapshot?
    /// Advances only on a saved shot, so a failure doesn't flash.
    @State private var shutterCount = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.white
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .keyframeAnimator(initialValue: 0.0, trigger: shutterCount) { content, opacity in
                    content.opacity(opacity)
                } keyframes: { _ in
                    MoveKeyframe(0.45)
                    LinearKeyframe(0.0, duration: 0.25)
                }
            if let toast {
                HStack(spacing: 10) {
                    Image(systemName: toast.url == nil ? "exclamationmark.triangle.fill" : "camera.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(toast.url == nil ? .orange : .white)
                    Text(toast.message)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                    if let url = toast.url {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.black.opacity(0.7), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .task(id: snapshot?.id) {
            guard let snapshot else { return }
            if snapshot.url != nil { shutterCount += 1 }
            toast = snapshot
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { toast = nil }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AudioEngineManager())
        .environmentObject(PerformanceState())
        .environmentObject(OutputWindowController())
        .environmentObject(PresetStore())
        .frame(width: 1000, height: 760)
}
