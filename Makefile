.PHONY: bootstrap mac phone phone-install test lint clean run run-log stop dev

bootstrap:
	./scripts/bootstrap.sh

# Regenerate the project on every build so new source files are picked up.
# xcodegen only rewrites the file when the spec or file list changed.
.PHONY: project
project:
	@command -v xcodegen >/dev/null || ./scripts/bootstrap.sh
	@cd Apps && xcodegen generate --spec project.yml --quiet

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

clean:
	rm -rf build .build Apps/Tether.xcodeproj
