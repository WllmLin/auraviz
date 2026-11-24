#!/usr/bin/env python3
"""Portable checks for the slow drift camera over the stage background.

Run with: python3 tests/check_drift_camera.py
Needs only Python 3 — no Xcode, no macOS tools — so it runs anywhere.
It pins the contract: the camera frames the background only (the orbs and
Beat mode's picture, not the visualizers, lyrics or images), sits inside
Beat mode's shake, runs on a shared clock that pauses with the audio, and
its pose math (ported below from DriftCamera) breathes slowly, stays in its
zoom range and never shifts past the room the zoom makes.
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


stage = read("AuraViz/Visualizers/VisualizerStage.swift")
beat = read("AuraViz/Visualizers/BeatVisualizerView.swift")
readme = read("README.md")

camera_src = stage[stage.find("enum DriftCamera"):stage.find("private final class DriftClock")]
clock_src = stage[stage.find("private final class DriftClock"):stage.find("extension View {")]
orbs = stage[stage.find("struct StageOrbs"):stage.find("private final class OrbDrift")]
visualizer_stage = stage[stage.find("struct VisualizerStage"):stage.find("struct StageOrbs")]

# Structure.
check("pose and camera defined", "struct DriftPose" in stage and "enum DriftCamera" in stage)
check("shared clock", "private static let clock = DriftClock()" in camera_src)
check("clock pauses with audio", "guard isActive, let lastTime" in clock_src)
check("clock clamps resume jumps", "min(0.1, max(0, now - lastTime))" in clock_src)
check("clock never rewinds", "max(lastTime, now)" in clock_src)
check("view modifier defined", "func driftCamera(_ pose: DriftPose)" in stage)

# Orbs: drawn through the camera inside their canvas, on their own pause.
check("orbs use the camera", "DriftCamera.pose(at: now, isActive: isActive)" in orbs)
i_scale, i_draw = orbs.find("context.scaleBy(x: camera.scale"), orbs.find("draw(in: context")
check("orbs transformed before drawing", -1 < i_scale < i_draw)

# Beat: the drift sits inside the shake, so the cover zoom still hides edges.
check("beat uses the camera", "DriftCamera.pose(at: now, isActive: isActive)" in beat)
m = re.search(r"picture\(size: size, backdrop: backdrop\)\s*\.driftCamera\(camera\)\s*\.scaleEffect\(look\.coverScale", beat)
check("beat drift inside the shake", m is not None)

# Foreground stays put.
check("visualizers, lyrics and images not drifted", "driftCamera" not in visualizer_stage)
check("README documents it", "**Drift camera**" in readme)


# Port of DriftCamera.pose(time:); keep in step with the Swift.
def constant(name):
    m = re.search(rf"static let {name} = ([0-9.]+)", camera_src)
    return float(m.group(1)) if m else float("nan")


def terms(name):
    m = re.search(rf"static let {name} = \[(.*?)\]\n", camera_src)
    if not m:
        return []
    return [tuple(float(v) for v in t) for t in
            re.findall(r"weight: ([0-9.]+), period: ([0-9.]+), phase: ([0-9.]+)", m.group(1))]


BASE, SWING, REACH = constant("baseZoom"), constant("zoomSwing"), constant("reach")
ZOOM, XS, YS = terms("zoomTerms"), terms("xTerms"), terms("yTerms")
check("constants parsed", all(math.isfinite(v) for v in (BASE, SWING, REACH)) and ZOOM and XS and YS)


def wave(ts, t):
    return sum(w * math.sin(2 * math.pi * t / p + ph) for w, p, ph in ts)


def pose(t):
    scale = 1 + BASE + SWING * wave(ZOOM, t)
    margin = REACH * (scale - 1) / 2
    return scale, margin * wave(XS, t), margin * wave(YS, t)


for name, ts in (("zoom", ZOOM), ("x", XS), ("y", YS)):
    check(f"{name} weights sum to 1 (stays within ±1)", abs(sum(w for w, _, _ in ts) - 1) < 1e-9)
periods = [p for ts in (ZOOM, XS, YS) for _, p, _ in ts]
check(f"slow periods ({min(periods):.0f}–{max(periods):.0f} s)", min(periods) >= 15 and max(periods) <= 120)
check("periods all distinct", len(set(periods)) == len(periods))

# Sample an hour at 30 fps.
dt = 1 / 30
samples = [pose(i * dt) for i in range(int(3600 / dt))]
scales = [s for s, _, _ in samples]
check(f"zoom range {min(scales):.4f}–{max(scales):.4f} stays zoomed in and gentle",
      min(scales) >= 1.0 + 1e-6 and max(scales) <= 1.1)
check(f"zoom actually breathes (swing {max(scales) - min(scales):.4f})", max(scales) - min(scales) > 0.03)

# Coverage: zoomed about the center by s and shifted by (dx, dy) of the stage,
# the background covers the stage iff |dx|, |dy| <= (s - 1) / 2.
worst = max(max(abs(dx), abs(dy)) / ((s - 1) / 2) for s, dx, dy in samples)
check(f"never shifts past the zoom's margin (worst {worst:.3f} of it)", worst <= REACH + 1e-9 and worst < 1)
xs = [dx for _, dx, _ in samples]
ys = [dy for _, _, dy in samples]
check(f"frame actually wanders (x {min(xs):+.4f}…{max(xs):+.4f}, y {min(ys):+.4f}…{max(ys):+.4f})",
      max(xs) - min(xs) > 0.02 and max(ys) - min(ys) > 0.02)

# Slow: on a 1920×1080 stage, the frame moves only a few pixels a second.
speed = max(math.hypot((b[1] - a[1]) * 1920, (b[2] - a[2]) * 1080) / dt for a, b in zip(samples, samples[1:]))
zoom_rate = max(abs(b[0] - a[0]) / dt for a, b in zip(samples, samples[1:]))
check(f"slow wander (peak {speed:.1f} px/s at 1080p)", speed < 25)
check(f"slow breath (peak {zoom_rate * 100:.2f} %/s zoom)", zoom_rate < 0.01)

# Doesn't loop within a set: after a minute it's somewhere new.
check("doesn't repeat after a minute", max(abs(a - b) for a, b in zip(pose(0), pose(60))) > 1e-3)

print()
if failures:
    print(f"{len(failures)} check(s) failed")
    sys.exit(1)
print("all drift camera checks passed")
