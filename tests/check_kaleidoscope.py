#!/usr/bin/env python3
"""Portable checks for the Kaleidoscope mode replacing Laser.

Run with: python3 tests/check_kaleidoscope.py
Needs only Python 3 — no Xcode, no macOS tools — so it runs anywhere.
It pins the shipped contract: the Laser view/mode is gone, the
Kaleidoscope view exists and is routed, build manifests list the new
file, and the view carries the rhythm/note sync hooks (beat-synced
rotation, bar-synced zoom, strobe-capped flash, drum accents, and
per-wedge spectrum energies with a loudest-band peak).
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


view_rel = "AuraViz/Visualizers/KaleidoscopeVisualizerView.swift"
old_rel = "AuraViz/Visualizers/LaserVisualizerView.swift"
view = read(view_rel)
theme = read("AuraViz/Theme.swift")
stage = read("AuraViz/Visualizers/VisualizerStage.swift")
commands = read("AuraViz/PerformanceCommands.swift")
pbx = read("AuraViz.xcodeproj/project.pbxproj")
build_sh = read("build.sh")
gen = read("generate_project.py")

check("kaleidoscope view file exists", bool(view))
check("laser view file removed", not (ROOT / old_rel).exists())
check("view struct defined", "struct KaleidoscopeVisualizerView" in view)
check("mode case renamed", 'case kaleidoscope = "Kaleidoscope"' in theme)
check("no .laser mode case left", "case laser" not in theme and ".laser" not in theme)
check("stage routes kaleidoscope", ".kaleidoscope" in stage and "KaleidoscopeVisualizerView(" in stage)
check("no LaserVisualizerView routing left", "LaserVisualizerView" not in stage)
check("shortcut sheet names Kaleidoscope", "Kaleidoscope" in commands and "/ Laser" not in commands)

for label, text in [("pbxproj", pbx), ("build.sh", build_sh), ("generate_project.py", gen)]:
    check(f"{label} lists new file", "KaleidoscopeVisualizerView.swift" in text)
    check(f"{label} drops old file", "LaserVisualizerView.swift" not in text)

# Reference-clip geometry: 8 mirrored wedges, expanding rings, center star.
check("eight sectors", "sectors = 8" in view)
check("expanding rings", "ringCount = 3" in view and "pow(progress, 1.35)" in view)
check("trapezoid wedges", "wedgePath" in view)
check("center star", "starPath" in view)
check("additive glow like the clip", ".plusLighter" in view)
check("theme gradient palette kept", "ThemePalette" in view and "palette.sample" in view)

# Rhythm sync: rotation on the beat grid, zoom on the bar grid.
check("rotation beat-synced", "beatPhase(at:" in view and "BeatSyncedPhase" in view)
check("zoom bar-synced (one cycle per bar)", "barPhase(at:" in view)
check("volume-only drift before tempo", "beat.bpm > 0" in view)
check("flash held to strobe cap", "strobeMinimumInterval" in view)

# Note sync: each wedge owns a spectrum slice; loudest band peaks white.
check("per-wedge spectrum energies", "wedgeEnergies" in view and "spectrum.count" in view)
check("loudest-band peak wedge", "peakWedge" in view)

# Drum voices, scaled by beat reactivity like every other mode.
for voice in ["kick", "snare", "hat"]:
    check(f"{voice} accent wired", f"beat.{voice}.pulse" in view)
check("drum reactivity scaled", "drumReactivity.scaled(by: beatReactivity)" in view)

# Persistence: pre-rename stored "Laser" still lands on Kaleidoscope.
check("legacy mapping", 'case "Laser": self = .kaleidoscope' in theme)
check("settings use legacy mapping", "VisualMode.init(storedValue:)" in read("AuraViz/PerformanceState.swift"))
check("presets use legacy mapping", "VisualMode.init(storedValue:)" in read("AuraViz/Presets.swift"))

# Truncation guard: balanced delimiters in the new view.
for open_c, close_c in [("{", "}"), ("(", ")"), ("[", "]")]:
    check(f"balanced {open_c}{close_c}", view.count(open_c) == view.count(close_c))
check("no placeholders", "TODO" not in view and "LaserLight" not in view)

print(f"\n{('ALL CHECKS PASSED' if not failures else 'FAILURES: ' + ', '.join(failures))}")
sys.exit(1 if failures else 0)
