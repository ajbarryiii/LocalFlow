# LocalFlow for iPhone, built with swiftc and make only (no Xcode project or
# SwiftPM). Run `make -C iOS <target>` from the repository root, or `make` in
# this directory. README.md documents usage; ARCHITECTURE.md is the contract.
.DEFAULT_GOAL := all

PLATFORM ?= simulator
BUNDLE_ID ?= com.ajbarryiii.localflow.ios.dev
KEYBOARD_BUNDLE_ID = $(BUNDLE_ID).keyboard
APP_GROUP ?= group.$(BUNDLE_ID)
URL_SCHEME ?= localflow-dev
DISPLAY_NAME ?= LocalFlow Dev
DEPLOYMENT_TARGET ?= 26.0
PARAKEET_BUNDLE_DIR ?=
TEAM_ID ?=
APP_PROFILE ?=
KEYBOARD_PROFILE ?=
BUILD_DIR ?= build/$(PLATFORM)
SWIFT_FLAGS ?=
SWIFT_OPTIMIZATION ?= $(if $(strip $(PARAKEET_BUNDLE_DIR)),-O,-Onone)
ICON_SOURCE ?= ../Resources/AppIcon-Dev-Source.png
PYTHON ?= python3

ifeq ($(PLATFORM),simulator)
SDK = iphonesimulator
SUPPORTED_PLATFORM = iPhoneSimulator
TARGET = arm64-apple-ios$(DEPLOYMENT_TARGET)-simulator
CODESIGN_IDENTITY ?= -
ifneq ($(filter install-device,$(MAKECMDGOALS)),)
$(error install-device needs PLATFORM=device)
endif
else ifeq ($(PLATFORM),device)
SDK = iphoneos
SUPPORTED_PLATFORM = iPhoneOS
TARGET = arm64-apple-ios$(DEPLOYMENT_TARGET)
CODESIGN_IDENTITY ?=
ifneq ($(filter install-sim run-sim,$(MAKECMDGOALS)),)
$(error install-sim and run-sim need PLATFORM=simulator)
endif
else
$(error PLATFORM must be simulator or device)
endif
SDK_PATH := $(shell xcrun --sdk $(SDK) --show-sdk-path)
SDK_VERSION := $(shell xcrun --sdk $(SDK) --show-sdk-version)

# Every list can be overridden, e.g. `make SHARED_SOURCES= HOSTCORE_SOURCES=`.
swift_sources = $(shell find $(1) -name '*.swift' -type f 2>/dev/null | LC_ALL=C sort)
APP_SWIFT_SOURCES ?= $(call swift_sources,App)
KEYBOARD_SWIFT_SOURCES ?= $(call swift_sources,Keyboard)
SHARED_SOURCES ?= $(call swift_sources,Shared)
HOSTCORE_SOURCES ?= $(call swift_sources,HostCore)
KEYBOARDCORE_SOURCES ?= $(call swift_sources,KeyboardCore)
TEST_SOURCES ?= $(call swift_sources,Tests)
PARAKEET_SOURCES ?= $(call swift_sources,../Sources/Parakeet)
DICTATION_CORE_SOURCES ?= ../Sources/LocalDictationCore.swift
APP_SOURCES = $(APP_SWIFT_SOURCES) $(SHARED_SOURCES) $(HOSTCORE_SOURCES) $(PARAKEET_SOURCES) $(DICTATION_CORE_SOURCES)
KEYBOARD_SOURCES = $(KEYBOARD_SWIFT_SOURCES) $(SHARED_SOURCES) $(KEYBOARDCORE_SOURCES)

OBJ_DIR = $(BUILD_DIR)/obj
APP_BUNDLE = $(BUILD_DIR)/LocalFlow.app
APPEX_BUNDLE = $(APP_BUNDLE)/PlugIns/LocalFlowKeyboard.appex
APP_BINARY = $(OBJ_DIR)/LocalFlow
KEYBOARD_BINARY = $(OBJ_DIR)/LocalFlowKeyboard
APP_ENTITLEMENTS = $(OBJ_DIR)/LocalFlow.xcent
KEYBOARD_ENTITLEMENTS = $(OBJ_DIR)/LocalFlowKeyboard.xcent
APP_SIGNATURE = $(APP_BUNDLE)/_CodeSignature/CodeResources
CONFIG_STAMP = $(OBJ_DIR)/configuration
PARAKEET_STAMP = $(OBJ_DIR)/parakeet-selection
PARAKEET_INSTALL_KEY = $(OBJ_DIR)/parakeet-installed
HOST_BUILD_DIR ?= build/host
HOST_TARGET ?= $(shell uname -m)-apple-macosx13.0

SWIFTC = xcrun --sdk $(SDK) swiftc
# iOS 26 deprecates the legacy CBLAS declarations the shared decoder calls; the
# new LAPACK headers keep the same 32-bit signatures.
ACCELERATE_FLAGS = -Xcc -DACCELERATE_NEW_LAPACK
SWIFT_COMMON_FLAGS = -swift-version 5 -parse-as-library -target $(TARGET) -sdk "$(SDK_PATH)" $(ACCELERATE_FLAGS) $(SWIFT_FLAGS)
KEYBOARD_SWIFT_FLAGS = -module-name LocalFlowKeyboard -application-extension
KEYBOARD_LINK_FLAGS = -Xlinker -e -Xlinker _NSExtensionMain

ifeq ($(PLATFORM),simulator)
# The simulator reads entitlements from these sections, as Xcode arranges for
# simulator builds; the ad-hoc signature itself carries none.
embedded_entitlements = -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$(1)" \
	-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __ents_der -Xlinker "$(1).der"
LINKED_APP_ENTITLEMENTS = $(APP_ENTITLEMENTS)
LINKED_KEYBOARD_ENTITLEMENTS = $(KEYBOARD_ENTITLEMENTS)
SIGNED_APP_ENTITLEMENTS =
SIGNED_KEYBOARD_ENTITLEMENTS =
else
embedded_entitlements =
LINKED_APP_ENTITLEMENTS =
LINKED_KEYBOARD_ENTITLEMENTS =
SIGNED_APP_ENTITLEMENTS = --entitlements "$(APP_ENTITLEMENTS)"
SIGNED_KEYBOARD_ENTITLEMENTS = --entitlements "$(KEYBOARD_ENTITLEMENTS)"
endif

# $(1): template, $(2): output, $(3): bundle identifier.
info_plist = cp "$(1)" "$(2)" && \
	plutil -replace CFBundleIdentifier -string "$(3)" "$(2)" && \
	plutil -replace CFBundleDisplayName -string "$(DISPLAY_NAME)" "$(2)" && \
	plutil -replace CFBundleSupportedPlatforms -json '["$(SUPPORTED_PLATFORM)"]' "$(2)" && \
	plutil -replace DTPlatformName -string "$(SDK)" "$(2)" && \
	plutil -replace DTPlatformVersion -string "$(SDK_VERSION)" "$(2)" && \
	plutil -replace DTSDKName -string "$(SDK)$(SDK_VERSION)" "$(2)" && \
	plutil -replace MinimumOSVersion -string "$(DEPLOYMENT_TARGET)" "$(2)" && \
	plutil -replace LocalFlowAppGroupIdentifier -string "$(APP_GROUP)" "$(2)" && \
	plutil -replace LocalFlowURLScheme -string "$(URL_SCHEME)" "$(2)"

.PHONY: all binaries check typecheck test lint install-sim run-sim smoke-sim clean configuration parakeet-selection signing-requirements

all: signing-requirements $(APP_SIGNATURE)

binaries: $(APP_BINARY) $(KEYBOARD_BINARY)

# Rebuild when identifiers, flags, signing inputs or source lists change.
CONFIGURATION = $(PLATFORM)|$(BUNDLE_ID)|$(APP_GROUP)|$(URL_SCHEME)|$(DISPLAY_NAME)|$(DEPLOYMENT_TARGET)|$(SDK_PATH)|$(SWIFT_OPTIMIZATION)|$(SWIFT_FLAGS)|$(CODESIGN_IDENTITY)|$(TEAM_ID)|$(APP_PROFILE)|$(KEYBOARD_PROFILE)|$(ICON_SOURCE)|$(APP_SOURCES)|$(KEYBOARD_SOURCES)
configuration:
	@mkdir -p "$(OBJ_DIR)"
	@printf '%s\n' "$(CONFIGURATION)" > "$(CONFIG_STAMP).tmp"
	@if cmp -s "$(CONFIG_STAMP).tmp" "$(CONFIG_STAMP)"; then rm -f "$(CONFIG_STAMP).tmp"; else mv "$(CONFIG_STAMP).tmp" "$(CONFIG_STAMP)"; fi

$(CONFIG_STAMP): configuration

# Weights stay outside Git and are copied only into the local app bundle.
parakeet-selection:
	@mkdir -p "$(OBJ_DIR)"
	@printf '%s\n' "$(PARAKEET_BUNDLE_DIR)" > "$(PARAKEET_STAMP).tmp"
ifneq ($(strip $(PARAKEET_BUNDLE_DIR)),)
	@test -f "$(PARAKEET_BUNDLE_DIR)/bundle.json" || { echo "PARAKEET_BUNDLE_DIR has no bundle.json." >&2; exit 1; }
	@shasum -a 256 "$(PARAKEET_BUNDLE_DIR)/bundle.json" >> "$(PARAKEET_STAMP).tmp"
endif
	@if cmp -s "$(PARAKEET_STAMP).tmp" "$(PARAKEET_STAMP)"; then rm -f "$(PARAKEET_STAMP).tmp"; else mv "$(PARAKEET_STAMP).tmp" "$(PARAKEET_STAMP)"; fi

$(PARAKEET_STAMP): parakeet-selection

signing-requirements:
ifeq ($(PLATFORM),device)
	@if [ -z "$(TEAM_ID)" ] || [ -z "$(APP_PROFILE)" ] || [ -z "$(KEYBOARD_PROFILE)" ] || [ -z "$(CODESIGN_IDENTITY)" ] || [ "$(CODESIGN_IDENTITY)" = "-" ]; then \
		echo "PLATFORM=device needs CODESIGN_IDENTITY, TEAM_ID, APP_PROFILE and KEYBOARD_PROFILE (see iOS/README.md)." >&2; \
		echo "Use 'make PLATFORM=device binaries' to compile and link without signing." >&2; exit 1; \
	fi
	@for profile in "$(APP_PROFILE)" "$(KEYBOARD_PROFILE)"; do \
		[ -f "$$profile" ] || { echo "Provisioning profile not found: $$profile" >&2; exit 1; }; \
	done
endif

$(APP_ENTITLEMENTS): ENTITLED_BUNDLE_ID = $(BUNDLE_ID)
$(APP_ENTITLEMENTS): ENTITLED_PROFILE = $(APP_PROFILE)
$(APP_ENTITLEMENTS): $(wildcard $(APP_PROFILE))
$(KEYBOARD_ENTITLEMENTS): ENTITLED_BUNDLE_ID = $(KEYBOARD_BUNDLE_ID)
$(KEYBOARD_ENTITLEMENTS): ENTITLED_PROFILE = $(KEYBOARD_PROFILE)
$(KEYBOARD_ENTITLEMENTS): $(wildcard $(KEYBOARD_PROFILE))

$(OBJ_DIR)/%.xcent: Config/%.entitlements $(CONFIG_STAMP) Makefile | signing-requirements
	@mkdir -p "$(@D)"
	@cp "$<" "$@.tmp"
	@/usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $(APP_GROUP)" "$@.tmp"
ifeq ($(PLATFORM),device)
	@# Signed entitlements must be a subset of the provisioning profile's.
	@profile="$@.profile.plist"; trap 'rm -f "$$profile"' EXIT; \
	security cms -D -i "$(ENTITLED_PROFILE)" > "$$profile" 2>/dev/null || { echo "Cannot decode $(ENTITLED_PROFILE)" >&2; exit 1; }; \
	expected="$(TEAM_ID).$(ENTITLED_BUNDLE_ID)"; \
	actual=$$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" "$$profile" 2>/dev/null); \
	[ "$$actual" = "$$expected" ] || { echo "$(ENTITLED_PROFILE) is for '$$actual', expected '$$expected'." >&2; exit 1; }; \
	/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.security.application-groups" "$$profile" 2>/dev/null | tr -d ' ' | grep -Fqx "$(APP_GROUP)" || \
		{ echo "$(ENTITLED_PROFILE) does not grant App Group $(APP_GROUP)." >&2; exit 1; }; \
	debuggable=$$(/usr/libexec/PlistBuddy -c "Print :Entitlements:get-task-allow" "$$profile" 2>/dev/null || echo false); \
	/usr/libexec/PlistBuddy -c "Add :application-identifier string $$expected" \
		-c "Add :com.apple.developer.team-identifier string $(TEAM_ID)" \
		-c "Add :get-task-allow bool $$debuggable" "$@.tmp"
endif
	@mv "$@.tmp" "$@"
ifeq ($(PLATFORM),simulator)
	@derq query -f xml -i "$@" -o "$@.der" --raw
endif

$(APP_BINARY): $(APP_SOURCES) $(CONFIG_STAMP) $(LINKED_APP_ENTITLEMENTS) Makefile
	@mkdir -p "$(@D)"
	$(SWIFTC) $(SWIFT_COMMON_FLAGS) $(SWIFT_OPTIMIZATION) -module-name LocalFlow \
		$(call embedded_entitlements,$(APP_ENTITLEMENTS)) -o "$@" $(APP_SOURCES)

$(KEYBOARD_BINARY): $(KEYBOARD_SOURCES) $(CONFIG_STAMP) $(LINKED_KEYBOARD_ENTITLEMENTS) Makefile
	@mkdir -p "$(@D)"
	$(SWIFTC) $(SWIFT_COMMON_FLAGS) $(SWIFT_OPTIMIZATION) $(KEYBOARD_SWIFT_FLAGS) $(KEYBOARD_LINK_FLAGS) \
		$(call embedded_entitlements,$(KEYBOARD_ENTITLEMENTS)) -o "$@" $(KEYBOARD_SOURCES)

$(APP_SIGNATURE): $(APP_BINARY) $(KEYBOARD_BINARY) $(APP_ENTITLEMENTS) $(KEYBOARD_ENTITLEMENTS) Makefile \
		Config/LocalFlow-Info.plist Config/LocalFlowKeyboard-Info.plist $(ICON_SOURCE) $(PARAKEET_STAMP) \
		$(wildcard ../Resources/Parakeet/*) ../scripts/label-localflow-model.py
	@rm -rf "$(APPEX_BUNDLE)" "$(APP_BUNDLE)/_CodeSignature" "$(APP_BUNDLE)/embedded.mobileprovision"
	@mkdir -p "$(APPEX_BUNDLE)"
	@cp "$(APP_BINARY)" "$(APP_BUNDLE)/LocalFlow"
	@cp "$(KEYBOARD_BINARY)" "$(APPEX_BUNDLE)/LocalFlowKeyboard"
	@$(call info_plist,Config/LocalFlow-Info.plist,$(APP_BUNDLE)/Info.plist,$(BUNDLE_ID))
	@plutil -replace CFBundleURLTypes.0.CFBundleURLName -string "$(BUNDLE_ID)" "$(APP_BUNDLE)/Info.plist"
	@plutil -replace CFBundleURLTypes.0.CFBundleURLSchemes -json '["$(URL_SCHEME)"]' "$(APP_BUNDLE)/Info.plist"
	@$(call info_plist,Config/LocalFlowKeyboard-Info.plist,$(APPEX_BUNDLE)/Info.plist,$(KEYBOARD_BUNDLE_ID))
	@! grep -l '\$$(' "$(APP_BUNDLE)/Info.plist" "$(APPEX_BUNDLE)/Info.plist" || { echo "Unexpanded Info.plist placeholder" >&2; exit 1; }
	@printf 'APPL????' > "$(APP_BUNDLE)/PkgInfo"
	@# The macOS icon source has a transparent margin and rounded corners; keep
	@# the opaque square inside them so iOS can apply its own mask.
	@sips --cropToHeightWidth 788 788 --cropOffset 118 118 "$(ICON_SOURCE)" --out "$(OBJ_DIR)/AppIcon.png" >/dev/null
	@sips -z 120 120 "$(OBJ_DIR)/AppIcon.png" --out "$(APP_BUNDLE)/AppIcon60x60@2x.png" >/dev/null
	@sips -z 180 180 "$(OBJ_DIR)/AppIcon.png" --out "$(APP_BUNDLE)/AppIcon60x60@3x.png" >/dev/null
ifneq ($(strip $(PARAKEET_BUNDLE_DIR)),)
	@{ cat "$(PARAKEET_STAMP)"; shasum -a 256 ../Resources/Parakeet/* ../scripts/label-localflow-model.py; } > "$(PARAKEET_INSTALL_KEY).tmp"
	@# Copying 330 MB is slow, so keep the installed copy while its inputs are unchanged.
	@if [ -f "$(APP_BUNDLE)/Parakeet/bundle.json" ] && cmp -s "$(PARAKEET_INSTALL_KEY).tmp" "$(PARAKEET_INSTALL_KEY)"; then \
		echo "Reusing installed model files"; \
	else \
		rm -f "$(PARAKEET_INSTALL_KEY)" && rm -rf "$(APP_BUNDLE)/Parakeet" && mkdir -p "$(APP_BUNDLE)/Parakeet" && \
		cp -R -X "$(PARAKEET_BUNDLE_DIR)/Encoder.mlmodelc" "$(APP_BUNDLE)/Parakeet/" && \
		cp -X "$(PARAKEET_BUNDLE_DIR)/bundle.json" "$(PARAKEET_BUNDLE_DIR)/frontend.json" "$(PARAKEET_BUNDLE_DIR)/frontend.f32bin" "$(PARAKEET_BUNDLE_DIR)/decoder_joint.json" "$(PARAKEET_BUNDLE_DIR)/decoder_joint.f32bin" "$(PARAKEET_BUNDLE_DIR)/vocabulary.json" "$(APP_BUNDLE)/Parakeet/" && \
		cp -X ../Resources/Parakeet/* "$(APP_BUNDLE)/Parakeet/" && \
		$(PYTHON) ../scripts/label-localflow-model.py "$(APP_BUNDLE)/Parakeet" && \
		cp "$(PARAKEET_INSTALL_KEY).tmp" "$(PARAKEET_INSTALL_KEY)"; \
	fi
	@rm -f "$(PARAKEET_INSTALL_KEY).tmp"
else
	@rm -rf "$(APP_BUNDLE)/Parakeet" "$(PARAKEET_INSTALL_KEY)"
endif
ifeq ($(PLATFORM),device)
	@cp "$(APP_PROFILE)" "$(APP_BUNDLE)/embedded.mobileprovision"
	@cp "$(KEYBOARD_PROFILE)" "$(APPEX_BUNDLE)/embedded.mobileprovision"
endif
	@# The extension is sealed inside the app, so it must be signed first.
	@codesign --force --sign "$(CODESIGN_IDENTITY)" $(SIGNED_KEYBOARD_ENTITLEMENTS) --timestamp=none --generate-entitlement-der "$(APPEX_BUNDLE)"
	@codesign --force --sign "$(CODESIGN_IDENTITY)" $(SIGNED_APP_ENTITLEMENTS) --timestamp=none --generate-entitlement-der "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

check: typecheck test lint

# Always against the simulator SDK, independent of PLATFORM. The self-test
# variant is checked too, so it cannot rot outside smoke-sim.
typecheck:
	@set -e; sdk=$$(xcrun --sdk iphonesimulator --show-sdk-path); \
	flags="-typecheck -warnings-as-errors -swift-version 5 -parse-as-library -target arm64-apple-ios$(DEPLOYMENT_TARGET)-simulator -sdk $$sdk $(ACCELERATE_FLAGS) $(SWIFT_FLAGS)"; \
	echo "Type-checking the app"; \
	xcrun --sdk iphonesimulator swiftc $$flags -module-name LocalFlow $(APP_SOURCES); \
	echo "Type-checking the app (self-test variant)"; \
	xcrun --sdk iphonesimulator swiftc $$flags -D LOCALFLOW_SELFTEST -module-name LocalFlow $(APP_SOURCES); \
	echo "Type-checking the keyboard"; \
	xcrun --sdk iphonesimulator swiftc $$flags $(KEYBOARD_SWIFT_FLAGS) $(KEYBOARD_SOURCES)

# Shared, HostCore and KeyboardCore are Foundation-only, so their tests run on the Mac.
test:
ifeq ($(strip $(TEST_SOURCES)),)
	@echo "No iOS host tests yet; skipping."
else
	@mkdir -p "$(HOST_BUILD_DIR)"
	xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -warnings-as-errors \
		-sdk "$$(xcrun --sdk macosx --show-sdk-path)" -target $(HOST_TARGET) -module-name LocalFlowiOSTests \
		-o "$(HOST_BUILD_DIR)/LocalFlowiOSTests" $(SHARED_SOURCES) $(HOSTCORE_SOURCES) $(KEYBOARDCORE_SOURCES) $(TEST_SOURCES)
	@"$(HOST_BUILD_DIR)/LocalFlowiOSTests"
endif

lint:
	plutil -lint Config/*.plist Config/*.entitlements

SIM_DEVICE ?= LocalFlow-Smoke
SIM_DEVICE_TYPE ?= iPhone 17 Pro
SIM_RUNTIME ?=
# Shell fragment: sets udid for SIM_DEVICE, creating the device on first use
# with SIM_RUNTIME or the newest installed iOS runtime.
SIM_RESOLVE = udid=$$(xcrun simctl list devices available | grep -F "    $(SIM_DEVICE) (" | head -n 1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'); \
	if [ -z "$$udid" ]; then \
		runtime="$(SIM_RUNTIME)"; \
		[ -n "$$runtime" ] || runtime=$$(xcrun simctl list runtimes available | sed -n -E 's/^iOS .* - (com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+)$$/\1/p' | tail -n 1); \
		echo "Creating simulator $(SIM_DEVICE) ($(SIM_DEVICE_TYPE), $$runtime)"; \
		udid=$$(xcrun simctl create "$(SIM_DEVICE)" "$(SIM_DEVICE_TYPE)" "$$runtime"); \
	fi
# Shell fragment: boots udid if needed; booted_here=1 when this run booted it.
SIM_BOOT = booted_here=0; \
	if ! xcrun simctl list devices | grep -F "($$udid) (Booted)" >/dev/null; then booted_here=1; xcrun simctl boot "$$udid"; fi; \
	xcrun simctl bootstatus "$$udid" >/dev/null

install-sim: all
	@set -e; $(SIM_RESOLVE); $(SIM_BOOT); \
	xcrun simctl install "$$udid" "$(APP_BUNDLE)"; \
	echo "Installed $(APP_BUNDLE) on $(SIM_DEVICE)"

run-sim: install-sim
	@set -e; $(SIM_RESOLVE); \
	open -a Simulator --args -CurrentDeviceUDID "$$udid"; \
	xcrun simctl launch --terminate-running-process "$$udid" "$(BUNDLE_ID)"

SMOKE_BUILD_DIR ?= build/smoke-simulator
SMOKE_PHRASE ?= The blue lantern is beside the green notebook.
SMOKE_COMPUTE ?= cpuAndNeuralEngine
SMOKE_TIMEOUT ?= 900
SMOKE_LOG = $(SMOKE_BUILD_DIR)/obj/selftest.log

# Transcribes invented speech from `say` inside the self-test build. The app
# prints only a pass/fail line with timings, never the transcript.
smoke-sim:
	@[ -n "$(strip $(PARAKEET_BUNDLE_DIR))" ] || { echo "smoke-sim needs PARAKEET_BUNDLE_DIR (the Parakeet model bundle)." >&2; exit 1; }
	@$(MAKE) --no-print-directory all PLATFORM=simulator BUILD_DIR="$(SMOKE_BUILD_DIR)" SWIFT_FLAGS="$(SWIFT_FLAGS) -D LOCALFLOW_SELFTEST"
	@set -e; $(SIM_RESOLVE); $(SIM_BOOT); \
	trap '[ "$$booted_here" = 1 ] && xcrun simctl shutdown "$$udid"' EXIT; \
	xcrun simctl install "$$udid" "$(SMOKE_BUILD_DIR)/LocalFlow.app"; \
	say -o "$(SMOKE_BUILD_DIR)/obj/selftest.wav" --data-format=LEI16@16000 "$(SMOKE_PHRASE)"; \
	container=$$(xcrun simctl get_app_container "$$udid" "$(BUNDLE_ID)" data); \
	mkdir -p "$$container/tmp"; \
	mv "$(SMOKE_BUILD_DIR)/obj/selftest.wav" "$$container/tmp/localflow-selftest.wav"; \
	( trap 'kill $$sleeper 2>/dev/null; exit 0' TERM; sleep $(SMOKE_TIMEOUT) & sleeper=$$!; wait $$sleeper; \
		xcrun simctl terminate "$$udid" "$(BUNDLE_ID)" ) >/dev/null 2>&1 & watchdog=$$!; \
	echo "Running the self-test on $(SIM_DEVICE) (compute: $(SMOKE_COMPUTE))"; \
	SIMCTL_CHILD_LOCALFLOW_SELFTEST_AUDIO=tmp/localflow-selftest.wav \
	SIMCTL_CHILD_LOCALFLOW_SELFTEST_EXPECTED="$(SMOKE_PHRASE)" \
	SIMCTL_CHILD_LOCALFLOW_SELFTEST_COMPUTE="$(SMOKE_COMPUTE)" \
		xcrun simctl launch --console-pty --terminate-running-process "$$udid" "$(BUNDLE_ID)" > "$(SMOKE_LOG)" 2>&1 || true; \
	kill $$watchdog 2>/dev/null || true; \
	rm -f "$$container/tmp/localflow-selftest.wav"; \
	result=$$(grep -a '^LocalFlow self-test:' "$(SMOKE_LOG)" | tail -n 1 | tr -d '\r'); \
	case "$$result" in \
		*"result=pass"*) echo "$$result"; rm -f "$(SMOKE_LOG)" ;; \
		"") echo "No self-test result; see $(SMOKE_LOG)" >&2; exit 1 ;; \
		*) echo "$$result" >&2; echo "See $(SMOKE_LOG)" >&2; exit 1 ;; \
	esac

.PHONY: install-device smoke-device

# A name or identifier from `xcrun devicectl list devices`.
DEVICE ?=
SMOKE_DEVICE_BUILD_DIR ?= build/smoke-device
SMOKE_DEVICE_LOG = $(SMOKE_DEVICE_BUILD_DIR)/obj/selftest.log
# 0 reruns the self-test build already on DEVICE without building or reinstalling it,
# so a second run shows whether Core ML kept its on-device specialization (a warm run).
SMOKE_DEVICE_INSTALL ?= 1
# Shell fragment: fails unless DEVICE is set, reachable and unlocked.
DEVICE_UNLOCKED = [ -n "$(DEVICE)" ] || { echo "Set DEVICE to a name or identifier from 'xcrun devicectl list devices'." >&2; exit 1; }; \
	lock_json=$$(mktemp); \
	xcrun devicectl device info lockState --device "$(DEVICE)" --quiet --json-output "$$lock_json" >/dev/null 2>&1 || \
		{ rm -f "$$lock_json"; echo "Cannot reach $(DEVICE); see 'xcrun devicectl list devices'." >&2; exit 1; }; \
	locked=$$(plutil -extract result.passcodeRequired raw -o - "$$lock_json" 2>/dev/null || echo unknown); rm -f "$$lock_json"; \
	[ "$$locked" = false ] || { echo "Unlock $(DEVICE) and keep it awake until the run finishes." >&2; exit 1; }

# Installs the signed build on DEVICE without launching it (PLATFORM=device).
install-device: all
	@[ -n "$(DEVICE)" ] || { echo "install-device needs DEVICE, a name or identifier from 'xcrun devicectl list devices'." >&2; exit 1; }
	xcrun devicectl device install app --device "$(DEVICE)" "$(APP_BUNDLE)"

# smoke-sim on a device. Builds and signs the self-test variant (it needs the device signing
# variables), replaces the BUNDLE_ID install on DEVICE with it, copies invented `say` speech
# into the app's data container and launches the app with the self-test environment. Prints
# only the content-free result line. The phone must stay unlocked. devicectl cannot delete
# files, so the recording is overwritten with an empty file afterwards.
smoke-device:
	@[ -n "$(DEVICE)" ] || { echo "smoke-device needs DEVICE, a name or identifier from 'xcrun devicectl list devices'." >&2; exit 1; }
ifneq ($(SMOKE_DEVICE_INSTALL),0)
	@[ -n "$(strip $(PARAKEET_BUNDLE_DIR))" ] || { echo "smoke-device needs PARAKEET_BUNDLE_DIR (the Parakeet model bundle)." >&2; exit 1; }
	@$(MAKE) --no-print-directory all PLATFORM=device BUILD_DIR="$(SMOKE_DEVICE_BUILD_DIR)" SWIFT_FLAGS="$(SWIFT_FLAGS) -D LOCALFLOW_SELFTEST"
endif
	@set -e; $(DEVICE_UNLOCKED); obj="$(SMOKE_DEVICE_BUILD_DIR)/obj"; mkdir -p "$$obj"; \
	if [ "$(SMOKE_DEVICE_INSTALL)" != 0 ]; then \
		xcrun devicectl device install app --quiet --device "$(DEVICE)" "$(SMOKE_DEVICE_BUILD_DIR)/LocalFlow.app"; \
	fi; \
	copy_audio() { xcrun devicectl device copy to --quiet --device "$(DEVICE)" --domain-type appDataContainer \
		--domain-identifier "$(BUNDLE_ID)" --source "$$1" --destination tmp/localflow-selftest.wav; }; \
	say -o "$$obj/selftest.wav" --data-format=LEI16@16000 "$(SMOKE_PHRASE)"; : > "$$obj/empty.wav"; \
	trap 'copy_audio "$$obj/empty.wav" >/dev/null 2>&1 || true; rm -f "$$obj/selftest.wav" "$$obj/empty.wav"' EXIT; \
	copy_audio "$$obj/selftest.wav"; \
	echo "Running the self-test on $(DEVICE) (compute: $(SMOKE_COMPUTE))"; \
	DEVICECTL_CHILD_LOCALFLOW_SELFTEST_AUDIO=tmp/localflow-selftest.wav \
	DEVICECTL_CHILD_LOCALFLOW_SELFTEST_EXPECTED="$(SMOKE_PHRASE)" \
	DEVICECTL_CHILD_LOCALFLOW_SELFTEST_COMPUTE="$(SMOKE_COMPUTE)" \
		xcrun devicectl device process launch --device "$(DEVICE)" --console --terminate-existing \
		--timeout $(SMOKE_TIMEOUT) "$(BUNDLE_ID)" > "$(SMOKE_DEVICE_LOG)" 2>&1 || true; \
	result=$$(LC_ALL=C sed -n -E 's/.*(LocalFlow self-test: result=)/\1/p' "$(SMOKE_DEVICE_LOG)" | tail -n 1 | tr -d '\r'); \
	case "$$result" in \
		*"result=pass"*) echo "$$result"; rm -f "$(SMOKE_DEVICE_LOG)" ;; \
		"") echo "No self-test result; see $(SMOKE_DEVICE_LOG)" >&2; exit 1 ;; \
		*) echo "$$result" >&2; echo "See $(SMOKE_DEVICE_LOG)" >&2; exit 1 ;; \
	esac

.PHONY: e2e-sim e2e-sim-probe e2e-sim-scenarios

E2E_BUILD_DIR ?= build/e2e-simulator
E2E_SIM_DEVICE ?= LocalFlow-E2E
E2E_PHRASE ?= $(SMOKE_PHRASE)
E2E_AUDIO = tmp/localflow-synthetic-mic.wav
E2E_LOG = $(E2E_BUILD_DIR)/obj/e2e-app.log
# Launch options of the self-test build (see App/SelfTest.swift).
E2E_SKIP_ONBOARDING ?=
E2E_SCREEN ?=
E2E_START_SESSION ?=
# e2e-sim-probe: seconds between recording and finish, the completion timeout,
# whether to send the app to the background while it records, and whether to
# also open <scheme>://dictate (the simulator asks "Open in …?", which needs a tap).
# E2E_FROM_BACKGROUND=1 needs a running session: LocalFlow goes to the background
# first and the request is admitted there, as for every dictation after the first.
E2E_SPEAK_SECONDS ?= 4
E2E_TIMEOUT ?= 600
E2E_BACKGROUND ?=
E2E_OPEN_URL ?=
E2E_FROM_BACKGROUND ?=
E2E_KEEP_PRESENCE = $(strip $(E2E_BACKGROUND)$(E2E_FROM_BACKGROUND))

# Installs the self-test variant on a dedicated simulator with the synthetic
# microphone (`say` speech, fed at real-time pace when a dictation starts) and
# leaves it running for a GUI or scripted end-to-end test. It does not open
# Simulator.app, and the Mac microphone is never used.
e2e-sim: SIM_DEVICE = $(E2E_SIM_DEVICE)
e2e-sim:
	@[ -n "$(strip $(PARAKEET_BUNDLE_DIR))" ] || { echo "e2e-sim needs PARAKEET_BUNDLE_DIR (the Parakeet model bundle)." >&2; exit 1; }
	@$(MAKE) --no-print-directory all PLATFORM=simulator BUILD_DIR="$(E2E_BUILD_DIR)" SWIFT_FLAGS="$(SWIFT_FLAGS) -D LOCALFLOW_SELFTEST"
	@set -e; $(SIM_RESOLVE); $(SIM_BOOT); \
	xcrun simctl terminate "$$udid" "$(BUNDLE_ID)" >/dev/null 2>&1 || true; \
	xcrun simctl install "$$udid" "$(E2E_BUILD_DIR)/LocalFlow.app"; \
	container=$$(xcrun simctl get_app_container "$$udid" "$(BUNDLE_ID)" data); \
	group=$$(xcrun simctl get_app_container "$$udid" "$(BUNDLE_ID)" "$(APP_GROUP)"); \
	mkdir -p "$$container/tmp"; \
	say -o "$(E2E_BUILD_DIR)/obj/synthetic-mic.wav" --data-format=LEI16@16000 "$(E2E_PHRASE)"; \
	mv "$(E2E_BUILD_DIR)/obj/synthetic-mic.wav" "$$container/$(E2E_AUDIO)"; \
	rm -f "$(E2E_LOG)"; \
	SIMCTL_CHILD_LOCALFLOW_SYNTHETIC_MIC="$(E2E_AUDIO)" \
	SIMCTL_CHILD_LOCALFLOW_SELFTEST_SKIP_ONBOARDING="$(E2E_SKIP_ONBOARDING)" \
	SIMCTL_CHILD_LOCALFLOW_SELFTEST_SCREEN="$(E2E_SCREEN)" \
	SIMCTL_CHILD_LOCALFLOW_SELFTEST_START_SESSION="$(E2E_START_SESSION)" \
		xcrun simctl launch --terminate-running-process --stdout="$(CURDIR)/$(E2E_LOG)" \
		"$$udid" "$(BUNDLE_ID)" >/dev/null; \
	echo "LocalFlow (self-test build, synthetic microphone) is running on $(E2E_SIM_DEVICE) $$udid."; \
	echo "  Window:        open -a Simulator --args -CurrentDeviceUDID $$udid"; \
	echo "  Keyboard:      Settings > General > Keyboard > Keyboards > Add New Keyboard > $(DISPLAY_NAME), then Allow Full Access"; \
	echo "  Every dictation hears the invented phrase \"$(E2E_PHRASE)\", then silence."; \
	echo "  Headless test: make -C iOS e2e-sim-probe [E2E_BACKGROUND=1 or E2E_FROM_BACKGROUND=1]"; \
	echo "  Shared files:  $$group/Library/Caches/LocalFlowDictation"; \
	echo "  App output:    $(E2E_LOG) (content-free self-test lines only)"; \
	echo "  Shut down:     xcrun simctl shutdown $$udid"

# Shell fragment for the probes below, which play the keyboard's part through the
# shared files from the Mac: udid, dir, intent ACTION [REQUEST], presence, field
# KEY (from status.json), status_of REQUEST (phase/error or none), and
# launch_app [simctl launch options], which brings the app forward (or starts it
# again) with the synthetic microphone.
E2E_SHELL = udid=$$(xcrun simctl list devices | grep -F "    $(E2E_SIM_DEVICE) (" | grep -F "(Booted)" | head -n 1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'); \
	[ -n "$$udid" ] || { echo "$(E2E_SIM_DEVICE) is not booted; run make e2e-sim first." >&2; exit 1; }; \
	group=$$(xcrun simctl get_app_container "$$udid" "$(BUNDLE_ID)" "$(APP_GROUP)"); \
	dir="$$group/Library/Caches/LocalFlowDictation"; mkdir -p "$$dir"; \
	request=$$(uuidgen); instance=$$(uuidgen); \
	intent() { printf '{"action":"%s","issuedAt":%s,"keyboardInstanceID":"%s","requestID":"%s","schema":1}' \
		"$$1" "$$(date +%s)" "$$instance" "$${2:-$$request}" > "$$dir/.e2e-intent.tmp"; mv "$$dir/.e2e-intent.tmp" "$$dir/intent.json"; }; \
	presence() { printf '{"keyboardInstanceID":"%s","schema":1,"seenAt":%s}' "$$instance" "$$(date +%s)" > "$$dir/.e2e-presence.tmp"; \
		mv "$$dir/.e2e-presence.tmp" "$$dir/presence.json"; }; \
	field() { plutil -extract "$$1" raw -o - "$$dir/status.json" 2>/dev/null || true; }; \
	status_of() { if [ "$$(field dictation.requestID)" = "$$1" ]; then echo "$$(field dictation.phase)/$$(field dictation.error)"; else echo none; fi; }; \
	launch_app() { SIMCTL_CHILD_LOCALFLOW_SYNTHETIC_MIC="$(E2E_AUDIO)" SIMCTL_CHILD_LOCALFLOW_SELFTEST_SKIP_ONBOARDING="$(E2E_SKIP_ONBOARDING)" \
		xcrun simctl launch "$$@" "$$udid" "$(BUNDLE_ID)" >/dev/null; }

# Scripted round trip against an e2e-sim install: a record intent, the app brought
# to the foreground (as when the user opens it), a finish intent, then the result
# is compared with E2E_PHRASE. Prints phases and pass/fail only, never the
# transcript; the result file is claimed (deleted) afterwards. If the app has to
# start again, launch_app keeps the synthetic microphone.
e2e-sim-probe:
	@set -e; $(E2E_SHELL); \
	phase() { if [ "$$(field dictation.requestID)" = "$$request" ]; then field dictation.phase; else echo none; fi; }; \
	wait_for() { deadline=$$(( $$(date +%s) + $$2 )); last=; while :; do \
		p=$$(phase); [ "$$p" = "$$last" ] || { echo "  $$(date +%T) phase=$$p session=$$(field session) model=$$(field model)"; last=$$p; }; \
		case " $$1 " in *" $$p "*) return 0 ;; esac; [ "$$(date +%s)" -lt "$$deadline" ] || return 1; \
		if [ -n "$(E2E_KEEP_PRESENCE)" ]; then presence; fi; sleep 0.25; done; }; \
	if [ -n "$(E2E_FROM_BACKGROUND)" ]; then \
		[ "$$(field session)" = active ] || { echo "E2E_FROM_BACKGROUND needs an active session." >&2; exit 1; }; \
		presence; xcrun simctl launch "$$udid" com.apple.Preferences >/dev/null; sleep 1; presence; \
		echo "Request $$request: record intent with LocalFlow in the background"; \
		intent record; \
	else \
		echo "Request $$request: record intent, then LocalFlow to the foreground"; \
		intent record; \
		launch_app; \
		if [ -n "$(E2E_OPEN_URL)" ]; then xcrun simctl openurl "$$udid" "$(URL_SCHEME)://dictate"; fi; \
	fi; \
	wait_for "recording failed cancelled" 30 || { echo "Timed out before recording" >&2; exit 1; }; \
	[ "$$(phase)" = recording ] || { echo "Not recording: $$(field dictation.error)" >&2; exit 1; }; \
	if [ -n "$(E2E_BACKGROUND)" ]; then \
		presence; xcrun simctl launch "$$udid" com.apple.Preferences >/dev/null; \
		echo "  $$(date +%T) LocalFlow sent to the background; writing keyboard presence"; \
	fi; \
	end=$$(( $$(date +%s) + $(E2E_SPEAK_SECONDS) )); \
	while [ "$$(date +%s)" -lt "$$end" ]; do if [ -n "$(E2E_KEEP_PRESENCE)" ]; then presence; fi; sleep 0.5; done; \
	echo "  $$(date +%T) finish intent"; \
	intent finish; \
	wait_for "completed failed cancelled" $(E2E_TIMEOUT) || { echo "Timed out waiting for the result" >&2; exit 1; }; \
	p=$$(phase); \
	[ "$$p" = completed ] || { echo "Dictation $$p: $$(field dictation.error)" >&2; exit 1; }; \
	result="$$dir/result-$$request.json"; \
	[ -f "$$result" ] || { echo "Completed without a result file" >&2; exit 1; }; \
	norm() { tr 'A-Z' 'a-z' | tr -cd 'a-z \n' | tr -s ' ' | sed -E 's/^ +| +$$//g'; }; \
	actual=$$(plutil -extract text raw -o - "$$result" | norm); \
	expected=$$(printf '%s\n' "$(E2E_PHRASE)" | norm); \
	enter=$$(plutil -extract pressEnter raw -o - "$$result"); \
	rm -f "$$result"; \
	if [ "$$actual" = "$$expected" ]; then echo "e2e: result=pass transcript_match=true press_enter=$$enter"; \
	else echo "e2e: result=fail transcript_match=false press_enter=$$enter" >&2; exit 1; fi

# Contract scenarios against an e2e-sim install, each printing one pass/fail line:
# - cancel: a cancel intent ends a recording.
# - kill-relaunch: the app is killed while recording; relaunched while the record
#   intent is still fresh, it reports the request interrupted and never restarts it.
# - url-hint: with LocalFlow in the background and no session, a record intent and
#   <scheme>://dictate admit nothing (the simulator holds the URL behind its "Open
#   in …?" alert; the in-app background hint path is covered by host tests). Only
#   arriving in the foreground admits, judging freshness then: a fresh intent
#   records, and one past pendingRecordTTL is neither admitted nor rejected.
# Relaunches end any session; the app is left running with no session.
e2e-sim-scenarios:
	@set -e; $(E2E_SHELL); \
	until_phase() { i=0; while [ "$$(field dictation.requestID)" != "$$1" ] || [ "$$(field dictation.phase)" != "$$2" ]; do \
		sleep 0.25; i=$$((i + 1)); [ $$i -lt 120 ] || return 1; done; }; \
	pass() { echo "e2e-scenario: $$1 result=pass"; }; \
	fail() { echo "e2e-scenario: $$1 result=fail $$2" >&2; exit 1; }; \
	to_background() { xcrun simctl launch "$$udid" com.apple.Preferences >/dev/null; sleep 2; }; \
	r=$$(uuidgen); intent record "$$r"; launch_app; \
	until_phase "$$r" recording || fail cancel "not recording: $$(status_of "$$r")"; \
	intent cancel "$$r"; until_phase "$$r" cancelled || fail cancel "$$(status_of "$$r")"; \
	pass cancel; \
	r=$$(uuidgen); intent record "$$r"; launch_app; \
	until_phase "$$r" recording || fail kill-relaunch "not recording: $$(status_of "$$r")"; \
	run=$$(field hostRunID); xcrun simctl terminate "$$udid" "$(BUNDLE_ID)"; launch_app; \
	i=0; while [ "$$(field hostRunID)" = "$$run" ]; do sleep 0.25; i=$$((i + 1)); [ $$i -lt 60 ] || fail kill-relaunch "no new run"; done; \
	sleep 2; outcome=$$(status_of "$$r"); \
	[ "$$outcome" = failed/interrupted ] && [ "$$(field session)" = inactive ] || fail kill-relaunch "$$outcome session=$$(field session)"; \
	pass kill-relaunch; \
	to_background; \
	r=$$(uuidgen); intent record "$$r"; xcrun simctl openurl "$$udid" "$(URL_SCHEME)://dictate" || true; sleep 4; \
	[ "$$(status_of "$$r")" = none ] && [ "$$(field session)" = inactive ] && [ "$$(field model)" = notPrepared ] || \
		fail url-hint-background "$$(status_of "$$r") session=$$(field session) model=$$(field model)"; \
	launch_app; until_phase "$$r" recording || fail url-hint-foreground "$$(status_of "$$r")"; \
	pass url-hint-fresh; \
	intent cancel "$$r"; until_phase "$$r" cancelled || true; \
	launch_app --terminate-running-process; sleep 3; to_background; \
	r=$$(uuidgen); intent record "$$r"; xcrun simctl openurl "$$udid" "$(URL_SCHEME)://dictate" || true; \
	sleep $$(( 21 + 3 )); launch_app; sleep 3; \
	[ "$$(status_of "$$r")" = none ] && [ "$$(field session)" = inactive ] || fail url-hint-stale "$$(status_of "$$r") session=$$(field session)"; \
	pass url-hint-stale

clean:
	rm -rf build "$(BUILD_DIR)" "$(SMOKE_BUILD_DIR)" "$(SMOKE_DEVICE_BUILD_DIR)" "$(HOST_BUILD_DIR)"
