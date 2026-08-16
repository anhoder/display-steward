# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- English README as the default document; Chinese README moved to `README.cn.md`.
- MIT license.
- CI workflow running all test phases and the install smoke test on macOS.
- Security policy and code of conduct.

### Changed

- LaunchAgent plist is now a machine-independent template rendered by `install.sh`;
  hardcoded user paths were removed.

## [1.0.0] - 2026-08-16

### Added

- Native macOS menu bar app for rule-driven display management.
- Display Profiles with per-profile automation, polling, and rules; profiles are activated explicitly, never switched automatically.
- Rule engine matching online/active display counts and exact-device or vendor/model-family state, with priority merging.
- Last-active-display protection, journaled disable/restore recovery evidence, and aggregate batch display recovery.
- Default external-display rules seeded into the fresh default profile on first observation.
- Manual enable/disable/restore from the menu bar and a configurable global hotkey (`⌃⌥⇧D` default) for the built-in display.
- Configuration storage with last-good fallback generations and legacy `screen-manager` migration.
- Phase 1–4 test suites covering model, evaluator, configuration, inventory, automation lifecycle, presentation, and end-to-end integration.
