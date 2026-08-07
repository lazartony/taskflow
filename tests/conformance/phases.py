"""Phase metadata shared by the conftest, the reporter and ``scripts/check-phase.sh``.

One table, imported everywhere, so a phase name never drifts between the marker
registration in ``pytest.ini``, the terminal report and the JSON dashboard.
"""

from __future__ import annotations

# Ordered so the report renders phases in roadmap order rather than dict order.
PHASES: dict[str, str] = {
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

PHASE_ORDER: list[str] = list(PHASES)

# impl -> host port published by docker-compose.yml.
IMPL_PORTS: dict[str, int] = {
    "go": 8001,
    "rust": 8002,
    "python": 8003,
    "csharp": 8004,
    "typescript": 8005,
}

ALL_IMPLS: list[str] = list(IMPL_PORTS)

# The docker-compose container name for each implementation, used by the tests
# that need to send a signal or read an environment variable (marked ``docker``).
IMPL_CONTAINERS: dict[str, str] = {
    "go": "taskflow-go",
    "rust": "taskflow-rust",
    "python": "taskflow-python",
    "csharp": "taskflow-csharp",
    "typescript": "taskflow-typescript",
}

# OTEL_SERVICE_NAME as set in docker-compose.yml — the ``service_name`` label in
# Prometheus.
IMPL_SERVICE_NAMES: dict[str, str] = {name: f"taskflow-{name}" for name in ALL_IMPLS}


#: Sections that are reported alongside the phases but are not phases: optional
#: material nobody has to finish. Kept out of ``PHASES`` so ``PHASE_ORDER`` (and
#: therefore the completion dashboard) still means "the required roadmap".
SECTIONS: dict[str, str] = {
    "appendix": "Kafka parity (optional — infrastructure spec §4.9)",
}


def phase_title(marker: str) -> str:
    """``phase1`` -> ``PHASE 1 — Core API``; ``appendix`` -> ``APPENDIX — …``."""
    if not marker.startswith("phase"):
        return f"{marker.upper()} — {SECTIONS.get(marker, 'Unknown')}"
    number = marker.removeprefix("phase")
    return f"PHASE {number} — {PHASES.get(marker, 'Unknown')}"


def base_url_for(impl: str) -> str:
    return f"http://localhost:{IMPL_PORTS[impl]}"
