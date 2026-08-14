# Display Steward Soul

## Identity

Display Steward is a small native macOS utility that keeps visible display state aligned with explicit user intent. It turns display management into observable rules and safe manual controls, not a hidden fixed policy.

## North star

Prefer a stable, explainable screen state over a clever transition. Make the safe state obvious, keep the manual escape hatch immediate, and leave enough evidence to explain every automatic decision.

## Principles

### Rules are the policy

Multiple ordered rules express intent. Conditions inside a rule are AND; multiple rules express OR. Matching rules merge, higher-priority explicit actions win per display, and no-action contributes no opinion. An empty rule list is valid and means no automatic display action.

The two Chinese external-present defaults are visible, editable rules generated only when a reliable built-in target is available. They are not a second policy embedded in runtime code.

### Reconcile, do not flip

Observe the current topology, derive a complete plan, bind it to that observation, and apply only missing transitions. Screen events, polling, wake, Save and Apply, manual controls, and the hotkey all meet at one coordinator. Never infer a transition from an event alone or duplicate automatic logic in presentation code.

### Truth before convenience

Distinguish online from active and drawable. A display disabled by this app has unknown physical connection state; a historical display is only not currently observed. Runtime IDs are operational current-boot handles, not hardware identity. Exact identity requires a reliable serial; family identity intentionally covers every matching vendor/model device.

### Preserve a visible screen

Retain at least one active usable display. Prefer the current main display on equal priority, then a built-in display, then stable identity order. Defer while displays are online but none are active. Journal disables before commit, verify the global postcondition afterward, compensate when a commit leaves no active display, and keep committed uncertainty recoverable until it settles.

### User control without stale overwrites

The overview, menu, Rules page, Displays page, and configurable `⌃⌥⌘D` built-in toggle all read the same current status. Rule drafts merge only rules into current settings when saved, so concurrent polling, shortcut, alias, history, and automatic-state changes are preserved. Manual display actions use the same safety path and pause automation until a real topology change, Resume, restart, or Save and Apply.

Preview is strictly read-only. It evaluates an injected or current snapshot without saving configuration, changing recovery state, querying an unrelated display state, or applying a transaction.

### JSON owns configuration

Validated configuration lives at `~/.config/display-steward/config.json` with `config.last-good.json` as fallback. Current-boot recovery state lives at `runtime-state.json`. Existing UserDefaults and the former `~/.config/screen-manager` directory are imported once only when the Display Steward JSON configuration is absent; afterward the new JSON location is the sole writable source and old defaults remain untouched and inert.

Corrupt data is evidence. Fall back without overwriting it. If neither configuration generation is usable, disable automation and report the failure instead of guessing.

### Native and bounded

Use AppKit, CoreGraphics, Carbon, Foundation, Darwin, and UserNotifications without helper applications or third-party runtime dependencies. Enumerate through supported online and active APIs; never scan arbitrary display IDs.

`CGSConfigureDisplayEnabled` is private SPI and therefore a compatibility boundary, not a foundation to spread through the app. Resolve it dynamically in the display adapter, contain it in a session transaction, and postcondition-check every use. If it is unavailable or ambiguous, surface the limitation and preserve safety.

### Observable and boring operations

Logs answer what topology was observed, which rules matched, what action was attempted, and whether the postcondition held. They live under `~/Library/Logs`; the single-instance lock remains under `~/Library/Application Support/Display Steward`.

Build, test, install, and inspect through checked-in scripts. Deterministic phase tests come first, then bundle and plist validation, then UI inspection. A real display smoke test is a separate, explicitly authorized step that starts with at least two active displays for any disable action, preserves one visible screen, and records postcondition and log evidence.

## Completion standard

A change is complete when focused tests protect its observable contract, the app bundle and plists are valid, one coordinator and one JSON configuration source remain, the UI describes state truthfully, and any authorized real smoke preserves an active screen with matching status and log evidence.
