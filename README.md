# AuraViz — Aesthetic Audio Visualizer for macOS

Native macOS SwiftUI app with three aesthetic visualizer modes reacting to **volume** and **frequency**.

<img src="https://via.placeholder.com/900x480/0B0B12/FFFFFF?text=AuraViz+Preview" />

## Features

- **Three visualizers**
  - **Circle** — radial spectrum around a pulsing glass core (60 bars, glow tips, orbit ring)
  - **Waves** — three layered filled sine waves driven by low/mid/high bands + live waveform, with grid and central orb
  - **Y2K Bars** — 32 chrome/gel bars with glass highlight, mirrored reflection, grid, peak caps, chrome ledge & scanlines

- **Audio input**
  - **Synth mode** (default) — controllable **Volume** (0–100%), **Frequency** (20–800 Hz, log-mapped), **Complexity** (harmonic richness). No mic needed, perfect for demo.
  - **Microphone mode** — live mic via `AVAudioEngine`, 1024-point FFT via `Accelerate/vDSP`, 64-band log-spaced spectrum, RMS volume. Permission requested via `AVCaptureDevice`.

- **Controls**
  - Volume / Frequency / Complexity (synth)
  - Sensitivity (0.3–2.2×) + Smoothing (0–92%)
  - Theme: Aurora / Sunset / Ocean / Y2K Chrome / Mono
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
│   ├── AudioEngineManager.swift       # AVAudioEngine + synth + vDSP FFT
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

- **Synth:** Timer at 60 Hz generates 256-point waveform (sine + harmonics + noise) and 64-band spectrum (Gaussian bell centered at log-mapped peakBand + bass boost + shimmer). Smoothing is exponential (`cur*α + target*(1-α)`).
- **Mic:** Tap 1024 frames, Hann window, pack even/odd into `DSPSplitComplex`, `vDSP.FFT<DSPSplitComplex>.forward`, `vDSP_zvabs` → 512 mags → log-grouped into 64 bands, `log1p` compression, sensitivity + smoothing.

## Customization

- Add a theme in `Theme.swift` → `ColorTheme` enum.
- Tweak bar counts: `CircularVisualizerView` 72 bars, `Y2KBarVisualizerView` 32 bars.
- Adjust `barMax`, `sensitivity` scaling, or `TimelineView` cadence (`1/60`).

## Troubleshooting

- **Mic shows 0:** Click “Enable Microphone” and allow in System Settings → Privacy & Security → Microphone → AuraViz. The app falls back to Synth if denied.
- **`actool` / `xcodebuild -runFirstLaunch` fails:** Run Xcode.app once and accept the license via GUI; thereafter CLI builds work.
- **No sound needed:** Use Synth mode — move Frequency 80→320 Hz while Y2K is selected to hear/see the sweep.

## License

MIT — do what you want with the gel.
