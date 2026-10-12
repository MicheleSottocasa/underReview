# Command Line Tools ship the Swift Testing macros but SwiftPM doesn't find them; Xcode doesn't need this.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing
APP := ReviewDesk.app

.PHONY: test app run

test:
	swift test -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS)

# Notifications need a real bundle, so wrap the release binary and sign it ad hoc (no sandbox: the app spawns CLIs).
app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/ReviewDesk $(APP)/Contents/MacOS/
	cp assets/Info.plist $(APP)/Contents/
	codesign --force --sign - $(APP)

run: app
	open $(APP)
