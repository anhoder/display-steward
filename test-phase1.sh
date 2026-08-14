#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/display-steward-phase1.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM

swiftc \
    "$ROOT_DIR/RuleModel.swift" \
    "$ROOT_DIR/RuleEvaluator.swift" \
    "$ROOT_DIR/RuleCycleAnalyzer.swift" \
    "$ROOT_DIR/ConfigurationStore.swift" \
    "$ROOT_DIR/RuntimeStateStore.swift" \
    "$ROOT_DIR/Tests/Phase1Tests.swift" \
    -o "$TEST_DIR/phase1-tests"

"$TEST_DIR/phase1-tests"
