#!/usr/bin/env python3
"""Portable checks for the Tunnel mode's reference-clip replacement.

Run with: python3 tests/check_tunnel.py
Needs only Python 3 — no Xcode, no macOS tools — so it runs anywhere.
It pins the shipped contract: the Tunnel mode/file/routing stay, the old
wobbly-ring and sparse-cage looks are gone, and the view carries the
watermarked preview clip's look (a twisted corridor of hexagonal box
layers — inner and outer hexagons, radial struts and rails — built from
steel tubes that show only in the flood, trimmed with cool neon strips and
warm side-wall box outlines, around a glowing core, with a full-stage
lit/dark strobe) plus the rhythm/note sync hooks (beat-synced flight, beat
rings, per-region note energies).
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


view = read("AuraViz/Visualizers/TunnelVisualizerView.swift")
theme = read("AuraViz/Theme.swift")
stage = read("AuraViz/Visualizers/VisualizerStage.swift")
readme = read("README.md")

check("tunnel view file exists", bool(view))
check("view struct defined", "struct TunnelVisualizerView" in view)
check("mode case kept", 'case tunnel = "Tunnel"' in theme)
check("stage routes tunnel", ".tunnel" in stage and "TunnelVisualizerView(" in stage)
for label, rel in [("pbxproj", "AuraViz.xcodeproj/project.pbxproj"), ("build.sh", "build.sh")]:
    check(f"{label} still lists tunnel file", "TunnelVisualizerView.swift" in read(rel))

# The old look (flat wobbling rings) is replaced, not kept alongside.
check("old radial-profile wobble gone", "radialProfile" not in view and "spectrumLevel" not in view)
check("old flight/palette helpers gone", "TunnelFlight" not in view and "TunnelPalette" not in view)

# The previous sparse cage (dashed rings with diagonal braces, faint wash)
# is replaced by the box-truss corridor.
check("sparse-cage braces gone", "diagonal" not in view.lower() and "dashBoundary" not in view)
check("faint wash replaced by flood", "drawWash" not in view and "drawFlood" in view)

# Reference-clip look: a twisted corridor of hexagonal box layers — inner
# and outer hexagons joined by radial struts and longitudinal rails — whose
# steel tubes show only in the flood and whose neon strips glow additively,
# batched by color/level, around a glowing core.
check("hexagon layers", "hexagon" in view and "ringCount" in view)
check("box layers between two hexagon radii", "innerRadius" in view and "outerRadius" in view and "boxDepth" in view)
check("struts and rails", ".strut" in view and ".rail" in view and ".outerRail" in view)
check("corridor twists per layer", "twistPerRing" in view)
check("perspective projection with near clip", "clipDepth" in view and "p.x / p.z" in view)
check("steel tubes lit only by the flood", "steelBody" in view and "steelSheen" in view and "steelLit" in view)
check("steel shades what is behind it", "blendMode = .normal" in view)
check("neon strip buckets", "TunnelBucket" in view)
check("warm side-wall boxes", "BoxTrim" in view and "isWarm" in view and "cos(faceAngle)" in view)
check("full-stage flood", "Path(CGRect(origin: .zero, size: size))" in view)
check("hexagonal core", "drawCore" in view)
check("additive glow", ".plusLighter" in view)
check("cool and warm layers from the theme", "TunnelColors" in view and "ThemePalette" in view and "palette.sample" in view)
check("stable per-layer pattern hash", "static func hash" in view)

# Rhythm sync: flight and roll on the beat grid (volume cruise before a
# tempo), a bright ring per beat, lit/dark strobe held to the strobe cap.
check("flight beat-synced", "ringsPerBeat" in view and "beatPhase(at:" in view and "BeatSyncedPhase" in view)
check("roll beat-synced", "rollPerBeat" in view)
check("volume-only motion before tempo", "beat.bpm > 0" in view)
check("beat rings launched", "beatRings" in view and "beat.beatCount" in view)
check("lit/dark strobe held to strobe cap", "strobeMinimumInterval" in view and "litHold" in view)

# Note sync: warm bars light by pitch region; loudest band peaks.
check("per-region note energies", "noteBins" in view and "spectrum.count" in view)
check("bars read their pitch region", "frame.note(at:" in view)
check("loudest-band peak", "peakNote" in view)

for voice in ["kick", "snare", "hat"]:
    check(f"{voice} accent wired", f"beat.{voice}.pulse" in view)
check("drum reactivity scaled", "drumReactivity.scaled(by: beatReactivity)" in view)

# README describes the new look and its sync.
tunnel_line = next((ln for ln in readme.splitlines() if "**Tunnel**" in ln), "")
check("README names the box-corridor look", "box" in tunnel_line and "watermarked preview clip" in tunnel_line)
check("README drops the wobble description", "outlines wobbling" not in readme)

# Truncation guard: balanced delimiters in the new view.
for open_c, close_c in [("{", "}"), ("(", ")"), ("[", "]")]:
    check(f"balanced {open_c}{close_c}", view.count(open_c) == view.count(close_c))
check("no placeholders", "TODO" not in view and "FIXME" not in view)

print(f"\n{('ALL CHECKS PASSED' if not failures else 'FAILURES: ' + ', '.join(failures))}")
sys.exit(1 if failures else 0)
