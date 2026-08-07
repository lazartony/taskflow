"""Small shared helpers: instants, sampling and diff rendering."""

from __future__ import annotations

import datetime as dt
import statistics
from typing import Any, Callable, Iterable, Sequence

ISO_MS = "%Y-%m-%dT%H:%M:%S.%f"


def iso(moment: dt.datetime) -> str:
    """RFC 3339, UTC, millisecond precision, literal ``Z`` — the house format."""
    return moment.astimezone(dt.timezone.utc).strftime(ISO_MS)[:-3] + "Z"


def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def future_iso(days: float = 7) -> str:
    return iso(now() + dt.timedelta(days=days))


def past_iso(days: float = 7) -> str:
    return iso(now() - dt.timedelta(days=days))


def parse_iso(value: str) -> dt.datetime:
    """Parse the house format, tolerating an offset instead of ``Z``."""
    text = value.replace("Z", "+00:00")
    return dt.datetime.fromisoformat(text)


def sample(fn: Callable[[], float], count: int, warmup: int = 0) -> list[float]:
    """Run ``fn`` ``count`` times, discarding ``warmup`` leading samples.

    Every timing assertion in this suite goes through here. A single timing
    measurement in a containerised stack is noise; a median of twenty is a
    measurement.
    """
    for _ in range(warmup):
        fn()
    return [fn() for _ in range(count)]


def percentile(values: Sequence[float], pct: float) -> float:
    if not values:
        raise ValueError("percentile of an empty sample")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * (pct / 100.0)
    low = int(rank)
    high = min(low + 1, len(ordered) - 1)
    weight = rank - low
    return ordered[low] * (1 - weight) + ordered[high] * weight


def median(values: Iterable[float]) -> float:
    data = list(values)
    return statistics.median(data) if data else 0.0


def describe(values: Sequence[float], unit: str = "ms") -> str:
    if not values:
        return "no samples"
    return (
        f"n={len(values)} min={min(values):.1f}{unit} "
        f"median={median(values):.1f}{unit} p95={percentile(values, 95):.1f}{unit} "
        f"max={max(values):.1f}{unit}"
    )


def key_paths(obj: Any, prefix: str = "") -> set[str]:
    """Every dotted key path in a JSON document, arrays collapsed to ``[]``."""
    paths: set[str] = set()
    if isinstance(obj, dict):
        for key, value in obj.items():
            path = f"{prefix}.{key}" if prefix else key
            paths.add(path)
            paths |= key_paths(value, path)
    elif isinstance(obj, list):
        for item in obj[:1]:
            paths |= key_paths(item, f"{prefix}[]")
    return paths
