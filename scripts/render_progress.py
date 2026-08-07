#!/usr/bin/env python3
"""Render ``reports/phase-status.json`` as a whole-project dashboard.

Invoked by ``scripts/progress.sh``. Kept as its own file rather than a heredoc
so it can be linted, and so the escape-sequence padding below is readable.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

def _configured_languages(default):
    """Only render columns for languages this project actually uses.

    A one-language project should not stare at four permanently-empty columns.
    Source of truth is COMPOSE_PROFILES in .env (scripts/use-languages.sh).
    """
    import os
    env = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
    try:
        with open(env) as fh:
            for line in fh:
                if line.startswith("COMPOSE_PROFILES="):
                    chosen = {p.strip() for p in line.split("=", 1)[1].strip().split(",")}
                    langs = [l for l in default if l in chosen]
                    if langs:
                        return langs
    except OSError:
        pass
    return list(default)


PHASE_TITLES = {
    "phase0": "Scaffold",
    "phase1": "Core API",
    "phase2": "Observability",
    "phase3": "Database Depth",
    "phase4": "Caching & Rate Limiting",
    "phase5": "Resilience",
    "phase6": "Events & the Outbox",
    "phase7": "Security Hardening",
    "phase8": "Load Testing & Profiling",
    "phase9": "Real-Time at Scale",
    "phase10": "Object Storage",
    "phase11": "Synthesis",
}
#: Phases gated on tooling output rather than assertions — "is this profile
#: good?" and "is this write-up honest?" are not booleans. They will never have
#: a row in phase-status.json, so "not measured" would read as an omission.
#: Kept in step with phase_without_tests() in scripts/check-phase.sh.
NO_TEST_PHASES = {"phase8": "no tests — make bench / soak / profile",
                  "phase11": "no tests — the write-up is the gate"}

ALL_IMPLS = ["go", "rust", "python", "csharp", "typescript"]
IMPLS = _configured_languages(ALL_IMPLS)
COLUMN = 12
LABEL = 32

# Colour wraps the two-character glyph only, and padding is computed from the
# *plain* text — otherwise the escape sequences count toward the column width
# and every row drifts a little further right than the one above it.
GLYPH = {
    "pass": ("██", "32"),
    "fail": ("▒▒", "31"),
    "not_implemented": ("░░", "33"),
    "unreachable": ("··", "90"),
    "skipped": ("··", "90"),
    "empty": ("  ", "0"),
}


def cell(text: str, glyph: str = "", colour: str = "0") -> str:
    plain = f"{glyph} {text}" if glyph else text
    padding = " " * max(1, COLUMN - len(plain))
    body = f"\033[{colour}m{glyph}\033[0m {text}" if glyph else text
    return body + padding


def main(path: str) -> int:
    status = json.loads(Path(path).read_text())
    phases = status.get("phases", {})

    print()
    print(f"  TaskFlow progress · generated {status.get('generatedAt', 'unknown')}")
    print()
    print("  " + "phase".ljust(LABEL) + "".join(i[:10].ljust(COLUMN) for i in IMPLS))
    print("  " + "─" * (LABEL + COLUMN * len(IMPLS)))

    for marker, title in PHASE_TITLES.items():
        payload = phases.get(marker)
        label = f"{marker.removeprefix('phase'):>2}. {title}"
        if marker in NO_TEST_PHASES:
            print("  " + label.ljust(LABEL) + "".join(cell("·") for _ in IMPLS)
                  + NO_TEST_PHASES[marker])
            continue
        if not payload:
            print("  " + label.ljust(LABEL) + "".join(cell("—") for _ in IMPLS) + "not measured")
            continue
        cells = []
        for impl in IMPLS:
            stats = payload.get("implementations", {}).get(impl)
            if not stats:
                cells.append(cell("—"))
                continue
            glyph, colour = GLYPH.get(stats.get("verdict", "empty"), ("  ", "0"))
            denominator = stats.get("considered", stats.get("total", 0))
            cells.append(cell(f"{stats.get('passed', 0)}/{denominator}", glyph, colour))
        print("  " + label.ljust(LABEL) + "".join(cells))

    print()
    complete = status.get("summary", {}).get("phasesPassed", {})
    if complete:
        print("  phases passing")
        for impl in IMPLS:
            numbers = sorted(
                int(p.removeprefix("phase")) for p in complete.get(impl, []) if p.startswith("phase")
            )
            listing = ", ".join(str(n) for n in numbers) if numbers else "none yet"
            print(f"    {impl:<12} {len(numbers):>2}  ({listing})")
        print()

    legend = "   ".join(
        f"\033[{colour}m{glyph}\033[0m {name.replace('_', ' ')}"
        for name, (glyph, colour) in GLYPH.items()
        if name not in ("skipped", "empty")
    )
    print("  " + legend)
    print()
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: render_progress.py <phase-status.json>", file=sys.stderr)
        raise SystemExit(2)
    try:
        raise SystemExit(main(sys.argv[1]))
    except BrokenPipeError:
        # `progress.sh | head` is a normal thing to do.
        raise SystemExit(0)
