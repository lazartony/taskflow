"""Per-language, per-phase reporting for the TaskFlow conformance suite.

Registered from ``tests/conftest.py``. At the end of a run it prints:

    PHASE 1 — Core API
    ────────────────────────────────────────────────
    go           ██████████████████████  48/48  PASS
    rust         ███████████████░░░░░░░  33/48  15 failing
    python       ████░░░░░░░░░░░░░░░░░░   9/48  39 not implemented
    csharp       ░░░░░░░░░░░░░░░░░░░░░░   0/48  not reachable
    typescript   ██████████████████████  48/48  PASS

and merges the same numbers into ``reports/phase-status.json`` so
``scripts/progress.sh`` can render a whole-project dashboard from many partial
runs (``check-phase.sh 1 go`` only knows about phase 1 and go — it must not
erase what the previous run learned about phase 2 and rust).
"""

from __future__ import annotations

import datetime as dt
import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .phases import ALL_IMPLS, PHASE_ORDER, PHASES, phase_title

BAR_WIDTH = 22
FILLED = "█"
EMPTY = "░"

# Outcome buckets, most-specific first.
PASSED = "passed"
FAILED = "failed"
NOT_IMPLEMENTED = "notImplemented"
UNREACHABLE = "unreachable"
SKIPPED = "skipped"

_COUNTERS = (PASSED, FAILED, NOT_IMPLEMENTED, UNREACHABLE, SKIPPED)

_COLOURS = {
    "green": "\033[32m",
    "red": "\033[31m",
    "yellow": "\033[33m",
    "blue": "\033[34m",
    "grey": "\033[90m",
    "bold": "\033[1m",
    "reset": "\033[0m",
}


def _colour(text: str, name: str, enabled: bool) -> str:
    if not enabled or name not in _COLOURS:
        return text
    return f"{_COLOURS[name]}{text}{_COLOURS['reset']}"


@dataclass
class Tally:
    counts: dict[str, int] = field(
        default_factory=lambda: dict.fromkeys(_COUNTERS, 0)
    )

    @property
    def total(self) -> int:
        return sum(self.counts.values())

    @property
    def considered(self) -> int:
        """Tests that could actually run — the denominator on the bar."""
        return self.total - self.counts[SKIPPED]

    def add(self, bucket: str) -> None:
        self.counts[bucket] = self.counts.get(bucket, 0) + 1

    def verdict(self) -> tuple[str, str]:
        """(machine verdict, human phrase)."""
        c = self.counts
        if self.total == 0:
            return "empty", "no tests"
        if c[UNREACHABLE] and c[UNREACHABLE] == self.total:
            return "unreachable", "not reachable"
        if c[SKIPPED] and c[SKIPPED] == self.total:
            return "skipped", "all skipped"
        parts: list[str] = []
        if c[FAILED]:
            parts.append(f"{c[FAILED]} failing")
        if c[NOT_IMPLEMENTED]:
            parts.append(f"{c[NOT_IMPLEMENTED]} not implemented")
        if c[UNREACHABLE]:
            parts.append(f"{c[UNREACHABLE]} unreachable")
        if not parts:
            suffix = f" ({c[SKIPPED]} skipped)" if c[SKIPPED] else ""
            return "pass", f"PASS{suffix}"
        if c[FAILED] == 0 and c[NOT_IMPLEMENTED]:
            return "not_implemented", ", ".join(parts)
        return "fail", ", ".join(parts)

    def as_json(self) -> dict[str, Any]:
        verdict, phrase = self.verdict()
        return {
            **{k: self.counts[k] for k in _COUNTERS},
            "total": self.total,
            # Tests that could actually run — the denominator the terminal
            # summary and the dashboard both display.
            "considered": self.considered,
            "verdict": verdict,
            "summary": phrase,
        }


class PhaseReporter:
    """Collects outcomes and renders the summary."""

    def __init__(self, config: Any) -> None:
        self.config = config
        # phase -> impl -> Tally
        self.tallies: dict[str, dict[str, Tally]] = {}
        self.report_path: Path | None = None
        raw = config.getoption("phase_report", default=None)
        if raw:
            path = Path(raw)
            self.report_path = path if path.is_absolute() else Path(config.rootpath) / path

    # -- collection --------------------------------------------------------

    def record(self, phase: str, impl: str, bucket: str) -> None:
        self.tallies.setdefault(phase, {}).setdefault(impl, Tally()).add(bucket)

    def pytest_runtest_logreport(self, report: Any) -> None:
        meta = getattr(report, "taskflow_meta", None)
        if not meta:
            return
        # Count each test once: the setup phase only when it decided the
        # outcome (skip/error), otherwise the call phase.
        if report.when == "call":
            bucket = _bucket_for(report, meta)
        elif report.when == "setup" and report.outcome in ("skipped", "failed"):
            bucket = _bucket_for(report, meta)
        elif report.when == "teardown" and report.outcome == "failed":
            bucket = FAILED
        else:
            return
        self.record(meta.get("phase", "unknown"), meta.get("impl", "-"), bucket)

    # -- rendering ---------------------------------------------------------

    def _impl_order(self, phase: str) -> list[str]:
        seen = self.tallies.get(phase, {})
        ordered = [i for i in ALL_IMPLS if i in seen]
        ordered += sorted(k for k in seen if k not in ALL_IMPLS)
        return ordered

    def render(self, colour: bool = True) -> list[str]:
        lines: list[str] = []
        phases = [p for p in PHASE_ORDER if p in self.tallies]
        phases += sorted(p for p in self.tallies if p not in PHASE_ORDER)
        for phase in phases:
            lines.append("")
            lines.append(_colour("  " + phase_title(phase), "bold", colour))
            lines.append("  " + "─" * 48)
            for impl in self._impl_order(phase):
                tally = self.tallies[phase][impl]
                lines.append("  " + self._row(impl, tally, colour))
        return lines

    @staticmethod
    def _row(impl: str, tally: Tally, colour: bool) -> str:
        verdict, phrase = tally.verdict()
        denominator = tally.considered
        passed = tally.counts[PASSED]
        ratio = (passed / denominator) if denominator else 0.0
        filled = int(round(ratio * BAR_WIDTH))
        if passed and filled == 0:
            filled = 1  # never render real progress as an empty bar
        if passed < denominator and filled == BAR_WIDTH:
            filled = BAR_WIDTH - 1  # never render an incomplete phase as full
        bar = FILLED * filled + EMPTY * (BAR_WIDTH - filled)
        tone = {
            "pass": "green",
            "fail": "red",
            "not_implemented": "yellow",
            "unreachable": "grey",
            "skipped": "grey",
            "empty": "grey",
        }.get(verdict, "reset")
        counts = f"{passed:>3}/{denominator:<3}"
        return (
            f"{impl:<12} {_colour(bar, tone, colour)}  {counts}  "
            f"{_colour(phrase, tone, colour)}"
        )

    # -- persistence -------------------------------------------------------

    def as_json(self) -> dict[str, Any]:
        now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        phases: dict[str, Any] = {}
        for phase, by_impl in self.tallies.items():
            phases[phase] = {
                "title": PHASES.get(phase, "Unknown"),
                "updatedAt": now,
                "implementations": {
                    impl: tally.as_json() for impl, tally in by_impl.items()
                },
            }
        return {"generatedAt": now, "phases": phases}

    def write_json(self) -> Path | None:
        if self.report_path is None:
            return None
        merged: dict[str, Any] = {"phases": {}}
        if self.report_path.exists():
            try:
                existing = json.loads(self.report_path.read_text())
                if isinstance(existing, dict) and isinstance(existing.get("phases"), dict):
                    merged = existing
            except (OSError, ValueError):
                merged = {"phases": {}}
        fresh = self.as_json()
        merged["generatedAt"] = fresh["generatedAt"]
        for phase, payload in fresh["phases"].items():
            slot = merged["phases"].setdefault(
                phase, {"title": payload["title"], "implementations": {}}
            )
            slot["title"] = payload["title"]
            slot["updatedAt"] = payload["updatedAt"]
            slot.setdefault("implementations", {}).update(payload["implementations"])
        merged["summary"] = _overall(merged["phases"])
        self.report_path.parent.mkdir(parents=True, exist_ok=True)
        self.report_path.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
        return self.report_path

    # -- pytest hooks ------------------------------------------------------

    def pytest_terminal_summary(self, terminalreporter: Any) -> None:
        if not self.tallies:
            return
        colour = not self.config.option.color == "no"
        terminalreporter.write_sep("=", "TaskFlow phase status")
        for line in self.render(colour=colour):
            terminalreporter.write_line(line)
        terminalreporter.write_line("")
        written = self.write_json()
        if written is not None:
            try:
                shown = written.relative_to(Path(self.config.rootpath))
            except ValueError:
                shown = written
            terminalreporter.write_line(f"  machine-readable status → {shown}")
            terminalreporter.write_line("")


def _bucket_for(report: Any, meta: dict[str, str]) -> str:
    if report.outcome == "passed":
        return PASSED
    flag = meta.get("flag")
    if report.outcome == "skipped":
        return UNREACHABLE if flag == "unreachable" else SKIPPED
    if flag == "not_implemented":
        return NOT_IMPLEMENTED
    if flag == "unreachable":
        return UNREACHABLE
    return FAILED


def _overall(phases: dict[str, Any]) -> dict[str, Any]:
    """Aggregate every phase into a per-implementation roll-up."""
    per_impl: dict[str, dict[str, int]] = {}
    for payload in phases.values():
        for impl, stats in payload.get("implementations", {}).items():
            slot = per_impl.setdefault(
                impl, dict.fromkeys(_COUNTERS, 0) | {"total": 0, "considered": 0}
            )
            for key in (*_COUNTERS, "total", "considered"):
                slot[key] = slot.get(key, 0) + int(stats.get(key, 0))
    completed = {
        impl: sorted(
            phase
            for phase, payload in phases.items()
            if payload.get("implementations", {}).get(impl, {}).get("verdict") == "pass"
        )
        for impl in per_impl
    }
    return {"implementations": per_impl, "phasesPassed": completed}


def enabled_for(config: Any) -> bool:
    """The reporter is on unless explicitly disabled (useful in CI JUnit runs)."""
    if config.getoption("no_phase_report", default=False):
        return False
    return os.environ.get("TASKFLOW_NO_PHASE_REPORT", "") == ""
