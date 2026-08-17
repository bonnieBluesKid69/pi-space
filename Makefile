.PHONY: help check build test install update package clean

help:
	@printf '%s\n' \
	  'make check                       Type-check and scan source files' \
	  'make build                       Build universal app bundles' \
	  'make test                        Run checks, clean build, and RPC smoke test' \
	  'make install                     Build and install Pi Space' \
	  'make update                      Update from GitHub and reinstall' \
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

update:
	./scripts/update.sh

package:
	./scripts/package.sh

clean:
	rm -rf build dist release
