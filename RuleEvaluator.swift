import Foundation

struct EvaluatedDisplayKey: Codable, Hashable, Comparable {
    var runtimeID: UInt32
    var stableIdentity: StableDisplayIdentity?
    var family: DisplayFamily

    static func < (lhs: EvaluatedDisplayKey, rhs: EvaluatedDisplayKey) -> Bool {
        switch (lhs.stableIdentity, rhs.stableIdentity) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.family != rhs.family { return lhs.family < rhs.family }
            return lhs.runtimeID < rhs.runtimeID
        }
    }
}

struct WinningDisplayAction: Codable, Equatable {
    var display: EvaluatedDisplayKey
    var action: DisplayAction
    var priority: Int
    var ruleIDs: [UUID]
}

struct PriorityConflict: Codable, Equatable {
    var display: EvaluatedDisplayKey
    var priority: Int
    var ruleIDs: [UUID]
    var actions: [DisplayAction]
}

enum UnavailableTargetReason: String, Codable, Equatable {
    case noMatchingDisplay
    case noBootScopedRuntimeID
    case targetNotObserved
}

struct UnavailableTarget: Codable, Equatable {
    var ruleID: UUID
    var target: DisplayTarget
    var action: DisplayAction
    var reason: UnavailableTargetReason
}

enum SafetyBlockReason: String, Codable, Equatable {
    case automationDisabled
    case onlineDisplaysHaveNoActiveDisplay
    case retainedLastActiveDisplay
}

struct SafetyBlock: Codable, Equatable {
    var reason: SafetyBlockReason
    var display: EvaluatedDisplayKey?
    var blockedRuleIDs: [UUID]
}

enum EvaluationDiagnosticSeverity: String, Codable, Equatable {
    case info
    case warning
    case error
}

enum EvaluationDiagnosticCode: String, Codable, Equatable {
    case invalidConfiguration
    case invalidSnapshot
    case automationDisabled
    case sleepingDisplayDeferral
    case unavailableTarget
    case priorityConflict
    case safetyActionBlocked
}

struct EvaluationDiagnostic: Codable, Equatable {
    var severity: EvaluationDiagnosticSeverity
    var code: EvaluationDiagnosticCode
    var message: String
    var ruleID: UUID?
}

struct RuleEvaluationPlan: Codable, Equatable {
    var matchedRuleIDs: [UUID]
    var winningActions: [WinningDisplayAction]
    var conflicts: [PriorityConflict]
    var unavailableTargets: [UnavailableTarget]
    var safetyBlocks: [SafetyBlock]
    var diagnostics: [EvaluationDiagnostic]

    static let empty = RuleEvaluationPlan(
        matchedRuleIDs: [],
        winningActions: [],
        conflicts: [],
        unavailableTargets: [],
        safetyBlocks: [],
        diagnostics: []
    )
}

struct RuleEvaluator {
    func evaluate(
        configuration: AppConfiguration,
        snapshot: ObservedDisplaySnapshot
    ) -> RuleEvaluationPlan {
        do {
            try configuration.validate()
        } catch {
            return RuleEvaluationPlan(
                matchedRuleIDs: [],
                winningActions: [],
                conflicts: [],
                unavailableTargets: [],
                safetyBlocks: [],
                diagnostics: [EvaluationDiagnostic(
                    severity: .error,
                    code: .invalidConfiguration,
                    message: error.localizedDescription,
                    ruleID: nil
                )]
            )
        }

        let snapshotDiagnostics = validate(snapshot: snapshot)
        if snapshotDiagnostics.contains(where: { $0.severity == .error }) {
            return RuleEvaluationPlan(
                matchedRuleIDs: [],
                winningActions: [],
                conflicts: [],
                unavailableTargets: [],
                safetyBlocks: [],
                diagnostics: snapshotDiagnostics
            )
        }

        let matchedRules = configuration.rules.filter {
            $0.isEnabled && matches(rule: $0, snapshot: snapshot)
        }
        let matchedRuleIDs = matchedRules.map(\.id)

        guard configuration.automatic.isEnabled else {
            return RuleEvaluationPlan(
                matchedRuleIDs: matchedRuleIDs,
                winningActions: [],
                conflicts: [],
                unavailableTargets: [],
                safetyBlocks: [SafetyBlock(
                    reason: .automationDisabled,
                    display: nil,
                    blockedRuleIDs: matchedRuleIDs
                )],
                diagnostics: snapshotDiagnostics + [EvaluationDiagnostic(
                    severity: .info,
                    code: .automationDisabled,
                    message: "Automatic rule evaluation is disabled.",
                    ruleID: nil
                )]
            )
        }

        if snapshot.onlineCount > 0 && snapshot.activeCount == 0 {
            return RuleEvaluationPlan(
                matchedRuleIDs: matchedRuleIDs,
                winningActions: [],
                conflicts: [],
                unavailableTargets: [],
                safetyBlocks: [SafetyBlock(
                    reason: .onlineDisplaysHaveNoActiveDisplay,
                    display: nil,
                    blockedRuleIDs: matchedRuleIDs
                )],
                diagnostics: snapshotDiagnostics + [EvaluationDiagnostic(
                    severity: .info,
                    code: .sleepingDisplayDeferral,
                    message: "Evaluation deferred because displays are online but none are active.",
                    ruleID: nil
                )]
            )
        }

        var candidates: [EvaluatedDisplayKey: [ActionCandidate]] = [:]
        var unavailable: [UnavailableTarget] = []

        for rule in matchedRules {
            for targetAction in rule.actions where targetAction.action != .noAction {
                let matchingDisplays = displays(matching: targetAction.target, in: snapshot)
                if matchingDisplays.isEmpty {
                    unavailable.append(UnavailableTarget(
                        ruleID: rule.id,
                        target: targetAction.target,
                        action: targetAction.action,
                        reason: .noMatchingDisplay
                    ))
                    continue
                }

                for display in matchingDisplays {
                    guard display.state != .notObserved else {
                        unavailable.append(UnavailableTarget(
                            ruleID: rule.id,
                            target: targetAction.target,
                            action: targetAction.action,
                            reason: .targetNotObserved
                        ))
                        continue
                    }
                    guard let key = key(for: display) else {
                        unavailable.append(UnavailableTarget(
                            ruleID: rule.id,
                            target: targetAction.target,
                            action: targetAction.action,
                            reason: .noBootScopedRuntimeID
                        ))
                        continue
                    }
                    candidates[key, default: []].append(ActionCandidate(
                        action: targetAction.action,
                        priority: rule.priority,
                        ruleID: rule.id
                    ))
                }
            }
        }

        var winners: [WinningDisplayAction] = []
        var conflicts: [PriorityConflict] = []
        for key in candidates.keys.sorted() {
            guard let displayCandidates = candidates[key],
                  let highestPriority = displayCandidates.map(\.priority).max() else { continue }
            let highest = displayCandidates.filter { $0.priority == highestPriority }
            let actions = Array(Set(highest.map(\.action))).sorted { $0.rawValue < $1.rawValue }
            let ruleIDs = orderedRuleIDs(from: highest, rules: configuration.rules)

            if actions.count > 1 {
                conflicts.append(PriorityConflict(
                    display: key,
                    priority: highestPriority,
                    ruleIDs: ruleIDs,
                    actions: actions
                ))
            } else if let action = actions.first {
                winners.append(WinningDisplayAction(
                    display: key,
                    action: action,
                    priority: highestPriority,
                    ruleIDs: ruleIDs
                ))
            }
        }

        var safetyBlocks: [SafetyBlock] = []
        enforceActiveDisplaySafety(
            snapshot: snapshot,
            winningActions: &winners,
            safetyBlocks: &safetyBlocks
        )

        winners.sort { $0.display < $1.display }
        conflicts.sort { $0.display < $1.display }
        unavailable.sort(by: unavailableTargetOrder)

        var diagnostics = snapshotDiagnostics
        diagnostics.append(contentsOf: unavailable.map {
            EvaluationDiagnostic(
                severity: .warning,
                code: .unavailableTarget,
                message: "Rule target is unavailable: \($0.reason.rawValue).",
                ruleID: $0.ruleID
            )
        })
        diagnostics.append(contentsOf: conflicts.map {
            EvaluationDiagnostic(
                severity: .error,
                code: .priorityConflict,
                message: "Equal-priority rules request conflicting actions for display \($0.display.runtimeID).",
                ruleID: nil
            )
        })
        diagnostics.append(contentsOf: safetyBlocks.map {
            EvaluationDiagnostic(
                severity: .warning,
                code: .safetyActionBlocked,
                message: "A disable action was blocked to retain an active display.",
                ruleID: $0.blockedRuleIDs.first
            )
        })

        return RuleEvaluationPlan(
            matchedRuleIDs: matchedRuleIDs,
            winningActions: winners,
            conflicts: conflicts,
            unavailableTargets: unavailable,
            safetyBlocks: safetyBlocks,
            diagnostics: diagnostics
        )
    }

    private func matches(rule: DisplayRule, snapshot: ObservedDisplaySnapshot) -> Bool {
        rule.conditions.allSatisfy { matches(condition: $0, snapshot: snapshot) }
    }

    private func matches(condition: RuleCondition, snapshot: ObservedDisplaySnapshot) -> Bool {
        switch condition {
        case .always:
            return true
        case .count(let condition):
            let scoped = snapshot.displays.filter {
                condition.scope == .all || !$0.isBuiltIn
            }
            let count: Int
            switch condition.kind {
            case .online:
                count = scoped.filter { $0.state.isOnline }.count
            case .active:
                count = scoped.filter { $0.state.isActive }.count
            }
            return condition.comparison.compare(count, condition.value)
        case .exactState(let identity, let state):
            let matching = snapshot.displays.filter { $0.stableIdentity == identity }
            if matching.isEmpty { return state == .notObserved }
            return matching.contains { $0.state.satisfies(state) }
        case .familyState(let family, let state):
            let matching = snapshot.displays.filter { $0.family == family }
            if matching.isEmpty { return state == .notObserved }
            return matching.contains { $0.state.satisfies(state) }
        }
    }

    private func displays(
        matching target: DisplayTarget,
        in snapshot: ObservedDisplaySnapshot
    ) -> [ObservedDisplay] {
        snapshot.displays.filter { display in
            switch target {
            case .exact(let identity): return display.stableIdentity == identity
            case .family(let family): return display.family == family
            }
        }
    }

    private func key(for display: ObservedDisplay) -> EvaluatedDisplayKey? {
        guard let runtimeID = display.runtimeID else { return nil }
        return EvaluatedDisplayKey(
            runtimeID: runtimeID,
            stableIdentity: display.stableIdentity,
            family: display.family
        )
    }

    private func orderedRuleIDs(
        from candidates: [ActionCandidate],
        rules: [DisplayRule]
    ) -> [UUID] {
        let ids = Set(candidates.map(\.ruleID))
        return rules.map(\.id).filter { ids.contains($0) }
    }

    private func enforceActiveDisplaySafety(
        snapshot: ObservedDisplaySnapshot,
        winningActions: inout [WinningDisplayAction],
        safetyBlocks: inout [SafetyBlock]
    ) {
        let activeDisplays = snapshot.displays.filter { $0.state.isActive }
        guard !activeDisplays.isEmpty else { return }

        let disabledRuntimeIDs = Set(winningActions.compactMap {
            $0.action == .disable ? $0.display.runtimeID : nil
        })
        if activeDisplays.contains(where: {
            guard let runtimeID = $0.runtimeID else { return true }
            return !disabledRuntimeIDs.contains(runtimeID)
        }) {
            return
        }

        let candidates: [(display: ObservedDisplay, action: WinningDisplayAction)] = activeDisplays.compactMap { display in
            guard let runtimeID = display.runtimeID,
                  let action = winningActions.first(where: {
                      $0.display.runtimeID == runtimeID && $0.action == .disable
                  }) else { return nil }
            return (display, action)
        }
        guard let retained = candidates.sorted(by: safetyRetentionOrder).first else { return }

        winningActions.removeAll { $0.display == retained.action.display }
        safetyBlocks.append(SafetyBlock(
            reason: .retainedLastActiveDisplay,
            display: retained.action.display,
            blockedRuleIDs: retained.action.ruleIDs
        ))
    }

    private func safetyRetentionOrder(
        _ lhs: (display: ObservedDisplay, action: WinningDisplayAction),
        _ rhs: (display: ObservedDisplay, action: WinningDisplayAction)
    ) -> Bool {
        if lhs.action.priority != rhs.action.priority {
            return lhs.action.priority < rhs.action.priority
        }
        if lhs.display.isMain != rhs.display.isMain { return lhs.display.isMain }
        if lhs.display.isBuiltIn != rhs.display.isBuiltIn { return lhs.display.isBuiltIn }
        return lhs.action.display < rhs.action.display
    }

    private func unavailableTargetOrder(_ lhs: UnavailableTarget, _ rhs: UnavailableTarget) -> Bool {
        if lhs.ruleID != rhs.ruleID { return lhs.ruleID.uuidString < rhs.ruleID.uuidString }
        if lhs.action != rhs.action { return lhs.action.rawValue < rhs.action.rawValue }
        return targetSortKey(lhs.target) < targetSortKey(rhs.target)
    }

    private func targetSortKey(_ target: DisplayTarget) -> String {
        switch target {
        case .exact(let identity):
            return "e:\(identity.family.vendorID):\(identity.family.modelID):\(identity.serialNumber)"
        case .family(let family):
            return "f:\(family.vendorID):\(family.modelID)"
        }
    }

    private func validate(snapshot: ObservedDisplaySnapshot) -> [EvaluationDiagnostic] {
        var diagnostics: [EvaluationDiagnostic] = []
        var runtimeIDs = Set<UInt32>()
        var identities = Set<StableDisplayIdentity>()

        for display in snapshot.displays {
            if let identity = display.stableIdentity {
                if !identity.isReliable {
                    diagnostics.append(EvaluationDiagnostic(
                        severity: .error,
                        code: .invalidSnapshot,
                        message: "Observed exact identity is not reliable.",
                        ruleID: nil
                    ))
                } else if !identities.insert(identity).inserted {
                    diagnostics.append(EvaluationDiagnostic(
                        severity: .error,
                        code: .invalidSnapshot,
                        message: "Observed snapshot contains a duplicate exact identity.",
                        ruleID: nil
                    ))
                }
            }
            if let runtimeID = display.runtimeID {
                if runtimeID == 0 {
                    diagnostics.append(EvaluationDiagnostic(
                        severity: .error,
                        code: .invalidSnapshot,
                        message: "Observed runtime display ID must be nonzero.",
                        ruleID: nil
                    ))
                } else if !runtimeIDs.insert(runtimeID).inserted {
                    diagnostics.append(EvaluationDiagnostic(
                        severity: .error,
                        code: .invalidSnapshot,
                        message: "Observed snapshot contains a duplicate runtime display ID.",
                        ruleID: nil
                    ))
                }
            }
            if display.state.isOnline && display.runtimeID == nil {
                diagnostics.append(EvaluationDiagnostic(
                    severity: .error,
                    code: .invalidSnapshot,
                    message: "An online display must have a runtime display ID.",
                    ruleID: nil
                ))
            }
            if display.isMain && !display.state.isActive {
                diagnostics.append(EvaluationDiagnostic(
                    severity: .error,
                    code: .invalidSnapshot,
                    message: "The main display must be active.",
                    ruleID: nil
                ))
            }
        }
        return diagnostics
    }
}

private struct ActionCandidate {
    var action: DisplayAction
    var priority: Int
    var ruleID: UUID
}
