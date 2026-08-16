# Display Steward Soul

## Identity

Display Steward is a small native macOS utility that keeps visible display state aligned with explicit user intent. It turns display management into observable rules and safe manual controls, not a hidden fixed policy.

## North star

Prefer a stable, explainable screen state over a clever transition. Make the safe state obvious, keep the manual escape hatch immediate, and leave enough evidence to explain every automatic decision.

## Principles

### Profiles own the policy

Exactly one manually selected Active Profile supplies Automation timing, polling, and Rules. Profiles are named reusable policies such as office or home; they are never selected automatically from display topology, and they never capture modes, layout, primary-display choice, or transient display state.

Multiple ordered Rules inside a Profile express intent. Conditions inside a Rule are AND; multiple Rules express OR. Matching Rules merge, higher-priority explicit actions win per display, and no-action contributes no opinion. An empty Rule list is valid and means no automatic display action. A newly created blank Profile starts with Automation and polling off.

The two Chinese external-present defaults remain visible, editable Rules only when imported from an existing configuration that already supplied them. They are not a second policy embedded in runtime code.

### Reconcile, do not flip

Observe the current topology, derive a complete plan, bind it to that observation, and apply only missing transitions. Screen events, polling, wake, Save and Apply, manual controls, and the hotkey all meet at one coordinator. Never infer a transition from an event alone or duplicate automatic logic in presentation code.

### Truth before convenience

Distinguish online from active and drawable. A display disabled by this app has unknown physical connection state; a historical display is only not currently observed. Runtime IDs are operational current-boot handles, not hardware identity. Exact identity requires a reliable serial; family identity intentionally covers every matching vendor/model device.

### Preserve a visible screen

Retain at least one active usable display. Prefer the current main display on equal priority, then a built-in display, then stable identity order. Defer while displays are online but none are active. Journal disables before commit, verify the global postcondition afterward, compensate when a commit leaves no active display, and keep committed uncertainty recoverable until it settles.

### User control without stale overwrites

The overview, menu, Profile editor, Rules page, Displays page, and configurable `⌃⌥⌘M` built-in toggle read the same current status. The status menu can activate a Profile quickly, but it must resolve dirty Profile drafts first, re-observe the display topology, preview the exact persisted Profile generation, and bind confirmation to that Profile and topology before applying any display action.

Settings distinguishes the Profile being edited from the Active Profile. Name, Automation, polling, and Rules share one identity-bound draft; ordinary list navigation never activates it. Saving an inactive draft has no runtime effect, while Active Save and Apply and explicit activation use the coordinator. The global hotkey, display history, recovery evidence, and manual display controls remain application-wide.

Preview is strictly read-only. It evaluates an injected or freshly observed snapshot without saving configuration, changing recovery state, or applying a transaction. A stale confirmation is refused before the Active selector or hardware changes.

### JSON owns configuration

Validated application settings live at `~/.config/display-steward/config.json` with `config.last-good.json` as fallback. Each Display Profile has one canonical `profiles/<uuid>.json` file and an independent `profiles/last-good/<uuid>.json` safety generation. Current-boot recovery state remains application-wide in `runtime-state.json`.

Existing monolithic JSON, UserDefaults, and the former `~/.config/screen-manager` directory are imported once when split settings are absent. Existing rules and timing migrate unchanged into an ordinary `默认` Profile; afterward the split JSON files are the sole writable source and old defaults remain untouched and inert.

Corrupt data is evidence. Fall back only to the matching settings/Profile safety generation without overwriting the bad file or choosing another Profile. Explicit restore and removal are user actions. If the Active Profile has no usable generation, disable Automation and report the failure instead of guessing.

### Native and bounded

Use AppKit, CoreGraphics, Carbon, Foundation, Darwin, and UserNotifications without helper applications or third-party runtime dependencies. Enumerate through supported online and active APIs; never scan arbitrary display IDs.

`CGSConfigureDisplayEnabled` is private SPI and therefore a compatibility boundary, not a foundation to spread through the app. Resolve it dynamically in the display adapter, contain it in a session transaction, and postcondition-check every use. If it is unavailable or ambiguous, surface the limitation and preserve safety.

### Observable and boring operations

Logs answer what topology was observed, which rules matched, what action was attempted, and whether the postcondition held. They live under `~/Library/Logs`; the single-instance lock remains under `~/Library/Application Support/Display Steward`.

Build, test, install, and inspect through checked-in scripts. Deterministic phase tests come first, then bundle and plist validation, then UI inspection. A real display smoke test is a separate, explicitly authorized step that starts with at least two active displays for any disable action, preserves one visible screen, and records postcondition and log evidence.

## Completion standard

A change is complete when focused tests protect its observable contract, the app bundle and plists are valid, one coordinator owns one Active Profile plus application-wide settings and recovery state, the UI describes selection and hardware outcomes truthfully, and any authorized real smoke preserves an active screen with matching status and evidence.
