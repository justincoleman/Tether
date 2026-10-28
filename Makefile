.PHONY: bootstrap mac phone phone-install test lint clean

bootstrap:
	./scripts/bootstrap.sh

Apps/Tether.xcodeproj:
	./scripts/bootstrap.sh

# Package-level tests. Pure Foundation, so this also runs on Linux.
test:
	swift test

mac: Apps/Tether.xcodeproj
	xcodebuild -project Apps/Tether.xcodeproj -scheme Tether -configuration Debug \
		-derivedDataPath build/mac CODE_SIGNING_ALLOWED=NO build

phone: Apps/Tether.xcodeproj
	xcodebuild -project Apps/Tether.xcodeproj -scheme TetherPhone -configuration Debug \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath build/phone \
		CODE_SIGNING_ALLOWED=NO build

phone-install:
	./scripts/phone-install.sh

clean:
	rm -rf build .build Apps/Tether.xcodeproj
