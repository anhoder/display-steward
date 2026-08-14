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
