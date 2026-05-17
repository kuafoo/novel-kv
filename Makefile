.PHONY: build release package test clean help

VERSION := $(shell grep -oP '\.version\s*=\s*"\K[^"]+' build.zig.zon)
ARCH    := $(shell uname -m)
PKG     := novelkv-$(VERSION)-linux-$(ARCH)

build:
	zig build

release:
	zig build -Doptimize=ReleaseSafe
	$(strip_cmd) zig-out/bin/novelkv 2>/dev/null || true
	@echo "Release binary: $$(du -sh zig-out/bin/novelkv | cut -f1)"

package: release
	@./scripts/package.sh $(VERSION)

test:
	zig build test

clean:
	rm -rf zig-out .zig-cache dist

help:
	@echo "Targets:"
	@echo "  build    - Debug build"
	@echo "  release  - Release build (ReleaseSafe, stripped)"
	@echo "  package  - Build release + create tar.gz in dist/"
	@echo "  test     - Run tests"
	@echo "  clean    - Remove build artifacts"
