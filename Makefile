# faceoff — task runner.
#
# Thin wrappers over the moon CLI and the scripts in scripts/. The scripts stay
# the source of truth, so what CI runs and what you run by hand cannot drift.
#
#   make          list the targets
#   make ci       the deterministic suite (this is what CI runs)

# Native builds on Linux need the C compiler named explicitly; without it the
# toolchain goes looking for an archiver at /usr/bin/lib.exe. `?=` so a value
# you already exported wins.
export MOON_CC ?= gcc

MOON ?= moon
SHELL := /bin/bash

.DEFAULT_GOAL := help
.PHONY: help deps check test smoke api e2e demo web fmt ci clean

help:  ## list these targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

deps:  ## fetch dependencies for both modules
	$(MOON) update
	cd web && $(MOON) update

check:  ## type-check the root (native) and web (native + js)
	$(MOON) check --target native
	cd web && $(MOON) check --target native
	cd web && $(MOON) check --target js

test:  ## unit tests, both modules
	$(MOON) test --target native
	cd web && $(MOON) test --target native

smoke:  ## the CLIs end to end, against a local mock endpoint
	bash scripts/smoke.sh

api:  ## the server HTTP contract: overrides, exports, traversal guards
	bash scripts/server-api.sh

e2e:  ## browser end to end; needs chromium, and it is slow
	bash scripts/web-e2e.sh

demo:  ## zero-API-key demo of all three paths
	bash scripts/demo.sh

web:  ## build the page and the static report
	bash web/build.sh

fmt:  ## format, and refresh the generated .mbti
	$(MOON) fmt
	$(MOON) info
	cd web && $(MOON) fmt
	cd web && $(MOON) info

ci: deps check test smoke api web  ## the deterministic suite CI runs
	@echo
	@echo "ci: ok"

clean:  ## remove build outputs; keeps web/runs, which is your data
	rm -rf _build scripts/_build web/_build web/out
