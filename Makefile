# Fila — Xcode build, macOS harness, and jailbreak Debian packaging.

# Shared Xcode products must not be rebuilt while another wrapper copies them.
.NOTPARALLEL:

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT_DIR            := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT             := $(ROOT_DIR)/Fila.xcodeproj
SCHEME              := Fila
CONFIGURATION       ?= Release
DERIVED_DATA        ?= /private/tmp/fila-deriveddata
APP_BUNDLE          := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/Fila.app
DAEMON_BINARY       := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/filad
HELPER_BINARY       := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/fila-archive
SIMULATOR_APP       := $(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/Fila.app
SIMULATOR           ?= booted
APP_BUNDLE_ID       := wiki.qaq.fila
PACKAGE_ID          ?= wiki.qaq.fila
PROJECT_OBJECT_VERSION := 77

# FLAVOR selects the jailbreak layout the .deb is built for:
#   roothide - files ship at rootful paths; roothide's dpkg relocates them into
#              the randomized bootstrap root. Architecture iphoneos-arm64e.
#   rootless - files ship under /var/jb, the fixed rootless prefix (Dopamine,
#              palera1n rootless, ...). Architecture iphoneos-arm64.
# The Mach-O slices are identical for both; only the layout differs, and the
# daemon works out which one it landed in at runtime (see InstallRoot).
FLAVOR              ?= roothide
ifeq ($(FLAVOR),roothide)
INSTALL_PREFIX      :=
DEFAULT_ARCHITECTURE := iphoneos-arm64e
else ifeq ($(FLAVOR),rootless)
INSTALL_PREFIX      := /var/jb
DEFAULT_ARCHITECTURE := iphoneos-arm64
else
$(error FLAVOR must be roothide or rootless, got '$(FLAVOR)')
endif
PACKAGE_ARCHITECTURE ?= $(DEFAULT_ARCHITECTURE)

PACKAGE_DIR         := $(ROOT_DIR)/Packages/FilaKit
CONFIG_DIR          := $(ROOT_DIR)/Configuration
VERSION_CONFIG      := $(CONFIG_DIR)/Version.xcconfig
BASE_CONFIG         := $(CONFIG_DIR)/Base.xcconfig
xcconfig_setting     = $(strip $(shell awk -F= '$$1 ~ /^[[:space:]]*$(1)[[:space:]]*$$/ { gsub(/[[:space:]]/, "", $$2); print $$2; exit }' "$(VERSION_CONFIG)"))
base_xcconfig_setting = $(strip $(shell awk -F= '$$1 ~ /^[[:space:]]*$(1)[[:space:]]*$$/ { gsub(/[[:space:]]/, "", $$2); print $$2; exit }' "$(BASE_CONFIG)"))
APP_VERSION         := $(call xcconfig_setting,MARKETING_VERSION)
BUILD_NUMBER        := $(call xcconfig_setting,CURRENT_PROJECT_VERSION)
MINIMUM_IOS_VERSION := $(call base_xcconfig_setting,IPHONEOS_DEPLOYMENT_TARGET)
DEB_OUTPUT          ?= $(ROOT_DIR)/build/Packages/$(PACKAGE_ID)_$(APP_VERSION)_$(PACKAGE_ARCHITECTURE).deb

# The two archives that carry the app alone. Same Fila.app as the .deb ships —
# the app looks the daemon's Mach service up at runtime and does the work
# in-process when there is none, so there is no build flag and no per-packaging
# source variant. What differs is the entitlements and where it lands.
TIPA_OUTPUT         ?= $(ROOT_DIR)/build/Packages/Fila_$(APP_VERSION).tipa
IPA_OUTPUT          ?= $(ROOT_DIR)/build/Packages/Fila_$(APP_VERSION).ipa

XCODEBUILD_WRAPPER  := $(ROOT_DIR)/Scripts/run-xcodebuild.sh
DEB_PACKAGER        := $(ROOT_DIR)/Scripts/package-deb.sh
DEB_VERIFIER        := $(ROOT_DIR)/Scripts/verify-deb.sh
IPA_PACKAGER        := $(ROOT_DIR)/Scripts/package-ipa.sh
IPA_VERIFIER        := $(ROOT_DIR)/Scripts/verify-ipa.sh
VERSION_APPLIER     := $(ROOT_DIR)/Scripts/apply-version.sh
DEVICE_INSTALLER    := $(ROOT_DIR)/Scripts/install-device.sh
UI_LIBRARY_CHECK    := $(ROOT_DIR)/Scripts/check-ui-libraries.sh
LOCALIZATION_CHECK  := $(ROOT_DIR)/Scripts/check-localization.sh
EXTRACTED_STRINGS   := $(ROOT_DIR)/Scripts/check-extracted-strings.py
WEBUI_BUILDER       := $(ROOT_DIR)/Scripts/build-webui.sh

# `make install` talks to the device over a usbmuxd forward (`iproxy 2333 22`),
# not over the network. Password auth is the jailbreak default; leave
# DEVICE_PASSWORD empty to use an ssh key instead.
DEVICE_HOST         ?= 127.0.0.1
DEVICE_PORT         ?= 2333
DEVICE_USER         ?= mobile
DEVICE_PASSWORD     ?= alpine
CONTROL_TEMPLATE    := $(ROOT_DIR)/Packaging/DEBIAN/control
ENTITLEMENTS        := $(ROOT_DIR)/Packaging/Fila.entitlements
DAEMON_ENTITLEMENTS := $(ROOT_DIR)/Packaging/Filad.entitlements
LAUNCH_DAEMON       := $(ROOT_DIR)/Packaging/wiki.qaq.filad.plist
INFO_PLIST_SUPPLEMENT := $(ROOT_DIR)/Packaging/Fila-Info.plist

XCODEBUILD_BASE := $(XCODEBUILD_WRAPPER) \
	-project "$(PROJECT)" \
	-derivedDataPath "$(DERIVED_DATA)" \
	-skipMacroValidation \
	-skipPackagePluginValidation \
	ARCHS=arm64 \
	ONLY_ACTIVE_ARCH=YES \
	ENABLE_DEBUG_DYLIB=NO
XCODEBUILD := $(XCODEBUILD_BASE) \
	CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
# CoreSimulator needs Xcode's linker-created entitlement section. Ad-hoc
# signing needs no developer identity, team or provisioning profile here.
SIMULATOR_XCODEBUILD := $(XCODEBUILD_BASE) \
	CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=""

ifeq ($(APP_VERSION),)
$(error MARKETING_VERSION is missing from Configuration/Version.xcconfig)
endif
ifeq ($(BUILD_NUMBER),)
$(error CURRENT_PROJECT_VERSION is missing from Configuration/Version.xcconfig)
endif

.PHONY: all help print-version print-build-number print-deb-path print-tipa-path \
	print-ipa-path print-flavor \
	set-version bump-build check harness build sim vphone _build-ios _package-deb \
	deb deb-roothide deb-rootless deb-all tipa ipa packages install clean

all: packages

help:
	@echo "Fila:"
	@echo "  harness     Run the FilaKit tests on macOS (no device, no simulator)"
	@echo "  check       Validate the Xcode project and packaging inputs"
	@echo "  build       Build the unsigned Fila.app, filad and fila-archive for iPhoneOS"
	@echo "  sim         Build Debug and launch the app on the booted simulator"
	@echo "  deb         Build, ad-hoc sign, package, and verify the .deb for FLAVOR"
	@echo "  deb-all     Package both the roothide and the rootless .deb"
	@echo "  tipa        Package the app alone for TrollStore"
	@echo "  ipa         Package the app alone, sandboxed, for AltStore/SideStore/Sideloadly"
	@echo "  packages    All four: both .deb flavours, the .tipa and the .ipa"
	@echo "  install     Build for FLAVOR and install it on the device via iproxy"
	@echo "  vphone      Incremental Debug build and serve one .deb for Safari/Sileo (no SSH)"
	@echo "              Install and check features in the VM; Ctrl-C stops the server"
	@echo "              Defaults: rootless, HTTP 192.168.64.1:8765; VPHONE_HTTP_HOST and VPHONE_HTTP_PORT override"
	@echo "  set-version Write VERSION=x.y.z [BUILD=n] into Configuration/Version.xcconfig"
	@echo "  clean       Remove derived data and generated packages"

print-version:
	@echo "$(APP_VERSION)"

print-build-number:
	@echo "$(BUILD_NUMBER)"

print-deb-path:
	@echo "$(DEB_OUTPUT)"

print-tipa-path:
	@echo "$(TIPA_OUTPUT)"

print-ipa-path:
	@echo "$(IPA_OUTPUT)"

print-flavor:
	@echo "$(FLAVOR)"

set-version:
	@test -n "$(VERSION)" || { echo "usage: make set-version VERSION=1.2.3 [BUILD=42]" >&2; exit 64; }
	@"$(VERSION_APPLIER)" "$(VERSION)" $(BUILD)

# Every build gets its own number, so a device can say which build it runs.
# CI is exempt: the workflow pins the build number to its run number, and a
# bump there would ship an artifact that disagrees with the tag.
bump-build:
	@if [ -n "$${CI:-}" ]; then echo "==> CI: keeping build $(BUILD_NUMBER)"; else \
		"$(VERSION_APPLIER)" "$(APP_VERSION)" $$(( $(BUILD_NUMBER) + 1 )) >/dev/null; \
		echo "==> build $$(( $(BUILD_NUMBER) + 1 ))"; fi

check:
	@command -v xcodebuild >/dev/null || { echo "error: xcodebuild is required" >&2; exit 69; }
	@command -v ldid >/dev/null || { echo "error: ldid is required" >&2; exit 69; }
	@command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb is required" >&2; exit 69; }
	@test -d "$(PROJECT)" || { echo "error: Fila.xcodeproj is missing" >&2; exit 66; }
	@test -f "$(CONTROL_TEMPLATE)" || { echo "error: Debian control template is missing" >&2; exit 66; }
	@command -v zip >/dev/null || { echo "error: zip is required" >&2; exit 69; }
	@test -f "$(PACKAGE_DIR)/Package.swift" || { echo "error: Packages/FilaKit/Package.swift is missing" >&2; exit 66; }
	@for script in "$(DEB_PACKAGER)" "$(DEB_VERIFIER)" "$(IPA_PACKAGER)" "$(IPA_VERIFIER)" "$(VERSION_APPLIER)" "$(XCODEBUILD_WRAPPER)" "$(DEVICE_INSTALLER)" "$(UI_LIBRARY_CHECK)" "$(LOCALIZATION_CHECK)" "$(WEBUI_BUILDER)"; do \
		test -x "$$script" || { echo "error: $$script is not executable" >&2; exit 66; }; \
	done
	@for xcconfig in Version Base Development Release; do \
		test -f "$(CONFIG_DIR)/$$xcconfig.xcconfig" || { echo "error: Configuration/$$xcconfig.xcconfig is missing" >&2; exit 66; }; \
	done
	@[[ "$(APP_VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]] || { echo "error: MARKETING_VERSION must look like 1.2.3, got '$(APP_VERSION)'" >&2; exit 65; }
	@[[ "$(BUILD_NUMBER)" =~ ^[0-9]+$$ ]] || { echo "error: CURRENT_PROJECT_VERSION must be an integer, got '$(BUILD_NUMBER)'" >&2; exit 65; }
	@[[ "$(MINIMUM_IOS_VERSION)" =~ ^[0-9]+\.[0-9]+$$ ]] || { echo "error: IPHONEOS_DEPLOYMENT_TARGET must look like 15.0, got '$(MINIMUM_IOS_VERSION)'" >&2; exit 65; }
	@grep -qE '(MARKETING_VERSION|CURRENT_PROJECT_VERSION) =' "$(PROJECT)/project.pbxproj" \
		&& { echo "error: versions must live in Configuration/Version.xcconfig, not project.pbxproj" >&2; exit 65; } || true
	@grep -q 'IPHONEOS_DEPLOYMENT_TARGET' "$(PROJECT)/project.pbxproj" \
		&& { echo "error: deployment target must live in Configuration/Base.xcconfig, not project.pbxproj" >&2; exit 65; } || true
	@grep -Fq "Depends: firmware (>= $(MINIMUM_IOS_VERSION))" "$(CONTROL_TEMPLATE)" \
		|| { echo "error: Debian firmware dependency must match iOS $(MINIMUM_IOS_VERSION)" >&2; exit 65; }
	@objver="$$(sed -n 's/^[[:space:]]*objectVersion = \([0-9]*\);.*/\1/p' "$(PROJECT)/project.pbxproj")"; \
		[[ "$$objver" == "$(PROJECT_OBJECT_VERSION)" ]] || { echo "error: project.pbxproj objectVersion must stay $(PROJECT_OBJECT_VERSION) so Xcode 16+ can read it, got '$$objver' (newer Xcode rewrites it on save)" >&2; exit 65; }
	@plutil -lint "$(ENTITLEMENTS)" "$(DAEMON_ENTITLEMENTS)" "$(LAUNCH_DAEMON)" "$(INFO_PLIST_SUPPLEMENT)"
	@targets="$$(xcodebuild -project "$(PROJECT)" -list)" || exit $$?; \
	for target in Filad FilaArchive Fila; do \
		grep -Eq "^[[:space:]]*$$target[[:space:]]*$$" <<<"$$targets" \
			|| { echo "error: missing Xcode target $$target" >&2; exit 65; }; \
	done
	@"$(UI_LIBRARY_CHECK)"
	@"$(LOCALIZATION_CHECK)"
	@Scripts/check-process-launch.sh

# The FilaKit tests, on the Mac, against a real filesystem. This is where a
# guard mistake or a copy that loses an xattr gets caught, and it needs neither
# a device nor a simulator — which is the whole reason the file layer lives in a
# package instead of inside the daemon target.
harness:
	swift test --package-path "$(PACKAGE_DIR)"

build: check harness
	@$(MAKE) --no-print-directory _build-ios

# The browser frontend served by the WebDAV server: React + webpack in WebUI/,
# static files in WebUI/dist. The app target's "Build Web UI" phase runs the
# same script and copies dist/ into Fila.app/WebUI; this refreshes dist/ alone.
webui:
	$(WEBUI_BUILDER)

# Shared recipes keep the UI iteration loop separate from the release gates.
_build-ios: bump-build
	XCBUILD_LABEL=build-ios python3 Scripts/build-package-inputs.py build "$(dir $(APP_BUNDLE))" $(XCODEBUILD) \
		-configuration "$(CONFIGURATION)" \
		-scheme "$(SCHEME)" \
		-destination "generic/platform=iOS" \
		build
	@python3 "$(EXTRACTED_STRINGS)" "$(DERIVED_DATA)"

# The simulator exercises the shell through the local backend. The real
# daemon and its privileges are verified on vphone.
sim: harness bump-build
	XCBUILD_LABEL=build-sim $(SIMULATOR_XCODEBUILD) \
		-configuration Debug \
		-scheme "$(SCHEME)" \
		-destination "generic/platform=iOS Simulator" \
		build
	bash Scripts/verify-simulator.sh "$(SIMULATOR_APP)"
	xcrun simctl install "$(SIMULATOR)" "$(SIMULATOR_APP)"
	xcrun simctl launch "$(SIMULATOR)" "$(APP_BUNDLE_ID)"

deb: build
	@$(MAKE) --no-print-directory _package-deb

_package-deb:
	"$(DEB_PACKAGER)" \
		"$(APP_BUNDLE)" \
		"$(DAEMON_BINARY)" \
		"$(HELPER_BINARY)" \
		"$(CONTROL_TEMPLATE)" \
		"$(ENTITLEMENTS)" \
		"$(DAEMON_ENTITLEMENTS)" \
		"$(LAUNCH_DAEMON)" \
		"$(DEB_OUTPUT)" \
		"$(PACKAGE_ID)" \
		"$(APP_VERSION)" \
		"$(PACKAGE_ARCHITECTURE)" \
		"$(FLAVOR)" \
		"$(INSTALL_PREFIX)"

deb-roothide:
	@$(MAKE) --no-print-directory deb FLAVOR=roothide

deb-rootless:
	@$(MAKE) --no-print-directory deb FLAVOR=rootless

deb-all: build
	@$(MAKE) --no-print-directory _package-deb FLAVOR=roothide
	@$(MAKE) --no-print-directory _package-deb FLAVOR=rootless

# TrollStore signs nothing itself: it installs the app with the entitlements it
# finds already embedded, which is why this is ad-hoc signed exactly like the
# .deb. No filad and no launchd job come with it — the app finds no Mach
# service and does the work in-process.
tipa: build
	"$(IPA_PACKAGER)" "$(APP_BUNDLE)" tipa "$(TIPA_OUTPUT)" "$(APP_VERSION)" "$(ENTITLEMENTS)"

# Fully sandboxed, ad-hoc signed with only the standard App Group: AltStore,
# SideStore and Sideloadly re-sign with the user's own certificate at install
# time, and a private entitlement left in the binary makes that step fail on
# their machine with nothing they can act on.
ipa: build
	"$(IPA_PACKAGER)" "$(APP_BUNDLE)" ipa "$(IPA_OUTPUT)" "$(APP_VERSION)"

packages: build
	@$(MAKE) --no-print-directory _package-deb FLAVOR=roothide
	@$(MAKE) --no-print-directory _package-deb FLAVOR=rootless
	"$(IPA_PACKAGER)" "$(APP_BUNDLE)" tipa "$(TIPA_OUTPUT)" "$(APP_VERSION)" "$(ENTITLEMENTS)"
	"$(IPA_PACKAGER)" "$(APP_BUNDLE)" ipa "$(IPA_OUTPUT)" "$(APP_VERSION)"

# Build for FLAVOR and install it on the device behind `iproxy $(DEVICE_PORT) 22`.
# The package's own postinst boots the daemon and runs uicache; nothing is
# duplicated here.
install: deb
	DEVICE_HOST="$(DEVICE_HOST)" DEVICE_PORT="$(DEVICE_PORT)" DEVICE_USER="$(DEVICE_USER)" \
	DEVICE_PASSWORD="$(DEVICE_PASSWORD)" "$(DEVICE_INSTALLER)" "$(DEB_OUTPUT)"

# Development only: Xcode owns incremental rebuilds; package signing and its
# entitlement checks still run. `build`, `deb`, and `install` retain all gates.
# Environment / command-line overrides are exported by make; file defaults
# remain private. Safari/Sileo handle installation; runtime checks are separate.
vphone:
	@"$(ROOT_DIR)/Scripts/vphone.sh"

clean:
	rm -rf "$(DERIVED_DATA)"
	rm -rf "$(ROOT_DIR)/build/Packages"
