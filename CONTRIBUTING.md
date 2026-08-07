# Contributing to TaskFlow

Thank you for being here. Before anything else, the one thing that matters most:

---

## Please don't send us finished phases

**TaskFlow is a learning project. The unimplemented phases are the entire product.**

If you send a pull request that implements Phase 1 in Go, or wires up the OTel SDK for
Phase 2 in Rust, we cannot merge it — not because it's bad work, but because merging it
would delete the exercise for everyone who comes after you: the wall of red from
`make check PHASE=1 IMPL=go` *is* the specification, and it only works while it's red.

This is by far the most common well-meant mistake people make with repos like this one, and
it's an easy one to make: you finished the phase, the code is good, sharing it feels like
the obvious next step. It is a generous instinct and we'd rather redirect it than refuse it.

**Where your implementation should go instead:**

- **Your own fork or repo.** This is the best option. It's your work, under your name, and
  it's a much better portfolio artifact standing on its own than buried in someone else's
  PR history.
- **A `solutions/` branch**, if you'd like it hosted here. Never `main`. Open a discussion
  first so we can agree on the branch layout — one branch per language keeps it navigable.
- **The "Built with TaskFlow" list.** If you finish some or all of the phases, open an issue
  or a PR adding a line to the README pointing at your repo, with the languages you used and
  anything you'd tell the next person. Someone stuck on Phase 6's outbox semantics learns
  far more from reading three different people's solutions than from finding one canonical
  answer sitting in `main`.

Everything below is about the other kind of contribution — the kind that makes the harness
better for everyone building against it.

---

## What we genuinely want

The scaffolding is the product. It can always be better, and there is a lot of it.

**Bugs in the harness, tests or scripts.** A test that asserts something the OpenAPI
contract doesn't actually say. A test that's flaky under `-n auto`. A script that breaks on
a path with a space in it. A `make` target that fails on a fresh clone. These are real bugs
and we want to know.

**Version drift, which is guaranteed.** Every version in the docs was verified in
August 2026. Library versions rot, links rot, and recommendations rot faster than either —
`docs/infrastructure-specification.md` recommends redis-rs over `fred` because `fred` hadn't
published since February 2025. If that changes, the doc is wrong. Corrections to any of
this are among the most valuable things you can send, and the easiest to review.

**Better error messages.** The suite's most important property is that a failure explains
itself. Every assertion should state the rule and then what happened, to someone who hasn't
read the spec. If you hit a failure that left you confused, fixing that message helps every
future learner more than most code changes.

**New reference links.** A genuinely better doc than the one linked, a canonical blog post
that explains a concept a phase teaches, an upstream doc that moved.

**More chaos experiments.** `scripts/chaos.sh` catalogues twelve and scripts the first
eight; 9–12 currently print what they would need and skip, so implementing one of those is
a well-defined place to start. Failure modes worth adding beyond the twelve: partial network
partitions, disk pressure, slow-but-not-dead dependencies. The bar is that the experiment
must teach something specific, and must state in its output what the *correct* behaviour
looks like.

**Platform fixes.** The stack is developed on Linux. Apple Silicon (`linux/arm64` image
availability, Rosetta fallbacks, performance cliffs on bind mounts) and Windows/WSL2 (line
endings, path translation, Docker Desktop socket paths) both have sharp edges we may not
have hit. Concrete fixes and clear bug reports are equally welcome.

**Spec corrections.** If a spec document says something that is wrong, ambiguous, or
contradicts `docs/openapi.yaml`, that's a bug in the teaching material. Those matter more
than bugs in code — a learner who follows a wrong instruction loses a day and may never find
out why.

---

## Changing the OpenAPI contract

`docs/openapi.yaml` is **normative**. When any document disagrees with it, it wins. It is
also the thing every implementation, every conformance test and the Schemathesis run are all
measured against.

That means a change there is not a local change. It's a change that every person working
through this project has to follow, in up to five languages, possibly after they'd already
made that part green.

Also, CI enforces it: the `conformance` job runs `oasdiff breaking` against the base branch
with `--fail-on ERR`. A breaking change fails the build, by design.

**So: open an issue or a discussion before writing the PR.** Include what's wrong today,
what it should say, whether it's breaking, and how many tests move. Non-breaking additions
(a new optional response field, a clarified description, a missing example) are usually
straightforward. Anything that changes an existing status code, field name, required-ness or
type needs a real conversation and probably a note in the roadmap for people mid-project.

---

## Adding a test

Read `tests/conformance/README.md` first — it documents the fixtures and the report format.
The short version:

1. **Put it in the file for its phase.** `tests/conformance/test_phase4_cache.py` and so on.
   The module-level `pytestmark` supplies the phase marker; you don't add one by hand, and
   you don't put a Phase 4 test in the Phase 1 file. `--strict-markers` is on, so a typo is
   an error rather than a silent "0 tests selected".
2. **Take a fixture, never build a client by hand.** `api`, `user`, `second_user`, `task`,
   `seeded_user`, `new_client`. They handle the base URL, the 501 detection and the exchange
   recording that makes failures readable.
3. **Assert through `assertions.py`.** Those helpers already know the response envelope and
   already print the request and response on failure.
4. **Write the failure message for someone who hasn't read the spec.** State the rule, then
   what happened. `assert resp.status == 404, f"{user.impl}: reading another user's task
   returned {resp.status}. A 403 confirms the resource exists, which turns the ID space into
   an enumeration oracle. The contract is 404."`
5. **Mark it `@pytest.mark.slow` if it takes more than ~10 s**, `@pytest.mark.docker` if it
   needs the Docker CLI, `@pytest.mark.destructive` if it mutates shared infrastructure.

### Hermeticity — non-negotiable

The whole suite must run correctly under `pytest -n auto`. Concretely:

- **Unique emails, always.** Use the fixtures, which generate a UUID address per test. Never
  a literal `test@example.com`; two workers will collide and you'll get an intermittent 409
  that looks like an implementation bug.
- **No cross-test dependencies.** No test may rely on another having run, or on a particular
  order. Create what you need; don't reach for what someone else created.
- **No reliance on seed data** unless you take the `seeded_user` fixture, which owns its own
  corpus.
- **Shared-state tests carry `@pytest.mark.xdist_group(...)`.** Rate-limit buckets and
  container restarts are global. Group them so they land on one worker, and run with
  `--dist loadgroup`.
- **Clean up what you can**, but don't assume you can — the suite must survive a previous
  run having died halfway.

### Timing assertions

Anything asserting on latency **must sample repeatedly and compare a median or a p95**, never
a single measurement, and the threshold must be generous enough that a loaded laptop or a
shared CI runner doesn't trip it.

A flaky test is worse than no test: it trains people to re-run until green, which is exactly
the habit this project exists to break. If a threshold ever fires spuriously, the fix is to
widen it or sample more, never to add a retry.

---

## Dev setup

```bash
make setup      # .env with a generated JWT secret, test deps, tool check
make up         # Postgres, Valkey, S3 + the APIs (~400 MB, no broker)
make check      # phase 0 — the scaffold must be green before anything else
```

Then, before you push:

```bash
make validate   # OpenAPI 3.1, compose files, YAML, shellcheck, Lua syntax
make lint       # per-language linters (IMPL=go for just one)
```

`make validate` and `make lint` both run every tool inside a container, so you don't need
Go, Rust, Python, .NET and Node installed to contribute. A tool that can't be obtained is
reported SKIP rather than FAIL.

One host-tool caveat: `benchmark.sh`, `bench-cache.sh` and `soak.sh` keep per-implementation
results in associative arrays, so they need **bash 4+**. `profile.sh` and `pin-actions.sh` do
not — `pin-actions.sh` caches resolved SHAs as one file per key precisely so the script you
run once, right before publishing, never demands a shell upgrade first. macOS ships 3.2;
`brew install bash` covers it. They check and say so up front. If you write a new script,
prefer constructs that work on 3.2 — and if you can't, call `require_bash4` from
`lib/common.sh` rather than failing in the middle of a run.

`make help` lists everything.

Working on one language? `make languages LANGS=go` narrows every tool to match, which makes
the loop dramatically faster. Just remember to check the others before submitting anything
that touches shared harness code.

---

## Pull request checklist

- [ ] `make validate` passes.
- [ ] `shellcheck` is clean on any script you touched — `scripts/validate.sh --only shell`
      for just that check, or it's covered by the full `make validate`.
- [ ] `pytest --collect-only` works from `tests/` — collection errors break every phase gate
      at once, so this catches the worst class of mistake instantly.
- [ ] New tests carry the right phase marker (via the file's `pytestmark`) and pass under
      `-n auto`.
- [ ] Docs updated if behaviour changed. If you changed what a `make` target does, the README
      table and `make help` both need to agree with it.
- [ ] **This is not an implementation of a phase.** See the top of this file.

CI will run the rest: migrations up/down/up, the five language jobs, conformance across all
five, the oasdiff breaking-change check, secret and dependency scanning, and a 30-second k6
smoke test.

---

## Commit messages

Keep it light. A clear imperative summary line under ~72 characters, and a body explaining
*why* if the why isn't obvious from the diff.

Conventional Commits (`fix:`, `docs:`, `test:`) are welcome if that's your habit, and
completely optional if it isn't. Nothing is generated from them, no release automation
depends on them, and no PR will be blocked over formatting. "Fix flaky pagination test under
xdist" is a perfect commit message.

---

## Code of conduct

Participation is covered by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) — Contributor
Covenant 2.1.

## Security

Please don't open public issues for security problems. See [`SECURITY.md`](SECURITY.md),
which also lists the deliberately insecure local-development defaults that are **not**
vulnerabilities, so you can check before reporting.

---

## A note on response times

This is a side project maintained in spare time. Issues and pull requests may sit for a
while — sometimes a few weeks. That's not disinterest and it isn't a reflection on your
contribution.

If something has gone genuinely quiet, a single polite nudge on the thread is welcome and
won't annoy anyone.

Reviews will tend to focus on whether a change keeps the project *teachable*, which is
occasionally a different question from whether the code is good. If a change is declined on
those grounds, it will come with a reason, and it isn't a judgement of the work.
