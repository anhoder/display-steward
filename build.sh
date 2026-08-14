#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/Display Steward.app"
CONTENTS_DIR="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/DisplaySteward.swift" "$BUILD_DIR/main.swift"

swiftc -O \
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
    -o "$CONTENTS_DIR/MacOS/DisplaySteward"

cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

codesign --force --deep --sign - "$APP_DIR" >/dev/null
printf 'Built: %s\n' "$APP_DIR"
