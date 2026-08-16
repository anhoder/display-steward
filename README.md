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
- **Global hotkey**: Default `⌃⌥⇧D` toggles the built-in display; configurable in Settings.

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

See [CONTRIBUTING.md](CONTRIBUTING.md) for further development constraints. Domain language and architecture decisions are recorded in [CONTEXT.md](CONTEXT.md), [SOUL.md](SOUL.md), and [`docs/adr/`](docs/adr/).

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
