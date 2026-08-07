"""A minimal Prometheus HTTP API client for the phase 2 metric assertions.

Metrics leave the services over OTLP, which a test process cannot scrape. So the
assertions are made one hop downstream: the collector exports to Prometheus, and
the tests query Prometheus. That also matches what a human would check.
"""

from __future__ import annotations

import time
from typing import Any, Callable

import requests


class PrometheusError(RuntimeError):
    pass


class Prometheus:
    def __init__(self, base_url: str, timeout: float = 10.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def query(self, expr: str) -> list[dict[str, Any]]:
        """Run an instant query. Returns the raw ``result`` list."""
        try:
            resp = requests.get(
                f"{self.base_url}/api/v1/query", params={"query": expr}, timeout=self.timeout
            )
        except requests.RequestException as exc:
            raise PrometheusError(f"querying prometheus failed: {exc}") from exc
        if resp.status_code != 200:
            raise PrometheusError(
                f"prometheus returned {resp.status_code} for {expr!r}: {resp.text[:400]}"
            )
        payload = resp.json()
        if payload.get("status") != "success":
            raise PrometheusError(f"prometheus rejected {expr!r}: {payload}")
        return payload.get("data", {}).get("result", [])

    def scalar(self, expr: str) -> float | None:
        """The single value of an instant query, or ``None`` when it is empty."""
        result = self.query(expr)
        if not result:
            return None
        return float(result[0]["value"][1])

    def series_labels(self, expr: str) -> list[dict[str, str]]:
        return [entry.get("metric", {}) for entry in self.query(expr)]

    def label_values(self, expr: str, label: str) -> set[str]:
        return {
            metric[label] for metric in self.series_labels(expr) if label in metric
        }

    def metric_names(self) -> set[str]:
        try:
            resp = requests.get(f"{self.base_url}/api/v1/label/__name__/values", timeout=self.timeout)
            resp.raise_for_status()
        except requests.RequestException as exc:
            raise PrometheusError(f"listing metric names failed: {exc}") from exc
        return set(resp.json().get("data", []))

    def wait_for(
        self,
        predicate: Callable[[], bool],
        timeout: float = 60.0,
        interval: float = 3.0,
    ) -> bool:
        """Poll until ``predicate`` is true or the deadline passes.

        Metric pipelines are asynchronous by design: the SDK batches for
        ``OTEL_METRIC_EXPORT_INTERVAL`` (15s in docker-compose), the collector
        batches again, and Prometheus scrapes on its own schedule. Anything that
        asserts on a metric has to wait, not sleep-and-hope.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if predicate():
                    return True
            except PrometheusError:
                pass
            time.sleep(interval)
        try:
            return predicate()
        except PrometheusError:
            return False
