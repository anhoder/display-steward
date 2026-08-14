import Foundation

enum CycleAnalysisStatus: String, Codable, Equatable {
    case converged
    case deferred
    case invalidInput
    case indeterminate
    case cycleDetected
    case transitionLimitReached
}

struct SimulatedDisplayState: Codable, Equatable, Comparable {
    var display: EvaluatedDisplayKey
    var state: ObservableDisplayState
    var isMain: Bool

    static func < (lhs: SimulatedDisplayState, rhs: SimulatedDisplayState) -> Bool {
        lhs.display < rhs.display
    }
}

struct SimulatedStateFrame: Codable, Equatable {
    var displays: [SimulatedDisplayState]
}

struct CycleAnalysis: Codable, Equatable {
    var status: CycleAnalysisStatus
    var involvedRuleIDs: [UUID]
    var stateSequence: [SimulatedStateFrame]
    var diagnostics: [EvaluationDiagnostic]
}

struct RuleCycleAnalyzer {
    var evaluator = RuleEvaluator()

    func analyze(
        configuration: AppConfiguration,
        initialSnapshot: ObservedDisplaySnapshot,
        maximumTransitions: Int = 16
    ) -> CycleAnalysis {
        var snapshot = initialSnapshot
        var sequence = [frame(for: snapshot)]
        var seen = [stateSignature(snapshot): 0]
        var transitionRuleIDs: [[UUID]] = []
        var diagnostics: [EvaluationDiagnostic] = []
        let limit = max(1, maximumTransitions)

        for _ in 0..<limit {
            let plan = evaluator.evaluate(configuration: configuration, snapshot: snapshot)
            diagnostics.append(contentsOf: plan.diagnostics)

            if let blockedStatus = blockedStatus(for: plan) {
                return CycleAnalysis(
                    status: blockedStatus,
                    involvedRuleIDs: blockingRuleIDs(for: plan, configuration: configuration),
                    stateSequence: sequence,
                    diagnostics: diagnostics
                )
            }
            if plan.winningActions.isEmpty {
                return CycleAnalysis(
                    status: .converged,
                    involvedRuleIDs: [],
                    stateSequence: sequence,
                    diagnostics: diagnostics
                )
            }

            let transition = applying(plan: plan, to: snapshot)
            let nextSnapshot = transition.snapshot
            if nextSnapshot == snapshot {
                return CycleAnalysis(
                    status: .converged,
                    involvedRuleIDs: [],
                    stateSequence: sequence,
                    diagnostics: diagnostics
                )
            }

            transitionRuleIDs.append(transition.ruleIDs)
            sequence.append(frame(for: nextSnapshot))
            let signature = stateSignature(nextSnapshot)
            if let cycleStart = seen[signature] {
                let involved = orderedUnique(
                    transitionRuleIDs[cycleStart...].flatMap { $0 },
                    ruleOrder: configuration.rules.map(\.id)
                )
                return CycleAnalysis(
                    status: .cycleDetected,
                    involvedRuleIDs: involved,
                    stateSequence: Array(sequence[cycleStart...]),
                    diagnostics: diagnostics
                )
            }

            seen[signature] = sequence.count - 1
            snapshot = nextSnapshot
        }

        return CycleAnalysis(
            status: .transitionLimitReached,
            involvedRuleIDs: orderedUnique(
                transitionRuleIDs.flatMap { $0 },
                ruleOrder: configuration.rules.map(\.id)
            ),
            stateSequence: sequence,
            diagnostics: diagnostics
        )
    }

    private func blockedStatus(for plan: RuleEvaluationPlan) -> CycleAnalysisStatus? {
        if plan.diagnostics.contains(where: {
            $0.code == .invalidConfiguration || $0.code == .invalidSnapshot
        }) {
            return .invalidInput
        }
        if plan.safetyBlocks.contains(where: {
            $0.reason == .automationDisabled || $0.reason == .onlineDisplaysHaveNoActiveDisplay
        }) {
            return .deferred
        }
        if !plan.conflicts.isEmpty || !plan.unavailableTargets.isEmpty {
            return .indeterminate
        }
        return nil
    }

    private func blockingRuleIDs(
        for plan: RuleEvaluationPlan,
        configuration: AppConfiguration
    ) -> [UUID] {
        var ids = plan.conflicts.flatMap(\.ruleIDs)
        ids.append(contentsOf: plan.unavailableTargets.map(\.ruleID))
        if ids.isEmpty && plan.safetyBlocks.contains(where: {
            $0.reason == .automationDisabled || $0.reason == .onlineDisplaysHaveNoActiveDisplay
        }) {
            ids = plan.matchedRuleIDs
        }
        return orderedUnique(ids, ruleOrder: configuration.rules.map(\.id))
    }

    private func applying(
        plan: RuleEvaluationPlan,
        to snapshot: ObservedDisplaySnapshot
    ) -> (snapshot: ObservedDisplaySnapshot, ruleIDs: [UUID]) {
        let actions = Dictionary(uniqueKeysWithValues: plan.winningActions.map {
            ($0.display.runtimeID, $0)
        })
        var displays = snapshot.displays
        var changedRuleIDs: [UUID] = []

        for index in displays.indices {
            guard let runtimeID = displays[index].runtimeID,
                  let winning = actions[runtimeID] else { continue }
            let oldState = displays[index].state
            switch winning.action {
            case .noAction:
                break
            case .enable:
                if displays[index].state == .disabledByThisAppConnectionUnknown {
                    displays[index].state = .online
                }
            case .disable:
                displays[index].state = .disabledByThisAppConnectionUnknown
                displays[index].isMain = false
            }
            if displays[index].state != oldState {
                changedRuleIDs.append(contentsOf: winning.ruleIDs)
            }
        }

        if !displays.contains(where: { $0.isMain && $0.state.isActive }),
           let newMainIndex = displays.indices
            .filter({ displays[$0].state.isActive })
            .sorted(by: { mainDisplayOrder(displays[$0], displays[$1]) })
            .first {
            displays[newMainIndex].isMain = true
        }

        return (
            ObservedDisplaySnapshot(displays: displays),
            Array(Set(changedRuleIDs)).sorted { $0.uuidString < $1.uuidString }
        )
    }

    private func mainDisplayOrder(_ lhs: ObservedDisplay, _ rhs: ObservedDisplay) -> Bool {
        if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
        guard let leftKey = evaluatorKey(lhs), let rightKey = evaluatorKey(rhs) else {
            return lhs.runtimeID ?? 0 < rhs.runtimeID ?? 0
        }
        return leftKey < rightKey
    }

    private func evaluatorKey(_ display: ObservedDisplay) -> EvaluatedDisplayKey? {
        guard let runtimeID = display.runtimeID else { return nil }
        return EvaluatedDisplayKey(
            runtimeID: runtimeID,
            stableIdentity: display.stableIdentity,
            family: display.family
        )
    }

    private func frame(for snapshot: ObservedDisplaySnapshot) -> SimulatedStateFrame {
        let states = snapshot.displays.compactMap { display -> SimulatedDisplayState? in
            guard let key = evaluatorKey(display) else { return nil }
            return SimulatedDisplayState(
                display: key,
                state: display.state,
                isMain: display.isMain
            )
        }.sorted()
        return SimulatedStateFrame(displays: states)
    }

    private func stateSignature(_ snapshot: ObservedDisplaySnapshot) -> String {
        frame(for: snapshot).displays.map {
            "\($0.display.runtimeID):\($0.state.rawValue):\($0.isMain ? 1 : 0)"
        }.joined(separator: "|")
    }

    private func orderedUnique(_ ids: [UUID], ruleOrder: [UUID]) -> [UUID] {
        let wanted = Set(ids)
        let ordered = ruleOrder.filter { wanted.contains($0) }
        let unknown = wanted.subtracting(ordered).sorted { $0.uuidString < $1.uuidString }
        return ordered + unknown
    }
}
