# Display Steward

Display Steward manages macOS display state through explainable rules and explicit manual recovery while preserving a usable screen.

## Language

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
