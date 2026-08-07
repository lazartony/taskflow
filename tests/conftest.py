"""Root conftest for the TaskFlow conformance and E2E suites.

What this file is responsible for
---------------------------------
1. ``--impl`` / ``--base-url`` — which implementation(s) a run targets.
2. Parameterising every test over the selected implementations, using the
   language as the test id so a failure names the language.
3. Fixtures: ``api``, ``user``, ``second_user``, ``task``, ``clean_db`` plus the
   infrastructure clients (Postgres, Valkey — including the phase 6 event
   streams — Prometheus, and optionally Kafka for the §4.9 appendix).
4. Skipping — not erroring — with an actionable message when a target is not
   running.
5. Turning ``501 NOT_IMPLEMENTED`` into a distinct, informative outcome. This is
   the single most important UX property of the suite: before you start a phase
   every one of its tests should say "not implemented yet", not throw a
   confusing assertion diff at you.
"""

from __future__ import annotations

import os
import socket
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator

import pytest

sys.path.insert(0, str(Path(__file__).parent))

from conformance.client import (  # noqa: E402
    NOT_IMPLEMENTED_SEEN,
    ApiClient,
    NotImplementedYet,
    Unreachable,
    VALID_PASSWORD,
    reset_not_implemented,
)
from conformance.phases import (  # noqa: E402
    ALL_IMPLS,
    IMPL_CONTAINERS,
    IMPL_PORTS,
    IMPL_SERVICE_NAMES,
    PHASE_ORDER,
    base_url_for,
)
from conformance.report import PhaseReporter, enabled_for  # noqa: E402

#: Repo root — ``tests/`` lives directly under it. Used so ``reports/`` lands at
#: the project root no matter which directory pytest was invoked from.
REPO_ROOT = Path(__file__).resolve().parent.parent

DEFAULT_PROMETHEUS_URL = "http://localhost:9090"
DEFAULT_POSTGRES_DSN = "postgresql://postgres:password@localhost:5432/taskflow_dev"
DEFAULT_VALKEY_URL = "redis://localhost:6379/0"
DEFAULT_KAFKA_BROKERS = "localhost:9092"
TASK_EVENTS_TOPIC = "taskflow.task-events"

#: Phase 6 runs on Valkey Streams. ``{env}`` is ``dev`` in the shipped compose
#: file; ``events_stream`` below discovers the real one if you changed ENV.
DEFAULT_EVENTS_STREAM = "taskflow:dev:events:task"
DEFAULT_EVENTS_GROUP = "taskflow.notifications"
#: Used to find the stream when ``ENV`` is not ``dev``.
EVENTS_STREAM_GLOB = "taskflow:*:events:task"


# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------


def pytest_addoption(parser: pytest.Parser) -> None:
    group = parser.getgroup("taskflow", "TaskFlow conformance suite")
    group.addoption(
        "--impl",
        action="store",
        default=os.environ.get("TASKFLOW_IMPL", "all"),
        help=(
            "Implementation(s) under test: go|rust|python|csharp|typescript|all, "
            "or a comma-separated list. Default: all."
        ),
    )
    group.addoption(
        "--base-url",
        action="append",
        default=[],
        dest="base_url",
        metavar="[LANG=]URL",
        help=(
            "Override the base URL for an ad-hoc target. Either a bare URL "
            "(applies to every selected implementation) or LANG=URL. Repeatable."
        ),
    )
    group.addoption(
        "--phase-report",
        action="store",
        default=os.environ.get(
            "TASKFLOW_PHASE_REPORT", str(REPO_ROOT / "reports" / "phase-status.json")
        ),
        help="Where to write the machine-readable phase status.",
    )
    group.addoption(
        "--no-phase-report",
        action="store_true",
        default=False,
        help="Disable the phase summary and the JSON status file.",
    )
    group.addoption(
        "--prometheus-url",
        action="store",
        default=os.environ.get("TASKFLOW_PROMETHEUS_URL", DEFAULT_PROMETHEUS_URL),
        help="Prometheus base URL for the phase 2 metric checks.",
    )
    group.addoption(
        "--postgres-dsn",
        action="store",
        default=os.environ.get("TASKFLOW_POSTGRES_DSN", DEFAULT_POSTGRES_DSN),
        help="Postgres DSN for the phase 3 and phase 6 checks.",
    )
    group.addoption(
        "--valkey-url",
        action="store",
        default=os.environ.get("TASKFLOW_VALKEY_URL", DEFAULT_VALKEY_URL),
        help="Valkey/Redis URL for the phase 4 cache-key checks.",
    )
    group.addoption(
        "--events-stream",
        action="store",
        default=os.environ.get("TASKFLOW_EVENTS_STREAM", DEFAULT_EVENTS_STREAM),
        help=(
            "Valkey stream carrying task events, for the phase 6 checks. "
            f"Default: {DEFAULT_EVENTS_STREAM}."
        ),
    )
    group.addoption(
        "--events-group",
        action="store",
        default=os.environ.get("TASKFLOW_EVENTS_GROUP", DEFAULT_EVENTS_GROUP),
        help=(
            "Consumer group expected on the task-events stream. "
            f"Default: {DEFAULT_EVENTS_GROUP}."
        ),
    )
    group.addoption(
        "--kafka-brokers",
        action="store",
        default=os.environ.get("TASKFLOW_KAFKA_BROKERS"),
        # No default value on purpose: Kafka is the optional §4.9 appendix, so
        # `-m appendix` must skip unless someone deliberately opts in. A default
        # of localhost:9092 would make "the appendix ran" indistinguishable from
        # "something else is listening on 9092".
        help=(
            "Kafka/Redpanda bootstrap servers. Only needed for the OPTIONAL "
            f"Kafka appendix (-m appendix), e.g. --kafka-brokers {DEFAULT_KAFKA_BROKERS}."
        ),
    )


def _configured_impls() -> list[str]:
    """The languages this project is currently using.

    Single source of truth is ``COMPOSE_PROFILES`` in ``.env``, written by
    ``scripts/use-languages.sh``. Running one language is a supported path, and
    a one-language project should not see four permanently-empty columns in
    every report — so ``--impl all`` means "all *configured*", not "all five".

    Falls back to all five when ``.env`` is missing, which is right for a fresh
    clone.
    """
    env_file = Path(__file__).resolve().parent.parent / ".env"
    try:
        for line in env_file.read_text().splitlines():
            if line.startswith("COMPOSE_PROFILES="):
                value = line.split("=", 1)[1].strip()
                # Filter out non-language profiles, e.g. the optional `kafka`.
                chosen = {p.strip() for p in value.split(",") if p.strip()}
                langs = [i for i in ALL_IMPLS if i in chosen]
                if langs:
                    return langs
    except OSError:
        pass
    return list(ALL_IMPLS)


def _selected_impls(config: pytest.Config) -> list[str]:
    raw = str(config.getoption("impl") or "all").strip().lower()
    if raw in ("all", ""):
        return _configured_impls()
    if raw == "every":
        # Escape hatch: ignore .env and target all five regardless.
        return list(ALL_IMPLS)
    names = [part.strip() for part in raw.split(",") if part.strip()]
    unknown = [n for n in names if n not in IMPL_PORTS]
    if unknown:
        raise pytest.UsageError(
            f"--impl: unknown implementation(s) {', '.join(unknown)}. "
            f"Choose from: {', '.join(ALL_IMPLS)}, all."
        )
    # Preserve the canonical order so reports read the same way every time.
    return [i for i in ALL_IMPLS if i in names]


def _base_url_overrides(config: pytest.Config) -> dict[str, str]:
    overrides: dict[str, str] = {}
    generic: str | None = None
    for value in config.getoption("base_url") or []:
        if "=" in value and not value.split("=", 1)[0].startswith("http"):
            lang, url = value.split("=", 1)
            lang = lang.strip().lower()
            if lang not in IMPL_PORTS:
                raise pytest.UsageError(
                    f"--base-url: unknown implementation {lang!r}. "
                    f"Choose from: {', '.join(ALL_IMPLS)}."
                )
            overrides[lang] = url.strip().rstrip("/")
        else:
            generic = value.strip().rstrip("/")
    if generic:
        for impl in _selected_impls(config):
            overrides.setdefault(impl, generic)
    return overrides


def resolve_base_url(config: pytest.Config, impl: str) -> str:
    return _base_url_overrides(config).get(impl, base_url_for(impl))


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


def pytest_configure(config: pytest.Config) -> None:
    # Guard against pytest.ini drifting away from phases.py.
    registered = {
        line.split(":", 1)[0].strip() for line in config.getini("markers")
    }
    missing = [p for p in PHASE_ORDER if p not in registered]
    if missing:
        raise pytest.UsageError(
            "pytest.ini is missing marker registrations for: "
            f"{', '.join(missing)} (see tests/conformance/phases.py). "
            "With --strict-markers an unregistered marker is an error."
        )
    # Fail fast and once, rather than raising the same UsageError from every
    # collected module during pytest_generate_tests.
    _selected_impls(config)
    _base_url_overrides(config)

    if enabled_for(config):
        config.pluginmanager.register(PhaseReporter(config), "taskflow-phase-reporter")


#: Words that may appear in a ``-m`` expression without naming a marker.
_MARKEXPR_KEYWORDS = {"not", "and", "or", "True", "False", "None"}


def pytest_collection(session: pytest.Session) -> None:
    # Runs after every plugin's pytest_configure, so markers registered by
    # pytest-xdist and friends are visible here but not in pytest_configure.
    _validate_marker_expression(session.config)


def _validate_marker_expression(config: pytest.Config) -> None:
    """Reject ``-m phse1`` instead of silently selecting nothing.

    ``--strict-markers`` catches a typo in ``@pytest.mark.phse1`` but says
    nothing about a typo on the command line — where the failure mode is
    "0 tests collected", which reads like "everything is fine".
    """
    import re as _re

    expression = getattr(config.option, "markexpr", "") or ""
    if not expression:
        return
    registered = {
        line.split(":", 1)[0].split("(", 1)[0].strip()
        for line in config.getini("markers")
    }
    names = set(_re.findall(r"[A-Za-z_][A-Za-z0-9_]*", expression)) - _MARKEXPR_KEYWORDS
    unknown = sorted(name for name in names if name not in registered)
    if unknown:
        raise pytest.UsageError(
            f"-m {expression!r} refers to unregistered marker(s): {', '.join(unknown)}.\n"
            f"TaskFlow markers: {', '.join(sorted(PHASE_ORDER))}, "
            f"differential, appendix, e2e, slow, docker, destructive.\n"
            f"A typo here would otherwise select zero tests and look like success."
        )


def pytest_generate_tests(metafunc: pytest.Metafunc) -> None:
    """Run every implementation-bound test once per selected implementation."""
    if "impl" in metafunc.fixturenames:
        impls = _selected_impls(metafunc.config)
        # Session scope so module-scoped fixtures (the 45-task seed) may depend
        # on the implementation, and so pytest groups a language's tests
        # together instead of interleaving five stacks.
        metafunc.parametrize("impl", impls, ids=lambda name: name, scope="session")


# ---------------------------------------------------------------------------
# Outcome tagging — 501 and unreachable become first-class outcomes
# ---------------------------------------------------------------------------

# Two phrases, deliberately distinct. Only the *implementation* being down is
# reported as "not reachable" in the phase summary; missing infrastructure is an
# ordinary skip, because it says nothing about whether the phase is finished.
_API_UNREACHABLE_HINT = "-api not reachable at"
_UNREACHABLE_HINT = "not reachable at"


@pytest.hookimpl(wrapper=True)
def pytest_runtest_makereport(item: pytest.Item, call: pytest.CallInfo) -> Any:
    report = yield

    markers = {m.name for m in item.iter_markers()}
    default_impl = "differential" if "differential" in markers else "cross-impl"
    impl = default_impl
    callspec = getattr(item, "callspec", None)
    if callspec is not None:
        impl = str(callspec.params.get("impl", default_impl))
    phase = next(
        (name for name in sorted(markers) if name.startswith("phase")),
        "appendix" if "appendix" in markers else "unknown",
    )

    flag = ""
    excinfo = getattr(call, "excinfo", None)
    if excinfo is not None and excinfo.errisinstance(NotImplementedYet):
        flag = "not_implemented"
    elif excinfo is not None and excinfo.errisinstance(Unreachable):
        # The service was up when the fixture probed it and went away mid-test.
        flag = "unreachable"
    elif (
        report.outcome == "failed"
        and NOT_IMPLEMENTED_SEEN
        and excinfo is not None
        and excinfo.errisinstance(AssertionError)
    ):
        # The test asserted on the status directly rather than going through
        # Response.implemented(), but a 501 was served during it. Report the
        # useful thing: this endpoint has not been built yet.
        flag = "not_implemented"
    elif report.outcome == "skipped":
        reason = _skip_reason(report)
        if _API_UNREACHABLE_HINT in reason:
            flag = "unreachable"

    # One-line "why" for the First failures block the phase reporter prints.
    # Captured here because `excinfo` only exists at hook time — by the time the
    # reporter sees the report, the exception is a formatted traceback string and
    # the useful sentence is buried in it.
    reason = ""
    if excinfo is not None:
        reason = str(excinfo.value).strip().splitlines()[0] if str(excinfo.value).strip() else ""
    elif report.outcome == "skipped":
        reason = _skip_reason(report).strip().splitlines()[0] if _skip_reason(report).strip() else ""

    report.taskflow_meta = {"impl": impl, "phase": phase, "flag": flag, "reason": reason}
    return report


def _skip_reason(report: Any) -> str:
    longrepr = getattr(report, "longrepr", None)
    if isinstance(longrepr, tuple) and len(longrepr) == 3:
        return str(longrepr[2])
    return str(longrepr or "")


def pytest_report_teststatus(report: Any, config: pytest.Config) -> Any:
    meta = getattr(report, "taskflow_meta", None)
    if not meta:
        return None
    if meta.get("flag") == "not_implemented":
        # Category stays "failed" so the process exit code still says "red" —
        # only the wording changes, so the learner reads "you have not built
        # this" instead of "something is broken".
        return "failed", "N", "NOT IMPLEMENTED"
    if meta.get("flag") == "unreachable":
        if report.outcome == "skipped":
            return "skipped", "R", "NOT REACHABLE"
        return "failed", "R", "NOT REACHABLE"
    return None


# ---------------------------------------------------------------------------
# Reachability
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset_not_implemented_log() -> Iterator[None]:
    """Each test starts with a clean 501 ledger — see conformance/client.py."""
    reset_not_implemented()
    yield
    reset_not_implemented()


@pytest.fixture(scope="session")
def _reachability() -> dict[str, bool]:
    """Per-process memo so a down service is probed once, not once per test."""
    return {}


def _require_reachable(
    impl: str, base_url: str, client: ApiClient, memo: dict[str, bool]
) -> None:
    if base_url not in memo:
        memo[base_url] = client.ping()
    if not memo[base_url]:
        port = base_url.rsplit(":", 1)[-1]
        pytest.skip(
            f"{impl}-api {_UNREACHABLE_HINT} :{port} ({base_url}), is it running? "
            f"Try `make up` or `docker compose up -d {impl}-api`."
        )


# ---------------------------------------------------------------------------
# Core fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def base_url(request: pytest.FixtureRequest, impl: str) -> str:
    return resolve_base_url(request.config, impl)


@pytest.fixture
def api(impl: str, base_url: str, _reachability: dict[str, bool]) -> Iterator[ApiClient]:
    """An unauthenticated client bound to one implementation."""
    client = ApiClient(base_url, impl)
    _require_reachable(impl, base_url, client, _reachability)
    yield client
    client.session.close()


@pytest.fixture
def new_client(impl: str, base_url: str, _reachability: dict[str, bool]):
    """Factory for extra independent clients against the same implementation."""
    created: list[ApiClient] = []

    def make() -> ApiClient:
        client = ApiClient(base_url, impl)
        _require_reachable(impl, base_url, client, _reachability)
        created.append(client)
        return client

    yield make
    for client in created:
        client.session.close()


@pytest.fixture
def created_accounts() -> list[dict[str, str]]:
    """Accounts registered by fixtures in this test, for optional DB cleanup."""
    return []


def _register_account(
    client: ApiClient, prefix: str, registry: list[dict[str, str]]
) -> ApiClient:
    email = ApiClient.unique_email(prefix)
    resp = client.register(email=email, display_name="Conformance User")
    resp.implemented()
    if resp.status != 201 or not client.access_token:
        raise AssertionError(
            f"{client.impl}: could not register a test account — the `user` fixture "
            f"needs a working POST /auth/register.\n{resp.exchange.render()}"
        )
    client.email = email  # type: ignore[attr-defined]
    client.password = VALID_PASSWORD  # type: ignore[attr-defined]
    registry.append({"email": email, "id": (client.user or {}).get("id", "")})
    return client


@pytest.fixture
def user(new_client, created_accounts: list[dict[str, str]]) -> ApiClient:
    """A freshly registered, authenticated user with a unique email."""
    return _register_account(new_client(), "u1", created_accounts)


@pytest.fixture
def second_user(new_client, created_accounts: list[dict[str, str]]) -> ApiClient:
    """A second independent user, for ownership-isolation tests."""
    return _register_account(new_client(), "u2", created_accounts)


@pytest.fixture
def task(user: ApiClient) -> dict:
    """A task owned by ``user``."""
    resp = user.create_task("Fixture task", description="Created by the task fixture")
    resp.expect(201)
    created = resp.task
    if not isinstance(created, dict):
        raise AssertionError(
            f"{user.impl}: POST /tasks did not return data.task\n{resp.exchange.render()}"
        )
    return created


@dataclass
class SeededUser:
    """A user with the 45-task corpus loaded — see ``conformance/seed.py``."""

    client: ApiClient
    nonce: str
    seed: list[dict]
    created: list[dict]

    @property
    def impl(self) -> str:
        return self.client.impl


@pytest.fixture(scope="module")
def seeded_user(
    request: pytest.FixtureRequest, impl: str, _reachability: dict[str, bool]
) -> Iterator[SeededUser]:
    """One user with 45 deterministic tasks, shared by the pagination module.

    Module-scoped because creating 45 tasks per test would turn a 30-second
    phase into a five-minute one. Still hermetic: the account is unique per
    module per implementation, so ``-n auto`` remains safe.
    """
    import uuid

    from conformance.seed import build_seed

    url = resolve_base_url(request.config, impl)
    client = ApiClient(url, impl)
    _require_reachable(impl, url, client, _reachability)

    nonce = uuid.uuid4().hex[:8]
    _register_account(client, f"seed-{nonce}", [])

    seed = build_seed(nonce)
    created: list[dict] = []
    for payload in seed:
        resp = client.post("/tasks", json_body=payload)
        resp.implemented()
        if resp.status != 201:
            raise AssertionError(
                f"{impl}: seeding the pagination corpus failed at task "
                f"{len(created)}/{len(seed)} — POST /tasks returned {resp.status}.\n"
                f"{resp.exchange.render()}"
            )
        created.append(resp.task)

    try:
        yield SeededUser(client=client, nonce=nonce, seed=seed, created=created)
    finally:
        client.session.close()


# ---------------------------------------------------------------------------
# Infrastructure fixtures
# ---------------------------------------------------------------------------


def _tcp_open(host: str, port: int, timeout: float = 1.5) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


@dataclass
class Db:
    """A thin psycopg helper for the tests that must look at the database."""

    conn: Any

    def rows(self, sql: str, params: tuple = ()) -> list[tuple]:
        with self.conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()

    def scalar(self, sql: str, params: tuple = ()) -> Any:
        rows = self.rows(sql, params)
        return rows[0][0] if rows else None

    def execute(self, sql: str, params: tuple = ()) -> None:
        with self.conn.cursor() as cur:
            cur.execute(sql, params)
        self.conn.commit()

    def purge_email(self, email: str) -> None:
        """Hard-delete one account and everything that cascades from it."""
        try:
            self.execute("DELETE FROM users WHERE email = %s", (email,))
        except Exception:  # pragma: no cover - cleanup must never fail a test
            self.conn.rollback()


@pytest.fixture
def db(request: pytest.FixtureRequest) -> Iterator[Db]:
    """A live Postgres connection, or a clear skip."""
    psycopg = pytest.importorskip("psycopg", reason="psycopg is required: pip install 'psycopg[binary]'")
    dsn = request.config.getoption("postgres_dsn")
    try:
        conn = psycopg.connect(dsn, connect_timeout=3)
    except Exception as exc:
        pytest.skip(f"postgres {_UNREACHABLE_HINT} {dsn} — is the stack up? ({exc})")
    try:
        yield Db(conn)
    finally:
        conn.close()


@pytest.fixture
def clean_db(db: Db, created_accounts: list[dict[str, str]]) -> Iterator[Db]:
    """Postgres access plus teardown of the accounts this test created.

    Deliberately scoped to *this test's own* users rather than truncating
    tables: the suite must stay safe under ``pytest -n auto``.
    """
    yield db
    for account in created_accounts:
        if account.get("email"):
            db.purge_email(account["email"])


@pytest.fixture(scope="session")
def prometheus_url(request: pytest.FixtureRequest) -> str:
    url = str(request.config.getoption("prometheus_url")).rstrip("/")
    import requests

    try:
        resp = requests.get(f"{url}/-/ready", timeout=3)
        ok = resp.status_code < 500
    except requests.RequestException:
        ok = False
    if not ok:
        pytest.skip(
            f"prometheus {_UNREACHABLE_HINT} {url} — start it with "
            f"`docker compose -f docker-compose.observability.yml up -d prometheus`."
        )
    return url


@pytest.fixture
def valkey(request: pytest.FixtureRequest) -> Iterator[Any]:
    redis = pytest.importorskip("redis", reason="redis is required: pip install redis")
    url = str(request.config.getoption("valkey_url"))
    try:
        client = redis.Redis.from_url(url, socket_connect_timeout=2, decode_responses=True)
        client.ping()
    except Exception as exc:
        pytest.skip(f"valkey {_UNREACHABLE_HINT} {url} — is the stack up? ({exc})")
    try:
        yield client
    finally:
        try:
            client.close()
        except Exception:
            pass


@pytest.fixture
def events_group(request: pytest.FixtureRequest) -> str:
    """The consumer group the notification consumer is expected to use."""
    return str(request.config.getoption("events_group"))


@pytest.fixture
def events_stream(request: pytest.FixtureRequest, valkey: Any) -> str:
    """The task-events stream, discovered rather than assumed.

    ``taskflow:{env}:events:task`` embeds ``ENV``, which is ``dev`` in the
    shipped compose file but yours may differ. Look for the configured name
    first, then for any stream matching the documented shape; fall back to the
    configured name so a missing stream fails with the *test's* message ("no
    event appeared") rather than a fixture skip that hides an unbuilt relay.
    """
    configured = str(request.config.getoption("events_stream"))
    if valkey.exists(configured):
        return configured
    found = sorted(str(k) for k in valkey.scan_iter(match=EVENTS_STREAM_GLOB, count=1000))
    return found[0] if found else configured


@pytest.fixture
def events_dlq(events_stream: str) -> str:
    """A DLQ is just another stream — see the infrastructure spec §4.7."""
    return f"{events_stream}:dlq"


@pytest.fixture
def kafka_brokers(request: pytest.FixtureRequest) -> str:
    """Brokers for the OPTIONAL Kafka appendix. Skips unless opted in.

    Phase 6 itself runs on Valkey Streams and needs none of this.
    """
    raw = request.config.getoption("kafka_brokers")
    if not raw:
        pytest.skip(
            "the Kafka appendix is optional and off by default — run it with "
            f"`pytest -m appendix --kafka-brokers {DEFAULT_KAFKA_BROKERS}` after "
            "`docker compose -f docker-compose.infra.yml --profile kafka up -d redpanda`."
        )
    brokers = str(raw)
    host, _, port = brokers.split(",")[0].partition(":")
    if not _tcp_open(host, int(port or 9092)):
        pytest.skip(
            f"kafka/redpanda {_UNREACHABLE_HINT} {brokers} — start it with "
            "`docker compose -f docker-compose.infra.yml --profile kafka up -d redpanda`."
        )
    return brokers


# ---------------------------------------------------------------------------
# Differential fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def all_impl_clients(request: pytest.FixtureRequest, _reachability: dict[str, bool]):
    """Every selected implementation at once — the differential test's input.

    Needs at least two implementations by definition. On a single-language
    project this skips cleanly rather than failing: it is the one part of the
    harness that a solo-language run genuinely cannot exercise, and the skip
    message says so instead of looking like a broken test.
    """
    config = request.config
    selected = _selected_impls(config)
    if len(selected) < 2:
        only = selected[0] if selected else "none"
        pytest.skip(
            "the differential test compares implementations against each "
            f"other, and this project is configured for one language ({only}). "
            "Nothing is wrong — add a second language when you want this check: "
            "`make languages LANGS=go,rust`."
        )

    clients: dict[str, ApiClient] = {}
    unreachable: list[str] = []
    for impl in selected:
        url = resolve_base_url(config, impl)
        client = ApiClient(url, impl)
        if url not in _reachability:
            _reachability[url] = client.ping()
        if _reachability[url]:
            clients[impl] = client
        else:
            unreachable.append(f"{impl} (:{IMPL_PORTS[impl]})")

    if len(clients) < 2:
        pytest.skip(
            f"fewer than two implementations are reachable on their ports "
            f"({', '.join(unreachable) or 'none reachable'}) — "
            "the differential test needs at least two to compare."
        )
    try:
        yield clients
    finally:
        for client in clients.values():
            client.session.close()


# ---------------------------------------------------------------------------
# Misc helpers exposed to tests
# ---------------------------------------------------------------------------


@pytest.fixture
def service_name(impl: str) -> str:
    return IMPL_SERVICE_NAMES[impl]


@pytest.fixture
def container_name(impl: str) -> str:
    return IMPL_CONTAINERS[impl]


@pytest.fixture(scope="session")
def kafka_topic() -> str:
    """Appendix only — the Streams equivalent is the ``events_stream`` fixture."""
    return TASK_EVENTS_TOPIC
