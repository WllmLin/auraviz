#!/usr/bin/env python3
"""Portable checks for the Beat mode replacing Neon.

Run with: python3 tests/check_beat.py
Needs only Python 3 — no Xcode, no macOS tools — so it runs anywhere.
It pins the shipped contract: the Neon view/mode is gone, the Beat view
exists and is routed with the chosen background image, build manifests list
the new file, stored "Neon" and "Particles" values still load, the
background is stored and pickable, and the view shakes the image and floods
it with a theme color on beats held to the strobe cap. It also replays the
shake math in Python to check the cover zoom always hides the stage edges.
"""
import math
import pathlib
import re
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


view = read("AuraViz/Visualizers/BeatVisualizerView.swift")
theme = read("AuraViz/Theme.swift")
stage = read("AuraViz/Visualizers/VisualizerStage.swift")
commands = read("AuraViz/PerformanceCommands.swift")
presets = read("AuraViz/Presets.swift")
settings = read("AuraViz/PerformanceState.swift")
store = read("AuraViz/ImageOverlays.swift")
content = read("AuraViz/ContentView.swift")
readme = read("README.md")

# The mode swap.
check("beat view file exists", bool(view))
check("neon view file removed", not (ROOT / "AuraViz/Visualizers/NeonVisualizerView.swift").exists())
check("view struct defined", "struct BeatVisualizerView" in view)
check("mode case renamed", 'case beat = "Beat"' in theme)
check("no .neon mode left", "case neon" not in theme and ".neon" not in theme)
check("no NeonVisualizerView anywhere in sources",
      not any("NeonVisualizerView" in p.read_text(errors="ignore") for p in (ROOT / "AuraViz").rglob("*.swift")))
check("no .neon anywhere in sources",
      not any(re.search(r"\.neon\b", p.read_text(errors="ignore")) for p in (ROOT / "AuraViz").rglob("*.swift")))
check("shortcut sheet names Beat", "/ Beat /" in commands and "Neon" not in commands)
check("built-in preset moved to beat", "mode: .beat" in presets and "Neon Cage" not in presets)
check("README drops Neon", "**Neon**" not in readme and "**Beat**" in readme)

for label, rel in [("pbxproj", "AuraViz.xcodeproj/project.pbxproj"), ("build.sh", "build.sh"), ("generate_project.py", "generate_project.py")]:
    text = read(rel)
    check(f"{label} lists new file", "BeatVisualizerView.swift" in text)
    check(f"{label} drops old file", "NeonVisualizerView.swift" not in text)
check("pbxproj lists the file in all four places", read("AuraViz.xcodeproj/project.pbxproj").count("BeatVisualizerView.swift") == 6)

# Persistence: retired raw values still land on their replacements.
check("legacy Neon and Particles mapping", 'case "Particles", "Neon": self = .beat' in theme)
check("legacy Laser mapping kept", 'case "Laser": self = .kaleidoscope' in theme)
check("settings use legacy mapping", "VisualMode.init(storedValue:)" in settings)
check("presets use legacy mapping", "VisualMode.init(storedValue:)" in presets)

# The background image: routed, stored, pickable.
check("stage routes beat with the image", "case .beat:" in stage and "BeatVisualizerView(image: beatBackground" in stage)
check("performance stage passes the stored image", "beatBackground: imageOverlays.beatBackgroundImage" in stage)
check("orbs skipped behind the picture", "if mode != .beat" in stage)
check("settings key for the background", 'static let beatBackground = "beatBackground"' in presets)
for fn in ["func chooseBeatBackground()", "func setBeatBackground(_ url: URL)", "func clearBeatBackground()", "private func loadBeatBackground()"]:
    check(f"store has {fn}", fn in store)
check("background decoded off the main thread", "Self.importImage(at: url, into: directory)" in store)
check("controls show the picker in Beat mode", "beatBackgroundControl" in content and "chooseBeatBackground()" in content)
check("drop sets the background in Beat mode", "imageOverlays.setBeatBackground(file)" in content)
check("menu command to pick the background", "chooseBeatBackground()" in commands)

# The look: image fills, shakes and turns a theme color on beats.
check("image fills the stage", ".aspectRatio(contentMode: .fill)" in view)
check("theme colors drive the flood", "theme.colors(brighterThan:" in view and ".blendMode(.color)" in view)
check("tint stays inside the stage", ".compositingGroup()" in view and ".clipped()" in view)
check("shake moves, twists and zooms", ".offset(" in view and ".rotationEffect(" in view and ".scaleEffect(look.coverScale" in view)
check("hits held to the strobe cap", "PerformanceState.strobeMinimumInterval" in view)
check("hits tracked by beat count", "beat.beatCount != lastBeatCount" in view)
check("each hit picks the next color", "index: hit.index &+ 1" in view and "colors[look.colorIndex % colors.count]" in view)
check("still at rest while stopped", "guard isActive else { return }" in view)
check("NaN guard for infinite age", "beatShake > 1e-4" in view and "kickShake > 1e-4" in view)
for voice in ["kick", "snare", "hat"]:
    check(f"{voice} accent wired", f"beat.{voice}.pulse" in view)
check("drum reactivity scaled", "drumReactivity.scaled(by: beatReactivity)" in view)
check("drum defaults for beat", "case .beat: return DrumReactivity(" in theme)

# Replays BeatLook's shake and cover zoom: at any moment the shifted,
# twisted, zoomed image must still cover every stage corner.
MAX_SHAKE, MAX_ROT, MAX_PUNCH = 0.035, 0.017, 0.04
check("constants match the view", f"maximumShake = {MAX_SHAKE}" in view and f"maximumRotation = {MAX_ROT}" in view and f"maximumPunch = {MAX_PUNCH}" in view)


def h(seed, salt):
    m = (1 << 64) - 1
    x = ((seed * 0x9E3779B97F4A7C15) & m) ^ ((salt * 0xBF58476D1CE4E5B9) & m)
    x ^= x >> 31
    x = (x * 0x94D049BB133111EB) & m
    x ^= x >> 29
    return (x >> 11) / float(1 << 53)


def shake(age, seed):
    angle, px, py, pt = (2 * math.pi * h(seed, s) for s in (1, 2, 3, 4))
    jolt = math.cos(2 * math.pi * 11 * age)
    return (math.cos(angle) * jolt + 0.35 * math.sin(2 * math.pi * 17 * age + px),
            math.sin(angle) * jolt + 0.35 * math.sin(2 * math.pi * 13 * age + py),
            math.sin(2 * math.pi * 7 * age + pt))


def covers(w, h_, beat_amp, kick_amp, hat_amp, a, k, jx, jy):
    short = min(w, h_)
    dx = MAX_SHAKE * (beat_amp * a[0] + kick_amp * k[0] + 0.15 * hat_amp * jx) * short
    dy = MAX_SHAKE * (beat_amp * a[1] + kick_amp * k[1] + 0.15 * hat_amp * jy) * short
    rot = MAX_ROT * (beat_amp * a[2] + kick_amp * k[2])
    bound = beat_amp + kick_amp + 0.15 * hat_amp
    punch = MAX_PUNCH * (beat_amp + 0.5 * kick_amp)
    s = 1 + math.sin(MAX_ROT * bound) * max(w, h_) / short + 2 * MAX_SHAKE * 1.35 * bound + punch
    # The image's rect at rest is exactly the stage (aspect fill can only be
    # larger), so check each stage corner lands inside the transformed rect.
    for cx, cy in [(-w / 2, -h_ / 2), (w / 2, -h_ / 2), (-w / 2, h_ / 2), (w / 2, h_ / 2)]:
        x, y = cx - dx, cy - dy
        c, sn = math.cos(-rot), math.sin(-rot)
        x, y = x * c - y * sn, x * sn + y * c
        if abs(x) > s * w / 2 + 1e-9 or abs(y) > s * h_ / 2 + 1e-9:
            return False
    return True


ok = True
for w, h_ in [(1920, 1080), (1080, 1920), (500, 500), (3440, 1440)]:
    for seed in range(40):
        for step in range(60):
            age = step / 120
            for beat_amp, kick_amp, hat_amp in [(1, 0, 0), (1, 0.6, 1), (0.3, 0.6, 0), (0, 0.6, 1), (0, 0, 1)]:
                a = shake(age, seed)
                k = shake(age * 1.3, seed + 7919)
                jx, jy = 2 * h(seed, 9) - 1, 2 * h(seed, 10) - 1
                if not covers(w, h_, beat_amp, kick_amp, hat_amp, a, k, jx, jy):
                    ok = False
check("cover zoom hides the stage edges through every shake", ok)

# Truncation guard: balanced delimiters in the new view.
for open_c, close_c in [("{", "}"), ("(", ")"), ("[", "]")]:
    check(f"balanced {open_c}{close_c}", view.count(open_c) == view.count(close_c))
check("no placeholders", "TODO" not in view and "FIXME" not in view)

print(f"\n{('ALL CHECKS PASSED' if not failures else 'FAILURES: ' + ', '.join(failures))}")
sys.exit(1 if failures else 0)
