# Command Line Tools ship the Swift Testing macros but SwiftPM doesn't find them; Xcode doesn't need this.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing
APP := ReviewDesk.app
INSTALL_DIR := /Applications
# `open` passes this shell's environment to the app; drop GitHub tokens (e.g. from direnv) so gh uses its
# own active login, exactly as when launched from Finder.
LAUNCH := env -u GH_TOKEN -u GITHUB_TOKEN open

.PHONY: test app run icon install

test:
	swift test -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS)

# Notifications need a real bundle, so wrap the release binary and sign it ad hoc (no sandbox: the app spawns CLIs).
app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/ReviewDesk $(APP)/Contents/MacOS/
	cp assets/Info.plist $(APP)/Contents/
	mkdir -p $(APP)/Contents/Resources
	cp assets/AppIcon.icns $(APP)/Contents/Resources/
	codesign --force --sign - $(APP)

run: app
	$(LAUNCH) $(APP)

# Replaces the copy in /Applications and starts it. The repo build is removed so macOS doesn't have two
# apps with the same bundle id (notification clicks could otherwise open the wrong one).
install: app
	-osascript -e 'quit app "ReviewDesk"' 2>/dev/null
	@sleep 1; pkill -x ReviewDesk 2>/dev/null; true
	rm -rf $(INSTALL_DIR)/$(APP)
	ditto $(APP) $(INSTALL_DIR)/$(APP)
	rm -rf $(APP)
	$(LAUNCH) $(INSTALL_DIR)/$(APP)

# Regenerates assets/AppIcon.icns from the drawing in assets/make-icon.swift.
icon:
	rm -rf .build/AppIcon.iconset && mkdir -p .build/AppIcon.iconset
	swift assets/make-icon.swift .build/AppIcon-1024.png
	for size in 16 32 128 256 512; do \
		sips -z $$size $$size .build/AppIcon-1024.png --out .build/AppIcon.iconset/icon_$${size}x$${size}.png >/dev/null; \
		sips -z $$((size * 2)) $$((size * 2)) .build/AppIcon-1024.png --out .build/AppIcon.iconset/icon_$${size}x$${size}@2x.png >/dev/null; \
	done
	iconutil -c icns .build/AppIcon.iconset -o assets/AppIcon.icns
