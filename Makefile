APP_NAME ?= LocalFlow Dev
.DEFAULT_GOAL := all
BUNDLE_ID ?= com.ajbarryiii.localflow.dev
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CODESIGN_IDENTITY ?= FreeFlow Dev
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
empty :=
space := $(empty) $(empty)
APP_EXECUTABLE = $(MACOS_DIR)/$(APP_NAME)
APP_EXECUTABLE_TARGET := $(subst $(space),\ ,$(APP_EXECUTABLE))

SOURCES = $(shell find Sources -name '*.swift' -type f | LC_ALL=C sort)
TEST_RUNNER = $(BUILD_DIR)/LocalFlowTests
TEST_PRODUCTION_SOURCES = \
	Sources/AppName.swift \
	Sources/PrivacyPermission.swift \
	Sources/LocalDictationCore.swift \
	Sources/PipelineHistoryItem.swift \
	Sources/PipelineHistoryStore.swift \
	Sources/SetupFlowCore.swift \
	Sources/Parakeet/LocalParakeetCore.swift \
	Sources/Parakeet/LocalParakeetService.swift \
	Sources/Parakeet/ParakeetAudioReader.swift \
	Sources/Parakeet/ParakeetDecoder.swift \
	Sources/Parakeet/ParakeetFrames.swift \
	Sources/Parakeet/ParakeetFrontEnd.swift \
	Sources/UpdateManager.swift \
	Sources/ShortcutCore/DictationShortcutSessionController.swift \
	Sources/ShortcutCore/ShortcutMatcher.swift \
	Sources/ShortcutCore/ShortcutModels.swift
TEST_SOURCES = $(shell find Tests -name '*.swift' -type f | LC_ALL=C sort)
SHELL_SCRIPTS = $(shell find .github/scripts .agents/skills -name '*.sh' -type f | LC_ALL=C sort)
YAML_FILES = $(shell find .github -type f \( -name '*.yml' -o -name '*.yaml' \) | LC_ALL=C sort)
RESOURCES = $(CONTENTS)/Resources
ARCH ?= $(shell uname -m)
PARAKEET_BUNDLE_DIR ?=
SWIFT_OPTIMIZATION ?= $(if $(strip $(PARAKEET_BUNDLE_DIR)),-O,-Onone)
PARAKEET_BUNDLE_STAMP = $(BUILD_DIR)/parakeet-bundle-selection
PARAKEET_INSTALL_KEY = $(BUILD_DIR)/$(APP_NAME).parakeet-installed

# Rebuild when switching between model bundles (including back to no bundle).
# Weights remain outside Git and are copied only into the local app bundle.
.PHONY: parakeet-selection
parakeet-selection:
	@mkdir -p "$(BUILD_DIR)"
	@printf '%s\n' "$(PARAKEET_BUNDLE_DIR)" > "$(PARAKEET_BUNDLE_STAMP).tmp"
	@printf '%s\n' "$(SWIFT_OPTIMIZATION)" >> "$(PARAKEET_BUNDLE_STAMP).tmp"
ifneq ($(strip $(PARAKEET_BUNDLE_DIR)),)
	@shasum -a 256 "$(PARAKEET_BUNDLE_DIR)/bundle.json" >> "$(PARAKEET_BUNDLE_STAMP).tmp"
endif
	@cmp -s "$(PARAKEET_BUNDLE_STAMP).tmp" "$(PARAKEET_BUNDLE_STAMP)" || mv "$(PARAKEET_BUNDLE_STAMP).tmp" "$(PARAKEET_BUNDLE_STAMP)"
	@rm -f "$(PARAKEET_BUNDLE_STAMP).tmp"

$(PARAKEET_BUNDLE_STAMP): parakeet-selection

# Pick the icon source based on which bundle we are building. Dev builds get
# a small amber badge on the waveform so a developer's dock shows at a glance
# which LocalFlow they are running when both are installed side by side.
ifeq ($(APP_NAME),LocalFlow Dev)
ICON_SOURCE = Resources/AppIcon-Dev-Source.png
ICON_ICNS = Resources/AppIcon-Dev.icns
else
ICON_SOURCE = Resources/AppIcon-Source.png
ICON_ICNS = Resources/AppIcon.icns
endif

.PHONY: all check clean run icon dmg codesign-dmg notarize test typecheck validate

all: parakeet-selection $(APP_EXECUTABLE_TARGET)

$(APP_EXECUTABLE_TARGET): $(SOURCES) Info.plist $(ICON_ICNS) $(PARAKEET_BUNDLE_STAMP) $(wildcard Resources/Parakeet/*) Resources/Attribution.txt LICENSE scripts/label-localflow-model.py
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)"
ifeq ($(ARCH),universal)
	swiftc \
		-parse-as-library \
		$(SWIFT_OPTIMIZATION) \
		-o "$(MACOS_DIR)/$(APP_NAME)-arm64" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target arm64-apple-macosx13.0 \
		$(SOURCES)
	swiftc \
		-parse-as-library \
		$(SWIFT_OPTIMIZATION) \
		-o "$(MACOS_DIR)/$(APP_NAME)-x86_64" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target x86_64-apple-macosx13.0 \
		$(SOURCES)
	lipo -create -output "$(MACOS_DIR)/$(APP_NAME)" \
		"$(MACOS_DIR)/$(APP_NAME)-arm64" \
		"$(MACOS_DIR)/$(APP_NAME)-x86_64"
	@rm "$(MACOS_DIR)/$(APP_NAME)-arm64" "$(MACOS_DIR)/$(APP_NAME)-x86_64"
else
	swiftc \
		-parse-as-library \
		$(SWIFT_OPTIMIZATION) \
		-o "$(MACOS_DIR)/$(APP_NAME)" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		$(SOURCES)
endif
	@cp Info.plist "$(CONTENTS)/"
	@plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	@cp $(ICON_ICNS) "$(RESOURCES)/AppIcon.icns"
	@cp Resources/Attribution.txt "$(RESOURCES)/Attribution.txt"
	@cp LICENSE "$(RESOURCES)/FreeFlow-LICENSE"
ifneq ($(strip $(PARAKEET_BUNDLE_DIR)),)
	@test -f "$(PARAKEET_BUNDLE_DIR)/bundle.json" || { echo "Missing Parakeet bundle.json"; exit 1; }
	@{ cat "$(PARAKEET_BUNDLE_STAMP)"; shasum -a 256 Resources/Parakeet/* scripts/label-localflow-model.py; } > "$(PARAKEET_INSTALL_KEY).tmp"
	@# Re-copying gives the model new files, which forces a full Neural Engine
	@# specialization on next launch. Keep the installed copy while it is unchanged.
	@if [ -f "$(RESOURCES)/Parakeet/bundle.json" ] && cmp -s "$(PARAKEET_INSTALL_KEY).tmp" "$(PARAKEET_INSTALL_KEY)"; then \
		echo "Reusing installed model files"; \
	else \
		rm -rf "$(RESOURCES)/Parakeet" && mkdir -p "$(RESOURCES)/Parakeet" && \
		cp -R "$(PARAKEET_BUNDLE_DIR)/Encoder.mlmodelc" "$(RESOURCES)/Parakeet/" && \
		cp "$(PARAKEET_BUNDLE_DIR)/bundle.json" "$(PARAKEET_BUNDLE_DIR)/frontend.json" "$(PARAKEET_BUNDLE_DIR)/frontend.f32bin" "$(PARAKEET_BUNDLE_DIR)/decoder_joint.json" "$(PARAKEET_BUNDLE_DIR)/decoder_joint.f32bin" "$(PARAKEET_BUNDLE_DIR)/vocabulary.json" "$(RESOURCES)/Parakeet/" && \
		cp Resources/Parakeet/* "$(RESOURCES)/Parakeet/" && \
		python3 scripts/label-localflow-model.py "$(RESOURCES)/Parakeet" && \
		cp "$(PARAKEET_INSTALL_KEY).tmp" "$(PARAKEET_INSTALL_KEY)"; \
	fi
	@rm -f "$(PARAKEET_INSTALL_KEY).tmp"
else
	@rm -rf "$(RESOURCES)/Parakeet" "$(PARAKEET_INSTALL_KEY)"
endif
	@plutil -replace NSMicrophoneUsageDescription -string "$(APP_NAME) needs microphone access to transcribe your speech." "$(CONTENTS)/Info.plist"
	@plutil -replace NSSpeechRecognitionUsageDescription -string "$(APP_NAME) needs speech recognition to convert your voice to text." "$(CONTENTS)/Info.plist"
	@plutil -replace NSAccessibilityUsageDescription -string "$(APP_NAME) needs accessibility access to detect the text cursor position and paste transcribed text." "$(CONTENTS)/Info.plist"
	@codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" --entitlements FreeFlow.entitlements "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

check: typecheck test validate

typecheck:
	swiftc \
		-parse-as-library \
		-typecheck \
		-warnings-as-errors \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		$(SOURCES)

test:
	@mkdir -p "$(BUILD_DIR)"
	swiftc \
		-parse-as-library \
		-warnings-as-errors \
		-o "$(TEST_RUNNER)" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		$(TEST_PRODUCTION_SOURCES) \
		$(TEST_SOURCES)
	@$(TEST_RUNNER)
	@python3 -m unittest discover -s Tests -p 'test_*.py'

validate:
	plutil -lint Info.plist FreeFlow.entitlements
	@set -e; for script in $(SHELL_SCRIPTS); do bash -n "$$script"; done
	@ruby -e 'require "yaml"; ARGV.each { |file| YAML.load_file(file) }' $(YAML_FILES)

icon: $(ICON_ICNS)

$(ICON_ICNS): $(ICON_SOURCE)
	@mkdir -p $(BUILD_DIR)/AppIcon.iconset
	@sips -z 16 16 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16.png > /dev/null
	@sips -z 32 32 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16@2x.png > /dev/null
	@sips -z 32 32 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32.png > /dev/null
	@sips -z 64 64 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32@2x.png > /dev/null
	@sips -z 128 128 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128.png > /dev/null
	@sips -z 256 256 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128@2x.png > /dev/null
	@sips -z 256 256 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256.png > /dev/null
	@sips -z 512 512 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256@2x.png > /dev/null
	@sips -z 512 512 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512.png > /dev/null
	@sips -z 1024 1024 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512@2x.png > /dev/null
	@iconutil -c icns -o $@ $(BUILD_DIR)/AppIcon.iconset
	@rm -rf $(BUILD_DIR)/AppIcon.iconset
	@echo "Generated $@"

dmg: all
	@rm -f "$(BUILD_DIR)/$(APP_NAME).dmg"
	@rm -rf $(BUILD_DIR)/dmg-staging
	@mkdir -p $(BUILD_DIR)/dmg-staging
	@cp -R "$(APP_BUNDLE)" $(BUILD_DIR)/dmg-staging/
	@osascript -e 'tell application "Finder" to make alias file to POSIX file "/Applications" at POSIX file "'"$$(cd $(BUILD_DIR)/dmg-staging && pwd)"'"'
	@ALIAS=$$(find $(BUILD_DIR)/dmg-staging -maxdepth 1 -not -name '*.app' -not -name '.DS_Store' -type f | head -1) && mv "$$ALIAS" "$(BUILD_DIR)/dmg-staging/Applications"
	@fileicon set "$(BUILD_DIR)/dmg-staging/Applications" /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns
	@echo "Creating DMG..."
	@create-dmg \
		--volname "$(APP_NAME)" \
		--volicon "$(ICON_ICNS)" \
		--background "Resources/dmg-background.tiff" \
		--window-pos 200 120 \
		--window-size 660 400 \
		--icon-size 128 \
		--icon "$(APP_NAME).app" 180 170 \
		--hide-extension "$(APP_NAME).app" \
		--icon "Applications" 480 170 \
		--no-internet-enable \
		"$(BUILD_DIR)/$(APP_NAME).dmg" \
		"$(BUILD_DIR)/dmg-staging"
	@rm -rf $(BUILD_DIR)/dmg-staging
	@echo "Created $(BUILD_DIR)/$(APP_NAME).dmg"

codesign-dmg: dmg
	codesign --force --sign "$(CODESIGN_IDENTITY)" "$(BUILD_DIR)/$(APP_NAME).dmg"

notarize:
	xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME).dmg" \
		--keychain-profile "$(NOTARIZE_PROFILE)" --wait
	xcrun stapler staple "$(BUILD_DIR)/$(APP_NAME).dmg"

clean:
	rm -rf $(BUILD_DIR)

run: all
	open "$(APP_BUNDLE)"
