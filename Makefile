.PHONY: bootstrap mac phone phone-install test lint clean

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

mac: project
	xcodebuild -project Apps/Tether.xcodeproj -scheme Tether -configuration Debug \
		-derivedDataPath build/mac CODE_SIGNING_ALLOWED=NO build

phone: project
	xcodebuild -project Apps/Tether.xcodeproj -scheme TetherPhone -configuration Debug \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath build/phone \
		CODE_SIGNING_ALLOWED=NO build

phone-install:
	./scripts/phone-install.sh

clean:
	rm -rf build .build Apps/Tether.xcodeproj
