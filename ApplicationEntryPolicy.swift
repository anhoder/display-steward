import Foundation

enum ApplicationLaunchMode: Equatable {
    case menuBarApplication
}

struct ApplicationEntryDecision: Equatable {
    var mode: ApplicationLaunchMode
    var requiresSingleInstanceLockBeforeRuntime: Bool
}

enum ApplicationEntryPolicy {
    static func decision(arguments: [String]) -> ApplicationEntryDecision {
        _ = arguments
        return ApplicationEntryDecision(
            mode: .menuBarApplication,
            requiresSingleInstanceLockBeforeRuntime: true
        )
    }
}

struct GlobalHotKeyReconciliationPlan: Equatable {
    var previous: HotKeyConfiguration?
    var desired: HotKeyConfiguration

    var requiresRegistration: Bool { previous != desired }

    func persistedConfiguration(afterRegistrationSucceeded succeeded: Bool) -> HotKeyConfiguration {
        succeeded ? desired : (previous ?? desired)
    }
}

enum GlobalHotKeyReconciliationPolicy {
    static func plan(
        registered: HotKeyConfiguration?,
        configured: HotKeyConfiguration
    ) -> GlobalHotKeyReconciliationPlan {
        GlobalHotKeyReconciliationPlan(previous: registered, desired: configured)
    }
}

enum ApplicationTerminationDecision: Equatable {
    case terminateNow
    case cancel
}

enum ApplicationTerminationPolicy {
    static func decision(dirtyDraftGuardAllowsTermination allowed: Bool) -> ApplicationTerminationDecision {
        allowed ? .terminateNow : .cancel
    }
}
