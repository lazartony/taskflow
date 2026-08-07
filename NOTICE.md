# Third-party licences

**This repository is MIT (see [`LICENSE`](LICENSE)).** That covers the specs, the test
suite, the scripts, the compose files and the five skeletons — everything actually
written here.

It does not cover the software this project *runs*. `make up` pulls about a dozen
container images, and `go.mod`, `Cargo.toml`, `pyproject.toml`, `package.json` and
`TaskFlow.Api.csproj` pull several hundred libraries between them. Those carry their own
licences, and a few of them are more interesting than "Apache 2.0, next".

**If you are working through this project on your own machine, none of this affects you.**
Running AGPL software locally, unmodified, triggers no obligation whatsoever. This page
exists for the other case: the day you take this stack — or half of it — into something
you ship or sell. Licence awareness is one of the things this project deliberately teaches,
and the honest way to teach it is to name the real situations rather than gesture at them.

---

## The ones worth reading before you copy this stack

### Valkey — BSD-3-Clause (Linux Foundation)

`valkey/valkey:9.1-alpine`, used as the cache, the rate-limiter host and the Phase 6 event
transport.

Redis's licence moved twice in two years:

- **March 2024** — Redis Ltd. took core Redis off BSD-3-Clause to a dual RSALv2 / SSPLv1
  arrangement. Neither is OSI-approved. The Linux Foundation forked the last BSD-licensed
  commit as **Valkey**.
- **May 2025** — Redis 8.0 added **AGPLv3** as a third option. Redis is now tri-licensed:
  RSALv2 **or** SSPLv1 **or** AGPLv3, your choice.
- **August 2026** — Valkey is at 9.1, still BSD-3-Clause, governed by the Linux Foundation.
  AWS ElastiCache and Aiven default new provisioning to it.

This project targets Valkey because BSD-3-Clause is permissive with no network-copyleft
question to answer, because it is wire-compatible with Redis (RESP2/RESP3, so every command
and every client carries over), and because the managed providers have already moved.

Everything here works unchanged on Redis 8 — swap the image. Redis under AGPLv3 is a
perfectly reasonable choice for a learning project; AGPL's network clause only bites if you
offer the *database itself* as a service. The RSALv2/SSPLv1 paths are the ones to avoid if
you intend to redistribute.

- <https://valkey.io/> · <https://github.com/valkey-io/valkey/blob/unstable/COPYING>

### Redpanda — BSL 1.1 (source-available, **not** open source)

`redpandadata/redpanda`, `redpandadata/console`. **Optional here.** Redpanda sits behind the
`kafka` compose profile and is used only by the Kafka appendix in
`docs/infrastructure-specification.md` — it is not started by `make up`, and no phase
requires it.

The Business Source Licence is source-available, not OSI open source: you may read, modify
and use it, but not offer it as a commercial streaming service, and each release converts to
Apache 2.0 four years after publication. Fine for local learning, a conversation with your
legal team for anything else.

This is worth noticing precisely because BSL projects are usually described as "open source"
in blog posts and conference talks. Reading the licence file takes a minute.

- <https://github.com/redpanda-data/redpanda/blob/dev/licenses/bsl.md>

### SeaweedFS — Apache 2.0

`chrislusf/seaweedfs`, the S3-compatible object store used from Phase 10.

Most tutorials still reach for MinIO here. `minio/minio` was **archived by its owner on
25 April 2026** and is read-only: no fixes, no CVE responses, no releases. The image still
pulls, which is exactly what makes it a trap.

Checking whether a project is still alive before adopting it costs about thirty seconds and
is a genuine production skill. That is why the substitution is called out rather than made
silently.

- <https://github.com/seaweedfs/seaweedfs/blob/master/LICENSE>

---

## The observability stack — AGPLv3

| Component | Image | Licence |
|---|---|---|
| Grafana | `grafana/grafana:13.0.3` | AGPLv3 |
| Loki | `grafana/loki:3.8.0` | AGPLv3 |
| Tempo | `grafana/tempo:3.0.2` | AGPLv3 |
| Pyroscope | `grafana/pyroscope:2.0.0` | AGPLv3 |
| k6 | `grafana/k6:1.8.0` | AGPLv3 |

Grafana Labs relicensed from Apache 2.0 to AGPLv3 in 2021. Running these unmodified — which
is all this project does, all any normal deployment does — carries no obligation. The
network clause is about *modified* versions offered to users over a network. If you fork
Grafana and host the fork as a product, you owe your users the source; if you run the
official image and point it at your own data, you do not.

Worth knowing anyway, because "we can't use AGPL software at all" is a common blanket policy
and it is usually wrong about this specific case.

- <https://github.com/grafana/grafana/blob/main/LICENSE> · <https://github.com/grafana/k6/blob/master/LICENSE>

## The permissive remainder

| Component | Image | Licence |
|---|---|---|
| PostgreSQL | `postgres:17-alpine` | PostgreSQL Licence (permissive, BSD/MIT-like) |
| Prometheus | `prom/prometheus:v3.13.2` | Apache 2.0 |
| OpenTelemetry Collector (contrib) | `otel/opentelemetry-collector-contrib:0.158.0` | Apache 2.0 |
| golang-migrate | `migrate/migrate:v4.19.1` | MIT |
| Sloth (SLO rule generator) | `ghcr.io/slok/sloth:v0.16.0` | Apache 2.0 |
| squawk, shellcheck, yamllint (lint tooling) | various | MIT / GPLv3 (tools only, run in containers, never linked) |

Note that container images bundle an operating system as well as the application, so an
image's stated licence is the *application's*. `docker sbom` or Trivy will show you the rest;
Phase 7 has you generate SBOMs for exactly this reason.

---

## Per-language dependencies

Enumerating a few hundred libraries here would be stale within a month and is the kind of
list nobody reads. Each implementation declares its own, with versions:

| | Manifest | Lock file |
|---|---|---|
| Go | `go/go.mod` | `go/go.sum` |
| Rust | `rust/Cargo.toml` | `rust/Cargo.lock` |
| Python | `python/pyproject.toml` | — |
| C# | `csharp/TaskFlow.Api/TaskFlow.Api.csproj` | — |
| TypeScript | `typescript/package.json` | `typescript/package-lock.json` |
| Test harness | `tests/conformance/requirements.txt` | — |

They are overwhelmingly MIT, Apache 2.0 or BSD. If you want the real answer rather than a
generalisation, generate it:

```bash
go -C go run github.com/google/go-licenses@latest report ./...
cargo license --manifest-path rust/Cargo.toml
pip-licenses
dotnet list csharp/TaskFlow.sln package --include-transitive
npx license-checker --prefix typescript
```

Phase 7 builds this into CI properly, with SBOMs in both SPDX and CycloneDX. That is not
busywork — under the EU Cyber Resilience Act, reporting obligations begin September 2026 and
full compliance (SBOM in technical documentation, ten-year retention) lands 11 December 2027.
See `docs/resilience-and-security-specification.md`.

---

## Summary

- **This repo:** MIT. Take it, fork it, teach from it.
- **What it runs:** mostly permissive; AGPLv3 for the Grafana stack; BSL for the optional
  Redpanda appendix.
- **Learning on your laptop:** no obligations, from any of them.
- **Building a product on the same stack:** read the Redpanda BSL and decide about the
  Grafana components deliberately rather than by accident. That decision is the lesson.
