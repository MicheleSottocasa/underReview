# Command Line Tools ship the Swift Testing macros but SwiftPM doesn't find them; Xcode doesn't need this.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing

.PHONY: test
test:
	swift test -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS)
