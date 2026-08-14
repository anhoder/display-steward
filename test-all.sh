#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

printf '%s\n' '== Phase 1: model, evaluator, configuration =='
"$ROOT_DIR/test-phase1.sh"
printf '%s\n' '== Phase 2: inventory, actions, automation lifecycle =='
"$ROOT_DIR/test-phase2.sh"
printf '%s\n' '== Phase 3: presentation and management UI seams =='
"$ROOT_DIR/test-phase3.sh"
printf '%s\n' '== Phase 4: end-to-end integration and migration =='
"$ROOT_DIR/test-phase4.sh"
