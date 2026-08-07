# Publishing checklist

Everything file-based is already done. `lazartony/taskflow` is filled in throughout, and the
Code of Conduct points at GitHub's private channels rather than a published email address.

What's left is GitHub settings, one command, and a fresh-clone test.

> **Forking this?** Run `make init-repo` — it reads your `git remote` and re-points every
> reference at your own owner and repo name. Nothing here needs doing by hand.

---

## 1. Pin every GitHub Action to a SHA

```bash
GITHUB_TOKEN=$(gh auth token) make pin-actions
git diff .github/workflows/
```

Tags are mutable pointers. The March 2025 `tj-actions/changed-files` compromise worked by
force-pushing over existing tags — including major-version tags — across roughly 23,000
repositories. `v4` is not a version, it's a bookmark someone else can move.

Check the diff: every `uses:` should now be a 40-character SHA with the version in a trailing
comment. `.github/dependabot.yml` keeps them current from here on — Dependabot understands SHA
pins, bumps the SHA and rewrites the comment.

The token is only needed to avoid the GitHub API's unauthenticated rate limit. Do this
**before** the repository is public, not after.

---

## 2. Verify everything parses

```bash
make validate     # openapi, compose, image tags, yaml, shell, lua
```

All six checks should pass. The `images` check is worth watching — it verifies every pinned
container tag actually exists in its registry, which is how `grafana/loki:3.8.0` (a real
release that was never published under that tag) got caught before it broke anyone's first run.

The issue forms are only schema-checked by GitHub once they're on the default branch. If one is
malformed, GitHub silently falls back to a blank issue body with no error anywhere — so open a
test issue after publishing and confirm all three forms render.

---

## 3. Repository settings

None of this lives in a file.

### Branch protection on `main`

Settings → Branches → Add rule:

- Require a pull request before merging
- Require status checks to pass — select `validate`, `migrations`, `conformance` and `security`
  once each has run at least once and appears in the list
- Require branches to be up to date before merging
- No force pushes, no deletions

The `conformance` job runs `oasdiff breaking --fail-on ERR` against the base branch. That check
is the entire reason the contract stays trustworthy — make sure it's required.

### Secret scanning and push protection

Settings → Code security. Enable **both**:

- **Secret scanning** — catches a credential that already landed
- **Push protection** — blocks the push before it does

Push protection matters more than usual here. `.env.example` contains a literal string that
looks exactly like a JWT signing secret, and the realistic accident is somebody copying their
real `.env` over it. Push protection is what stops that at the last moment.

Enable Dependabot alerts and the dependency graph while you're on this page.

### Private vulnerability reporting

Settings → Code security → **Private vulnerability reporting: Enable**.

This one is load-bearing. `SECURITY.md`, `.github/ISSUE_TEMPLATE/config.yml` **and the Code of
Conduct** all point at `/security/advisories/new`, and that URL 404s until it's switched on —
which would leave the conduct policy with no working reporting channel at all.

### Discussions

Settings → Features → **Discussions**. The issue-template config links to it, and it's where
completed implementations are meant to go instead of into pull requests.

| Category | For |
|---|---|
| **Built with TaskFlow** | Finished implementations. Link the good ones from the README |
| **Stuck on a phase** | The overflow valve for the question issue form |
| **Benchmarks** | Cross-language numbers, with the caveats from `benchmarks/README.md` |
| **Contract proposals** | Where an OpenAPI change is discussed before anyone writes the PR |

Pin a welcome post explaining the "please don't PR your solutions" rule. It'll save you saying
it individually.

### Description and topics

Settings → General, and the About panel.

**Description** — say *learning project* out loud so nobody arrives expecting a framework:

> A production-grade backend API built five times over — Go, Rust, Python, C#, TypeScript —
> against one OpenAPI contract, one conformance suite and one benchmark harness. A learning
> project: the tests ship, the implementation is yours.

**Topics** — this is what search actually uses:

```
learning-project  backend  golang  rust  python  csharp  typescript
openapi  rest-api  postgresql  valkey  observability  opentelemetry
prometheus  grafana  docker-compose  load-testing  k6  chaos-engineering
conformance-testing
```

Set **website** to the roadmap if you don't have a site.

### Also worth doing

- Turn **Wikis** off — the docs are in `docs/`, and a second half-empty place to look helps
  nobody
- Turn **Projects** off unless you'll use it
- Add a `good first issue` label and apply it to two or three real ones before announcing. An
  empty issue tracker reads as an abandoned project

---

## 4. A last look before the switch

- [ ] `git log -p | grep -i 'JWT_SECRET=\|password'` over your own commits — confirm no real
      `.env` was ever committed. If one was, the history needs rewriting *and* the secret
      rotating; push protection only covers the future
- [ ] `git ls-files | grep '^\.env$'` returns nothing
- [ ] `make setup && make up && make check` passes from a **fresh clone in a clean directory** —
      not your working tree, which has state your readers won't
- [ ] Insights → Community Standards shows a tick for LICENSE, CONTRIBUTING, CODE_OF_CONDUCT,
      SECURITY and the issue/PR templates
- [ ] The README's opening paragraph still describes what you're actually shipping
- [ ] Delete this file, or move it to `docs/`

---

## What's deliberately *not* here

**No email address anywhere.** Publishing one guarantees scraper spam, which in practice means
the inbox stops being monitored — a reporting channel that quietly rots is worse than one
that's honestly limited. Conduct and security reports both route through GitHub's private
advisory form, which reaches you and nobody else. If the project grows past one maintainer,
revisit that.

**No `solutions/` branch.** Publishing answers to a project whose entire value is the exercise
would undo it. Point people at Discussions instead.

**The version pins will rot.** Every version in `docs/` was verified in August 2026, and the
docs say so. The `docs.yml` issue form exists specifically to collect drift reports — that's
the maintenance this project actually needs, and it's a good source of first issues.
