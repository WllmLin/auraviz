#!/usr/bin/env python3
"""Portable checks for the Neon mode replacing Particles.

Run with: python3 tests/check_neon.py
Needs only Python 3 — no Xcode, no macOS tools — so it runs anywhere.
It pins the shipped contract: the Particles view/mode is gone, the Neon
view exists and is routed, build manifests list the new file, stored
"Particles" values still load, and the view carries the clip's look
(tumbling broken-bar frames, hexagonal core, lit/dark strobe) and the
rhythm/note sync hooks.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
failures = []


def check(label, ok):
    print(("PASS" if ok else "FAIL"), label)
    if not ok:
        failures.append(label)


def read(rel):
    p = ROOT / rel
    return p.read_text(errors="ignore") if p.exists() else ""


view = read("AuraViz/Visualizers/NeonVisualizerView.swift")
theme = read("AuraViz/Theme.swift")
stage = read("AuraViz/Visualizers/VisualizerStage.swift")
commands = read("AuraViz/PerformanceCommands.swift")
presets = read("AuraViz/Presets.swift")
settings = read("AuraViz/PerformanceState.swift")
readme = read("README.md")

check("neon view file exists", bool(view))
check("particle view file removed", not (ROOT / "AuraViz/Visualizers/ParticleVisualizerView.swift").exists())
check("view struct defined", "struct NeonVisualizerView" in view)
check("mode case renamed", 'case neon = "Neon"' in theme)
check("no .particles mode left", "case particles" not in theme and ".particles" not in theme)
check("stage routes neon", ".neon" in stage and "NeonVisualizerView(" in stage)
check("no ParticleVisualizerView anywhere in sources",
      not any("ParticleVisualizerView" in p.read_text(errors="ignore") for p in (ROOT / "AuraViz").rglob("*.swift")))
check("shortcut sheet names Neon", "/ Neon /" in commands and "Particles" not in commands)
check("built-in preset moved to neon", "mode: .neon" in presets and ".particles" not in presets)
check("README drops Particles", "Particles" not in readme and "**Neon**" in readme)

for label, rel in [("pbxproj", "AuraViz.xcodeproj/project.pbxproj"), ("build.sh", "build.sh"), ("generate_project.py", "generate_project.py")]:
    text = read(rel)
    check(f"{label} lists new file", "NeonVisualizerView.swift" in text)
    check(f"{label} drops old file", "ParticleVisualizerView.swift" not in text)
check("pbxproj lists the file in all four places", read("AuraViz.xcodeproj/project.pbxproj").count("NeonVisualizerView.swift") == 6)

# Persistence: retired raw values still land on their replacements.
check("legacy Particles mapping", 'case "Particles": self = .neon' in theme)
check("legacy Laser mapping kept", 'case "Laser": self = .kaleidoscope' in theme)
check("settings use legacy mapping", "VisualMode.init(storedValue:)" in settings)
check("presets use legacy mapping", "VisualMode.init(storedValue:)" in presets)

# Reference-clip look: tumbling hexagon/rectangle frames of broken bars,
# a hexagonal core and additive neon glow in two color layers.
check("hexagon and rectangle frames", "hexagon" in view and "square" in view and "sides == 6" in view)
check("frames tumble on two axes", "tiltX" in view and "tiltY" in view and "tumble" in view)
check("edges broken into dashes", "dashCount" in view and "dashBoundary" in view)
check("perspective projection with near clip", "clipDepth" in view and "/ p0.z" in view)
check("hexagonal core", "drawCore" in view)
check("additive glow", ".plusLighter" in view)
check("cool and warm layers from the theme", "NeonColors" in view and "ThemePalette" in view and "palette.sample" in view)

# Rhythm sync: flight and roll on the beat grid, lit/dark strobe capped.
check("flight beat-synced", "framesPerBeat" in view and "beatPhase(at:" in view and "BeatSyncedPhase" in view)
check("roll beat-synced", "rollPerBeat" in view)
check("volume-only motion before tempo", "beat.bpm > 0" in view)
check("lit/dark strobe held to strobe cap", "strobeMinimumInterval" in view and "litHold" in view)

# Note sync: warm bars light by pitch region; loudest band peaks.
check("per-region note energies", "noteBins" in view and "spectrum.count" in view)
check("bars read their pitch region", "frame.note(at:" in view)
check("loudest-band peak", "peakNote" in view)

for voice in ["kick", "snare", "hat"]:
    check(f"{voice} accent wired", f"beat.{voice}.pulse" in view)
check("drum reactivity scaled", "drumReactivity.scaled(by: beatReactivity)" in view)

# Truncation guard: balanced delimiters in the new view.
for open_c, close_c in [("{", "}"), ("(", ")"), ("[", "]")]:
    check(f"balanced {open_c}{close_c}", view.count(open_c) == view.count(close_c))
check("no placeholders", "TODO" not in view and "FIXME" not in view)

print(f"\n{('ALL CHECKS PASSED' if not failures else 'FAILURES: ' + ', '.join(failures))}")
sys.exit(1 if failures else 0)
