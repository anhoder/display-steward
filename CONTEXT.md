# Display Steward

Display Steward manages macOS display state through explainable rules and explicit manual recovery while preserving a usable screen.

## Language

**Display Profile（显示配置档）**:
A uniquely named set of Automation settings and Rules with a stable identity. One local canonical file persists each Profile, but the Profile is the domain object rather than the file itself.
_Avoid_: Scene, location, configuration file, display snapshot

**Active Profile（当前配置档）**:
The single Display Profile manually selected to govern display behavior. It remains active across application and system restarts until the user selects another Profile.
_Avoid_: Detected profile, automatic profile

**Application Settings（应用设置）**:
Settings shared by every Display Profile, including the application hotkey and Display History Records.
_Avoid_: Global profile, default profile

**Automation（自动化）**:
The mechanism that evaluates enabled Rules in the Active Profile and applies their resolved display actions. Stopping or pausing Automation does not change whether individual Rules are enabled.
_Avoid_: Automatic rules, rule enablement

**Rule（规则）**:
A condition-and-action policy that belongs to one Display Profile and can remain enabled or disabled independently of Automation's running state.
_Avoid_: Automation, automatic rule

**Current Display（当前显示器）**:
A display represented by current observation rather than configuration history alone. It may be active, online, or carry current-startup recovery evidence.
_Avoid_: Known display, historical display

**Display History Record（显示器历史记录）**:
A persisted display identity, name, and optional alias retained for recognition and Rule references when the display is not currently observed. It is not evidence of a physical connection or a recoverable state.
_Avoid_: Offline display, current display, Recoverable Display


**Recoverable Display（可恢复显示器）**:
A display for which Display Steward retains current-startup evidence that one of its disable attempts may be responsible for the display state. It includes confirmed disables and unresolved interrupted attempts, and excludes ordinary display history.
_Avoid_: App-disabled display, offline display, historical display

**Recovery Pending Confirmation（恢复待确认）**:
A Recoverable Display currently observed online whose preceding disable outcome remains unresolved. It is not considered restored until an explicit recovery settles.
_Avoid_: Online, restored

**Restored Display（已恢复显示器）**:
A former Recoverable Display that remained online through confirmation and whose recovery evidence was durably retired.
_Avoid_: Enabled display

**Unresolved Recovery（仍需恢复）**:
A recovery attempt that failed or did not settle while Display Steward still retains recovery evidence.
_Avoid_: Failed display

**Uncertain Recovery State（恢复状态不确定）**:
An outcome where a display change may have committed but Display Steward could not establish and persist a reliable final state.
_Avoid_: Restored, failed

**Recovery Evidence（恢复证据）**:
Current-startup evidence that attributes a disable attempt to one specific display identity strongly enough to permit recovery. It remains until recovery settles or later observation proves the identity stale.
_Avoid_: Recovery handle, display history, offline status
