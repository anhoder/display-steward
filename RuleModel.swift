import Foundation

struct DisplayFamily: Codable, Hashable, Comparable {
    var vendorID: UInt32
    var modelID: UInt32

    static func < (lhs: DisplayFamily, rhs: DisplayFamily) -> Bool {
        if lhs.vendorID != rhs.vendorID { return lhs.vendorID < rhs.vendorID }
        return lhs.modelID < rhs.modelID
    }

    var isValid: Bool { vendorID != 0 && modelID != 0 }
}

struct StableDisplayIdentity: Codable, Hashable, Comparable {
    var family: DisplayFamily
    var serialNumber: UInt32

    static func < (lhs: StableDisplayIdentity, rhs: StableDisplayIdentity) -> Bool {
        if lhs.family != rhs.family { return lhs.family < rhs.family }
        return lhs.serialNumber < rhs.serialNumber
    }

    var isReliable: Bool { family.isValid && serialNumber != 0 }
}

enum ObservableDisplayState: String, Codable, Equatable {
    case online
    case active
    case disabledByThisAppConnectionUnknown
    case notObserved

    var isOnline: Bool { self == .online || self == .active }
    var isActive: Bool { self == .active }

    func satisfies(_ condition: ObservableDisplayState) -> Bool {
        switch condition {
        case .online:
            return isOnline
        case .active:
            return isActive
        case .disabledByThisAppConnectionUnknown:
            return self == .disabledByThisAppConnectionUnknown
        case .notObserved:
            return self == .notObserved
        }
    }
}
struct DisplayModeDetails: Codable, Equatable {
    var logicalWidth: Int
    var logicalHeight: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var refreshRate: Double
    var rotationDegrees: Double
    var scaleFactor: Double?
}


struct ObservedDisplay: Codable, Equatable {
    var runtimeID: UInt32?
    var stableIdentity: StableDisplayIdentity?
    var family: DisplayFamily
    var name: String?
    var isBuiltIn: Bool
    var isMain: Bool
    var state: ObservableDisplayState
    var mirrorsRuntimeID: UInt32?
    var mode: DisplayModeDetails?

    init(
        runtimeID: UInt32?,
        stableIdentity: StableDisplayIdentity?,
        family: DisplayFamily,
        name: String? = nil,
        isBuiltIn: Bool,
        isMain: Bool,
        state: ObservableDisplayState,
        mirrorsRuntimeID: UInt32? = nil,
        mode: DisplayModeDetails? = nil
    ) {
        self.runtimeID = runtimeID
        self.stableIdentity = stableIdentity
        self.family = family
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
        self.state = state
        self.mirrorsRuntimeID = mirrorsRuntimeID
        self.mode = mode
    }
}

struct ObservedDisplaySnapshot: Codable, Equatable {
    var displays: [ObservedDisplay]

    init(displays: [ObservedDisplay]) {
        self.displays = displays
    }

    var onlineCount: Int { displays.filter { $0.state.isOnline }.count }
    var activeCount: Int { displays.filter { $0.state.isActive }.count }
}

enum DisplayCountKind: String, Codable, Equatable {
    case online
    case active
}

enum DisplayCountScope: String, Codable, Equatable {
    case all
    case external
}

enum CountComparisonOperator: String, Codable, Equatable {
    case equal
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual

    func compare(_ lhs: Int, _ rhs: Int) -> Bool {
        switch self {
        case .equal: return lhs == rhs
        case .greaterThan: return lhs > rhs
        case .greaterThanOrEqual: return lhs >= rhs
        case .lessThan: return lhs < rhs
        case .lessThanOrEqual: return lhs <= rhs
        }
    }
}

struct DisplayCountCondition: Codable, Equatable {
    var kind: DisplayCountKind
    var scope: DisplayCountScope
    var comparison: CountComparisonOperator
    var value: Int
}

enum RuleCondition: Codable, Equatable {
    case always
    case count(DisplayCountCondition)
    case exactState(identity: StableDisplayIdentity, state: ObservableDisplayState)
    case familyState(family: DisplayFamily, state: ObservableDisplayState)
}

enum DisplayTarget: Codable, Hashable {
    case exact(StableDisplayIdentity)
    case family(DisplayFamily)
}

enum DisplayAction: String, Codable, Hashable {
    case noAction
    case enable
    case disable
}

struct TargetAction: Codable, Equatable {
    var target: DisplayTarget
    var action: DisplayAction
}

struct DisplayRule: Codable, Equatable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var priority: Int
    var conditions: [RuleCondition]
    var actions: [TargetAction]
}

struct AutomaticConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var startupStabilizationSeconds: TimeInterval
    var wakeStabilizationSeconds: TimeInterval

    static let `default` = AutomaticConfiguration(
        isEnabled: true,
        startupStabilizationSeconds: 3,
        wakeStabilizationSeconds: 3
    )
}

struct PollingConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var intervalSeconds: TimeInterval

    static let `default` = PollingConfiguration(isEnabled: true, intervalSeconds: 3)
}

struct HotKeyConfiguration: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = HotKeyConfiguration(keyCode: 2, modifiers: 0x1A00)
}

struct KnownDisplay: Codable, Equatable {
    var target: DisplayTarget
    var name: String?
    var isBuiltIn: Bool
    var alias: String? = nil
}

struct AppConfiguration: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var automatic: AutomaticConfiguration
    var polling: PollingConfiguration
    var hotKey: HotKeyConfiguration
    var deviceHistory: [KnownDisplay]
    var rules: [DisplayRule]

    static let `default` = AppConfiguration(
        schemaVersion: currentSchemaVersion,
        automatic: .default,
        polling: .default,
        hotKey: .default,
        deviceHistory: [],
        rules: []
    )

    func validate() throws {
        var issues: [ConfigurationValidationIssue] = []

        if schemaVersion != Self.currentSchemaVersion {
            issues.append(.init(path: "schemaVersion", message: "unsupported schema version \(schemaVersion)"))
        }
        if !automatic.startupStabilizationSeconds.isFinite
            || !(0...60).contains(automatic.startupStabilizationSeconds) {
            issues.append(.init(path: "automatic.startupStabilizationSeconds", message: "must be between 0 and 60"))
        }
        if !automatic.wakeStabilizationSeconds.isFinite
            || !(0...60).contains(automatic.wakeStabilizationSeconds) {
            issues.append(.init(path: "automatic.wakeStabilizationSeconds", message: "must be between 0 and 60"))
        }
        if !polling.intervalSeconds.isFinite || !(1...3600).contains(polling.intervalSeconds) {
            issues.append(.init(path: "polling.intervalSeconds", message: "must be between 1 and 3600"))
        }
        if hotKey.modifiers == 0 {
            issues.append(.init(path: "hotKey.modifiers", message: "must contain at least one modifier"))
        }

        var historyTargets = Set<DisplayTarget>()
        for (index, display) in deviceHistory.enumerated() {
            validate(target: display.target, path: "deviceHistory[\(index)].target", issues: &issues)
            if !historyTargets.insert(display.target).inserted {
                issues.append(.init(path: "deviceHistory[\(index)].target", message: "duplicate display history target"))
            }
        }

        var ruleIDs = Set<UUID>()
        for (ruleIndex, rule) in rules.enumerated() {
            let path = "rules[\(ruleIndex)]"
            if !ruleIDs.insert(rule.id).inserted {
                issues.append(.init(path: "\(path).id", message: "duplicate rule ID"))
            }
            if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "\(path).name", message: "must not be empty"))
            }
            if rule.conditions.isEmpty {
                issues.append(.init(path: "\(path).conditions", message: "must contain at least one condition"))
            }
            if rule.conditions.count > 1 && rule.conditions.contains(.always) {
                issues.append(.init(path: "\(path).conditions", message: "always cannot be combined with other conditions"))
            }
            for (conditionIndex, condition) in rule.conditions.enumerated() {
                validate(condition: condition, path: "\(path).conditions[\(conditionIndex)]", issues: &issues)
            }

            var actionTargets = Set<DisplayTarget>()
            for (actionIndex, action) in rule.actions.enumerated() {
                let actionPath = "\(path).actions[\(actionIndex)].target"
                validate(target: action.target, path: actionPath, issues: &issues)
                if !actionTargets.insert(action.target).inserted {
                    issues.append(.init(path: actionPath, message: "duplicate target in rule"))
                }
            }
        }

        if !issues.isEmpty { throw ConfigurationValidationError(issues: issues) }
    }

    private func validate(
        condition: RuleCondition,
        path: String,
        issues: inout [ConfigurationValidationIssue]
    ) {
        switch condition {
        case .always:
            break
        case .count(let count):
            if count.value < 0 {
                issues.append(.init(path: "\(path).value", message: "must not be negative"))
            }
        case .exactState(let identity, _):
            if !identity.isReliable {
                issues.append(.init(path: "\(path).identity", message: "exact matching requires nonzero vendor, model, and serial numbers"))
            }
        case .familyState(let family, _):
            if !family.isValid {
                issues.append(.init(path: "\(path).family", message: "family requires nonzero vendor and model numbers"))
            }
        }
    }

    private func validate(
        target: DisplayTarget,
        path: String,
        issues: inout [ConfigurationValidationIssue]
    ) {
        switch target {
        case .exact(let identity):
            if !identity.isReliable {
                issues.append(.init(path: path, message: "exact target requires nonzero vendor, model, and serial numbers"))
            }
        case .family(let family):
            if !family.isValid {
                issues.append(.init(path: path, message: "family target requires nonzero vendor and model numbers"))
            }
        }
    }
}

struct ConfigurationValidationIssue: Codable, Equatable {
    var path: String
    var message: String
}

struct ConfigurationValidationError: Error, LocalizedError, Equatable {
    var issues: [ConfigurationValidationIssue]

    var errorDescription: String? {
        issues.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
    }
}
