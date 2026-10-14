#!/bin/sh
# Checks that a built LocalFlow.app (and optionally its .ipa) is what App Store
# Connect accepts and what ARCHITECTURE.md ("App Store packaging") promises:
# production identifiers, the compiled icon, privacy manifests, Xcode build
# metadata, matching versions, distribution signing and no self-test code.
# It reads only the bundle; it never uploads or contacts Apple.
#
# Usage: check-appstore-bundle.sh --app PATH --bundle-id ID --app-group GROUP
#          --url-scheme SCHEME --display-name NAME --team-id TEAM [--ipa PATH]
# Prints every failure and exits 1 if there is any.
set -u

app= bundle_id= app_group= url_scheme= display_name= team_id= ipa=
while [ $# -gt 0 ]; do
    case "$1" in
        --app) app=$2 ;;
        --bundle-id) bundle_id=$2 ;;
        --app-group) app_group=$2 ;;
        --url-scheme) url_scheme=$2 ;;
        --display-name) display_name=$2 ;;
        --team-id) team_id=$2 ;;
        --ipa) ipa=$2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift 2 || { echo "Missing value for $1" >&2; exit 2; }
done
for required in app bundle_id app_group url_scheme display_name team_id; do
    eval "value=\$$required"
    [ -n "$value" ] || { echo "Missing --$(echo "$required" | tr _ -)" >&2; exit 2; }
done
[ -d "$app" ] || { echo "Not a directory: $app" >&2; exit 2; }

appex="$app/PlugIns/LocalFlowKeyboard.appex"
work=$(mktemp -d "${TMPDIR:-/tmp}/localflow-appstore-check.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
    echo "FAIL: $*"
    failures=$((failures + 1))
}

# A scalar at a plutil key path, or empty if absent.
value() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }
# A value at a key path as compact JSON, or empty if absent.
json() { plutil -extract "$2" json -o - "$1" 2>/dev/null; }

# A key path for messages, without the escapes of dotted keys.
shown() { printf '%s' "$1" | tr -d '\\'; }

expect() {   # file keypath expected what
    actual=$(value "$1" "$2")
    [ "$actual" = "$3" ] || fail "$4: $(shown "$2") is '$actual', expected '$3'"
}

expect_json() {   # file keypath expected-json what
    actual=$(json "$1" "$2")
    [ "$actual" = "$3" ] || fail "$4: $(shown "$2") is $actual, expected $3"
}

# Info.plist: identity, versions and metadata.
app_plist="$app/Info.plist"
keyboard_plist="$appex/Info.plist"
for plist in "$app_plist" "$keyboard_plist"; do
    [ -f "$plist" ] || { fail "missing $plist"; continue; }
done
if [ -f "$app_plist" ] && [ -f "$keyboard_plist" ]; then
    case "$bundle_id" in *.dev|*.dev.*) fail "bundle identifier '$bundle_id' is a development identifier" ;; esac
    expect "$app_plist" CFBundleIdentifier "$bundle_id" app
    expect "$keyboard_plist" CFBundleIdentifier "$bundle_id.keyboard" keyboard
    expect "$app_plist" CFBundleDisplayName "$display_name" app
    expect "$keyboard_plist" CFBundleDisplayName "$display_name" keyboard

    version=$(value "$app_plist" CFBundleShortVersionString)
    build=$(value "$app_plist" CFBundleVersion)
    for pair in "CFBundleShortVersionString:$version" "CFBundleVersion:$build"; do
        key=${pair%%:*} number=${pair#*:}
        echo "$number" | grep -Eqx '[0-9]+(\.[0-9]+){0,2}' || fail "app: $key '$number' is not one to three integers"
    done
    expect "$keyboard_plist" CFBundleShortVersionString "$version" keyboard
    expect "$keyboard_plist" CFBundleVersion "$build" keyboard

    for plist in "$app_plist" "$keyboard_plist"; do
        what=$( [ "$plist" = "$app_plist" ] && echo app || echo keyboard )
        for key in DTXcode DTXcodeBuild DTSDKBuild DTSDKName DTPlatformVersion DTPlatformBuild DTCompiler BuildMachineOSBuild; do
            [ -n "$(value "$plist" "$key")" ] || fail "$what: $key is missing (App Store Connect checks the toolchain)"
        done
        expect "$plist" DTPlatformName iphoneos "$what"
        expect_json "$plist" CFBundleSupportedPlatforms '["iPhoneOS"]' "$what"
        expect "$plist" LocalFlowAppGroupIdentifier "$app_group" "$what"
        expect "$plist" LocalFlowURLScheme "$url_scheme" "$what"
    done

    expect "$app_plist" ITSAppUsesNonExemptEncryption false app
    expect_json "$app_plist" UIBackgroundModes '["audio"]' app
    [ -n "$(value "$app_plist" NSMicrophoneUsageDescription)" ] || fail "app: NSMicrophoneUsageDescription is missing"
    expect_json "$app_plist" CFBundleURLTypes.0.CFBundleURLSchemes "[\"$url_scheme\"]" app
    expect "$keyboard_plist" NSExtension.NSExtensionAttributes.RequestsOpenAccess true keyboard

    # The icon comes from a compiled asset catalog, as App Store Connect requires.
    expect "$app_plist" CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName AppIcon app
    if [ -f "$app/Assets.car" ]; then
        xcrun assetutil --info "$app/Assets.car" > "$work/assets.json" 2>/dev/null || fail "app: cannot read Assets.car"
        icon= index=0
        while [ -n "$(json "$work/assets.json" "$index")" ]; do
            if [ "$(value "$work/assets.json" "$index.Name")" = AppIcon ] &&
                [ "$(value "$work/assets.json" "$index.PixelWidth")" = 1024 ]; then
                icon=$(value "$work/assets.json" "$index.Opaque")
                break
            fi
            index=$((index + 1))
        done
        case "$icon" in
            true) ;;
            "") fail "app: Assets.car has no 1024-pixel AppIcon" ;;
            *) fail "app: the 1024-pixel App Store icon is not opaque (an alpha channel is rejected)" ;;
        esac
    else
        fail "app: Assets.car is missing (no compiled app icon)"
    fi
fi

# Privacy manifests: no tracking, no collected data, a reason for every
# required-reason API category the code uses.
for target in app keyboard; do
    if [ "$target" = app ]; then manifest="$app/PrivacyInfo.xcprivacy"; else manifest="$appex/PrivacyInfo.xcprivacy"; fi
    if [ ! -f "$manifest" ]; then
        fail "$target: PrivacyInfo.xcprivacy is missing"
        continue
    fi
    plutil -lint -s "$manifest" || { fail "$target: PrivacyInfo.xcprivacy is not a valid plist"; continue; }
    expect "$manifest" NSPrivacyTracking false "$target privacy manifest"
    expect_json "$manifest" NSPrivacyTrackingDomains '[]' "$target privacy manifest"
    expect_json "$manifest" NSPrivacyCollectedDataTypes '[]' "$target privacy manifest"
    declared= index=0
    while type=$(value "$manifest" "NSPrivacyAccessedAPITypes.$index.NSPrivacyAccessedAPIType") && [ -n "$type" ]; do
        reason=$(value "$manifest" "NSPrivacyAccessedAPITypes.$index.NSPrivacyAccessedAPITypeReasons.0")
        if echo "$reason" | grep -Eqx '[0-9A-F]{4}\.[0-9]'; then declared="$declared $type"; fi
        index=$((index + 1))
    done
    for category in UserDefaults SystemBootTime FileTimestamp; do
        case "$declared " in
            *" NSPrivacyAccessedAPICategory$category "*) ;;
            *) fail "$target privacy manifest: no reason declared for NSPrivacyAccessedAPICategory$category" ;;
        esac
    done
done

# Contents: the model, no self-test code, nothing a build machine left behind.
[ -f "$app/Parakeet/bundle.json" ] || fail "app: the Parakeet model is missing (build with PARAKEET_BUNDLE_DIR)"
for binary in "$app/LocalFlow" "$appex/LocalFlowKeyboard"; do
    [ -f "$binary" ] || { fail "missing $binary"; continue; }
    if grep -aq LOCALFLOW_SELFTEST "$binary"; then fail "$(basename "$binary") is a self-test build"; fi
done
junk=$(find "$app" \( -name .DS_Store -o -name '*.xcent' -o -name '*.der' -o -name '__MACOSX' \) -print | head -5)
[ -z "$junk" ] || fail "app contains build leftovers: $junk"

# Signing: an Apple Distribution identity, App Store profiles, and entitlements
# that match them (no debugging, TestFlight allowed, the production App Group).
if codesign --verify --deep --strict "$app" 2>"$work/verify.txt"; then :; else
    fail "codesign --verify failed: $(head -2 "$work/verify.txt" | tr '\n' ' ')"
fi
for bundle in "$app" "$appex"; do
    what=$( [ "$bundle" = "$app" ] && echo app || echo keyboard )
    id=$( [ "$bundle" = "$app" ] && echo "$bundle_id" || echo "$bundle_id.keyboard" )
    authority=$(codesign -dvv "$bundle" 2>&1 | sed -n 's/^Authority=//p' | head -1)
    case "$authority" in
        "Apple Distribution:"*|"iPhone Distribution:"*) ;;
        *) fail "$what: signed by '$authority', expected an Apple Distribution identity" ;;
    esac
    entitlements="$work/$what-entitlements.plist"
    if codesign -d --entitlements - --xml "$bundle" > "$entitlements" 2>/dev/null && [ -s "$entitlements" ]; then
        expect "$entitlements" application-identifier "$team_id.$id" "$what entitlements"
        expect "$entitlements" com\\.apple\\.developer\\.team-identifier "$team_id" "$what entitlements"
        expect_json "$entitlements" com\\.apple\\.security\\.application-groups "[\"$app_group\"]" "$what entitlements"
        [ "$(value "$entitlements" get-task-allow)" != true ] || fail "$what entitlements: get-task-allow is true (a development signature)"
        expect "$entitlements" beta-reports-active true "$what entitlements"
    else
        fail "$what: cannot read its signed entitlements"
    fi
    profile="$work/$what-profile.plist"
    if [ ! -f "$bundle/embedded.mobileprovision" ]; then
        fail "$what: embedded.mobileprovision is missing"
    elif security cms -D -i "$bundle/embedded.mobileprovision" > "$profile" 2>/dev/null; then
        [ -z "$(json "$profile" ProvisionedDevices)" ] || fail "$what: the provisioning profile lists devices (development or ad hoc, not App Store)"
        [ "$(value "$profile" ProvisionsAllDevices)" != true ] || fail "$what: the provisioning profile is an enterprise profile"
        [ "$(value "$profile" Entitlements.get-task-allow)" != true ] || fail "$what: the provisioning profile allows debugging"
        expect "$profile" Entitlements.application-identifier "$team_id.$id" "$what profile"
    else
        fail "$what: cannot decode embedded.mobileprovision"
    fi
done

# The .ipa: exactly the app under Payload/, nothing else.
if [ -n "$ipa" ]; then
    if [ ! -f "$ipa" ]; then
        fail "missing $ipa"
    elif unzip -Z1 "$ipa" > "$work/ipa.txt" 2>/dev/null; then
        grep -qx 'Payload/LocalFlow.app/Info.plist' "$work/ipa.txt" || fail "ipa: Payload/LocalFlow.app/Info.plist is missing"
        stray=$(grep -v '^Payload/LocalFlow.app/' "$work/ipa.txt" | grep -vx 'Payload/' | head -3)
        [ -z "$stray" ] || fail "ipa: unexpected entries: $stray"
        mkdir "$work/ipa" && unzip -q "$ipa" -d "$work/ipa" &&
            cmp -s "$app/LocalFlow" "$work/ipa/Payload/LocalFlow.app/LocalFlow" || fail "ipa: its app binary differs from $app"
    else
        fail "ipa: not a readable zip archive"
    fi
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures App Store bundle check(s) failed."
    exit 1
fi
echo "App Store bundle checks passed: $app${ipa:+ and $ipa}"
