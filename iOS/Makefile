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
TEST_SOURCES ?= $(call swift_sources,Tests)
PARAKEET_SOURCES ?= $(call swift_sources,../Sources/Parakeet)
DICTATION_CORE_SOURCES ?= ../Sources/LocalDictationCore.swift
APP_SOURCES = $(APP_SWIFT_SOURCES) $(SHARED_SOURCES) $(HOSTCORE_SOURCES) $(PARAKEET_SOURCES) $(DICTATION_CORE_SOURCES)
KEYBOARD_SOURCES = $(KEYBOARD_SWIFT_SOURCES) $(SHARED_SOURCES)

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

# Shared and HostCore are Foundation-only, so their tests run on the Mac.
test:
ifeq ($(strip $(TEST_SOURCES)),)
	@echo "No iOS host tests yet; skipping."
else
	@mkdir -p "$(HOST_BUILD_DIR)"
	xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -warnings-as-errors \
		-sdk "$$(xcrun --sdk macosx --show-sdk-path)" -target $(HOST_TARGET) -module-name LocalFlowiOSTests \
		-o "$(HOST_BUILD_DIR)/LocalFlowiOSTests" $(SHARED_SOURCES) $(HOSTCORE_SOURCES) $(TEST_SOURCES)
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

clean:
	rm -rf build "$(BUILD_DIR)" "$(SMOKE_BUILD_DIR)" "$(HOST_BUILD_DIR)"
