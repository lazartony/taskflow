# Security policy

## Read this first: the insecure defaults are deliberate

This repository ships a local development stack with **known-weak credentials and wide-open
access**, on purpose. Everything binds to localhost, nothing is exposed, and the alternative —
making a learner fight a secrets manager before they can run `make up` — would teach nothing
and stop most people at step one.

**None of the following are vulnerabilities. Please don't report them.**

| What | Where | Why it's fine |
|---|---|---|
| A literal JWT signing secret in the template | `.env.example` (`JWT_SECRET=change-me-…`) | `make setup` overwrites it with `openssl rand -hex 32` in your real `.env`, which is gitignored |
| Postgres password is `password` | `docker-compose.yml`, `.env.example` | Bound to localhost, holds throwaway data, dropped by `make clean` |
| Grafana runs with anonymous Admin and no login form | `docker-compose.observability.yml` (`GF_AUTH_ANONYMOUS_*`) | It's a dashboard over your own laptop's metrics |
| Everything is plaintext HTTP, no TLS anywhere | all compose files | Localhost. TLS termination is an infrastructure concern the project deliberately doesn't simulate |
| S3 storage with fixed dev credentials | `infrastructure/seaweedfs/` | Same reason |
| Containers reachable from the host on fixed ports | 8001–8005, 5432, 6379, 8333, 3000, 9090 | You need them to be, to run the harness |
| `CORS_ORIGINS` includes localhost dev servers | `.env.example` | That's what it's for |

Scanners will flag several of these. That's the scanner doing its job on a file that
deliberately looks like a mistake. If you're running this on a machine with a public IP or a
shared network, that's the thing to change — not the defaults.

The specs are explicit that production is different: see
`docs/resilience-and-security-specification.md` §8, and Phase 7 of the roadmap, which has you
replace the lot with SOPS + age, pinned JWT algorithms, refresh-token families and security
headers.

---

## What is worth reporting

Three categories, and the third is the one that actually matters for a teaching repository.

**1. A flaw in the harness that could leak a real secret.** The test suite, the scripts and
the CI workflows run on contributors' machines and in their GitHub accounts. Anything that
could exfiltrate or expose something real is serious. For example: a script that prints the
contents of `.env` into a log or an uploaded artifact; a workflow that would run untrusted PR
code with access to repository secrets (`pull_request_target` with an untrusted checkout);
a `make` target that writes a generated secret somewhere gitignored files don't cover; an
artifact upload with too broad a path glob.

**2. A supply-chain problem.** A dependency or container image here that is compromised,
typosquatted, or unmaintained-in-a-dangerous-way. A GitHub Action pinned to a tag rather than
a SHA (the March 2025 `tj-actions/changed-files` compromise worked by force-pushing over
existing tags, including major-version tags, across ~23,000 repositories — `make pin-actions`
exists because of it). An image reference that could resolve to something unexpected.

**3. An insecure pattern *taught* by the specs.** This is the important one, and it's
specific to what this project is.

If `docs/openapi.yaml`, a specification document, an example snippet, or a test's expected
behaviour would lead a learner to build something genuinely dangerous, that is the highest-
impact bug this repository can have. Nobody deploys TaskFlow — but people will carry what it
taught them into code that *is* deployed. A wrong lesson propagates.

Concretely, that includes: an example that verifies a JWT without pinning the algorithm; a
snippet vulnerable to SQL injection; a test that would pass an implementation returning 403
where 404 is required (403 confirms existence and turns the ID space into an enumeration
oracle); guidance on password storage, session handling, file-upload validation or CORS that
is out of date or subtly wrong; a rate-limiting design with a bypass.

Please report these even if you're not certain. "This example looks like it would teach the
wrong thing" is a perfectly good report, and it doesn't have to be a proven exploit.

---

## How to report

Use **GitHub's private security advisories**:

> **Security** → **Report a vulnerability**
> <https://github.com/lazartony/taskflow/security/advisories/new>

That gives us a private thread, and a way to credit you when it's resolved.

Please don't open a public issue for anything in the three categories above. For anything in
the table at the top — the deliberate defaults — a public issue is completely fine, though
you'll probably just get a link back to this page.

Include what you'd want to receive: what's wrong, where, what an attacker gets out of it, and
how to reproduce it. For category 3, a sentence on what a learner would plausibly build after
reading the passage is more useful than a CVSS score.

## What happens next

This is a side project, so the honest version rather than a service-level agreement:

- **Acknowledgement:** usually within a week.
- **Assessment:** we'll tell you whether it's being treated as a security issue, an ordinary
  bug, or a documented-and-intentional default, and why.
- **Fix:** category 1 and 2 issues get priority. Category 3 fixes ship as documentation
  changes, which is the fastest path there is.
- **Credit:** you'll be named in the advisory and the changelog entry unless you'd rather not
  be.

There is no bug bounty. There is no production deployment, no user data and no service — the
blast radius of anything here is a contributor's laptop, which is exactly why category 1
matters more than it looks.

## Scope

**In scope:** everything in this repository — the harness, scripts, compose files, CI
workflows, migrations, the OpenAPI contract, the specification documents and the five
skeletons.

**Out of scope:** vulnerabilities in upstream projects (report those to Postgres, Valkey,
Grafana, and so on — though do tell us if this repo pins an affected version); anything
arising from exposing the local stack to an untrusted network; and any implementation of the
phases, including your own. The skeletons return 501 for a reason: there is almost no
application code here to be vulnerable yet.
