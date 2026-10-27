# AuraViz — Aesthetic Audio Visualizer for macOS

Native macOS SwiftUI app with six aesthetic visualizer modes reacting to **volume** and **frequency**.

<img src="https://via.placeholder.com/900x480/0B0B12/FFFFFF?text=AuraViz+Preview" />

## Features

- **Six visualizers**
  - **Circle** — radial spectrum around a neon LED-tunnel core: BPM-synced tunnel rings, spectrum dot meter, segmented LED ring and a neon rim that flares with a shockwave on every kick
  - **Waves** — three layered filled sine waves driven by low/mid/high bands + live waveform, with grid and central orb
  - **Bars** — 32 chrome/gel bars with glass highlight, mirrored reflection, grid, peak caps, chrome ledge & scanlines
  - **Tunnel** — pseudo-3D flight through hexagonal rings in the theme's colors: one ring per beat once a tempo is detected (volume sets the speed until then), outlines wobbling with the spectrum, corner rails spiraling to a drifting vanishing point, and a white-hot ring launched down the tunnel on every kick
  - **Particles** — beat-driven spark fountain from the center: each beat fires a burst sized by how hard it hit, sparks drift outward with drag in theme colors and fade out, high-frequency energy adds jitter and twinkle
  - **Laser** — club laser wall: beam fans from emitters along the top edge and the bottom corners sweep across the whole stage, hitting an edge on every beat (one full swing per two beats), brightening with the kick and the low band, drawn additively in the theme's gradient; kick flashes keep to the 3-per-second strobe cap

- **Lyrics overlay** — type lyrics, a track title or a shout-out into the **Lyrics** field under the sliders and toggle **Lyrics** (or press **L**) to lay it over any mode as big kinetic type, wrapped to fill the middle of the preview and output. Each character swells and thickens (regular → black weight) with the RMS volume on a wave that sweeps through the text (once per bar at full beat reactivity), every kick ripples out from the middle and punches the characters up, and the type runs along the theme's gradient with a kick-driven glow. Kick punches keep to the strobe cap; blackout and strobe cover it like the rest of the stage. Return, Esc or a click on the stage finishes editing; the single-key shortcuts are off while you type.

- **Audio input**
  - **System Audio mode** (default) — real-time audio from music, video, browsers, and other apps via `ScreenCaptureKit`. AuraViz excludes its own process audio and captures only a minimal 2×2 video stream to keep overhead low.
  - **Microphone mode** — optional live mic via `AVAudioEngine`.
  - Both live inputs use a 4096-point FFT via `Accelerate/vDSP`, a 64-band log-spaced spectrum, RMS volume, waveform samples, and dominant-frequency detection.

- **Drum detection** — besides the tempo-tracked beat, every hit is classified into three voices by where its energy lands: **kick** (40–150 Hz low thump), **snare** (250 Hz–5 kHz mid crack) and **hat** (6–16 kHz high sizzle). Each voice's detector tracks the rise in power across its FFT bins relative to the program level, so it works for quiet and loud sources and ignores the Sensitivity trim and auto gain. Snares and hats must also lift most of their bins at once, the way noise does, which sets them apart from sung or played notes. Leakage between neighbors (a kick's beater click in the snare band, a snare's wires in the hat band) is masked while the neighbor is hitting. Visualizers read `beat.kick` / `beat.snare` / `beat.hat` (hit count, last hit time, strength, activity envelope, `pulse(at:)`), alongside the unchanged beat API.
  - Each visualizer answers the drums its own way, on top of its beat effects: **Circle** kick shockwave, snare rim flare, hat LED twinkle · **Waves** kick lifts the low layer, snare jolts the mid layer, hats shimmer the high layer · **Bars** kick bounce, snare gloss (held to the strobe cap), hat cap glints · **Tunnel** kick breath, snare-lit rails, hat corner sparks · **Particles** kick core swell, snare spark ring, hat glints · **Laser** kick aperture punch, snare fan opening, hat beam shimmer

- **Controls**
  - Auto Gain (on by default; **AGC** badge in the HUD) + Sensitivity (0.3–2.2×, a trim on top of Auto Gain while it is on) + Smoothing (0–92%) + Beat reactivity (0–100%, 0 = volume-only)
  - **Kick / Snare / Hat** reactivity (0–100% each) for the current visualizer, set separately for every mode and scaled by Beat reactivity; a dot beside each flashes on every detected hit
  - Theme: Aurora / Sunset / Ocean / Y2K Chrome / Stockholm / Tokyo Night / Cyberpunk / Chrome
  - Segmented mode switch, live volume & Hz HUD, play/pause
  - **Open Output** — opens the separate "AuraViz Output" window (visualizer only, on black) in native full screen on the display picked from its arrow menu; Esc in the output leaves full screen and the cursor hides over it after 2 s idle. Mode, theme and Circle FPS stay in sync with the control window's preview.
  - Mode, theme, Circle FPS, input, Auto Gain, Sensitivity, Smoothing, Beat reactivity, every mode's drum reactivity and the lyrics text and overlay toggle are remembered across launches.

- **Presets** (header **Presets** button and the **Presets** menu)
  - Built-in: **Chill** (Waves, Ocean, high smoothing) · **Peak Time** (Circle, Cyberpunk, low smoothing, 60 FPS) · **Retro** (Bars, Y2K Chrome)
  - **Save Current…** stores mode, theme, Circle FPS, Sensitivity, Auto Gain, Smoothing, Beat reactivity and the mode's drum reactivity under a name (an existing name is replaced); **Delete** removes your own presets. Saved as JSON in `~/Library/Application Support/com.auraviz.app/Presets.json`.
  - Recalling a preset crossfades the preview and output to the new look over 0.5 s; the input source is left alone.

- **Performance shortcuts** (app-wide, so they work from either window; listed in the **Performance** menu and in the **?** cheat sheet, ⌘/)
  - **1 / 2 / 3 / 4 / 5 / 6** visual mode · **T / ⇧T** next / previous theme · **L** lyrics overlay on / off
  - **Space** blackout: fades the preview and output to black over 300 ms while audio keeps running (a **BLACKOUT** badge shows in the HUD)
  - **S** (hold) white strobe over the stage, rate-limited to at most 3 flashes per second (photosensitivity limit), even when tapped quickly
  - **F** toggle the output window's full screen (opens it if closed) · **B** tap tempo · **R** reset sensitivity, smoothing, beat reactivity and every mode's drum reactivity · **H** show/hide controls

- **Aesthetic**
  - Dark mesh background with blurred aurora orbs, glassmorphism cards, rounded 22pt containers, ultraThinMaterial, neon gradients, glow + shadow.

## Project

```
AuraViz/
├── AuraViz.xcodeproj/project.pbxproj  # Xcode 14+ / macOS 14+ target
├── AuraViz/
│   ├── AuraVizApp.swift               # @main App, control WindowGroup + output Window
│   ├── ContentView.swift              # Header, preview card, controls
│   ├── PerformanceState.swift         # Shared mode / theme / FPS, blackout, rate-limited strobe, crossfade
│   ├── PerformanceCommands.swift      # Performance menu shortcuts + cheat-sheet overlay
│   ├── Presets.swift                  # Preset model, built-ins, JSON store, Presets menu; settings keys
│   ├── OutputWindow.swift             # Output window view, display placement, Esc, cursor hiding
│   ├── Theme.swift                    # VisualMode, ColorTheme, glass modifiers
│   ├── AudioEngineManager.swift       # ScreenCaptureKit + AVAudioEngine + vDSP FFT
│   ├── BeatTracker.swift              # Kick onsets, spectral flux, BPM, beat phase, tap tempo; kick/snare/hat detection
│   ├── Visualizers/
│   │   ├── VisualizerStage.swift      # Mode switch → current visualizer; crossfading stage; scale factor
│   │   ├── CircularVisualizerView.swift
│   │   ├── WaveVisualizerView.swift
│   │   ├── Y2KBarVisualizerView.swift
│   │   ├── TunnelVisualizerView.swift
│   │   ├── ParticleVisualizerView.swift
│   │   ├── LaserVisualizerView.swift
│   │   └── LyricsOverlayView.swift    # Kinetic-type lyrics laid over every mode
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
  -O -whole-module-optimization \
  -target arm64-apple-macosx14.0 \
  -load-plugin-library .../libSwiftUIMacros.dylib ...
```

## Audio details

- **System audio:** `ScreenCaptureKit` provides 48 kHz stereo PCM from apps playing through the Mac. The channels are mixed to mono for analysis, accumulated into overlapping 4096-sample windows, then transformed into waveform, level, frequency, and spectrum values.
- **Auto gain:** a peak-biased follower (≈0.15 s rise, ≈9 s fall) tracks the RMS level and the band energy and normalizes volume, waveform and spectrum against them (up to +30 dB boost / −18 dB cut), so quiet laptop sources and loud club feeds fill the same visual range. Below a −60 dBFS noise floor, or 40 dB under the tracked peak, the gain fades back to 0 dB and the reference holds, so silence and hiss stay dark and the next track starts at the previous level. With Auto Gain off the analysis is unchanged.
- **Analysis:** Hann window, real FFT, logarithmic 35 Hz–16 kHz bands, decibel compression, sensitivity, and fast-attack/exponential-release smoothing. System audio uses 50% overlap (about 23 updates/second at 48 kHz), while fixed ring/work buffers avoid allocations and array shifts in the hot path.

## Performance

- Circle can switch between 30 and 60 FPS, Waves animate at 30 FPS and Tunnel, Particles and Laser at 60 FPS; all five stop scheduling frames when paused.
- Bars redraw only when new audio data arrives; there is no independent animation timer.
- Frequency-band boundaries are cached per sample rate, FFT storage is reused, and each analysis publishes one combined SwiftUI update.
- The standalone packaging script uses whole-module optimization for its production binary.

## Customization

- Add a theme in `Theme.swift` → `ColorTheme` enum.
- Tweak bar counts: `CircularVisualizerView` 72 bars, `Y2KBarVisualizerView` 32 bars.
- Adjust `barMax`, `sensitivity` scaling, or the Circle FPS toggle in `ContentView.swift`.

## Troubleshooting

- **System audio shows 0:** Play audio in another app. If prompted, allow AuraViz in System Settings → Privacy & Security → Screen & System Audio Recording, then press Start again (or relaunch if macOS asks you to).
- **Mic shows 0:** Click “Enable Microphone” and allow it in System Settings → Privacy & Security → Microphone → AuraViz.
- **`actool` / `xcodebuild -runFirstLaunch` fails:** Run Xcode.app once and accept the license via GUI; thereafter CLI builds work.

## License

MIT — do what you want with the gel.
