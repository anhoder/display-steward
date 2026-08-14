#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/display-steward-phase3.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM

swiftc \
    -framework AppKit \
    -framework CoreGraphics \
    -framework Foundation \
    -framework Carbon \
    -framework UserNotifications \
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
    "$ROOT_DIR/Shortcut.swift" \
    "$ROOT_DIR/ManagementUI.swift" \
    "$ROOT_DIR/Tests/Phase3Tests.swift" \
    -o "$TEST_DIR/phase3-tests"

"$TEST_DIR/phase3-tests"
