PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin

INSTALL = install -m 755

.DEFAULT_GOAL := help

.PHONY: help install uninstall check

help:
	@echo "mac-cleaner make targets:"
	@echo "  make help                 Show this help message"
	@echo "  make check                Run syntax checks and ShellCheck when available"
	@echo "  make install              Install to $(BINDIR)/mac-cleaner"
	@echo "  make install PREFIX=...   Install under a custom prefix"
	@echo "  make uninstall            Remove $(BINDIR)/mac-cleaner"

check:
	bash -n mac-cleaner.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck mac-cleaner.sh; \
	else \
		echo "shellcheck not found; skipping"; \
	fi

install:
	@mkdir -p $(BINDIR)
	$(INSTALL) mac-cleaner.sh $(BINDIR)/mac-cleaner
	@echo "mac-cleaner.sh has been installed to $(BINDIR)/mac-cleaner"

uninstall:
	rm -f $(BINDIR)/mac-cleaner
	@echo "mac-cleaner has been removed from $(BINDIR)/mac-cleaner"
