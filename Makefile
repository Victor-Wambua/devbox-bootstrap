.PHONY: deps test lint docs docs-check try

BATS := ./node_modules/bats/bin/bats

deps:
	@test -x $(BATS) || npm install --no-audit --no-fund

# runs the whole suite against the mocked machine; touches nothing real
test: deps
	$(BATS) --print-output-on-failure tests

lint:
	shellcheck bin/devbox lib/*.sh scripts/*.sh tests/helpers/*.sh tests/helpers/*.bash tests/mocks/*

# regenerate Brewfiles, docs/ and the captured terminal sessions
docs:
	bash scripts/build-docs.sh

# fail if the committed Brewfiles or docs are stale
docs-check: docs
	git diff --exit-code -- Brewfiles docs

# try devbox on a throwaway mocked machine: make try ARGS="plan --profile php-laravel"
try:
	scripts/try.sh -- $(ARGS)
