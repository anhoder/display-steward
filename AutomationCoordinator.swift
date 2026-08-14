import Foundation

protocol AutomationScheduledTask: AnyObject {
    func cancel()
}

protocol AutomationScheduling: AnyObject {
    var now: Date { get }
    func schedule(after delay: TimeInterval, repeating interval: TimeInterval?, _ action: @escaping () -> Void) -> AutomationScheduledTask
}

private final class DispatchAutomationTask: AutomationScheduledTask {
    private let source: DispatchSourceTimer
    init(source: DispatchSourceTimer) { self.source = source }
    func cancel() {
        source.setEventHandler {}
        source.cancel()
    }
}

final class DispatchAutomationScheduler: AutomationScheduling {
    var now: Date { Date() }

    func schedule(after delay: TimeInterval, repeating interval: TimeInterval?, _ action: @escaping () -> Void) -> AutomationScheduledTask {
        let source = DispatchSource.makeTimerSource(queue: .main)
        let deadline = DispatchTime.now() + max(0, delay)
        if let interval {
            source.schedule(deadline: deadline, repeating: dispatchInterval(max(0.001, interval)))
        } else {
            source.schedule(deadline: deadline, repeating: .never)
        }
        source.setEventHandler(handler: action)
        source.resume()
        return DispatchAutomationTask(source: source)
    }

    private func dispatchInterval(_ seconds: TimeInterval) -> DispatchTimeInterval {
        .nanoseconds(Int(min(seconds * 1_000_000_000, Double(Int.max))))
    }
}

enum AutomationPauseReason: String, Equatable {
    case manualDisplayAction
    case explicit
}

enum RuntimeDiagnosticSeverity: String, Equatable {
    case info
    case warning
    case error
}

enum RuntimeDiagnosticCode: String, Equatable {
    case configurationFallback
    case configurationUnavailable
    case runtimeStateUnavailable
    case staleBootStateDiscarded
    case legacyRecoveryImported
    case automationPaused
    case actionSuppressed
    case actionFailed
    case cycleRulesDisabled
    case safetyRecovery
    case statePersistenceFailed
    case staleRuntimeIdentityDiscarded
}

struct RuntimeDiagnostic: Equatable {
    var severity: RuntimeDiagnosticSeverity
    var code: RuntimeDiagnosticCode
    var message: String
}

struct ConfigurationPreview: Equatable {
    var evaluation: RuleEvaluationPlan
    var cycleAnalysis: CycleAnalysis
}

enum DisplayRecoveryEvidenceKind: String, Equatable {
    case disabledByApplication
    case pendingConfirmation
}

struct DisplayRecoveryTarget: Equatable {
    var display: EvaluatedDisplayKey
    var name: String?
    var isBuiltIn: Bool
    var observedState: ObservableDisplayState
    var evidence: DisplayRecoveryEvidenceKind
}

struct DisplayRecoveryPlan: Equatable {
    var targets: [DisplayRecoveryTarget]

    static let empty = DisplayRecoveryPlan(targets: [])
    var isEmpty: Bool { targets.isEmpty }
}

enum DisplayRecoveryDisposition: String, Equatable {
    case restored
    case unresolved
    case uncertain
    case skipped
}

struct DisplayRecoveryItemResult: Equatable {
    var target: DisplayRecoveryTarget
    var disposition: DisplayRecoveryDisposition
    var explanation: String
}

struct DisplayRecoveryBatchResult: Equatable {
    var items: [DisplayRecoveryItemResult]

    var unresolvedTargets: [DisplayRecoveryTarget] {
        items.compactMap {
            $0.disposition == .unresolved || $0.disposition == .uncertain ? $0.target : nil
        }
    }

    var hasRetryableTargets: Bool { !unresolvedTargets.isEmpty }
}

struct AutomationRuntimeStatus: Equatable {
    var configuration: AppConfiguration
    var inventory: ObservedDisplaySnapshot
    var lastEvaluation: RuleEvaluationPlan
    var lastCycleAnalysis: CycleAnalysis?
    var lastTrigger: String?
    var pauseReason: AutomationPauseReason?
    var diagnostics: [RuntimeDiagnostic]
    var configurationLoadSource: ConfigurationLoadSource?
    var recoveryPlan: DisplayRecoveryPlan = .empty
    var lastRecoveryResult: DisplayRecoveryBatchResult? = nil

    var isPaused: Bool { pauseReason != nil }
}

enum AutomationCoordinatorError: Error, LocalizedError {
    case displayNotFound(UInt32)
    case invalidManualAction
    case displayIdentityChanged(UInt32)
    case lastActiveDisplay
    case actionFailed(String)

    var errorDescription: String? {
        switch self {
        case .displayNotFound(let runtimeID):
            return "Runtime display \(runtimeID) is not in the current boot-scoped inventory."
        case .invalidManualAction:
            return "Manual display actions must explicitly enable or disable one display."
        case .displayIdentityChanged(let runtimeID):
            return "Runtime display \(runtimeID) no longer has the identity selected by the caller."
        case .lastActiveDisplay:
            return "The manual action was blocked because it would remove the last active usable display."
        case .actionFailed(let message):
            return message
        }
    }
}

protocol DisplayManagingRuntime: AnyObject {
    var status: AutomationRuntimeStatus { get }
    func previewConfigurationReadOnly(
        _ configuration: AppConfiguration,
        observation: ObservedDisplaySnapshot?
    ) throws -> ConfigurationPreview
    @discardableResult func updateConfiguration(_ configuration: AppConfiguration, applyImmediately: Bool) throws -> AutomationRuntimeStatus
    @discardableResult func performManualAction(runtimeID: UInt32, action: DisplayAction) throws -> AutomationRuntimeStatus
    func prepareDisplayRecovery(only targets: [DisplayRecoveryTarget]?) throws -> DisplayRecoveryPlan
    @discardableResult func restoreDisplays(_ plan: DisplayRecoveryPlan) -> DisplayRecoveryBatchResult
    func pause()
    func resume()
    @discardableResult func refresh() throws -> AutomationRuntimeStatus
}

final class AutomationCoordinator: DisplayManagingRuntime {
    var onStatusChange: (() -> Void)?

    private let configurationStore: ConfigurationStore
    private let runtimeStateStore: RuntimeStateStore
    private let adapter: DisplayRuntimeAdapting
    private let evaluator: RuleEvaluator
    private let cycleAnalyzer: RuleCycleAnalyzer
    private let scheduler: AutomationScheduling
    private let debounceSeconds: TimeInterval
    private let maximumActionAttempts: Int
    private let suppressionSeconds: TimeInterval
    private let log: (String) -> Void
    private let lock = NSRecursiveLock()

    private var configuration: AppConfiguration
    private var runtimeState: RuntimeState
    private var configurationIsWritable: Bool
    private var runtimeStateIsWritable: Bool
    private var automaticEnabledAfterRuntimeRecovery: Bool?
    private var baseDiagnostics: [RuntimeDiagnostic]
    private var currentStatus: AutomationRuntimeStatus
    private var pendingEvaluation: AutomationScheduledTask?
    private var pollingTask: AutomationScheduledTask?
    private var generation = 0
    private var manualTopologyBaseline: Set<String>?
    private var manualRecoverySelfTopologyChanges: Set<String>?
    private var automaticNotBefore: Date?
    private var shouldGenerateInitialDefaultRules: Bool

    var status: AutomationRuntimeStatus {
        lock.lock()
        defer { lock.unlock() }
        return currentStatus
    }

    init(
        configurationStore: ConfigurationStore = ConfigurationStore(),
        runtimeStateStore: RuntimeStateStore = RuntimeStateStore(),
        adapter: DisplayRuntimeAdapting,
        evaluator: RuleEvaluator = RuleEvaluator(),
        cycleAnalyzer: RuleCycleAnalyzer = RuleCycleAnalyzer(),
        scheduler: AutomationScheduling = DispatchAutomationScheduler(),
        debounceSeconds: TimeInterval = 1.5,
        maximumActionAttempts: Int = 3,
        suppressionSeconds: TimeInterval = 60,
        log: @escaping (String) -> Void = { _ in }
    ) throws {
        self.configurationStore = configurationStore
        self.runtimeStateStore = runtimeStateStore
        self.adapter = adapter
        self.evaluator = evaluator
        self.cycleAnalyzer = cycleAnalyzer
        self.scheduler = scheduler
        self.debounceSeconds = max(0, debounceSeconds)
        self.maximumActionAttempts = max(1, maximumActionAttempts)
        self.suppressionSeconds = max(1, suppressionSeconds)
        self.log = log

        var diagnostics: [RuntimeDiagnostic] = []
        let loadedConfiguration: AppConfiguration
        let loadSource: ConfigurationLoadSource?
        do {
            let loaded = try configurationStore.loadOrMigrate()
            loadedConfiguration = loaded.configuration
            loadSource = loaded.source
            if loaded.source == .lastKnownGoodBackup {
                diagnostics.append(RuntimeDiagnostic(
                    severity: .warning,
                    code: .configurationFallback,
                    message: loaded.primaryErrorDescription.map {
                        "Using config.last-good.json because config.json is invalid: \($0)"
                    } ?? "Using config.last-good.json because config.json is unavailable."
                ))
            }
        } catch {
            var disabled = AppConfiguration.default
            disabled.automatic.isEnabled = false
            loadedConfiguration = disabled
            loadSource = nil
            diagnostics.append(RuntimeDiagnostic(
                severity: .error,
                code: .configurationUnavailable,
                message: "Automation is disabled because neither configuration generation is usable: \(error.localizedDescription)"
            ))
        }

        var loadedRuntimeState: RuntimeState
        var runtimeStateWasLoaded = true
        do {
            let loaded = try runtimeStateStore.load(
                importLegacyMarker: loadSource == .migratedLegacyDefaults
            )
            loadedRuntimeState = loaded.state
            if loaded.discardedStaleBootState {
                diagnostics.append(RuntimeDiagnostic(
                    severity: .info,
                    code: .staleBootStateDiscarded,
                    message: "Boot-scoped runtime display IDs from an earlier boot were discarded."
                ))
                try runtimeStateStore.save(loaded.state)
            }
            if loaded.importedLegacyMarker {
                diagnostics.append(RuntimeDiagnostic(
                    severity: .info,
                    code: .legacyRecoveryImported,
                    message: "The legacy built-in display identity was imported without trusting its saved runtime ID."
                ))
            }
        } catch {
            runtimeStateWasLoaded = false
            loadedRuntimeState = try runtimeStateStore.freshState()
            diagnostics.append(RuntimeDiagnostic(
                severity: .error,
                code: .runtimeStateUnavailable,
                message: "Runtime state could not be loaded; automation is disabled until it is explicitly saved: \(error.localizedDescription)"
            ))
        }

        var effectiveConfiguration = loadedConfiguration
        if diagnostics.contains(where: { $0.code == .configurationUnavailable || $0.code == .runtimeStateUnavailable }) {
            effectiveConfiguration.automatic.isEnabled = false
        }

        configuration = effectiveConfiguration
        runtimeState = loadedRuntimeState
        runtimeStateIsWritable = runtimeStateWasLoaded
        automaticEnabledAfterRuntimeRecovery = runtimeStateWasLoaded
            ? nil
            : loadedConfiguration.automatic.isEnabled
        configurationIsWritable = loadSource != nil && loadSource != .lastKnownGoodBackup
        shouldGenerateInitialDefaultRules = (
            loadSource == .createdDefaults || loadSource == .migratedLegacyDefaults
        ) && effectiveConfiguration.rules.isEmpty
        baseDiagnostics = diagnostics
        currentStatus = AutomationRuntimeStatus(
            configuration: effectiveConfiguration,
            inventory: ObservedDisplaySnapshot(displays: []),
            lastEvaluation: .empty,
            lastCycleAnalysis: nil,
            lastTrigger: nil,
            pauseReason: nil,
            diagnostics: diagnostics,
            configurationLoadSource: loadSource
        )
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        manualTopologyBaseline = nil
        manualRecoverySelfTopologyChanges = nil
        currentStatus.pauseReason = nil
        do {
            let snapshot = try observeAndNormalize()
            currentStatus.inventory = snapshot
            currentStatus.configuration = configuration
            scheduleEvaluation(after: configuration.automatic.startupStabilizationSeconds, trigger: "startup")
            restartPolling()
            publishStatus()
        } catch {
            recordRuntimeError(.runtimeStateUnavailable, "Startup inventory failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        pendingEvaluation?.cancel()
        pendingEvaluation = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    func handleWake() {
        lock.lock()
        defer { lock.unlock() }
        scheduleEvaluation(after: configuration.automatic.wakeStabilizationSeconds, trigger: "wake")
    }

    func handleDisplayEvent() {
        lock.lock()
        defer { lock.unlock() }
        handleObservedTrigger(trigger: "display-event", delay: debounceSeconds)
    }

    func previewConfigurationReadOnly(
        _ candidate: AppConfiguration,
        observation: ObservedDisplaySnapshot?
    ) throws -> ConfigurationPreview {
        lock.lock()
        defer { lock.unlock() }
        try candidate.validate()
        let snapshot = observation ?? currentStatus.inventory
        return ConfigurationPreview(
            evaluation: evaluator.evaluate(configuration: candidate, snapshot: snapshot),
            cycleAnalysis: cycleAnalyzer.analyze(configuration: candidate, initialSnapshot: snapshot)
        )
    }

    @discardableResult
    func updateConfiguration(_ candidate: AppConfiguration, applyImmediately: Bool) throws -> AutomationRuntimeStatus {
        lock.lock()
        defer { lock.unlock() }
        try candidate.validate()
        try recoverRuntimeStatePersistenceIfNeeded()
        try configurationStore.save(candidate)
        configuration = candidate
        configurationIsWritable = true
        shouldGenerateInitialDefaultRules = false
        baseDiagnostics.removeAll { $0.code == .configurationUnavailable || $0.code == .configurationFallback }
        currentStatus.configurationLoadSource = .primary
        currentStatus.configuration = candidate
        restartPolling()

        if applyImmediately {
            currentStatus.pauseReason = nil
            manualTopologyBaseline = nil
            manualRecoverySelfTopologyChanges = nil
            try evaluateAndMaybeApply(trigger: "save-and-apply", applyActions: true)
        } else {
            let snapshot = try observeAndNormalize()
            currentStatus.inventory = snapshot
            currentStatus.lastEvaluation = evaluator.evaluate(configuration: configuration, snapshot: snapshot)
            currentStatus.lastCycleAnalysis = cycleAnalyzer.analyze(configuration: configuration, initialSnapshot: snapshot)
            currentStatus.lastTrigger = "save"
            currentStatus.diagnostics = baseDiagnostics
            publishStatus()
        }
        return currentStatus
    }

    @discardableResult
    func performManualAction(runtimeID: UInt32, action: DisplayAction) throws -> AutomationRuntimeStatus {
        try performManualAction(runtimeID: runtimeID, action: action, expectedTarget: nil)
    }

    @discardableResult
    func performManualAction(
        runtimeID: UInt32,
        action: DisplayAction,
        expectedTarget: DisplayTarget?
    ) throws -> AutomationRuntimeStatus {
        lock.lock()
        defer { lock.unlock() }
        guard action != .noAction else { throw AutomationCoordinatorError.invalidManualAction }
        let snapshot = try observeAndNormalize()
        guard runtimeID != 0, let display = snapshot.displays.first(where: { $0.runtimeID == runtimeID }) else {
            throw AutomationCoordinatorError.displayNotFound(runtimeID)
        }
        if let expectedTarget, !self.display(display, matches: expectedTarget) {
            throw AutomationCoordinatorError.displayIdentityChanged(runtimeID)
        }
        let request = DisplayActionRequest(
            display: EvaluatedDisplayKey(runtimeID: runtimeID, stableIdentity: display.stableIdentity, family: display.family),
            action: action
        )
        let recoveryTarget = action == .enable
            ? recoveryPlan(for: snapshot).targets.first(where: { $0.display == request.display })
            : nil
        if recoveryTarget != nil {
            do {
                try beginRecoveryAttempts([request])
            } catch {
                recordRuntimeStatePersistenceFailure(error)
                finishManualRecoveryFailure(
                    request: request,
                    snapshot: snapshot,
                    baselineIsReliable: true,
                    message: "无法在恢复前持久化恢复证据：\(error.localizedDescription)"
                )
                throw AutomationCoordinatorError.actionFailed(error.localizedDescription)
            }
        }
        if action == .disable { try enforceActiveSafety(requests: [request], snapshot: snapshot) }
        try journalPendingDisables([request], snapshot: snapshot)

        let outcome: DisplayTransactionOutcome
        var afterWasObserved = true
        do {
            outcome = try adapter.apply(
                requests: [request],
                expectedFingerprint: policyFingerprint(snapshot),
                configuration: configuration,
                runtimeState: runtimeState,
                didCommit: { try self.markPendingDisablesCommitted([request]) }
            )
        } catch {
            let committedUnknown = isCommittedUnknown(error)
                || runtimeState.pendingDisableDisplays.contains {
                    $0.runtimeID == request.display.runtimeID
                        && $0.phase == .committedUncertain
                }
            if committedUnknown { afterWasObserved = false }
            outcome = DisplayTransactionOutcome(
                before: snapshot,
                after: committedUnknown ? ObservedDisplaySnapshot(displays: []) : snapshot,
                results: [DisplayActionResult(
                    request: request,
                    succeeded: false,
                    wasIdempotent: false,
                    errorDescription: error.localizedDescription
                )],
                transactionWasCommitted: committedUnknown
            )
        }
        if recoveryTarget != nil,
           let succeeded = outcome.results.first(where: { $0.succeeded }) {
            do {
                try retireRecoveryEvidence(for: [succeeded.request])
            } catch {
                recordRuntimeStatePersistenceFailure(error)
                finishManualRecoveryFailure(
                    request: request,
                    snapshot: outcome.after,
                    baselineIsReliable: true,
                    message: "显示器已在线，但恢复证据无法可靠持久化：\(error.localizedDescription)"
                )
                throw AutomationCoordinatorError.actionFailed(error.localizedDescription)
            }
        } else {
            try applyConfirmedResults(outcome.results)
        }
        try clearPendingForKnownUncommittedFailures(outcome)
        if outcome.requiresReevaluation {
            let message = "The display topology changed before the manual transaction; refresh and try again."
            if recoveryTarget != nil {
                finishManualRecoveryFailure(
                    request: request,
                    snapshot: snapshot,
                    baselineIsReliable: true,
                    message: message
                )
            }
            throw AutomationCoordinatorError.actionFailed(message)
        }
        let safetyDiagnostic = try recoverIfCommittedWithoutActiveDisplay(
            outcome: outcome,
            disableRequests: [request]
        )
        if let failed = outcome.results.first(where: { !$0.succeeded }) {
            if recoveryTarget != nil {
                var recoverySnapshot = afterWasObserved ? outcome.after : snapshot
                if !afterWasObserved,
                   let observed = try? adapter.observe(configuration: configuration, runtimeState: runtimeState) {
                    recoverySnapshot = observed
                }
                finishManualRecoveryFailure(
                    request: request,
                    snapshot: recoverySnapshot,
                    baselineIsReliable: afterWasObserved,
                    message: failed.errorDescription ?? "The manual display recovery failed."
                )
            } else if let safetyDiagnostic {
                currentStatus.inventory = try observeAndNormalize()
                currentStatus.lastTrigger = "manual-recovery"
                currentStatus.diagnostics = baseDiagnostics + [safetyDiagnostic]
                publishStatus()
            }
            throw AutomationCoordinatorError.actionFailed(failed.errorDescription ?? "The manual display action failed.")
        }

        let after: ObservedDisplaySnapshot
        if recoveryTarget != nil {
            after = outcome.after
        } else {
            after = try observeAndNormalize()
        }
        currentStatus.inventory = after
        currentStatus.lastEvaluation = evaluator.evaluate(configuration: configuration, snapshot: after)
        currentStatus.lastCycleAnalysis = cycleAnalyzer.analyze(configuration: configuration, initialSnapshot: after)
        currentStatus.lastTrigger = recoveryTarget == nil ? "manual" : "manual-recovery"
        if safetyDiagnostic == nil {
            currentStatus.pauseReason = .manualDisplayAction
            manualTopologyBaseline = onlineTopology(in: after)
            manualRecoverySelfTopologyChanges = nil
        }
        currentStatus.diagnostics = baseDiagnostics + [safetyDiagnostic ?? RuntimeDiagnostic(
            severity: .info,
            code: .automationPaused,
            message: "Automation is paused until online display identity topology changes, Resume is chosen, the app restarts, or Save and Apply is used."
        )]
        publishStatus()
        return currentStatus
    }
    func prepareDisplayRecovery(only targets: [DisplayRecoveryTarget]?) throws -> DisplayRecoveryPlan {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = try observeAndNormalize()
        let available = recoveryPlan(for: snapshot)
        currentStatus.inventory = snapshot
        currentStatus.recoveryPlan = available
        currentStatus.lastEvaluation = evaluator.evaluate(configuration: configuration, snapshot: snapshot)
        currentStatus.lastCycleAnalysis = cycleAnalyzer.analyze(configuration: configuration, initialSnapshot: snapshot)
        currentStatus.lastTrigger = "manual-recovery-preview"
        currentStatus.diagnostics = baseDiagnostics
        publishStatus()

        guard let targets else { return available }
        let confirmedKeys = Set(targets.map(\.display))
        return DisplayRecoveryPlan(
            targets: available.targets.filter { confirmedKeys.contains($0.display) }
        )
    }

    @discardableResult
    func restoreDisplays(_ plan: DisplayRecoveryPlan) -> DisplayRecoveryBatchResult {
        lock.lock()
        defer { lock.unlock() }

        currentStatus.pauseReason = .manualDisplayAction
        manualTopologyBaseline = nil
        manualRecoverySelfTopologyChanges = nil

        let snapshot: ObservedDisplaySnapshot
        do {
            snapshot = try observeAndNormalize()
        } catch {
            let items = plan.targets.map {
                DisplayRecoveryItemResult(
                    target: $0,
                    disposition: .unresolved,
                    explanation: "执行前无法刷新显示器状态：\(error.localizedDescription)"
                )
            }
            return finishDisplayRecovery(items: items, snapshot: currentStatus.inventory)
        }

        let available = recoveryPlan(for: snapshot)
        let availableByKey = Dictionary(uniqueKeysWithValues: available.targets.map { ($0.display, $0) })
        var itemResults: [EvaluatedDisplayKey: DisplayRecoveryItemResult] = [:]
        var actionableTargets: [DisplayRecoveryTarget] = []
        for target in plan.targets {
            let currentTarget = availableByKey[target.display]
            if currentTarget?.evidence == target.evidence,
               currentTarget?.observedState == target.observedState {
                actionableTargets.append(target)
                continue
            }
            let runtimeIdentityChanged = snapshot.displays.contains {
                $0.runtimeID == target.display.runtimeID
                    && ($0.stableIdentity != target.display.stableIdentity || $0.family != target.display.family)
            }
            itemResults[target.display] = DisplayRecoveryItemResult(
                target: target,
                disposition: .skipped,
                explanation: runtimeIdentityChanged
                    ? "运行时显示器身份已变化，已安全跳过。"
                    : currentTarget != nil
                        ? "确认后的恢复证据或观察状态已变化，请重新确认。"
                        : "该显示器已不再需要恢复，已跳过。"
            )
        }

        var finalSnapshot = snapshot
        var finalSnapshotIsReliable = true
        let requests = actionableTargets.map {
            DisplayActionRequest(display: $0.display, action: .enable)
        }
        if !requests.isEmpty {
            do {
                try beginRecoveryAttempts(requests)
            } catch {
                recordRuntimeStatePersistenceFailure(error)
                for target in actionableTargets {
                    itemResults[target.display] = DisplayRecoveryItemResult(
                        target: target,
                        disposition: .unresolved,
                        explanation: "无法在事务前持久化恢复证据，未执行显示器操作：\(error.localizedDescription)"
                    )
                }
                let items = plan.targets.map { target in
                    itemResults[target.display] ?? DisplayRecoveryItemResult(
                        target: target,
                        disposition: .skipped,
                        explanation: "该显示器没有可执行的恢复请求。"
                    )
                }
                return finishDisplayRecovery(items: items, snapshot: snapshot)
            }
            do {
                let outcome = try adapter.apply(
                    requests: requests,
                    expectedFingerprint: policyFingerprint(snapshot),
                    configuration: configuration,
                    runtimeState: runtimeState,
                    didCommit: {}
                )
                finalSnapshot = outcome.after
                if outcome.requiresReevaluation {
                    for target in actionableTargets {
                        itemResults[target.display] = DisplayRecoveryItemResult(
                            target: target,
                            disposition: .skipped,
                            explanation: "确认后显示器拓扑发生变化，请重新确认后重试。"
                        )
                    }
                } else {
                    var restoredRequests: [DisplayActionRequest] = []
                    for target in actionableTargets {
                        guard let actionResult = outcome.results.first(where: {
                            $0.request.display == target.display
                        }) else {
                            itemResults[target.display] = DisplayRecoveryItemResult(
                                target: target,
                                disposition: .uncertain,
                                explanation: "事务没有返回该显示器的确定结果，恢复证据已保留。"
                            )
                            continue
                        }
                        if actionResult.succeeded {
                            restoredRequests.append(actionResult.request)
                            itemResults[target.display] = DisplayRecoveryItemResult(
                                target: target,
                                disposition: .restored,
                                explanation: "显示器已持续在线，恢复证据已清理。"
                            )
                        } else {
                            itemResults[target.display] = DisplayRecoveryItemResult(
                                target: target,
                                disposition: .unresolved,
                                explanation: actionResult.errorDescription ?? "显示器未达到稳定在线状态，恢复证据已保留。"
                            )
                        }
                    }

                    if !restoredRequests.isEmpty {
                        do {
                            try retireRecoveryEvidence(for: restoredRequests)
                        } catch {
                            for request in restoredRequests {
                                guard let target = actionableTargets.first(where: { $0.display == request.display }) else { continue }
                                itemResults[request.display] = DisplayRecoveryItemResult(
                                    target: target,
                                    disposition: .uncertain,
                                    explanation: "显示器已在线，但恢复证据无法可靠持久化：\(error.localizedDescription)"
                                )
                            }
                            recordRuntimeStatePersistenceFailure(error)
                        }
                    }
                }
            } catch {
                let committedUnknown = isCommittedUnknown(error)
                let disposition: DisplayRecoveryDisposition = committedUnknown ? .uncertain : .unresolved
                if committedUnknown { finalSnapshotIsReliable = false }
                for target in actionableTargets {
                    itemResults[target.display] = DisplayRecoveryItemResult(
                        target: target,
                        disposition: disposition,
                        explanation: disposition == .uncertain
                            ? "事务可能已提交，但最终状态无法确认；恢复证据已保留。"
                            : "恢复事务未完成：\(error.localizedDescription)"
                    )
                }
                if let observed = try? adapter.observe(configuration: configuration, runtimeState: runtimeState) {
                    finalSnapshot = observed
                    finalSnapshotIsReliable = !committedUnknown
                }
            }
        }

        let items = plan.targets.map { target in
            itemResults[target.display] ?? DisplayRecoveryItemResult(
                target: target,
                disposition: .skipped,
                explanation: "该显示器没有可执行的恢复请求。"
            )
        }
        return finishDisplayRecovery(
            items: items,
            snapshot: finalSnapshot,
            baselineIsReliable: finalSnapshotIsReliable
        )
    }

    func pause() {
        lock.lock()
        defer { lock.unlock() }
        currentStatus.pauseReason = .explicit
        manualTopologyBaseline = nil
        manualRecoverySelfTopologyChanges = nil
        currentStatus.diagnostics = baseDiagnostics + [RuntimeDiagnostic(
            severity: .info,
            code: .automationPaused,
            message: "Automation is explicitly paused."
        )]
        publishStatus()
    }


    func resume() {
        lock.lock()
        defer { lock.unlock() }
        do {
            try recoverRuntimeStatePersistenceIfNeeded()
        } catch {
            log("[STATE] resume blocked until runtime state can be persisted: \(error.localizedDescription)")
            return
        }
        currentStatus.pauseReason = nil
        manualTopologyBaseline = nil
        manualRecoverySelfTopologyChanges = nil
        do {
            try evaluateAndMaybeApply(trigger: "resume", applyActions: true)
        } catch {
            recordRuntimeError(.actionFailed, "Resume evaluation failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func refresh() throws -> AutomationRuntimeStatus {
        lock.lock()
        defer { lock.unlock() }
        try evaluateAndMaybeApply(trigger: "refresh", applyActions: false)
        return currentStatus
    }

    private func scheduleEvaluation(after delay: TimeInterval, trigger: String) {
        let requestedDeadline = scheduler.now.addingTimeInterval(max(0, delay))
        if automaticNotBefore == nil || requestedDeadline > automaticNotBefore! {
            automaticNotBefore = requestedDeadline
        }
        let deadline = automaticNotBefore ?? requestedDeadline
        generation += 1
        let scheduledGeneration = generation
        pendingEvaluation?.cancel()
        pendingEvaluation = scheduler.schedule(
            after: max(0, deadline.timeIntervalSince(scheduler.now)),
            repeating: nil
        ) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.generation == scheduledGeneration else { return }
            guard self.scheduler.now >= deadline else {
                self.scheduleEvaluation(
                    after: deadline.timeIntervalSince(self.scheduler.now),
                    trigger: trigger
                )
                return
            }
            self.pendingEvaluation = nil
            self.automaticNotBefore = nil
            do {
                try self.evaluateAndMaybeApply(trigger: trigger, applyActions: true)
            } catch {
                self.recordRuntimeError(.actionFailed, "\(trigger) evaluation failed: \(error.localizedDescription)")
            }
        }
    }

    private func restartPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        guard configuration.automatic.isEnabled, configuration.polling.isEnabled else { return }
        pollingTask = scheduler.schedule(after: configuration.polling.intervalSeconds, repeating: configuration.polling.intervalSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.handleObservedTrigger(trigger: "poll", delay: 0)
        }
    }

    private func handleObservedTrigger(trigger: String, delay: TimeInterval) {
        do {
            let snapshot = try observeAndNormalize()
            currentStatus.inventory = snapshot
            resumeManualPauseIfTopologyChanged(snapshot)
            scheduleEvaluation(after: delay, trigger: trigger)
            publishStatus()
        } catch {
            recordRuntimeError(.runtimeStateUnavailable, "\(trigger) inventory failed: \(error.localizedDescription)")
        }
    }

    private func resumeManualPauseIfTopologyChanged(_ snapshot: ObservedDisplaySnapshot) {
        guard currentStatus.pauseReason == .manualDisplayAction else { return }
        let observedTopology = onlineTopology(in: snapshot)
        guard let baseline = manualTopologyBaseline else {
            manualTopologyBaseline = observedTopology
            manualRecoverySelfTopologyChanges = nil
            log("[AUTO] established a post-recovery topology baseline while keeping automation paused")
            return
        }
        let changes = observedTopology.symmetricDifference(baseline)
        guard !changes.isEmpty else { return }
        if let recoveryChanges = manualRecoverySelfTopologyChanges,
           changes.isSubset(of: recoveryChanges) {
            manualTopologyBaseline = observedTopology
            let remaining = recoveryChanges.subtracting(changes)
            manualRecoverySelfTopologyChanges = remaining.isEmpty ? nil : remaining
            log("[AUTO] recovery-generated topology change kept automation paused")
            return
        }
        currentStatus.pauseReason = nil
        manualTopologyBaseline = nil
        manualRecoverySelfTopologyChanges = nil
        log("[AUTO] manual pause ended after an actual online identity topology change")
    }

    private func evaluateAndMaybeApply(trigger: String, applyActions: Bool) throws {
        var diagnostics = baseDiagnostics
        var snapshot = try observeAndNormalize()
        let analysis = cycleAnalyzer.analyze(configuration: configuration, initialSnapshot: snapshot)
        currentStatus.lastCycleAnalysis = analysis

        if analysis.status == .cycleDetected && !analysis.involvedRuleIDs.isEmpty {
            let involved = Set(analysis.involvedRuleIDs)
            var safeConfiguration = configuration
            for index in safeConfiguration.rules.indices where involved.contains(safeConfiguration.rules[index].id) {
                safeConfiguration.rules[index].isEnabled = false
            }
            if configurationIsWritable {
                do {
                    try configurationStore.save(safeConfiguration)
                } catch {
                    configurationIsWritable = false
                    diagnostics.append(RuntimeDiagnostic(
                        severity: .error,
                        code: .configurationUnavailable,
                        message: "Cycle participants were disabled in memory but could not be persisted: \(error.localizedDescription)"
                    ))
                }
            }
            configuration = safeConfiguration
            diagnostics.append(RuntimeDiagnostic(
                severity: .warning,
                code: .cycleRulesDisabled,
                message: "Rules participating in a runtime cycle were disabled: \(analysis.involvedRuleIDs.map(\.uuidString).joined(separator: ", "))."
            ))
        }

        let plan = evaluator.evaluate(configuration: configuration, snapshot: snapshot)
        currentStatus.configuration = configuration
        currentStatus.inventory = snapshot
        currentStatus.lastEvaluation = plan
        currentStatus.lastTrigger = trigger
        logEvaluation(trigger: trigger, snapshot: snapshot, plan: plan)

        guard applyActions, configuration.automatic.isEnabled, currentStatus.pauseReason == nil else {
            if currentStatus.pauseReason != nil {
                diagnostics.append(RuntimeDiagnostic(
                    severity: .info,
                    code: .automationPaused,
                    message: "Automatic actions were not applied because automation is paused."
                ))
            }
            currentStatus.diagnostics = diagnostics
            publishStatus()
            return
        }

        let boundFingerprint = policyFingerprint(snapshot)
        let now = scheduler.now
        let oldSuppressionCount = runtimeState.failureSuppressions.count
        runtimeState.failureSuppressions.removeAll { $0.suppressedUntil <= now }
        if oldSuppressionCount != runtimeState.failureSuppressions.count { try persistRuntimeState() }

        if !plan.winningActions.isEmpty {
            diagnostics.append(contentsOf: try applyWithRetries(
                initialSnapshot: snapshot,
                initialPlan: plan,
                boundFingerprint: boundFingerprint
            ))
            snapshot = try observeAndNormalize()
            currentStatus.inventory = snapshot
        }
        currentStatus.diagnostics = diagnostics
        publishStatus()
    }

    private func applyWithRetries(
        initialSnapshot: ObservedDisplaySnapshot,
        initialPlan: RuleEvaluationPlan,
        boundFingerprint: DisplayPolicySnapshotFingerprint
    ) throws -> [RuntimeDiagnostic] {
        var retryKeys: Set<String>?
        var finalFailures: [DisplayActionResult] = []
        var diagnostics: [RuntimeDiagnostic] = []
        let initialMatchesBinding = policyFingerprint(initialSnapshot) == boundFingerprint

        for attempt in 1...maximumActionAttempts {
            let freshSnapshot = try observeAndNormalize()
            let freshFingerprint = policyFingerprint(freshSnapshot)
            let plan = attempt == 1 && initialMatchesBinding && freshFingerprint == boundFingerprint
                ? initialPlan
                : evaluator.evaluate(configuration: configuration, snapshot: freshSnapshot)
            currentStatus.inventory = freshSnapshot
            currentStatus.lastEvaluation = plan

            var requests = plan.winningActions.map {
                DisplayActionRequest(display: $0.display, action: $0.action)
            }
            if let retryKeys {
                requests.removeAll { !retryKeys.contains(actionKey($0)) }
            }
            try enforceActiveSafety(requests: requests, snapshot: freshSnapshot)
            requests.removeAll { request in
                let suppressed = runtimeState.failureSuppressions.contains {
                    $0.target == suppressionTarget(for: request.display)
                        && $0.action == request.action
                        && $0.suppressedUntil > scheduler.now
                }
                if suppressed {
                    diagnostics.append(RuntimeDiagnostic(
                        severity: .warning,
                        code: .actionSuppressed,
                        message: "Suppressed \(request.action.rawValue) for runtime display \(request.display.runtimeID) after repeated failures."
                    ))
                }
                return suppressed
            }
            guard !requests.isEmpty else {
                finalFailures = []
                break
            }

            try journalPendingDisables(requests, snapshot: freshSnapshot)
            let outcome: DisplayTransactionOutcome
            var afterWasObserved = true
            do {
                outcome = try adapter.apply(
                    requests: requests,
                    expectedFingerprint: freshFingerprint,
                    configuration: configuration,
                    runtimeState: runtimeState,
                    didCommit: { try self.markPendingDisablesCommitted(requests) }
                )
            } catch {
                let committedUnknown = isCommittedUnknown(error)
                    || requests.contains(where: { request in
                        runtimeState.pendingDisableDisplays.contains {
                            $0.runtimeID == request.display.runtimeID
                                && $0.phase == .committedUncertain
                        }
                    })
                if committedUnknown { afterWasObserved = false }
                outcome = DisplayTransactionOutcome(
                    before: freshSnapshot,
                    after: committedUnknown ? ObservedDisplaySnapshot(displays: []) : freshSnapshot,
                    results: requests.map {
                        DisplayActionResult(
                            request: $0,
                            succeeded: false,
                            wasIdempotent: false,
                            errorDescription: error.localizedDescription
                        )
                    },
                    transactionWasCommitted: committedUnknown
                )
            }
            logTransactionOutcome(
                attempt: attempt,
                outcome: outcome,
                afterWasObserved: afterWasObserved
            )
            if outcome.requiresReevaluation {
                try clearPendingForKnownUncommittedFailures(outcome)
                retryKeys = nil
                continue
            }
            try applyConfirmedResults(outcome.results)
            try clearPendingForKnownUncommittedFailures(outcome)
            if let safety = try recoverIfCommittedWithoutActiveDisplay(
                outcome: outcome,
                disableRequests: requests
            ) {
                diagnostics.append(safety)
                finalFailures = []
                break
            }

            finalFailures = outcome.results.filter { !$0.succeeded }
            retryKeys = Set(finalFailures.map { actionKey($0.request) })
            if finalFailures.isEmpty { break }
            log("[AUTO] display action attempt \(attempt)/\(maximumActionAttempts) failed for runtime IDs \(finalFailures.map { $0.request.display.runtimeID })")
        }

        guard !finalFailures.isEmpty else { return diagnostics }
        let now = scheduler.now
        for failure in finalFailures {
            let target = suppressionTarget(for: failure.request.display)
            let previous = runtimeState.failureSuppressions.first { $0.target == target && $0.action == failure.request.action }
            runtimeState.failureSuppressions.removeAll { $0.target == target && $0.action == failure.request.action }
            runtimeState.failureSuppressions.append(FailureSuppressionRecord(
                target: target,
                action: failure.request.action,
                consecutiveFailureCount: (previous?.consecutiveFailureCount ?? 0) + 1,
                suppressedUntil: now.addingTimeInterval(suppressionSeconds),
                lastError: failure.errorDescription ?? "Unknown display action failure"
            ))
        }
        try persistRuntimeState()
        diagnostics.append(contentsOf: finalFailures.map {
            RuntimeDiagnostic(
                severity: .error,
                code: .actionFailed,
                message: "\($0.request.action.rawValue) failed for runtime display \($0.request.display.runtimeID): \($0.errorDescription ?? "unknown error")"
            )
        })
        return diagnostics
    }

    private func applyConfirmedResults(_ results: [DisplayActionResult]) throws {
        var changed = false
        for result in results where result.succeeded {
            let request = result.request
            let target = suppressionTarget(for: request.display)
            let suppressionCount = runtimeState.failureSuppressions.count
            runtimeState.failureSuppressions.removeAll { $0.target == target && $0.action == request.action }
            changed = changed || suppressionCount != runtimeState.failureSuppressions.count

            switch request.action {
            case .noAction:
                break
            case .enable:
                let oldCount = runtimeState.appDisabledDisplays.count
                let oldPendingCount = runtimeState.pendingDisableDisplays.count
                let oldRecoveryCount = runtimeState.pendingRecoveryDisplays.count
                runtimeState.appDisabledDisplays.removeAll {
                    $0.runtimeID == request.display.runtimeID && $0.stableIdentity == request.display.stableIdentity && $0.family == request.display.family
                }
                runtimeState.pendingDisableDisplays.removeAll {
                    $0.runtimeID == request.display.runtimeID
                }
                runtimeState.pendingRecoveryDisplays.removeAll {
                    $0.runtimeID == request.display.runtimeID && $0.stableIdentity == request.display.stableIdentity && $0.family == request.display.family
                }
                changed = changed
                    || oldCount != runtimeState.appDisabledDisplays.count
                    || oldPendingCount != runtimeState.pendingDisableDisplays.count
                    || oldRecoveryCount != runtimeState.pendingRecoveryDisplays.count
            case .disable:
                guard !result.wasIdempotent else { break }
                runtimeState.pendingDisableDisplays.removeAll { $0.runtimeID == request.display.runtimeID }
                runtimeState.appDisabledDisplays.removeAll { $0.runtimeID == request.display.runtimeID }
                runtimeState.pendingRecoveryDisplays.removeAll { $0.runtimeID == request.display.runtimeID }
                runtimeState.appDisabledDisplays.append(AppDisabledDisplayRecord(
                    runtimeID: request.display.runtimeID,
                    stableIdentity: request.display.stableIdentity,
                    family: request.display.family
                ))
                changed = true
            }
        }
        if changed { try persistRuntimeState() }
    }

    private func observeAndNormalize() throws -> ObservedDisplaySnapshot {
        var snapshot = try adapter.observe(configuration: configuration, runtimeState: runtimeState)
        var stateChanged = false
        let onlineByRuntimeID: [UInt32: ObservedDisplay] = Dictionary(uniqueKeysWithValues: snapshot.displays.compactMap {
            guard $0.state.isOnline, let runtimeID = $0.runtimeID else { return nil }
            return (runtimeID, $0)
        })

        runtimeState.appDisabledDisplays.removeAll { record in
            guard let online = onlineByRuntimeID[record.runtimeID] else { return false }
            stateChanged = true
            if online.stableIdentity == record.stableIdentity && online.family == record.family {
                log("[STATE] cleared app-disabled record after confirmed online restore for \(record.runtimeID)")
            } else {
                log("[STATE] discarded stale app-disabled runtime ID reused by another display: \(record.runtimeID)")
            }
            return true
        }

        let pendingRecords = runtimeState.pendingDisableDisplays
        for pending in pendingRecords {
            if let online = onlineByRuntimeID[pending.runtimeID] {
                let identityMatches = online.stableIdentity == pending.stableIdentity
                    && online.family == pending.family
                if !identityMatches {
                    runtimeState.pendingDisableDisplays.removeAll { $0.runtimeID == pending.runtimeID }
                    stateChanged = true
                    let message = "Discarded pending recovery handle because runtime display ID \(pending.runtimeID) was reused by a different identity."
                    if !baseDiagnostics.contains(where: { $0.code == .staleRuntimeIdentityDiscarded && $0.message == message }) {
                        baseDiagnostics.append(RuntimeDiagnostic(
                            severity: .warning,
                            code: .staleRuntimeIdentityDiscarded,
                            message: message
                        ))
                    }
                    currentStatus.diagnostics = baseDiagnostics
                    log("[STATE] \(message)")
                } else if pending.phase == .uncommittedIntent {
                    runtimeState.pendingDisableDisplays.removeAll { $0.runtimeID == pending.runtimeID }
                    stateChanged = true
                    log("[STATE] cleared uncommitted disable intent still observed online: \(pending.runtimeID)")
                } else {
                    log("[STATE] retained committed-uncertain recovery handle after matching one online observation: \(pending.runtimeID)")
                }
            } else {
                runtimeState.pendingDisableDisplays.removeAll { $0.runtimeID == pending.runtimeID }
                runtimeState.appDisabledDisplays.removeAll { $0.runtimeID == pending.runtimeID }
                runtimeState.appDisabledDisplays.append(pending.disabledRecord)
                stateChanged = true
                log("[STATE] promoted interrupted pending disable to a recoverable app-disabled record: \(pending.runtimeID)")
            }
        }

        let pendingRecoveryRecords = runtimeState.pendingRecoveryDisplays
        for recovery in pendingRecoveryRecords {
            guard let online = onlineByRuntimeID[recovery.runtimeID] else { continue }
            let identityMatches = online.stableIdentity == recovery.stableIdentity
                && online.family == recovery.family
            if identityMatches {
                log("[STATE] retained unresolved recovery evidence after a matching online observation: \(recovery.runtimeID)")
                continue
            }
            runtimeState.pendingRecoveryDisplays.removeAll { $0.runtimeID == recovery.runtimeID }
            stateChanged = true
            let message = "Discarded unresolved recovery evidence because runtime display ID \(recovery.runtimeID) was reused by a different identity."
            if !baseDiagnostics.contains(where: { $0.code == .staleRuntimeIdentityDiscarded && $0.message == message }) {
                baseDiagnostics.append(RuntimeDiagnostic(
                    severity: .warning,
                    code: .staleRuntimeIdentityDiscarded,
                    message: message
                ))
            }
            currentStatus.diagnostics = baseDiagnostics
            log("[STATE] \(message)")
        }
        if let marker = runtimeState.legacyBuiltInRecovery,
           snapshot.displays.contains(where: {
               guard $0.state.isOnline, $0.isBuiltIn else { return false }
               if let identity = marker.stableIdentity { return $0.stableIdentity == identity }
               return $0.family == marker.family
           }) {
            runtimeState.legacyBuiltInRecovery = nil
            stateChanged = true
        }
        if stateChanged { try persistRuntimeState() }

        if updateDisplayHistoryAndDefaultRules(from: snapshot) {
            snapshot = try adapter.observe(configuration: configuration, runtimeState: runtimeState)
        }
        currentStatus.recoveryPlan = recoveryPlan(for: snapshot)
        return snapshot
    }

    private func updateDisplayHistoryAndDefaultRules(from snapshot: ObservedDisplaySnapshot) -> Bool {
        guard configurationIsWritable, runtimeStateIsWritable else { return false }
        var updated = configuration

        for display in snapshot.displays where display.state.isOnline && display.family.isValid {
            let target: DisplayTarget = display.stableIdentity.map(DisplayTarget.exact) ?? .family(display.family)
            if let index = updated.deviceHistory.firstIndex(where: { $0.target == target }) {
                if updated.deviceHistory[index].name != display.name || updated.deviceHistory[index].isBuiltIn != display.isBuiltIn {
                    updated.deviceHistory[index].name = display.name
                    updated.deviceHistory[index].isBuiltIn = display.isBuiltIn
                }
            } else {
                updated.deviceHistory.append(KnownDisplay(target: target, name: display.name, isBuiltIn: display.isBuiltIn))
            }
        }
        if shouldGenerateInitialDefaultRules,
           updated.rules.isEmpty,
           let builtIn = updated.deviceHistory.first(where: { $0.isBuiltIn }) {
            updated.rules = LegacyConfigurationMigrator.defaultExternalRules(target: builtIn.target)
            shouldGenerateInitialDefaultRules = false
        }
        guard updated != configuration else { return false }

        do {
            try configurationStore.save(updated)
            configuration = updated
            currentStatus.configuration = updated
            return true
        } catch {
            configurationIsWritable = false
            baseDiagnostics.append(RuntimeDiagnostic(
                severity: .error,
                code: .configurationUnavailable,
                message: "Display history could not be persisted: \(error.localizedDescription)"
            ))
            return false
        }
    }

    private func recoveryPlan(for snapshot: ObservedDisplaySnapshot) -> DisplayRecoveryPlan {
        let appDisabled = runtimeState.appDisabledDisplays.compactMap {
            recoveryTarget(for: $0, evidence: .disabledByApplication, snapshot: snapshot)
        }
        let committedUncertain = runtimeState.pendingDisableDisplays.compactMap { record in
            record.phase == .committedUncertain
                ? recoveryTarget(for: record.disabledRecord, evidence: .pendingConfirmation, snapshot: snapshot)
                : nil
        }
        let pendingRecovery = runtimeState.pendingRecoveryDisplays.compactMap {
            recoveryTarget(for: $0, evidence: .pendingConfirmation, snapshot: snapshot)
        }
        return DisplayRecoveryPlan(
            targets: (appDisabled + committedUncertain + pendingRecovery).sorted { $0.display < $1.display }
        )
    }

    private func recoveryTarget(
        for record: AppDisabledDisplayRecord,
        evidence: DisplayRecoveryEvidenceKind,
        snapshot: ObservedDisplaySnapshot
    ) -> DisplayRecoveryTarget? {
        guard record.runtimeID != 0,
              record.family.isValid,
              let display = snapshot.displays.first(where: {
                  $0.runtimeID == record.runtimeID
                      && $0.stableIdentity == record.stableIdentity
                      && $0.family == record.family
              }) else { return nil }
        return DisplayRecoveryTarget(
            display: EvaluatedDisplayKey(
                runtimeID: record.runtimeID,
                stableIdentity: record.stableIdentity,
                family: record.family
            ),
            name: display.name,
            isBuiltIn: display.isBuiltIn,
            observedState: display.state,
            evidence: evidence
        )
    }

    private func beginRecoveryAttempts(_ requests: [DisplayActionRequest]) throws {
        var updated = runtimeState
        for request in requests where request.action == .enable {
            let evidence = AppDisabledDisplayRecord(
                runtimeID: request.display.runtimeID,
                stableIdentity: request.display.stableIdentity,
                family: request.display.family
            )
            let isRecoverable = updated.appDisabledDisplays.contains { $0 == evidence }
                || updated.pendingDisableDisplays.contains { $0.disabledRecord == evidence }
                || updated.pendingRecoveryDisplays.contains { $0 == evidence }
            guard isRecoverable else { continue }
            updated.appDisabledDisplays.removeAll { $0.runtimeID == evidence.runtimeID }
            updated.pendingDisableDisplays.removeAll { $0.runtimeID == evidence.runtimeID }
            updated.pendingRecoveryDisplays.removeAll { $0.runtimeID == evidence.runtimeID }
            updated.pendingRecoveryDisplays.append(evidence)
        }
        guard updated != runtimeState else { return }
        try runtimeStateStore.save(updated)
        runtimeState = updated
        runtimeStateIsWritable = true
    }

    private func retireRecoveryEvidence(for requests: [DisplayActionRequest]) throws {
        let restored = Set(requests.map(\.display))
        var updated = runtimeState
        updated.appDisabledDisplays.removeAll { record in
            restored.contains(EvaluatedDisplayKey(
                runtimeID: record.runtimeID,
                stableIdentity: record.stableIdentity,
                family: record.family
            ))
        }
        updated.pendingDisableDisplays.removeAll { record in
            restored.contains(EvaluatedDisplayKey(
                runtimeID: record.runtimeID,
                stableIdentity: record.stableIdentity,
                family: record.family
            ))
        }
        updated.pendingRecoveryDisplays.removeAll { record in
            restored.contains(EvaluatedDisplayKey(
                runtimeID: record.runtimeID,
                stableIdentity: record.stableIdentity,
                family: record.family
            ))
        }
        updated.failureSuppressions.removeAll { suppression in
            requests.contains {
                $0.action == .enable && suppression.target == suppressionTarget(for: $0.display)
            }
        }
        guard updated != runtimeState else { return }
        try runtimeStateStore.save(updated)
        runtimeState = updated
        runtimeStateIsWritable = true
    }

    private func recordRuntimeStatePersistenceFailure(_ error: Error) {
        runtimeStateIsWritable = false
        if automaticEnabledAfterRuntimeRecovery == nil {
            automaticEnabledAfterRuntimeRecovery = configuration.automatic.isEnabled
        }
        configuration.automatic.isEnabled = false
        currentStatus.configuration = configuration
        restartPolling()
        baseDiagnostics.removeAll { $0.code == .statePersistenceFailed }
        baseDiagnostics.append(RuntimeDiagnostic(
            severity: .error,
            code: .statePersistenceFailed,
            message: "Runtime state could not be saved; automation was disabled: \(error.localizedDescription)"
        ))
    }

    private func finishDisplayRecovery(
        items: [DisplayRecoveryItemResult],
        snapshot: ObservedDisplaySnapshot,
        baselineIsReliable: Bool = true
    ) -> DisplayRecoveryBatchResult {
        let result = DisplayRecoveryBatchResult(items: items)
        currentStatus.inventory = snapshot
        currentStatus.recoveryPlan = recoveryPlan(for: snapshot)
        currentStatus.lastRecoveryResult = result
        currentStatus.lastEvaluation = evaluator.evaluate(configuration: configuration, snapshot: snapshot)
        currentStatus.lastCycleAnalysis = cycleAnalyzer.analyze(configuration: configuration, initialSnapshot: snapshot)
        currentStatus.lastTrigger = "manual-recovery"
        currentStatus.pauseReason = .manualDisplayAction
        if baselineIsReliable {
            manualTopologyBaseline = onlineTopology(in: snapshot)
            manualRecoverySelfTopologyChanges = nil
        } else {
            let baseline = onlineTopology(in: snapshot)
            manualTopologyBaseline = baseline
            let expectedChanges = Set(items.compactMap { item -> String? in
                guard item.disposition == .uncertain else { return nil }
                let identity = topologyIdentity(for: item.target.display)
                return baseline.contains(identity) ? nil : identity
            })
            manualRecoverySelfTopologyChanges = expectedChanges.isEmpty ? nil : expectedChanges
        }

        let restored = items.filter { $0.disposition == .restored }.count
        let unresolved = items.filter { $0.disposition == .unresolved }.count
        let uncertain = items.filter { $0.disposition == .uncertain }.count
        let skipped = items.filter { $0.disposition == .skipped }.count
        let severity: RuntimeDiagnosticSeverity
        if restored == 0 && (unresolved > 0 || uncertain > 0) {
            severity = .error
        } else if unresolved > 0 || uncertain > 0 || skipped > 0 {
            severity = .warning
        } else {
            severity = .info
        }
        currentStatus.diagnostics = baseDiagnostics + [RuntimeDiagnostic(
            severity: severity,
            code: .automationPaused,
            message: "Bulk recovery finished: restored=\(restored), unresolved=\(unresolved), uncertain=\(uncertain), skipped=\(skipped). Automation remains paused."
        )]
        let details = items.map {
            "\($0.target.display.runtimeID):\($0.disposition.rawValue):\($0.explanation)"
        }.joined(separator: " | ")
        log("[RECOVERY] restored=\(restored) unresolved=\(unresolved) uncertain=\(uncertain) skipped=\(skipped) results=[\(details)]")
        publishStatus()
        return result
    }
    private func finishManualRecoveryFailure(
        request: DisplayActionRequest,
        snapshot: ObservedDisplaySnapshot,
        baselineIsReliable: Bool,
        message: String
    ) {
        currentStatus.inventory = snapshot
        currentStatus.recoveryPlan = recoveryPlan(for: snapshot)
        currentStatus.lastEvaluation = evaluator.evaluate(configuration: configuration, snapshot: snapshot)
        currentStatus.lastCycleAnalysis = cycleAnalyzer.analyze(configuration: configuration, initialSnapshot: snapshot)
        currentStatus.lastTrigger = "manual-recovery"
        currentStatus.pauseReason = .manualDisplayAction
        let baseline = onlineTopology(in: snapshot)
        manualTopologyBaseline = baseline
        let identity = topologyIdentity(for: request.display)
        manualRecoverySelfTopologyChanges = !baselineIsReliable && !baseline.contains(identity)
            ? [identity]
            : nil
        currentStatus.diagnostics = baseDiagnostics + [RuntimeDiagnostic(
            severity: .error,
            code: .actionFailed,
            message: "Manual display recovery failed while automation remained paused: \(message)"
        )]
        log("[RECOVERY] single runtimeID=\(request.display.runtimeID) unresolved=\(message)")
        publishStatus()
    }


    private func enforceActiveSafety(requests: [DisplayActionRequest], snapshot: ObservedDisplaySnapshot) throws {
        let active = Set(snapshot.displays.compactMap { $0.state.isActive ? $0.runtimeID : nil })
        guard !active.isEmpty else { return }
        let disabled = Set(requests.compactMap {
            $0.action == .disable && active.contains($0.display.runtimeID) ? $0.display.runtimeID : nil
        })
        if active.subtracting(disabled).isEmpty { throw AutomationCoordinatorError.lastActiveDisplay }
    }

    private func journalPendingDisables(
        _ requests: [DisplayActionRequest],
        snapshot: ObservedDisplaySnapshot
    ) throws {
        var changed = false
        for request in requests where request.action == .disable {
            guard snapshot.displays.contains(where: {
                $0.runtimeID == request.display.runtimeID && $0.state.isOnline
            }) else { continue }
            guard !runtimeState.appDisabledDisplays.contains(where: {
                $0.runtimeID == request.display.runtimeID
            }), !runtimeState.pendingDisableDisplays.contains(where: {
                $0.runtimeID == request.display.runtimeID
            }), !runtimeState.pendingRecoveryDisplays.contains(where: {
                $0.runtimeID == request.display.runtimeID
            }) else { continue }
            runtimeState.pendingDisableDisplays.append(PendingDisableRecord(
                runtimeID: request.display.runtimeID,
                stableIdentity: request.display.stableIdentity,
                family: request.display.family
            ))
            changed = true
        }
        if changed { try persistRuntimeState() }
    }

    private func markPendingDisablesCommitted(
        _ requests: [DisplayActionRequest]
    ) throws {
        let disableIDs = Set(requests.compactMap {
            $0.action == .disable ? $0.display.runtimeID : nil
        })
        guard !disableIDs.isEmpty else { return }
        var changed = false
        let recoveryRecords = runtimeState.pendingRecoveryDisplays.filter {
            disableIDs.contains($0.runtimeID)
        }
        if !recoveryRecords.isEmpty {
            runtimeState.pendingRecoveryDisplays.removeAll { disableIDs.contains($0.runtimeID) }
            for record in recoveryRecords where !runtimeState.pendingDisableDisplays.contains(where: { $0.runtimeID == record.runtimeID }) {
                runtimeState.pendingDisableDisplays.append(PendingDisableRecord(
                    runtimeID: record.runtimeID,
                    stableIdentity: record.stableIdentity,
                    family: record.family,
                    phase: .committedUncertain
                ))
            }
            changed = true
        }
        for index in runtimeState.pendingDisableDisplays.indices
            where disableIDs.contains(runtimeState.pendingDisableDisplays[index].runtimeID)
                && runtimeState.pendingDisableDisplays[index].phase != .committedUncertain {
            runtimeState.pendingDisableDisplays[index].phase = .committedUncertain
            changed = true
        }
        if changed { try persistRuntimeState() }
    }

    private func clearPendingForKnownUncommittedFailures(
        _ outcome: DisplayTransactionOutcome
    ) throws {
        guard !outcome.transactionWasCommitted else { return }
        let failedDisableIDs = Set(outcome.results.compactMap {
            !$0.succeeded && $0.request.action == .disable
                ? $0.request.display.runtimeID
                : nil
        })
        guard !failedDisableIDs.isEmpty else { return }
        let oldCount = runtimeState.pendingDisableDisplays.count
        runtimeState.pendingDisableDisplays.removeAll {
            failedDisableIDs.contains($0.runtimeID)
                && $0.phase == .uncommittedIntent
        }
        if oldCount != runtimeState.pendingDisableDisplays.count {
            try persistRuntimeState()
        }
    }

    private func recoverIfCommittedWithoutActiveDisplay(
        outcome: DisplayTransactionOutcome,
        disableRequests: [DisplayActionRequest]
    ) throws -> RuntimeDiagnostic? {
        guard outcome.transactionWasCommitted,
              disableRequests.contains(where: { $0.action == .disable }),
              outcome.after.activeCount == 0 else { return nil }

        currentStatus.pauseReason = .explicit
        manualTopologyBaseline = nil
        manualRecoverySelfTopologyChanges = nil
        let candidates = disableRequests.filter { request in
            request.action == .disable
                && outcome.after.displays.first(where: {
                    $0.runtimeID == request.display.runtimeID
                })?.state.isOnline != true
        }
        let recovery = candidates.sorted { lhs, rhs in
            let left = outcome.before.displays.first { $0.runtimeID == lhs.display.runtimeID }
            let right = outcome.before.displays.first { $0.runtimeID == rhs.display.runtimeID }
            if left?.isMain != right?.isMain { return left?.isMain == true }
            if left?.isBuiltIn != right?.isBuiltIn { return left?.isBuiltIn == true }
            return lhs.display < rhs.display

        }.first

        var suffix = "No disabled target retained a recoverable current-boot handle."
        if let recovery {
            let enable = DisplayActionRequest(display: recovery.display, action: .enable)
            do {
                let compensationBefore = try adapter.observe(
                    configuration: configuration,
                    runtimeState: runtimeState
                )
                let compensation = try adapter.apply(
                    requests: [enable],
                    expectedFingerprint: policyFingerprint(compensationBefore),
                    configuration: configuration,
                    runtimeState: runtimeState,
                    didCommit: {}
                )
                if compensation.requiresReevaluation {
                    suffix = "The topology changed before the compensating restore could begin."
                } else {
                    try applyConfirmedResults(compensation.results)
                    try clearPendingForKnownUncommittedFailures(compensation)
                    let observed = try adapter.observe(
                        configuration: configuration,
                        runtimeState: runtimeState
                    )
                    suffix = observed.activeCount > 0
                        ? "A compensating restore re-established an active display."
                        : "A compensating restore was attempted, but no active display was observed."
                }
            } catch {
                suffix = "The compensating restore failed: \(error.localizedDescription)"
            }
        }
        return RuntimeDiagnostic(
            severity: .error,
            code: .safetyRecovery,
            message: "A committed disable left no active display; automation was paused. \(suffix)"
        )
    }

    private func isCommittedUnknown(_ error: Error) -> Bool {
        guard let adapterError = error as? DisplayActionAdapterError else { return false }
        if case .committedOutcomeUnknown = adapterError { return true }
        return false
    }

    private func logEvaluation(
        trigger: String,
        snapshot: ObservedDisplaySnapshot,
        plan: RuleEvaluationPlan
    ) {
        let matched = plan.matchedRuleIDs.map(\.uuidString).joined(separator: ",")
        let winning = plan.winningActions.map {
            "\($0.display.runtimeID):\($0.action.rawValue)"
        }.joined(separator: ",")
        let conflicts = plan.conflicts.map {
            "\($0.display.runtimeID):\($0.actions.map(\.rawValue).joined(separator: "+"))"
        }.joined(separator: ",")
        let safety = plan.safetyBlocks.map {
            "\($0.reason.rawValue):\($0.display.map { String($0.runtimeID) } ?? "none")"
        }.joined(separator: ",")
        log(
            "[AUTO] evaluation trigger=\(trigger) online=\(snapshot.onlineCount) active=\(snapshot.activeCount) "
                + "matched=[\(matched)] winning=[\(winning)] conflicts=[\(conflicts)] safety=[\(safety)]"
        )
    }

    private func logTransactionOutcome(
        attempt: Int,
        outcome: DisplayTransactionOutcome,
        afterWasObserved: Bool
    ) {
        let successes = outcome.results.filter(\.succeeded).map {
            "\($0.request.display.runtimeID):\($0.request.action.rawValue)"
                + ($0.wasIdempotent ? ":idempotent" : "")
        }.joined(separator: ",")
        let failures = outcome.results.filter { !$0.succeeded }.map {
            "\($0.request.display.runtimeID):\($0.request.action.rawValue)"
        }.joined(separator: ",")
        let afterActive = afterWasObserved ? String(outcome.after.activeCount) : "unknown"
        log(
            "[AUTO] transaction attempt=\(attempt)/\(maximumActionAttempts) "
                + "committed=\(outcome.transactionWasCommitted) reevaluate=\(outcome.requiresReevaluation) "
                + "success=[\(successes)] failure=[\(failures)] afterActive=\(afterActive)"
        )
    }

    private func actionKey(_ request: DisplayActionRequest) -> String {
        "\(request.display.runtimeID):\(request.action.rawValue)"
    }

    private func policyFingerprint(
        _ snapshot: ObservedDisplaySnapshot
    ) -> DisplayPolicySnapshotFingerprint {
        DisplayPolicySnapshotFingerprint(snapshot: snapshot)
    }

    private func recoverRuntimeStatePersistenceIfNeeded() throws {
        guard !runtimeStateIsWritable else { return }
        do {
            try runtimeStateStore.save(runtimeState)
            runtimeStateIsWritable = true
            if let requestedAutomatic = automaticEnabledAfterRuntimeRecovery {
                configuration.automatic.isEnabled = requestedAutomatic
                currentStatus.configuration = configuration
                automaticEnabledAfterRuntimeRecovery = nil
                restartPolling()
            }
            baseDiagnostics.removeAll {
                $0.code == .runtimeStateUnavailable || $0.code == .statePersistenceFailed
            }
            currentStatus.diagnostics = baseDiagnostics
            log("[STATE] fresh runtime state persisted; configuration saves are enabled")
        } catch {
            configuration.automatic.isEnabled = false
            currentStatus.configuration = configuration
            currentStatus.diagnostics = baseDiagnostics
            restartPolling()
            publishStatus()
            throw error
        }
    }

    private func persistRuntimeState() throws {
        do {
            try runtimeStateStore.save(runtimeState)
            runtimeStateIsWritable = true
        } catch {
            runtimeStateIsWritable = false
            if automaticEnabledAfterRuntimeRecovery == nil {
                automaticEnabledAfterRuntimeRecovery = configuration.automatic.isEnabled
            }
            configuration.automatic.isEnabled = false
            currentStatus.configuration = configuration
            restartPolling()
            currentStatus.pauseReason = .explicit
            baseDiagnostics.append(RuntimeDiagnostic(
                severity: .error,
                code: .statePersistenceFailed,

                message: "Runtime state could not be saved; automation was disabled: \(error.localizedDescription)"
            ))
            currentStatus.diagnostics = baseDiagnostics
            publishStatus()
            throw error
        }
    }

    private func display(_ display: ObservedDisplay, matches target: DisplayTarget) -> Bool {
        switch target {
        case .exact(let identity):
            return display.stableIdentity == identity
        case .family(let family):
            return display.family == family
        }
    }

    private func suppressionTarget(for display: EvaluatedDisplayKey) -> DisplayTarget {
        display.stableIdentity.map(DisplayTarget.exact) ?? .family(display.family)
    }
    private func topologyIdentity(for display: EvaluatedDisplayKey) -> String {
        if let identity = display.stableIdentity {
            return "exact:\(identity.family.vendorID):\(identity.family.modelID):\(identity.serialNumber)"
        }
        return "boot:\(display.runtimeID):\(display.family.vendorID):\(display.family.modelID)"
    }

    private func onlineTopology(in snapshot: ObservedDisplaySnapshot) -> Set<String> {
        Set(snapshot.displays.compactMap { display in
            guard display.state.isOnline, let runtimeID = display.runtimeID else { return nil }
            if let identity = display.stableIdentity {
                return "exact:\(identity.family.vendorID):\(identity.family.modelID):\(identity.serialNumber)"
            }
            return "boot:\(runtimeID):\(display.family.vendorID):\(display.family.modelID)"
        })
    }

    private func recordRuntimeError(_ code: RuntimeDiagnosticCode, _ message: String) {
        currentStatus.diagnostics = baseDiagnostics + [RuntimeDiagnostic(severity: .error, code: code, message: message)]
        log("[AUTO] \(message)")
        publishStatus()
    }

    private func publishStatus() {
        currentStatus.configuration = configuration
        onStatusChange?()
    }
}
