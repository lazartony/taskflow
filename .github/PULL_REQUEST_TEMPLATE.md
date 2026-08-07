<!-- Keep this short. The checklist matters more than the prose. -->

## This is not an implementation of a phase

- [ ] **Confirmed: this PR does not implement any part of Phases 1–11 in any language.**

The unfinished phases are the exercise — merging a completed one removes it for everyone
else. If that is what you have built, it is welcome, just not here: put it in your own fork
or a `solutions/` branch and add yourself to the "Built with TaskFlow" list — see
`CONTRIBUTING.md`.

## Type of change

- [ ] Bug fix — harness, tests, scripts or compose
- [ ] Documentation — version drift, dead link, correction, clarification
- [ ] New test, or a test made less flaky
- [ ] New chaos experiment
- [ ] Platform fix (Apple Silicon, Windows/WSL, other)
- [ ] Better error or failure message
- [ ] OpenAPI contract change — **was this discussed in an issue first?** #
- [ ] Other:

## What it does

<!-- A couple of sentences. If it fixes an issue, "Fixes #123". -->

## Checklist

- [ ] `make validate` passes
- [ ] `shellcheck` clean on any script touched (`scripts/validate.sh --only shell`)
- [ ] `pytest --collect-only` works from `tests/`
- [ ] New tests carry the right phase marker and pass under `-n auto`
- [ ] New tests use unique per-test users and depend on no other test
- [ ] Timing assertions sample repeatedly and use a generous threshold
- [ ] Docs updated if behaviour changed (README table, `make help`, the relevant spec)
- [ ] Verified against more than one language, if it touches shared harness code
