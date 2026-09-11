# Loupe build: Rust staticlib -> C header -> SwiftPM binary -> .app bundle -> signed DMG (-> notarized).
# One `make` does everything up to a signed DMG. `make notarize` needs NOTARY_PROFILE and a Developer ID.

APP        := Loupe
BUNDLE_ID  := dev.loupe.app
VERSION    := 0.1.0
ARCHS      ?= arm64 x86_64
BUILD      := build
DIST       := dist
RUST_LIB   := target/universal/release/libsysmon_core.a
HEADER     := sysmon-core/include/sysmon.h
SWIFT_HDR  := Loupe/Sources/CSysmon/include/sysmon.h
APP_DIR    := $(BUILD)/$(APP).app
DMG        := $(DIST)/$(APP)-$(VERSION).dmg

# Use the full Xcode toolchain when present (notarytool, swift-driver) without touching xcode-select.
ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
endif

# Developer ID if the keychain has one, else Apple Development, else ad-hoc.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"')
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')
endif
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := -
endif

RUST_TARGET_arm64  := aarch64-apple-darwin
RUST_TARGET_x86_64 := x86_64-apple-darwin
SWIFT_ARCH_FLAGS   := $(foreach a,$(ARCHS),--arch $(a))
RUST_LIBS          := $(foreach a,$(ARCHS),target/$(RUST_TARGET_$(a))/release/libsysmon_core.a)

.PHONY: all rust header app sign dmg notarize test verify check-unwrap run clean leaktest childtest

all: dmg

rust: $(RUST_LIB)

$(RUST_LIBS): $(wildcard sysmon-core/src/*.rs sysmon-core/src/bin/*.rs) sysmon-core/Cargo.toml
	$(foreach a,$(ARCHS),cargo build --release --manifest-path sysmon-core/Cargo.toml --target $(RUST_TARGET_$(a)) &&) true

$(RUST_LIB): $(RUST_LIBS)
	mkdir -p $(dir $@)
	lipo -create $(RUST_LIBS) -output $@

header: $(SWIFT_HDR)

$(SWIFT_HDR): sysmon-core/src/ffi.rs sysmon-core/cbindgen.toml
	cd sysmon-core && cbindgen --config cbindgen.toml --crate sysmon-core --output include/sysmon.h 2>/dev/null
	cp $(HEADER) $@

app: $(RUST_LIB) $(SWIFT_HDR)
	cd Loupe && swift build -c release $(SWIFT_ARCH_FLAGS) --product $(APP) 2>&1 | grep -v "^\[" || true
	@test -x Loupe/.build/apple/Products/Release/$(APP) || test -x Loupe/.build/release/$(APP) || { echo "swift build failed"; exit 1; }
	rm -rf $(APP_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS $(APP_DIR)/Contents/Resources
	cp $$(ls Loupe/.build/apple/Products/Release/$(APP) 2>/dev/null || ls Loupe/.build/release/$(APP)) $(APP_DIR)/Contents/MacOS/$(APP)
	cp Loupe/Resources/Info.plist $(APP_DIR)/Contents/Info.plist
	@if [ -f Loupe/Resources/AppIcon.icns ]; then cp Loupe/Resources/AppIcon.icns $(APP_DIR)/Contents/Resources/; fi
	printf 'APPL????' > $(APP_DIR)/Contents/PkgInfo
	@echo "built $(APP_DIR)"

sign: app
	codesign --force --options runtime --timestamp=none --sign "$(SIGN_IDENTITY)" $(APP_DIR)
	codesign --verify --strict --verbose=2 $(APP_DIR)
	@echo "signed with: $(SIGN_IDENTITY)"

dmg: sign
	mkdir -p $(DIST) $(BUILD)/dmgroot
	rm -rf $(BUILD)/dmgroot/* $(DMG)
	cp -R $(APP_DIR) $(BUILD)/dmgroot/
	ln -s /Applications $(BUILD)/dmgroot/Applications
	hdiutil create -quiet -volname "$(APP)" -srcfolder $(BUILD)/dmgroot -ov -format UDZO $(DMG)
	codesign --force --sign "$(SIGN_IDENTITY)" $(DMG)
	@echo "wrote $(DMG)"

# Needs: a Developer ID Application identity in SIGN_IDENTITY and a notarytool keychain profile
# (xcrun notarytool store-credentials <name>) in NOTARY_PROFILE.
notarize: dmg
	@test -n "$(NOTARY_PROFILE)" || { echo "set NOTARY_PROFILE=<notarytool keychain profile>"; exit 1; }
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP_DIR)
	rm -f $(DMG) && $(MAKE) dmg SIGN_IDENTITY="$(SIGN_IDENTITY)"
	xcrun stapler staple $(DMG)

test: check-unwrap
	cargo test --manifest-path sysmon-core/Cargo.toml
	cd Loupe && swift build -c debug --product Loupe >/dev/null && swift test 2>&1 | tail -20

# A panic across FFI aborts the host app: no unwrap/expect in the library.
check-unwrap:
	@if grep -rn --include=*.rs -E '\.(unwrap|expect)\(' sysmon-core/src | grep -v '^sysmon-core/src/bin/' | grep -v 'unwrap_or' ; then echo "unwrap/expect found in sysmon-core/src"; exit 1; else echo "no unwrap/expect in sysmon-core/src"; fi

# 60 s side-by-side with `mo status --json`; memory, disk, network within 2%, process CPU explained.
verify:
	cargo run --release --manifest-path sysmon-core/Cargo.toml --bin verify

run: app
	open $(APP_DIR)

# Runs the app with the panel open for DURATION seconds and reports RSS growth (spec 10.3 leak test).
leaktest: app
	scripts/leaktest.sh $(APP_DIR) $(or $(DURATION),3600)

# Launches, quits, and asserts no orphaned Mole child (spec 10.3).
childtest: app
	scripts/childtest.sh $(APP_DIR)

clean:
	rm -rf $(BUILD) $(DIST) target Loupe/.build
