# Command Line Tools ship the Swift Testing macros but SwiftPM doesn't find them; Xcode doesn't need this.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing
APP := ReviewDesk.app
INSTALL_DIR := /Applications
# `open` passes this shell's environment to the app; drop GitHub tokens (e.g. from direnv) so gh uses its
# own active login, exactly as when launched from Finder.
LAUNCH := env -u GH_TOKEN -u GITHUB_TOKEN open
# Release version: Info.plist by default, overridden by the release workflow from the git tag.
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" assets/Info.plist)
BUILD ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
DIST := dist
# Empty = this Mac's architecture; the dmg target builds a universal (Apple silicon + Intel) app.
ARCH_FLAGS ?=

# Several copies of the app under one bundle id (a dev build, an old disk image) can leave Notification Center
# without the icon: register only the installed copy.
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: test app run icon install dmg

test:
	swift test -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS)

# Notifications need a real bundle, so wrap the release binary and sign it ad hoc (no sandbox: the app spawns CLIs).
app:
	swift build -c release $(ARCH_FLAGS)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$$(swift build -c release $(ARCH_FLAGS) --show-bin-path)/ReviewDesk" $(APP)/Contents/MacOS/
	cp assets/Info.plist $(APP)/Contents/
	mkdir -p $(APP)/Contents/Resources
	cp assets/AppIcon.icns $(APP)/Contents/Resources/
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" -c "Set :CFBundleVersion $(BUILD)" $(APP)/Contents/Info.plist
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
	-$(LSREGISTER) -u $(CURDIR)/$(APP)
	$(LSREGISTER) -f $(INSTALL_DIR)/$(APP)
	rm -rf $(APP)
	$(LAUNCH) $(INSTALL_DIR)/$(APP)

# Drag-to-Applications disk image for GitHub Releases: dist/ReviewDesk-<version>.dmg.
# ponytail: ad hoc signed, so first launch elsewhere needs right-click > Open; add Developer ID signing and
# notarization (codesign --options runtime + notarytool) once there's an Apple Developer account.
dmg:
	$(MAKE) app ARCH_FLAGS="--arch arm64 --arch x86_64"
	rm -rf $(DIST)/dmg && mkdir -p $(DIST)/dmg
	ditto $(APP) $(DIST)/dmg/$(APP)
	ln -s /Applications $(DIST)/dmg/Applications
	hdiutil create -volname "ReviewDesk $(VERSION)" -srcfolder $(DIST)/dmg -ov -format UDZO $(DIST)/ReviewDesk-$(VERSION).dmg
	rm -rf $(DIST)/dmg $(APP)

# Regenerates assets/AppIcon.icns from the drawing in assets/make-icon.swift.
icon:
	rm -rf .build/AppIcon.iconset && mkdir -p .build/AppIcon.iconset
	swift assets/make-icon.swift .build/AppIcon-1024.png
	for size in 16 32 128 256 512; do \
		sips -z $$size $$size .build/AppIcon-1024.png --out .build/AppIcon.iconset/icon_$${size}x$${size}.png >/dev/null; \
		sips -z $$((size * 2)) $$((size * 2)) .build/AppIcon-1024.png --out .build/AppIcon.iconset/icon_$${size}x$${size}@2x.png >/dev/null; \
	done
	iconutil -c icns .build/AppIcon.iconset -o assets/AppIcon.icns
