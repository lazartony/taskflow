"""Docker helpers for the handful of tests that must act on the container itself.

Everything here is best-effort: if the Docker CLI is missing or the container is
not running, the caller gets ``None`` and skips. Tests that need Docker carry
``@pytest.mark.docker`` so ``-m "not docker"`` deselects them cleanly.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from typing import Any


def docker_available() -> bool:
    if shutil.which("docker") is None:
        return False
    return _run(["docker", "info", "--format", "{{.ServerVersion}}"]) is not None


def _run(cmd: list[str], timeout: float = 15.0) -> str | None:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def container_running(name: str) -> bool:
    state = _run(["docker", "inspect", "-f", "{{.State.Running}}", name])
    return state == "true"


def container_env(name: str) -> dict[str, str] | None:
    """The container's environment as a dict, or ``None`` if unavailable."""
    raw = _run(["docker", "inspect", "-f", "{{json .Config.Env}}", name])
    if raw is None:
        return None
    try:
        entries: list[str] = json.loads(raw)
    except ValueError:
        return None
    env: dict[str, str] = {}
    for entry in entries:
        key, _, value = entry.partition("=")
        env[key] = value
    return env


def signal(name: str, sig: str = "SIGTERM") -> bool:
    return _run(["docker", "kill", "--signal", sig, name]) is not None


def start(name: str) -> bool:
    return _run(["docker", "start", name], timeout=60) is not None


def stop(name: str, timeout_s: int = 10) -> bool:
    return _run(["docker", "stop", "-t", str(timeout_s), name], timeout=timeout_s + 30) is not None


def inspect(name: str) -> dict[str, Any] | None:
    raw = _run(["docker", "inspect", name])
    if raw is None:
        return None
    try:
        parsed = json.loads(raw)
    except ValueError:
        return None
    return parsed[0] if parsed else None
