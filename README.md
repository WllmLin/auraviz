# AuraViz — Aesthetic Audio Visualizer for macOS

Native macOS SwiftUI app with three aesthetic visualizer modes reacting to **volume** and **frequency**.

<img src="https://via.placeholder.com/900x480/0B0B12/FFFFFF?text=AuraViz+Preview" />

## Features

- **Three visualizers**
  - **Circle** — radial spectrum around a pulsing glass core (60 bars, glow tips, orbit ring)
  - **Waves** — three layered filled sine waves driven by low/mid/high bands + live waveform, with grid and central orb
  - **Bars** — 32 chrome/gel bars with glass highlight, mirrored reflection, grid, peak caps, chrome ledge & scanlines

- **Audio input**
  - **System Audio mode** (default) — real-time audio from music, video, browsers, and other apps via `ScreenCaptureKit`. AuraViz excludes its own process audio and captures only a minimal 2×2 video stream to keep overhead low.
  - **Microphone mode** — optional live mic via `AVAudioEngine`.
  - Both live inputs use a 4096-point FFT via `Accelerate/vDSP`, a 64-band log-spaced spectrum, RMS volume, waveform samples, and dominant-frequency detection.

- **Controls**
  - Sensitivity (0.3–2.2×) + Smoothing (0–92%)
  - Theme: Aurora / Sunset / Ocean / Y2K Chrome / Stockholm / Tokyo Night / Cyberpunk / Chrome
  - Segmented mode switch, live volume & Hz HUD, play/pause

- **Aesthetic**
  - Dark mesh background with blurred aurora orbs, glassmorphism cards, rounded 22pt containers, ultraThinMaterial, neon gradients, glow + shadow.

## Project

```
AuraViz/
├── AuraViz.xcodeproj/project.pbxproj  # Xcode 14+ / macOS 14+ target
├── AuraViz/
│   ├── AuraVizApp.swift               # @main App, WindowGroup
│   ├── ContentView.swift              # Header, 420pt visualizer card, controls
│   ├── Theme.swift                    # VisualMode, ColorTheme, glass modifiers
│   ├── AudioEngineManager.swift       # ScreenCaptureKit + AVAudioEngine + vDSP FFT
│   ├── Visualizers/
│   │   ├── CircularVisualizerView.swift
│   │   ├── WaveVisualizerView.swift
│   │   └── Y2KBarVisualizerView.swift
│   ├── Assets.xcassets/AppIcon.appiconset
│   └── AuraViz.entitlements           # audio-input, no sandbox
└── build/AuraViz.app                  # pre-built (adhoc signed)
```

## Open in Xcode

```bash
open /Users/wlinwork/projects/AuraViz/AuraViz.xcodeproj
# Select scheme "AuraViz" → My Mac → Run (⌘R)
```

- On first launch Xcode may prompt to accept license / install components: accept.
- The entitlements file already grants `com.apple.security.device.audio-input`; if sandboxed, keep it.
- Deployment target macOS 14.0, Swift 5, no external dependencies.

## Build from CLI (without `xcodebuild` license fuss)

A helper script that mirrors what Xcode does, using the Xcode toolchain directly:

```bash
./build.sh
# produces build/AuraViz.app (arm64, adhoc signed)
```

`build.sh` compiles with:
```
swiftc -sdk $(xcrun --show-sdk-path) \
  -target arm64-apple-macosx14.0 \
  -load-plugin-library .../libSwiftUIMacros.dylib ...
```

## Audio details

- **System audio:** `ScreenCaptureKit` provides 48 kHz stereo PCM from apps playing through the Mac. The channels are mixed to mono for analysis, accumulated into overlapping 4096-sample windows, then transformed into waveform, level, frequency, and spectrum values.
- **Analysis:** Hann window, real FFT, logarithmic 35 Hz–16 kHz bands, decibel compression, sensitivity, and fast-attack/exponential-release smoothing.

## Customization

- Add a theme in `Theme.swift` → `ColorTheme` enum.
- Tweak bar counts: `CircularVisualizerView` 72 bars, `Y2KBarVisualizerView` 32 bars.
- Adjust `barMax`, `sensitivity` scaling, or `TimelineView` cadence (`1/60`).

## Troubleshooting

- **System audio shows 0:** Play audio in another app. If prompted, allow AuraViz in System Settings → Privacy & Security → Screen & System Audio Recording, then press Start again (or relaunch if macOS asks you to).
- **Mic shows 0:** Click “Enable Microphone” and allow it in System Settings → Privacy & Security → Microphone → AuraViz.
- **`actool` / `xcodebuild -runFirstLaunch` fails:** Run Xcode.app once and accept the license via GUI; thereafter CLI builds work.

## License

MIT — do what you want with the gel.
