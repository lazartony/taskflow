.DEFAULT_GOAL := help
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

COMPOSE_CORE  := -f docker-compose.yml
COMPOSE_INFRA := -f docker-compose.yml -f docker-compose.infra.yml
COMPOSE_FULL  := -f docker-compose.yml -f docker-compose.infra.yml -f docker-compose.observability.yml

IMPL  ?= all
PHASE ?= 0
SIZE  ?= small
LANGS ?=

BOLD := \033[1m
DIM  := \033[2m
GRN  := \033[32m
YEL  := \033[33m
RST  := \033[0m

## ─────────────────────────── help ───────────────────────────

help: ## Show this help
	@echo ""
	@printf "$(BOLD)TaskFlow$(RST) — production backend engineering, one phase at a time\n"
	@echo ""
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(BOLD)%-22s$(RST) %s\n", $$1, $$2}'
	@echo ""
	@printf "$(DIM)  Variables: IMPL=go|rust|python|csharp|typescript|all  PHASE=0..11  SIZE=small|large|huge$(RST)\n"
	@printf "$(DIM)  First time?  make setup && make up && make check$(RST)\n"
	@echo ""

## ─────────────────────────── setup ───────────────────────────

setup: ## One-time setup: .env, test deps, tool check
	@test -f .env || { cp .env.example .env; \
	  SECRET=$$(openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | xxd -p -c64); \
	  sed -i.bak "s|^JWT_SECRET=.*|JWT_SECRET=$$SECRET|" .env && rm -f .env.bak; \
	  printf "$(GRN)created .env with a random JWT_SECRET$(RST)\n"; }
	@pip install -q -r tests/conformance/requirements.txt
	@command -v docker >/dev/null || { echo "docker is required"; exit 1; }
	@docker compose version >/dev/null || { echo "docker compose v2 is required"; exit 1; }
	@printf "$(GRN)ready.$(RST) Next:  make up\n"

## ─────────────────────────── stack ───────────────────────────

# `docker compose up --wait` treats ANY exited container as a failure — even one
# that exited 0 having done exactly its job. The one-shot jobs below are supposed
# to run once and stop, so waiting on them turns a healthy stack into
# "container taskflow-valkey-init exited (0)" and a non-zero make.
#
# (Compose makes an exception for a service someone depends on with
# service_completed_successfully, which is why `migrate` never tripped this and
# the three initialisers did.)
#
# So: start everything, then wait only on the services that are meant to stay up.
# `config --services` honours COMPOSE_PROFILES, so a one-language project waits
# on one API rather than five that will never arrive.
ONESHOT_SERVICES := migrate valkey-init valkey-streams-init seaweedfs-init redpanda-init
ONESHOT_FILTER   := grep -vxF $(foreach s,$(ONESHOT_SERVICES),-e $(s))

define compose_up_wait
	docker compose $(1) up -d --build
	docker compose $(1) up -d --no-recreate --wait \
	  $$(docker compose $(1) config --services | $(ONESHOT_FILTER) | tr '\n' ' ')
endef

up: ## Start Postgres + infra + all five APIs
	$(call compose_up_wait,$(COMPOSE_INFRA))
	@$(MAKE) --no-print-directory status

up-full: ## Start everything including the observability stack
	$(call compose_up_wait,$(COMPOSE_FULL))
	@echo ""
	@printf "  Grafana        $(BOLD)http://localhost:3000$(RST)\n"
	@printf "  Prometheus     http://localhost:9090\n"
	@printf "  SeaweedFS      http://localhost:9333\n"
	@printf "$(DIM)  Redpanda UI    only with the optional kafka profile$(RST)\n"
	@echo ""

up-one: ## Start one implementation only (IMPL=go)
	@test "$(IMPL)" != "all" || { echo "up-one needs a single language, e.g. make up-one IMPL=go"; exit 2; }
	docker compose $(COMPOSE_INFRA) up -d --build --wait postgres valkey seaweedfs $(IMPL)-api

down: ## Stop everything, keep data
	docker compose $(COMPOSE_FULL) down --remove-orphans

clean: ## Stop everything and delete all volumes
	docker compose $(COMPOSE_FULL) down -v --remove-orphans
	@rm -rf reports/ benchmarks/results/* profiles/*
	@printf "$(YEL)all data and results removed$(RST)\n"

restart: ## Rebuild and restart one implementation (IMPL=go)
	docker compose $(COMPOSE_INFRA) up -d --build --force-recreate $(IMPL)-api

logs: ## Tail logs (IMPL=go for one service)
	@if [ "$(IMPL)" = "all" ]; then docker compose $(COMPOSE_FULL) logs -f --tail=100; \
	else docker compose $(COMPOSE_FULL) logs -f --tail=100 $(IMPL)-api; fi

status: ## Show which services are up and healthy
	@./scripts/status.sh

languages: ## Choose active languages (LANGS=go | go,rust | all); no arg shows current
	@./scripts/use-languages.sh $(LANGS)

## ─────────────────────────── the loop you live in ───────────────────────────

check: ## Run one phase against one or all languages (PHASE=1 IMPL=go)
	@./scripts/check-phase.sh $(PHASE) $(IMPL)

progress: ## Full dashboard: every phase, every language
	@./scripts/progress.sh

test: check ## Alias for check

conformance: ## Schemathesis property-based conformance against all five
	@./scripts/conformance.sh

diff: ## Differential test — do all five return identical shapes?
	@pytest tests/conformance/test_differential.py -v --impl all

## ─────────────────────────── data ───────────────────────────

seed: ## Seed deterministic data (SIZE=small|large|huge)
	@./scripts/seed.sh --size $(SIZE)

migrate: ## Apply pending migrations
	@./scripts/migrate.sh up

migrate-down: ## Roll back one migration
	@./scripts/migrate.sh down 1

migrate-test: ## Verify up → down → up leaves an identical schema
	@./scripts/migrate.sh test

psql: ## Open a psql shell
	@docker exec -it taskflow-db psql -U postgres -d taskflow_dev

valkey-cli: ## Open a valkey shell
	@docker exec -it taskflow-valkey valkey-cli

## ─────────────────────────── performance ───────────────────────────

bench: ## Full benchmark, fair-comparison rules enforced (IMPL=all)
	@./scripts/benchmark.sh --impl $(IMPL)

bench-quick: ## Single short run, for iterating
	@./scripts/benchmark.sh --impl $(IMPL) --quick

bench-cache: ## THE cache A/B — proves what Valkey actually buys you
	@./scripts/bench-cache.sh --impl $(IMPL)

soak: ## 1 hour soak test — finds leaks a 5-minute run cannot
	@./scripts/soak.sh --impl $(IMPL)

profile: ## Capture CPU + heap profiles under load
	@./scripts/profile.sh --impl $(IMPL)

profile-diff: ## Profile with cache on vs off, diff the flamegraphs (one language)
	@./scripts/profile-diff.sh --impl $(if $(filter all,$(IMPL)),go,$(IMPL))

## ─────────────────────────── quality ───────────────────────────

lint: ## Lint one language, or all (IMPL=go)
	@./scripts/lint.sh $(IMPL)

lint-migrations: ## Squawk — catch migrations that lock the table
	@./scripts/lint-migrations.sh

validate: ## Validate OpenAPI, compose files and configs
	@./scripts/validate.sh

slo: ## Regenerate Prometheus SLO rules from observability/slo/taskflow.yaml
	@docker run --rm -v "$$PWD:/w" -w /w ghcr.io/slok/sloth:v0.16.0 \
	  generate -i observability/slo/taskflow.yaml -o observability/prometheus/rules/slo.yaml
	@docker compose $(COMPOSE_FULL) exec -T prometheus \
	  wget -qO- --post-data='' http://localhost:9090/-/reload || true
	@printf "$(GRN)SLO rules regenerated$(RST)\n"

pin-actions: ## Replace GitHub Action tags with commit SHAs (do before going public)
	@./scripts/pin-actions.sh

## ─────────────────────────── chaos ───────────────────────────

chaos: ## Run a chaos experiment (N=1..12) — see the resilience spec
	@./scripts/chaos.sh $(N)

.PHONY: help setup up up-full up-one down clean restart logs status languages check progress \
        test conformance diff seed migrate migrate-down migrate-test psql valkey-cli \
        bench bench-quick bench-cache soak profile profile-diff lint lint-migrations \
        validate slo pin-actions chaos
