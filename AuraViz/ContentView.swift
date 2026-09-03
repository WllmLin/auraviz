import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audio: AudioEngineManager
    @State private var selectedMode: VisualMode = .circle
    @State private var selectedTheme: ColorTheme = .aurora
    @State private var showSettings = true

    var body: some View {
        ZStack {
            // background mesh
            auraBackgroundGradient
                .ignoresSafeArea()
            // subtle orbs
            GeometryReader { geo in
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Color.purple.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 400))
                        .frame(width: 700, height: 700)
                        .position(x: geo.size.width * 0.22, y: geo.size.height * 0.18)
                        .blur(radius: 40)
                    Circle()
                        .fill(RadialGradient(colors: [Color.cyan.opacity(0.18), .clear], center: .center, startRadius: 0, endRadius: 500))
                        .frame(width: 800, height: 800)
                        .position(x: geo.size.width * 0.85, y: geo.size.height * 0.75)
                        .blur(radius: 50)
                    Circle()
                        .fill(RadialGradient(colors: [Color.pink.opacity(0.14), .clear], center: .center, startRadius: 0, endRadius: 350))
                        .frame(width: 600, height: 600)
                        .position(x: geo.size.width * 0.5, y: geo.size.height * 0.5)
                        .blur(radius: 60)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(LinearGradient(colors: selectedTheme.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 36, height: 36)
                                .shadow(color: selectedTheme.gradient.first!.opacity(0.5), radius: 10, x: 0, y: 4)
                            Image(systemName: "waveform.path.badge.mic")
                                .foregroundStyle(.white)
                                .font(.system(size: 16, weight: .semibold))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("AURA_VIZ")
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .tracking(1.4)
                                .foregroundStyle(.white)
                            Text("AESTHETIC AUDIO VISUALIZER  •  macOS")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .tracking(0.8)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    Spacer()
                    // mode picker
                    Picker("", selection: $selectedMode) {
                        ForEach(VisualMode.allCases) { m in
                            Label(m.rawValue, systemImage: m.icon).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 360)
                    .background(.ultraThinMaterial, in: Capsule())
                    // theme
                    Menu {
                        ForEach(ColorTheme.allCases) { th in
                            Button(th.rawValue) { selectedTheme = th }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(LinearGradient(colors: selectedTheme.gradient, startPoint: .leading, endPoint: .trailing)).frame(width: 14, height: 14)
                            Text(selectedTheme.rawValue).font(.system(size: 12, weight: .semibold, design: .rounded))
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)

                // Visualizer Card
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.black.opacity(0.42))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
                    // inner subtle border highlight
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.04), lineWidth: 1)
                        .padding(1)

                    Group {
                        switch selectedMode {
                        case .circle:
                            CircularVisualizerView(spectrum: audio.spectrum, volume: audio.volume, theme: selectedTheme, sensitivity: audio.sensitivity)
                        case .waves:
                            WaveVisualizerView(spectrum: audio.spectrum, waveform: audio.waveform, volume: audio.volume, theme: selectedTheme, sensitivity: audio.sensitivity)
                        case .y2k:
                            Y2KBarVisualizerView(spectrum: audio.spectrum, volume: audio.volume, theme: selectedTheme, sensitivity: audio.sensitivity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                    // top HUD
                    VStack {
                        HStack {
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
                .frame(height: 420)
                .padding(.horizontal, 18)

                // Controls
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
                        GridRow {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Label("Sensitivity", systemImage: "eye.fill").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                                    Spacer()
                                    Text(String(format: "%.1fx", audio.sensitivity)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                                }
                                Slider(value: $audio.sensitivity, in: 0.3...2.2)
                                    .tint(.orange)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Label("Smoothing", systemImage: "water.waves").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                                    Spacer()
                                    Text(String(format: "%.0f%%", audio.smoothing*100)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                                }
                                Slider(value: $audio.smoothing, in: 0...0.92)
                                    .tint(.purple)
                            }
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
                    }
                }
                .padding(16)
                .glassCard()
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 980, minHeight: 700)
        .onAppear {
            if !audio.isRunning { audio.start() }
        }
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
                        .fill(LinearGradient(colors: selectedTheme.gradient, startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * audio.volume, height: 6)
                }
            }
            .frame(width: 90, height: 6)
        }
    }
}

#Preview {
    ContentView().environmentObject(AudioEngineManager())
        .frame(width: 1000, height: 760)
}
