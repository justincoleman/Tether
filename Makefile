.PHONY: bootstrap mac phone phone-install test lint clean run run-log stop dev release ghostty-source

bootstrap:
	./scripts/bootstrap.sh

# Regenerate the project on every build so new source files are picked up.
# xcodegen only rewrites the file when the spec or file list changed.
# With .ghostty-source present (scripts/ghosttykit.sh), the spec is rewritten
# to use the libghostty built from source in Vendor/ instead of the package.
.PHONY: project
project:
	@command -v xcodegen >/dev/null || ./scripts/bootstrap.sh
ifneq ($(wildcard .ghostty-source),)
	@perl -0pe 's#(\n  libghostty-spm:\n)    url: [^\n]*\n    from: [^\n]*\n#$$1    path: ../Vendor/libghostty-spm\n#' \
		Apps/project.yml > Apps/project.source.yml
	@grep -q 'path: ../Vendor/libghostty-spm' Apps/project.source.yml || { echo "Couldn't point the spec at Vendor/libghostty-spm" >&2; exit 1; }
	@echo "libghostty: built from source (scripts/ghosttykit.sh --off to switch back)"
	@cd Apps && xcodegen generate --spec project.source.yml --quiet
else
	@cd Apps && xcodegen generate --spec project.yml --quiet
endif

# Package-level tests. Pure Foundation, so this also runs on Linux.
test:
	swift test

APP := build/mac/Build/Products/Debug/Tether.app

# -quiet prints only warnings and errors, so a failure is easy to find.
mac: project
	xcodebuild -quiet -project Apps/Tether.xcodeproj -scheme Tether -configuration Debug \
		-derivedDataPath build/mac CODE_SIGNING_ALLOWED=NO build
	@echo "Built $(APP)"

# Quit a running Tether (its Claude tabs resume on the next launch).
stop:
	-@pkill -x Tether
	@sleep 1

# Build, replace the running app, and launch it. Uses `open`, so it also works
# from an ssh session on a Mac with someone logged in.
run: mac stop
	open $(APP)

# Same, but runs the binary in this terminal so its log output is visible.
run-log: mac stop
	$(APP)/Contents/MacOS/Tether

# The usual loop: tests first, then build, then launch.
dev: test mac stop
	open $(APP)

phone: project
	xcodebuild -quiet -project Apps/Tether.xcodeproj -scheme TetherPhone -configuration Debug \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath build/phone \
		CODE_SIGNING_ALLOWED=NO build

phone-install:
	./scripts/phone-install.sh

# Developer ID build, notarized, published as a GitHub release (docs/RELEASING.md).
release:
	./scripts/release.sh

# Build libghostty from source and use it until scripts/ghosttykit.sh --off.
ghostty-source:
	./scripts/ghosttykit.sh

clean:
	rm -rf build .build Apps/Tether.xcodeproj
