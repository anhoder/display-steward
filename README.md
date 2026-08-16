<p align="center">
  <img src="Assets/DisplaySteward.svg" width="144" alt="Display Steward icon">
</p>

# Display Steward

[中文](README.cn.md) | **English**

Display Steward is a native macOS menu bar app that manages display enable/disable state with explicit rules. It supports creating multiple Display Profiles for different usage contexts such as the office or home, while preserving manual control, recovery evidence, and last-active-display protection.

## Features

- **Display Profiles**: Each profile independently stores its name, automation settings, polling configuration, and rules.
- **Manual activation**: Profiles are never switched automatically based on location or display topology; the user explicitly selects one from Settings or the menu bar.
- **Rule engine**: Matches rules against the count of online/active displays and specific device state, then merges actions by priority.
- **Safe switching**: Previews the latest display topology before activating; requires confirmation for actions that disable displays or raise safety warnings.
- **Last-active-display protection**: Prevents rules or manual actions from disabling the last usable display.
- **Recoverable state**: Records disable and restore operations initiated by the app that have not yet been confirmed complete.
- **Manual control**: The menu bar can enable, disable, or restore managed displays.
- **Global hotkey**: Default `⌃⌥⌘M` toggles the built-in display; configurable in Settings.

Display Steward only manages display enable/disable state. It does not modify the main display, arrangement, resolution, refresh rate, scaling, HDR, or color configuration.

## System Requirements

- macOS 13 or later
- Xcode Command Line Tools, providing `swiftc`, `codesign`, `plutil`

The project builds directly with `swiftc` and system frameworks; it does not depend on Swift Package Manager or third-party runtime libraries.

## Quick Start

### Build locally

```sh
./build.sh
```

The app is produced at:

```text
build/Display Steward.app
```

### Install and launch

```sh
./install.sh
```

The install script:

1. Builds and signs the app;
2. Stops old Display Steward / Screen Manager processes and LaunchAgents;
3. Migrates compatible legacy configuration directories;
4. Installs and starts the `com.anhoder.display-steward` LaunchAgent.

### Side-effect-free install check

```sh
./install.sh --smoke-test
```

This mode only verifies the build, bundle, plist, and code signature. It does not touch LaunchAgents, processes, configuration, or display state.

## Usage

1. Open **Display Steward → Open Settings…** from the menu bar.
2. In the Profiles list, create a blank profile or duplicate an existing one.
3. Edit the name, automation, polling, and rules.
4. Commit explicitly with **Save**, **Save and Activate**, or **Save and Apply**.
5. You can also quickly activate a saved profile from the **Profiles** submenu in the menu bar.

Settings marks the profiles currently being edited and currently active separately. Clicking the list only switches the editing target; it never changes display state. Unsaved changes go through a Save, Discard, or Cancel confirmation before switching, closing, quitting, or a menu bar action.

## Common Usage Scenarios

**Office / home switching (manual)**

Create one profile per place — for example, an "Office" profile that disables a rarely used secondary display and a "Home" profile that enables it. Switch from the **Profiles** submenu in the menu bar. Profiles never auto-switch based on location or display topology; the choice stays with you.

**Single-screen focus mode**

Create a profile with a high-priority `always` rule that disables the external display (targeted by exact identity or display family). Activate it from the menu bar when you need to concentrate, and switch back afterwards. The built-in display is protected by last-active-display protection, so a rule can never leave you with no usable screen.

**Toggle the built-in display with the hotkey**

Default `⌃⌥⌘M` toggles the built-in display on and off. Use it to flip between a dual-screen desk setup and external-monitor-only mode without opening Settings. If another app occupies the shortcut, rebind it in Settings.

**Automatic cleanup when monitors change**

Count conditions watch the number of online/active external displays. Example: a rule that enables a specific projector display only when external active displays are 2 or more, and disables it when they drop below. Automation evaluates after the startup/wake stabilization delay and on the polling interval, so plugging or unplugging a cable settles the state by itself. Give such rules distinct priorities — equal-priority rules requesting conflicting actions are reported as conflicts instead of being applied.

**Presentation / projector setup**

A dedicated "Presentation" profile whose rules enable the projector by exact identity or family. When actions conflict, the highest-priority rule wins. Activation previews the latest topology and asks for confirmation before disabling displays, so you can review what will change before committing.

**Recovery after an unexpected quit**

If the app disables a display and quits or crashes before the operation settles, it keeps recovery evidence in `runtime-state.json`. On the next launch, use the menu bar restore action to bring managed displays back. Recovery, automation, and manual operations all honor the last-active-display safety constraint at every step.

All scenarios only change display enable/disable state — arrangement, resolution, refresh rate, and color configuration are never touched.

## Configuration Files

Default configuration root:

```text
~/.config/display-steward/
├── config.json                         # Global hotkey, display history, active profile ID
├── config.last-good.json               # Safe generation of global settings
├── runtime-state.json                  # Recovery evidence for the current launch
└── profiles/
    ├── <uuid>.json                     # Canonical profile files
    └── last-good/
        └── <uuid>.json                 # Safe generations of profiles
```

If configuration is corrupt, the app only falls back to the last-good generation of the same settings or profile. It never silently selects another profile and never silently overwrites a corrupt file.

## Troubleshooting

### Log files

- **Main log**: `~/Library/Logs/com.anhoder.display-steward.log`. The app appends ISO 8601-timestamped lines with category prefixes: `[AUTO]` (topology observations, rule evaluations, transactions, postconditions), `[HOTKEY]` (shortcut registration and use), `[RULES]` (rule seeding and errors).
- **LaunchAgent stderr**: `~/Library/Logs/com.anhoder.display-steward.error.log`.
- **Configuration and recovery evidence**: `~/.config/display-steward/` (`config.json`, `config.last-good.json`, `runtime-state.json`).
- **Single-instance lock**: `~/Library/Application Support/Display Steward/instance.lock`.

### Common issues

| Symptom | Check |
| --- | --- |
| App missing from the menu bar | `launchctl print "gui/$(id -u)/com.anhoder.display-steward"`; reinstall with `./install.sh` |
| Global hotkey not working | `[HOTKEY]` lines in the log; another app may hold the shortcut — change it in Settings |
| Automation not behaving as expected | `[AUTO] evaluation` lines show matched rules, winning actions, conflicts, and last-active-display safety blocks |
| Display behavior wrong after an upgrade | Rebuild and reinstall with `./install.sh`; run `./install.sh --smoke-test` first to verify artifacts without side effects |

## Development and Verification

Run the full test suite:

```sh
./test-all.sh
```

Test phases:

| Phase | Scope |
| --- | --- |
| Phase 1 | Domain model, rule evaluation, configuration storage and migration |
| Phase 2 | Display inventory, action transactions, automation and recovery lifecycle |
| Phase 3 | Presentation, profile drafts, and the AppKit management UI |
| Phase 4 | Launch, migration, menu bar, and end-to-end integration |

Run a single phase:

```sh
./test-phase1.sh
./test-phase2.sh
./test-phase3.sh
./test-phase4.sh
```

Before committing changes, it is recommended to run:

```sh
./test-all.sh
./install.sh --smoke-test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for further development constraints. Domain language and architecture decisions are recorded in [CONTEXT.md](CONTEXT.md), [SOUL.md](SOUL.md), and [`docs/adr/`](docs/adr/). Release history lives in [CHANGELOG.md](CHANGELOG.md); see [SECURITY.md](SECURITY.md) for the security policy.

## Main Modules

| File | Responsibility |
| --- | --- |
| `DisplaySteward.swift` | App entry point, menu bar, global hotkey, and AppKit lifecycle |
| `AutomationCoordinator.swift` | Automation scheduling, profile activation, action retries, and recovery coordination |
| `RuleModel.swift` | Display, rule, profile, and global settings models |
| `RuleEvaluator.swift` | Condition matching, priority merging, and last-active-display protection |
| `ConfigurationStore.swift` | Split configuration persistence, fallback, migration, and profile lifecycle |
| `RuntimeStateStore.swift` | Disable and restore evidence for the current launch |
| `AppPresentation.swift` | User-visible state and interaction copy |
| `ManagementUI.swift` | Settings, profile, rule, and display management UI |

## Safety Notes

Display enable/disable relies on the private CoreGraphics SPI `CGSConfigureDisplayEnabled`, resolved dynamically. The app confines it to a transaction adapter and verifies display topology and results before and after every operation, but macOS releases may still change this interface's behavior.

Before modifying real display state, make sure at least one usable display remains. Automation, recovery, and manual operations must all continue to satisfy the last-active-display safety constraint.

## License

[MIT](LICENSE) © 2026 anhoder
