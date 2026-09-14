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
.PHONY: help deps check test smoke api e2e demo web serve dev serve-demo real-gateway install uninstall fmt ci clean

help:  ## list these targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

# 只在动过 moon.mod / 需要刷新注册表时手动跑。ci 里不再自动跑它：
# moon update 要走网络（实测 6-45s），本地迭代每次付这个钱不值当；
# 缺依赖时 moon check 会自己报错，比默默花掉半分钟更好懂
deps:  ## fetch deps / refresh the registry (run by hand, not part of ci)
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

e2e:  ## browser end to end; needs chromium (~1 min, was ~4)
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
#
# 这是 release 的用法：构建一次、起一个服务端，进程不动。想边改边看用 `make dev`
serve:  ## build, then serve the page from web/ (Ctrl-C to stop)
	$(MOON) run --target native scripts/build-web.mbtx
	@echo
	@echo "打开 http://127.0.0.1:$${LLM_WEB_PORT:-8137}/  （Ctrl-C 停）"
	cd web && ./_build/native/debug/build/cmd/server/server.exe

dev:  ## dev server: build, serve, rebuild on change (Ctrl-C to stop)
	bash scripts/dev.sh

# 演示：本地假端点 + 一套演示数据 + 页面，先把两次评测跑好再交给你。
# 演示数据全在临时目录，退出即删，不碰你自己的 runs / cases / presets。
# 注：写成 serve-demo 而不是 serve:demo —— GNU Make 不接受目标名里的转义冒号
serve-demo:  ## demo: mock endpoint + demo data + page (Ctrl-C to stop)
	bash scripts/serve-demo.sh

fmt:  ## format, and refresh the generated .mbti
	$(MOON) fmt
	$(MOON) info
	cd web && $(MOON) fmt
	cd web && $(MOON) info

# ci 的真身在 scripts/ci.sh：按「抢哪个构建目录」分三条通道并行
# （root / web / e2e），通道内保持串行。Makefile 只做一层壳
ci:  ## the deterministic suite CI runs（三条通道并行）
	bash scripts/ci.sh

clean:  ## remove build outputs; keeps web/runs, which is your data
	rm -rf _build scripts/_build web/_build web/out
