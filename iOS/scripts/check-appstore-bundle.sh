#!/bin/sh
# Checks that a built LocalFlow.app (and optionally its .ipa) is what App Store
# Connect accepts and what ARCHITECTURE.md ("App Store packaging") promises:
# production identifiers, the compiled icon, privacy manifests, Xcode build
# metadata, matching versions, distribution signing and no self-test code.
# It reads only the bundle; it never uploads or contacts Apple.
#
# Usage: check-appstore-bundle.sh --app PATH --bundle-id ID --app-group GROUP
#          --url-scheme SCHEME --display-name NAME --team-id TEAM [--ipa PATH]
# With --ipa, every check runs on the app inside the .ipa, which is what Apple
# receives; it must hold the same build as --app. Prints every failure and
# exits 1 if there is any.
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
built=$app

work=$(mktemp -d "${TMPDIR:-/tmp}/localflow-appstore-check.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
    echo "FAIL: $*"
    failures=$((failures + 1))
}

# The .ipa: exactly the app under Payload/. The checks below then run on its
# copy of the app, so a damaged archive cannot pass on the strength of the
# loose build.
if [ -n "$ipa" ]; then
    if [ ! -f "$ipa" ]; then
        fail "missing $ipa"
    elif unzip -Z1 "$ipa" > "$work/ipa.txt" 2>/dev/null; then
        grep -Fqx 'Payload/LocalFlow.app/Info.plist' "$work/ipa.txt" || fail "ipa: Payload/LocalFlow.app/Info.plist is missing"
        stray=$(grep -v '^Payload/LocalFlow\.app/' "$work/ipa.txt" | grep -Fvx 'Payload/' | head -3)
        [ -z "$stray" ] || fail "ipa: unexpected entries: $stray"
        if mkdir "$work/ipa" && unzip -q "$ipa" -d "$work/ipa" && [ -d "$work/ipa/Payload/LocalFlow.app" ]; then
            # Every file, the keyboard, resources and signatures included.
            diff -rq "$app" "$work/ipa/Payload/LocalFlow.app" > "$work/ipa-diff.txt" 2>&1 ||
                fail "ipa: it holds a different build than $app ($(head -1 "$work/ipa-diff.txt"))"
            app="$work/ipa/Payload/LocalFlow.app"
        else
            fail "ipa: cannot extract Payload/LocalFlow.app"
        fi
    else
        fail "ipa: not a readable zip archive"
    fi
fi
appex="$app/PlugIns/LocalFlowKeyboard.appex"

# A scalar at a plutil key path, or empty if absent.
value() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }
# A collection at a key path as compact JSON, or empty if absent (plutil cannot
# write a scalar as JSON).
json() { plutil -extract "$2" json -o - "$1" 2>/dev/null; }
# The type at a key path (string, array, dictionary, ...), or empty if absent.
kind() { plutil -type "$2" "$1" 2>/dev/null; }

# A key path for messages, without the escapes of dotted keys.
shown() { printf '%s' "$1" | tr -d '\\'; }

expect() {   # file keypath expected what
    actual=$(value "$1" "$2")
    [ "$actual" = "$3" ] || fail "$4: $(shown "$2") is '$actual', expected '$3'"
}

expect_bool() {   # file keypath true|false what: a Boolean, not a string that reads the same
    actual_kind=$(kind "$1" "$2")
    if [ "$actual_kind" != bool ]; then
        fail "$4: $(shown "$2") is ${actual_kind:-missing}, expected the Boolean $3"
    else
        expect "$1" "$2" "$3" "$4"
    fi
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
        expect_json "$plist" UIRequiredDeviceCapabilities '["arm64"]' "$what"
        expect "$plist" LocalFlowAppGroupIdentifier "$app_group" "$what"
        expect "$plist" LocalFlowURLScheme "$url_scheme" "$what"
    done

    expect_bool "$app_plist" ITSAppUsesNonExemptEncryption false app
    expect_json "$app_plist" UIBackgroundModes '["audio"]' app
    [ -n "$(value "$app_plist" NSMicrophoneUsageDescription)" ] || fail "app: NSMicrophoneUsageDescription is missing"
    expect_json "$app_plist" CFBundleURLTypes.0.CFBundleURLSchemes "[\"$url_scheme\"]" app
    expect_bool "$keyboard_plist" NSExtension.NSExtensionAttributes.RequestsOpenAccess true keyboard
    # App Review requires every extension to be universal, whatever the app's family.
    expect_json "$keyboard_plist" UIDeviceFamily '[1,2]' keyboard

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

# Privacy manifests: no tracking, no collected data, only reasons Apple defines
# for each category, and the reasons ARCHITECTURE.md records for what the code
# uses (a new use needs both the manifest and this list).
approved_reasons() {
    case "$1" in
        NSPrivacyAccessedAPICategoryUserDefaults) echo "CA92.1 1C8F.1 C56D.1 AC6B.1" ;;
        NSPrivacyAccessedAPICategorySystemBootTime) echo "35F9.1 8FFB.1 3D61.1" ;;
        NSPrivacyAccessedAPICategoryFileTimestamp) echo "DDA9.1 C617.1 3B52.1 0A2A.1" ;;
        NSPrivacyAccessedAPICategoryDiskSpace) echo "85F4.1 E174.1 7D9E.1 B728.1" ;;
        NSPrivacyAccessedAPICategoryActiveKeyboards) echo "3EC4.1 54BD.1" ;;
    esac
}
for target in app keyboard; do
    if [ "$target" = app ]; then manifest="$app/PrivacyInfo.xcprivacy"; else manifest="$appex/PrivacyInfo.xcprivacy"; fi
    if [ ! -f "$manifest" ]; then
        fail "$target: PrivacyInfo.xcprivacy is missing"
        continue
    fi
    plutil -lint -s "$manifest" || { fail "$target: PrivacyInfo.xcprivacy is not a valid plist"; continue; }
    expect_bool "$manifest" NSPrivacyTracking false "$target privacy manifest"
    expect_json "$manifest" NSPrivacyTrackingDomains '[]' "$target privacy manifest"
    expect_json "$manifest" NSPrivacyCollectedDataTypes '[]' "$target privacy manifest"
    # Every element is visited by index (the type is empty only past the end),
    # and every reason must be a string equal to one approved code.
    declared= index=0
    [ "$(kind "$manifest" NSPrivacyAccessedAPITypes)" = array ] ||
        fail "$target privacy manifest: NSPrivacyAccessedAPITypes is not an array"
    while entry=$(kind "$manifest" "NSPrivacyAccessedAPITypes.$index") && [ -n "$entry" ]; do
        base="NSPrivacyAccessedAPITypes.$index"
        [ "$entry" = dictionary ] || fail "$target privacy manifest: entry $index is a $entry, not a dictionary"
        type=$(value "$manifest" "$base.NSPrivacyAccessedAPIType")
        approved=$(approved_reasons "$type")
        [ -n "$approved" ] || fail "$target privacy manifest: entry $index has an unknown category '$type'"
        [ "$(kind "$manifest" "$base.NSPrivacyAccessedAPITypeReasons")" = array ] ||
            fail "$target privacy manifest: entry $index has no reasons array"
        reasons=0
        while item=$(kind "$manifest" "$base.NSPrivacyAccessedAPITypeReasons.$reasons") && [ -n "$item" ]; do
            reason=$(value "$manifest" "$base.NSPrivacyAccessedAPITypeReasons.$reasons")
            matched=
            if [ "$item" = string ]; then
                for code in $approved; do [ "$reason" = "$code" ] && matched=yes; done
            fi
            if [ -n "$matched" ]; then
                declared="$declared ${type#NSPrivacyAccessedAPICategory}:$reason"
            elif [ -n "$approved" ]; then
                fail "$target privacy manifest: '$reason' ($item) is not a reason Apple defines for $type"
            fi
            reasons=$((reasons + 1))
        done
        [ "$reasons" -gt 0 ] || fail "$target privacy manifest: entry $index ($type) has no reason"
        index=$((index + 1))
    done
    if [ "$target" = app ]; then
        required="UserDefaults:CA92.1 UserDefaults:1C8F.1 SystemBootTime:35F9.1 FileTimestamp:C617.1"
    else
        required="UserDefaults:1C8F.1 SystemBootTime:35F9.1 FileTimestamp:C617.1"
    fi
    for pair in $required; do
        case "$declared " in
            *" $pair "*) ;;
            *) fail "$target privacy manifest: missing reason ${pair#*:} for NSPrivacyAccessedAPICategory${pair%%:*}" ;;
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
        debuggable=$(kind "$entitlements" get-task-allow)
        if [ -n "$debuggable" ] && { [ "$debuggable" != bool ] || [ "$(value "$entitlements" get-task-allow)" != false ]; }; then
            fail "$what entitlements: get-task-allow is present and not the Boolean false (a development signature)"
        fi
        expect_bool "$entitlements" beta-reports-active true "$what entitlements"
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
        expect "$profile" TeamIdentifier.0 "$team_id" "$what profile"
        expect_bool "$profile" Entitlements.beta-reports-active true "$what profile"
        json "$profile" Entitlements.com\\.apple\\.security\\.application-groups | tr -d '[]' | tr ',' '\n' |
            grep -Fqx "\"$app_group\"" || fail "$what profile: it does not grant App Group $app_group"
        # ISO 8601 UTC strings compare in date order.
        expires=$(value "$profile" ExpirationDate)
        now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        if [ -z "$expires" ] || [ "$(printf '%s\n%s\n' "$now" "$expires" | LC_ALL=C sort | tail -1)" != "$expires" ] ||
            [ "$expires" = "$now" ]; then
            fail "$what profile: expired or without an expiration date ('$expires')"
        fi
        # The signing certificate must be one the profile authorizes.
        if codesign -d --extract-certificates="$work/$what-certificate" "$bundle" 2>/dev/null &&
            [ -s "$work/$what-certificate0" ]; then
            leaf=$(base64 < "$work/$what-certificate0" | tr -d '\n')
            authorized= index=0
            while certificate=$(value "$profile" "DeveloperCertificates.$index") && [ -n "$certificate" ]; do
                [ "$(printf '%s' "$certificate" | tr -d '\n')" = "$leaf" ] && authorized=yes
                index=$((index + 1))
            done
            [ -n "$authorized" ] || fail "$what: its signing certificate is not one the provisioning profile authorizes"
        else
            fail "$what: cannot read its signing certificate"
        fi
    else
        fail "$what: cannot decode embedded.mobileprovision"
    fi
done

if [ "$failures" -gt 0 ]; then
    echo "$failures App Store bundle check(s) failed."
    exit 1
fi
echo "App Store bundle checks passed: ${ipa:-$built}"
