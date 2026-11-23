#!/usr/bin/env python3
"""Portable checks for the monochrome film-grain finish.

Run with: python3 tests/check_film_grain.py
Needs only Python 3 — no Xcode, no macOS tools — so it runs anywhere.
It pins the contract: the grain lives in the shared stage effects overlay
(so it covers every mode in the preview and the output), sits under the
strobe, dimmer and blackout, is monochrome (gray tiles, overlay/screen
blended), animates at film's 24 fps, and has a persisted strength slider.
It also ports the tile generator to Python and checks its statistics.
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
state = read("AuraViz/PerformanceState.swift")
presets = read("AuraViz/Presets.swift")
content = read("AuraViz/ContentView.swift")
readme = read("README.md")

# Placement: inside StageEffectsOverlay, between the vibe kill and the strobe,
# so it covers every mode and stays under strobe / dimmer / blackout.
effects = stage[stage.find("struct StageEffectsOverlay"):stage.find("private struct AmbientLoop")]
check("overlay struct defined", "struct FilmGrainOverlay" in stage)
check("grain in shared effects overlay", "FilmGrainOverlay(amount: performance.filmGrain)" in effects)
i_vibe, i_grain = effects.find("AmbientLoop("), effects.find("FilmGrainOverlay(")
i_strobe, i_blackout = effects.find("Color.white"), effects.find("performance.isBlackedOut")
check("grain above vibe kill, under strobe and blackout", -1 < i_vibe < i_grain < i_strobe < i_blackout)
check("grain hidden at zero", "performance.filmGrain > 0" in effects)
check("effects overlay still used by preview and output",
      "StageEffectsOverlay()" in content and "StageEffectsOverlay()" in read("AuraViz/OutputWindow.swift"))

# Look: monochrome tiles, blended, animated at 24 fps, with a vignette.
grain = stage[stage.find("struct FilmGrainOverlay"):stage.find("extension CGSize")]
check("monochrome (gray color space)", "CGColorSpaceCreateDeviceGray()" in grain and "DeviceRGB" not in grain)
check("overlay and screen blends", ".blendMode(.overlay)" in grain and ".blendMode(.screen)" in grain)
check("film frame rate", re.search(r"grainFrameRate\s*=\s*24", grain) is not None)
check("tiled fill", ".tiledImage(" in grain)
check("vignette", ".radialGradient(" in grain)
check("no hit testing", ".allowsHitTesting(false)" in grain)

# Setting: persisted, clamped, with a slider.
check("state property", "@Published var filmGrain" in state)
check("persisted", "SettingsKey.filmGrain" in state and 'static let filmGrain = "filmGrain"' in presets)
check("restored clamped", "SettingsKey.filmGrain, in: Self.filmGrainRange" in state)
check("slider in controls", "filmGrainControl" in content and "$performance.filmGrain" in content)
check("README documents it", "**Film grain**" in readme)


# Port of FilmGrainTiles.makeValues; keep in step with the Swift.
MASK = (1 << 64) - 1


def splitmix(state):
    state = (state + 0x9E3779B97F4A7C15) & MASK
    z = state
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
    z ^= z >> 31
    return state, (z >> 11) / float(1 << 53)


def make_values(seed, n=256, clump=3, fine=0.55, contrast=38.0):
    m = n // clump + (0 if n % clump == 0 else 1)
    st = [seed]

    def gaussian():
        s = 0.0
        for _ in range(4):
            st[0], u = splitmix(st[0])
            s += u
        return (s - 2) * math.sqrt(3)

    lattice = [gaussian() for _ in range(m * m)]
    raw = []
    for y in range(n):
        fy = y * m / n
        y0 = int(fy); y1 = (y0 + 1) % m; ty = fy - y0
        for x in range(n):
            fx = x * m / n
            x0 = int(fx); x1 = (x0 + 1) % m; tx = fx - x0
            top = lattice[y0 * m + x0] * (1 - tx) + lattice[y0 * m + x1] * tx
            bot = lattice[y1 * m + x0] * (1 - tx) + lattice[y1 * m + x1] * tx
            raw.append(fine * gaussian() + (1 - fine) * (top * (1 - ty) + bot * ty))
    mean = sum(raw) / len(raw)
    dev = max(math.sqrt(sum((v - mean) ** 2 for v in raw) / len(raw)), 1e-9)
    return [min(255, max(0, round(128 + (v - mean) / dev * contrast))) for v in raw], n


vals, n = make_values(0xF11A6EA1)
mean = sum(vals) / len(vals)
sd = math.sqrt(sum((v - mean) ** 2 for v in vals) / len(vals))
check(f"tile mean near mid-gray ({mean:.1f})", abs(mean - 128) < 1.5)
check(f"tile spread near contrast ({sd:.1f})", 34 < sd < 40)
clipped = sum(1 for v in vals if v in (0, 255)) / len(vals)
check(f"little clipping ({clipped:.4%})", clipped < 0.001)


def corr(pairs):
    a = [p[0] for p in pairs]; b = [p[1] for p in pairs]
    ma, mb = sum(a) / len(a), sum(b) / len(b)
    cov = sum((x - ma) * (y - mb) for x, y in pairs)
    return cov / math.sqrt(sum((x - ma) ** 2 for x in a) * sum((y - mb) ** 2 for y in b))


# Clumped, not flat white noise: neighbors correlate a little.
inner = [(vals[y * n + x], vals[y * n + x + 1]) for y in range(n) for x in range(n - 1)]
c_inner = corr(inner)
check(f"grain clumps (neighbor corr {c_inner:.2f})", 0.1 < c_inner < 0.6)
# Seamless: the wrap seam correlates like any other neighbor pair.
seam = [(vals[y * n + n - 1], vals[y * n]) for y in range(n)]
c_seam = corr(seam)
check(f"tile wraps seamlessly (seam corr {c_seam:.2f})", abs(c_seam - c_inner) < 0.2)

print()
if failures:
    print(f"{len(failures)} check(s) failed")
    sys.exit(1)
print("all film grain checks passed")
