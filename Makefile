.PHONY: help check build test install install-with-wake-listener package clean

help:
	@printf '%s\n' \
	  'make check                       Type-check and scan source files' \
	  'make build                       Build universal app bundles' \
	  'make test                        Run checks, clean build, and RPC smoke test' \
	  'make install                     Build and install Pi Space' \
	  'make install-with-wake-listener  Install Pi Space and voice listener' \
	  'make package                     Create versioned release archives' \
	  'make clean                       Remove generated output'

check:
	./scripts/check.sh

build:
	./scripts/build.sh

test:
	./scripts/test.sh

install:
	./scripts/install.sh

install-with-wake-listener:
	./scripts/install.sh --with-wake-listener

package:
	./scripts/package.sh

clean:
	rm -rf build dist release
