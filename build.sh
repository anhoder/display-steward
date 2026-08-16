#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/Display Steward.app"
CONTENTS_DIR="$APP_DIR/Contents"
# The Swift driver rejects repeated -arch flags, so each slice is compiled
# separately and merged with lipo, matching Xcode's universal-build flow.
MACOS_VERSION=$(sw_vers -productVersion | awk -F. '{print $1"."$2}')

compile_slice() {
    ARCH="$1"
    OUTPUT="$2"
    swiftc -O \
        -target "$ARCH-apple-macosx$MACOS_VERSION" \
        -framework AppKit \
        -framework CoreGraphics \
        -framework Foundation \
        -framework Carbon \
        -framework UserNotifications \
        "$ROOT_DIR/ApplicationEntryPolicy.swift" \
        "$ROOT_DIR/RuleModel.swift" \
        "$ROOT_DIR/RuleEvaluator.swift" \
        "$ROOT_DIR/RuleCycleAnalyzer.swift" \
        "$ROOT_DIR/ConfigurationStore.swift" \
        "$ROOT_DIR/RuntimeStateStore.swift" \
        "$ROOT_DIR/DisplayInventory.swift" \
        "$ROOT_DIR/DisplayActionAdapter.swift" \
        "$ROOT_DIR/AutomationCoordinator.swift" \
        "$ROOT_DIR/AppPresentation.swift" \
        "$ROOT_DIR/SevereNotificationPresenter.swift" \
        "$ROOT_DIR/ManagementUI.swift" \
        "$ROOT_DIR/Shortcut.swift" \
        "$BUILD_DIR/main.swift" \
        -o "$OUTPUT"
}

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/DisplaySteward.swift" "$BUILD_DIR/main.swift"

compile_slice arm64 "$CONTENTS_DIR/MacOS/DisplaySteward-arm64"
compile_slice x86_64 "$CONTENTS_DIR/MacOS/DisplaySteward-x86_64"

lipo -create \
    "$CONTENTS_DIR/MacOS/DisplaySteward-arm64" \
    "$CONTENTS_DIR/MacOS/DisplaySteward-x86_64" \
    -output "$CONTENTS_DIR/MacOS/DisplaySteward"
rm -f "$CONTENTS_DIR/MacOS/DisplaySteward-arm64" "$CONTENTS_DIR/MacOS/DisplaySteward-x86_64"

cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Assets/DisplaySteward.icns" "$CONTENTS_DIR/Resources/DisplaySteward.icns"

codesign --force --deep --sign - "$APP_DIR" >/dev/null
printf 'Built: %s\n' "$APP_DIR"
