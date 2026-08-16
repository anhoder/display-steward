# Display Steward Agent Guide

## Scope and architecture

Display Steward is a native macOS menu-bar app for rule-driven, multi-display management.

- `ApplicationEntryPolicy.swift` keeps every invocation on the locked menu-bar application entry; obsolete one-shot display-operation flags have no alternate path.
- `RuleModel.swift`, `RuleEvaluator.swift`, and `RuleCycleAnalyzer.swift` define and evaluate ordered rules.
- `ConfigurationStore.swift` owns validated JSON configuration and one-time legacy import.
- `RuntimeStateStore.swift` owns current-boot recovery journals and failure suppression.
- `DisplayInventory.swift` obtains online and active display lists from CoreGraphics; it never guesses display IDs.
- `DisplayActionAdapter.swift` is the only private-SPI boundary and applies one session transaction with postcondition checks.
- `AutomationCoordinator.swift` is the single automatic and manual coordination path.
- `AppPresentation.swift`, `ManagementUI.swift`, and `SevereNotificationPresenter.swift` expose truthful status, Rules and Displays management, menu presentation, and severe safety notifications.
- `DisplaySteward.swift` wires the app lifecycle, one coordinator, screen/wake events, polling, menu, windows, hotkey, logging, and the single-instance lock.
- `Shortcut.swift` provides native shortcut recording and Carbon key mapping.
- `build.sh`, `install.sh`, `Info.plist`, and `com.anhoder.display-steward.plist` define the local bundle and LaunchAgent.

## Product contract

- Rules are named, enabled, ordered, and independently prioritized. Conditions inside one rule are AND; multiple rules provide OR.
- Every matching rule contributes. The highest-priority explicit action wins per display; `noAction` has no opinion. Equal-priority enable/disable conflicts are reported, not guessed.
- Conditions support online or active counts over all or external displays (the macOS headless virtual framebuffer — vendor `unkn`, model `virt` — is excluded from both count scopes), exact-device state, vendor/model-family state, and always.
- Exact identity requires nonzero vendor, model, and serial values. Family identity uses vendor and model and intentionally applies to every current match.
- Observable states are `online`, `active` (awake/drawable), app-disabled with physical connection unknown, and not currently observed. Never describe cached or historical records as physically connected or disconnected.
- Enabling means making a display online. It must not implicitly alter mirroring, mode, layout, wake, brightness, or the main display.
- Preserve at least one active usable display. When equal-priority disables need arbitration, retain the current main display first, then a built-in display, then stable identity order.
- Automatic work uses screen events plus debounce and optional polling. Startup and wake share a stabilization deadline. If displays are online but none are active, defer instead of acting.
- Manual display operations use the coordinator and the same safety checks. They pause automation until a real online-identity topology change, explicit Resume, app restart, or Save and Apply.
- Aggregate recovery freezes the user-confirmed current-boot recovery targets, revalidates every identity, enables all still-actionable targets in one CoreGraphics session transaction, reports per-display restored/unresolved/uncertain/skipped outcomes, retires only durably settled evidence, and keeps automation paused. Online committed-uncertain records require explicit stable enable confirmation; history and stale boot IDs are never candidates.
- The aggregate entry label intentionally uses the user-facing copy `恢复所有由本应用关闭的显示器…`; its confirmation and per-display states must use Recoverable Display terminology and explicitly distinguish closed, pending-confirmation, unresolved, and uncertain evidence.
- Menu display commands are short-lived: refresh and re-resolve the row and expected hardware target before acting, then bind the coordinator request to that target.
- The main window is a concise overview. The management window has Rules and Displays pages. The status menu has per-display submenus. There is no fixed built-in-only automatic policy or duplicate policy path.
- The global hotkey remains a configurable built-in-display toggle, defaults to `⌃⌥⌘M`, and preserves the previous registration when a replacement fails.
- Two explicit Chinese default rules reproduce the old external-present behavior only after a reliable built-in target is known. An intentionally empty saved rule list remains empty and performs no hidden action.

## Persistence and runtime files

The only writable configuration source after migration is JSON under `~/.config/display-steward/`:

- `config.json` — current validated configuration.
- `config.last-good.json` — validated fallback generation.
- `runtime-state.json` — current-boot app-disabled records, pending/committed disable journals, unresolved recovery-attempt journals, and failure suppression.

On the first launch without either Display Steward configuration generation, move the former `~/.config/screen-manager` directory when present; otherwise import automatic mode, polling, hotkey, and built-in hardware identity from the former `com.anhoder.screen-manager` UserDefaults domain once. The legacy numeric display ID is never trusted. Once Display Steward JSON exists, changed legacy defaults are inert and are not rewritten or deleted.

Logs remain at `~/Library/Logs/com.anhoder.display-steward.log` and `~/Library/Logs/com.anhoder.display-steward.error.log`. The single-instance `flock` remains at `~/Library/Application Support/Display Steward/instance.lock`.

## Platform and safety limits

- Keep runtime dependencies to Swift, AppKit, CoreGraphics, Carbon.HIToolbox, Foundation, Darwin, and UserNotifications.
- Online discovery must use `CGGetOnlineDisplayList`; active/drawable discovery must use `CGGetActiveDisplayList`. Never scan arbitrary numeric display IDs.
- Display runtime IDs and app-disabled recovery handles are boot-scoped. A new boot discards them. A same-boot committed-uncertain journal is retained until a restore reaches a settled postcondition.
- If runtime state cannot load, automatic mode remains off. Every configuration save must first persist a fresh runtime state; a failed recovery rejects the save and remains visibly off.
- A committed-uncertain record is retained online only when runtime ID, stable identity, and family still match. Runtime-ID reuse discards the record with a surfaced diagnostic and can never promote it later.
- `CGSConfigureDisplayEnabled` is private SPI. Resolve it dynamically in `DisplayActionAdapter.swift` only. It can disappear or change on a macOS release; surface that failure and disable unsafe automation rather than adding another hidden implementation.
- Journal a disable before commit, bind transactions to a fresh topology fingerprint, verify global active-display safety, reread postconditions, compensate if a committed transaction leaves no active display, and retain uncertain recovery evidence.
- A corrupt primary falls back to last-good without overwriting evidence. If both generations are unusable, automatic actions stay disabled and the UI/logs report the error.
- Rule Preview is read-only: no configuration write, runtime-state write, display observation beyond the supplied/current snapshot, or display transaction.

## Change and verification workflow

1. Read affected symbols and every caller. Preserve the single coordinator and JSON ownership boundaries.
2. Run focused deterministic suites:

   ```bash
   ./test-phase1.sh
   ./test-phase2.sh
   ./test-phase3.sh
   ./test-phase4.sh
   # or, in the same sequence:
   ./test-all.sh
   ```

3. Build and validate artifacts:

   ```bash
   ./build.sh
   plutil -lint Info.plist com.anhoder.display-steward.plist
   ```
4. Run `./install.sh --smoke-test` for non-destructive install verification. It builds, stages and lints the LaunchAgent, checks its executable path, and verifies the bundle signature without touching the live service, configuration, or displays.

5. Only when real-service verification and display actions are explicitly authorized, run `./install.sh`, inspect `launchctl print "gui/$(id -u)/com.anhoder.display-steward"`, and confirm exactly one process.
6. Exercise the real UI and dry-run/read-only paths before any display action. For a disable scenario, begin with at least two active usable displays, never request disabling all of them, keep one visible screen throughout, then verify the postcondition in the Displays page and logs.
7. Inspect logs with `tail -n 200 ~/Library/Logs/com.anhoder.display-steward.log`. Evidence must include the observed topology, rule decision, transaction result, and postcondition or explicit uncertainty.

Do not install/restart the service or operate real displays during ordinary unit/integration work. Do not silently reset, delete, or rewrite legacy defaults or user configuration.
