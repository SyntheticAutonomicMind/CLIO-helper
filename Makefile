# CLIO-helper Makefile
# SPDX-License-Identifier: GPL-3.0-only

PERL = perl

.PHONY: help version test release install

help:
	@printf "clio-helper %s\n" "$$(grep 'our $$VERSION' clio-helper | head -1 | sed "s/.*'\(.*\)'.*/\1/")"
	@echo ""
	@echo "Targets:"
	@echo "  make version        - Show current version"
	@echo "  make test           - Run tests"
	@echo "  make release VERSION=YYYYMMDD.N - Prepare a release"
	@echo "  make install        - Install (runs install.sh)"
	@echo ""

version:
	@grep 'our $$VERSION' clio-helper | head -1 | sed "s/.*'\\(.*\\)'.*/\\1/"

test:
	@echo "Running tests..."
	@$(PERL) -I./lib t/guardrails.t
	@echo "All tests passed."

release:
	@if [ -z "$(VERSION)" ]; then \
		echo "Usage: make release VERSION=YYYYMMDD.N"; \
		echo "Example: make release VERSION=20260415.1"; \
		exit 1; \
	fi
	@./scripts/release.sh $(VERSION)

install:
	@./install.sh
