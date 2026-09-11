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
.PHONY: help deps check test smoke api e2e demo web serve real-gateway install uninstall fmt ci clean

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
	$(MOON) run --target native scripts/smoke.mbtx

api:  ## the server HTTP contract: overrides, exports, traversal guards
	$(MOON) run --target native scripts/server-api.mbtx

e2e:  ## browser end to end; needs chromium, and it is slow
	bash scripts/web-e2e.sh

# The one target that needs a real endpoint: export MOONLLM_BASE_URL,
# MOONLLM_API_KEY and MOONLLM_MODEL first. Deliberately not part of `make ci`.
real-gateway:  ## probes against a real gateway; needs a key, not in CI
	$(MOON) run --target native scripts/real-gateway.mbtx

# `moon install` copies the built main packages into a bin directory. The default
# is the MoonBit toolchain's own ~/.moon/bin: a **per-user** directory, no sudo,
# nothing touched outside your home. It is that way because that directory is
# already on PATH — that is the whole point — not because it is a system
# location. Override BIN_DIR to put the binaries somewhere else instead.
BIN_DIR ?= $(HOME)/.moon/bin

install:  ## install the CLIs into $BIN_DIR (per-user, no sudo)
	@echo "installing faceoff + bench into $(BIN_DIR)"
	@echo "（家目录下的普通目录，不需要 sudo，不动系统）"
	$(MOON) install ./cmd/... --bin "$(BIN_DIR)"
	@echo
	@echo "装好了：$(BIN_DIR)/faceoff、$(BIN_DIR)/bench"
	@echo "撤掉：make uninstall（或直接 rm 那两个文件）"

uninstall:  ## remove the CLIs from $BIN_DIR
	rm -f "$(BIN_DIR)/faceoff" "$(BIN_DIR)/bench"
	@echo "已从 $(BIN_DIR) 移除 faceoff、bench"

demo:  ## zero-API-key demo of all three paths
	$(MOON) run --target native scripts/demo.mbtx

web:  ## build the page and the static report
	$(MOON) run --target native scripts/build-web.mbtx

# 服务端必须从 web/ 启动：out/、runs/、cases/、presets.json 都是按工作目录解析的，
# 从仓库根起会「/api 通、页面全 404」。这个目标把 cd 做掉，省得每次记。
serve:  ## build the page, then start the server from web/ (Ctrl-C to stop)
	$(MOON) run --target native scripts/build-web.mbtx
	@echo
	@echo "打开 http://127.0.0.1:$${LLM_WEB_PORT:-8137}/  （Ctrl-C 停）"
	cd web && ./_build/native/debug/build/cmd/server/server.exe

fmt:  ## format, and refresh the generated .mbti
	$(MOON) fmt
	$(MOON) info
	cd web && $(MOON) fmt
	cd web && $(MOON) info

ci: deps check test smoke web api  ## the deterministic suite CI runs
	@echo
	@echo "ci: ok"

clean:  ## remove build outputs; keeps web/runs, which is your data
	rm -rf _build scripts/_build web/_build web/out
