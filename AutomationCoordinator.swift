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

enum RuntimeDiagnosticCode: String, Equatable, Hashable {
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
struct ProfileActivationPreview: Equatable {
    var profile: DisplayProfile
    var evaluation: RuleEvaluationPlan
    var cycleAnalysis: CycleAnalysis
    var profileSource: PersistenceGenerationSource
    var primaryErrorDescription: String?
    var policyFingerprint: DisplayPolicySnapshotFingerprint
}

enum ProfileHardwareApplicationOutcome: String, Equatable {
    case notNeeded
    case applied
    case partiallyFailed
    case failed
    case blockedBySafety
}

struct ProfileActivationResult: Equatable {
    var activeProfile: DisplayProfile
    var preview: ProfileActivationPreview
    var hardwareOutcome: ProfileHardwareApplicationOutcome
    var actionDiagnostics: [RuntimeDiagnostic]
}

private struct HardwareApplicationReport {
    var outcome: ProfileHardwareApplicationOutcome
    var diagnostics: [RuntimeDiagnostic]
}
private struct ConfirmedActionIntent: Hashable {
    var display: EvaluatedDisplayKey
    var action: DisplayAction
}
private struct ConfirmedProfileGeneration {
    var profile: DisplayProfile
    var source: PersistenceGenerationSource
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
    var activeProfile: DisplayProfile? = nil
    var profileCatalog: DisplayProfileCatalog = DisplayProfileCatalog(profiles: [], invalidProfiles: [])
    var settingsGenerationSource: PersistenceGenerationSource? = nil
    var activeProfileGenerationSource: PersistenceGenerationSource? = nil
    var persistenceErrorDescription: String? = nil
    var lastProfileActivation: ProfileActivationResult? = nil
    var externalApplicationSettings: ApplicationSettings? = nil
    var externalSettingsGenerationSource: PersistenceGenerationSource? = nil
    var externalSettingsErrorDescription: String? = nil
    var externalActiveProfileID: UUID? = nil

    var isCatalogValid: Bool { profileCatalog.invalidProfiles.isEmpty }

    var isPaused: Bool { pauseReason != nil }
}

enum AutomationCoordinatorError: Error, LocalizedError {
    case displayNotFound(UInt32)
    case invalidManualAction
    case displayIdentityChanged(UInt32)
    case lastActiveDisplay
    case actionFailed(String)
    case staleProfileActivationPreview

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
        case .staleProfileActivationPreview:
            return "The confirmed Profile activation preview is stale because its Profile or display topology changed."
        }
    }
}

protocol DisplayManagingRuntime: AnyObject {
    var status: AutomationRuntimeStatus { get }
    func previewConfigurationReadOnly(
        _ configuration: AppConfiguration,
        observation: ObservedDisplaySnapshot?
    ) throws -> ConfigurationPreview
    func previewProfileActivation(
        id: UUID,
        observation: ObservedDisplaySnapshot?
    ) throws -> ProfileActivationPreview
    @discardableResult func activateProfile(id: UUID) throws -> ProfileActivationResult
    @discardableResult func activateProfile(id: UUID, confirmedPreview: ProfileActivationPreview) throws -> ProfileActivationResult
    @discardableResult func createBlankProfile(named name: String) throws -> DisplayProfile
    @discardableResult func duplicateProfile(id: UUID, named name: String) throws -> DisplayProfile
    @discardableResult func renameProfile(id: UUID, to name: String) throws -> DisplayProfile
    func deleteInactiveProfile(id: UUID) throws
    @discardableResult func saveProfile(_ profile: DisplayProfile, applyImmediately: Bool) throws -> AutomationRuntimeStatus
    @discardableResult func restoreProfileFromLastKnownGood(id: UUID) throws -> DisplayProfile
    @discardableResult func removeInvalidProfile(fileName: String) throws -> AutomationRuntimeStatus
    @discardableResult func reloadProfileCatalog() -> AutomationRuntimeStatus
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
    private let guardIntervalSeconds: TimeInterval
    private var liveApplicationSettingsActiveProfileID: UUID?
    private let log: (String) -> Void
    private let lock = NSRecursiveLock()

    private var configuration: AppConfiguration
    private var activeProfile: DisplayProfile?
    private var runtimeState: RuntimeState
    private var settingsIsWritable: Bool
    private var activeProfileIsWritable: Bool
    private var runtimeStateIsWritable: Bool
    private var automaticEnabledAfterRuntimeRecovery: Bool?
    private var baseDiagnostics: [RuntimeDiagnostic]
    private var currentStatus: AutomationRuntimeStatus
    private var pendingEvaluation: AutomationScheduledTask?
    private var pollingTask: AutomationScheduledTask?
    private var safetyGuardTask: AutomationScheduledTask?
    private var generation = 0
    private var manualTopologyBaseline: Set<String>?
    private var manualRecoverySelfTopologyChanges: Set<String>?
    private var automaticNotBefore: Date?

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
        guardIntervalSeconds: TimeInterval = 3,
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
        self.guardIntervalSeconds = max(1, guardIntervalSeconds)
        self.log = log

        var diagnostics: [RuntimeDiagnostic] = []
        let loadedConfiguration: AppConfiguration
        let loadedResult: ConfigurationLoadResult?
        let settingsOnlyResult: ApplicationSettingsLoadResult?
        do {
            let loaded = try configurationStore.loadOrMigrate()
            loadedConfiguration = loaded.configuration
            loadedResult = loaded
            settingsOnlyResult = nil
            if loaded.source == .lastKnownGoodBackup {
                diagnostics.append(RuntimeDiagnostic(
                    severity: .warning,
                    code: .configurationFallback,
                    message: loaded.primaryErrorDescription.map {
                        "Using a last-known-good persistence generation because a primary generation is invalid: \($0)"
                    } ?? "Using a last-known-good persistence generation because a primary generation is unavailable."
                ))
            }
        } catch let combinedError {
            loadedResult = nil
            do {
                let settings = try configurationStore.loadApplicationSettings()
                let unavailableProfile = DisplayProfile.blank(
                    id: settings.settings.activeProfileID,
                    name: "Unavailable Active Profile"
                )
                loadedConfiguration = AppConfiguration(settings: settings.settings, profile: unavailableProfile)
                settingsOnlyResult = settings
                diagnostics.append(RuntimeDiagnostic(
                    severity: .error,
                    code: .configurationUnavailable,
                    message: "Automation is disabled because the Active Profile is unusable: \(combinedError.localizedDescription)"
                ))
            } catch let settingsError {
                var disabled = AppConfiguration.default
                disabled.automatic.isEnabled = false
                loadedConfiguration = disabled
                settingsOnlyResult = nil
                diagnostics.append(RuntimeDiagnostic(
                    severity: .error,
                    code: .configurationUnavailable,
                    message: "Automation is disabled because Application Settings and the Active Profile are unusable: \(settingsError.localizedDescription); \(combinedError.localizedDescription)"
                ))
            }
        }
        let loadSource = loadedResult?.source

        let catalog = configurationStore.catalog()

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
        activeProfile = loadedResult?.activeProfile
        runtimeState = loadedRuntimeState
        runtimeStateIsWritable = runtimeStateWasLoaded
        automaticEnabledAfterRuntimeRecovery = runtimeStateWasLoaded
            ? nil
            : loadedConfiguration.automatic.isEnabled
        liveApplicationSettingsActiveProfileID = loadedResult?.activeProfile.id
            ?? settingsOnlyResult?.settings.activeProfileID
        settingsIsWritable = (loadedResult?.settingsSource ?? settingsOnlyResult?.source) == .primary
        activeProfileIsWritable = loadedResult?.profileSource == .primary
        baseDiagnostics = diagnostics
        currentStatus = AutomationRuntimeStatus(
            configuration: effectiveConfiguration,
            inventory: ObservedDisplaySnapshot(displays: []),
            lastEvaluation: .empty,
            lastCycleAnalysis: nil,
            lastTrigger: nil,
            pauseReason: nil,
            diagnostics: diagnostics,
            configurationLoadSource: loadSource,
            activeProfile: loadedResult?.activeProfile,
            profileCatalog: catalog,
            settingsGenerationSource: loadedResult?.settingsSource ?? settingsOnlyResult?.source,
            activeProfileGenerationSource: loadedResult?.profileSource,
            persistenceErrorDescription: loadedResult?.primaryErrorDescription ?? settingsOnlyResult?.primaryErrorDescription
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
            if configuration.automatic.isEnabled {
                scheduleEvaluation(after: configuration.automatic.startupStabilizationSeconds, trigger: "startup")
            }
            restartPolling()
            restartSafetyGuard()
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
        safetyGuardTask?.cancel()
        safetyGuardTask = nil
    }

    func handleWake() {
        lock.lock()
        defer { lock.unlock() }
        guard configuration.automatic.isEnabled else { return }
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
    func previewProfileActivation(
        id: UUID,
        observation: ObservedDisplaySnapshot?
    ) throws -> ProfileActivationPreview {
        lock.lock()
        defer { lock.unlock() }
        let loaded = try configurationStore.loadProfile(id: id)
        let candidate = try configurationStore.previewProfile(id: id)
        let snapshot: ObservedDisplaySnapshot
        if let observation {
            snapshot = observation
        } else {
            snapshot = try adapter.observe(configuration: candidate, runtimeState: runtimeState)
        }
        let evaluationCandidate = configurationForEvaluation(candidate, forceActions: true)
        return ProfileActivationPreview(
            profile: loaded.profile,
            evaluation: evaluator.evaluate(configuration: evaluationCandidate, snapshot: snapshot),
            cycleAnalysis: cycleAnalyzer.analyze(configuration: evaluationCandidate, initialSnapshot: snapshot),
            profileSource: loaded.source,
            primaryErrorDescription: loaded.primaryErrorDescription,
            policyFingerprint: policyFingerprint(snapshot)
        )
    }

    @discardableResult
    func activateProfile(id: UUID) throws -> ProfileActivationResult {
        lock.lock()
        defer { lock.unlock() }
        return try activateProfileLocked(id: id, confirmedPreview: nil)
    }

    @discardableResult
    func activateProfile(
        id: UUID,
        confirmedPreview: ProfileActivationPreview
    ) throws -> ProfileActivationResult {
        lock.lock()
        defer { lock.unlock() }
        return try activateProfileLocked(id: id, confirmedPreview: confirmedPreview)
    }

    private func activateProfileLocked(
        id: UUID,
        confirmedPreview: ProfileActivationPreview?
    ) throws -> ProfileActivationResult {
        let candidate = try configurationStore.previewProfile(id: id)
        let target = try configurationStore.loadProfile(id: id)
        let previewSnapshot = try adapter.observe(
            configuration: candidate,
            runtimeState: runtimeState
        )
        let fingerprint = policyFingerprint(previewSnapshot)
        if let confirmedPreview,
           confirmedPreview.profile != target.profile
            || confirmedPreview.profileSource != target.source
            || confirmedPreview.policyFingerprint != fingerprint {
            throw AutomationCoordinatorError.staleProfileActivationPreview
        }
        let confirmedIntents = confirmedPreview.map { preview in
            Set(preview.evaluation.winningActions.map {
                ConfirmedActionIntent(display: $0.display, action: $0.action)
            })
        }
        try recoverRuntimeStatePersistenceIfNeeded()

        let activatedConfiguration: AppConfiguration
        let activatedProfile: DisplayProfile
        let activationSource: ConfigurationLoadSource
        let activatedProfileSource: PersistenceGenerationSource
        let activationErrorDescription: String?
        if confirmedPreview != nil {
            let beforePersistence = try configurationStore.loadProfile(id: id)
            guard beforePersistence.profile == target.profile,
                  beforePersistence.source == target.source else {
                throw AutomationCoordinatorError.staleProfileActivationPreview
            }
            let settingsLoad = try configurationStore.loadApplicationSettings()
            var settings = settingsLoad.settings
            settings.activeProfileID = id
            try configurationStore.saveApplicationSettings(settings)
            activatedConfiguration = AppConfiguration(settings: settings, profile: target.profile)
            activatedProfile = target.profile
            activatedProfileSource = target.source
            activationSource = target.source == .primary ? .primary : .lastKnownGoodBackup
            activationErrorDescription = target.primaryErrorDescription
        } else {
            let loaded = try configurationStore.activateProfile(id: id)
            activatedConfiguration = loaded.configuration
            activatedProfile = loaded.activeProfile
            activatedProfileSource = loaded.profileSource
            activationSource = loaded.source
            activationErrorDescription = loaded.primaryErrorDescription
        }

        let evaluationCandidate = configurationForEvaluation(activatedConfiguration, forceActions: true)
        let preview = ProfileActivationPreview(
            profile: activatedProfile,
            evaluation: evaluator.evaluate(configuration: evaluationCandidate, snapshot: previewSnapshot),
            cycleAnalysis: cycleAnalyzer.analyze(configuration: evaluationCandidate, initialSnapshot: previewSnapshot),
            profileSource: activatedProfileSource,
            primaryErrorDescription: activationErrorDescription,
            policyFingerprint: fingerprint
        )

        // The selector is now durable. A later stale check may stop hardware, but
        // must never roll back or select another Profile.
        configuration = activatedConfiguration
        activeProfile = activatedProfile
        baseDiagnostics.removeAll {
            $0.code == .configurationUnavailable || $0.code == .configurationFallback
        }
        if activationSource == .lastKnownGoodBackup {
            baseDiagnostics.append(RuntimeDiagnostic(
                severity: .warning,
                code: .configurationFallback,
                message: activationErrorDescription.map {
                    "The Active Profile uses its last-known-good generation: \($0)"
                } ?? "The Active Profile uses its last-known-good generation."
            ))
        }
        currentStatus.diagnostics = baseDiagnostics
        currentStatus.externalActiveProfileID = nil
        liveApplicationSettingsActiveProfileID = id
        settingsIsWritable = true
        activeProfileIsWritable = activatedProfileSource == .primary
        currentStatus.configurationLoadSource = activationSource
        currentStatus.settingsGenerationSource = .primary
        currentStatus.activeProfileGenerationSource = activatedProfileSource
        currentStatus.persistenceErrorDescription = activationErrorDescription
        currentStatus.activeProfile = activatedProfile
        currentStatus.configuration = activatedConfiguration
        currentStatus.pauseReason = nil
        manualTopologyBaseline = nil
        manualRecoverySelfTopologyChanges = nil
        generation += 1
        pendingEvaluation?.cancel()
        pendingEvaluation = nil
        automaticNotBefore = nil
        restartPolling()
        refreshCatalogStatus()

        var postPersistenceProfileIsStale = false
        if confirmedPreview != nil {
            do {
                let currentTarget = try configurationStore.loadProfile(id: id)
                postPersistenceProfileIsStale = currentTarget.profile != activatedProfile
                    || currentTarget.source != activatedProfileSource
            } catch {
                postPersistenceProfileIsStale = true
            }
        }

        let hardwareOutcome: ProfileHardwareApplicationOutcome
        if postPersistenceProfileIsStale {
            hardwareOutcome = .failed
            currentStatus.diagnostics = baseDiagnostics + [RuntimeDiagnostic(
                severity: .error,
                code: .actionFailed,
                message: "The Active Profile was persisted, but hardware was not applied because the confirmed Profile generation became stale."
            )]
        } else {
            do {
                hardwareOutcome = try evaluateAndMaybeApply(
                    trigger: "profile-activation",
                    applyActions: true,
                    forceActions: true,
                    reconcileRecoveryEvidence: true,
                    requiredInitialFingerprint: confirmedPreview == nil ? nil : fingerprint,
                    requiredProfileGeneration: confirmedPreview == nil
                        ? nil
                        : ConfirmedProfileGeneration(profile: activatedProfile, source: activatedProfileSource),
                    allowedActionIntents: confirmedIntents
                )
            } catch {
                if let coordinatorError = error as? AutomationCoordinatorError,
                   case .lastActiveDisplay = coordinatorError {
                    hardwareOutcome = .blockedBySafety
                } else {
                    hardwareOutcome = .failed
                }
                let diagnostic = RuntimeDiagnostic(
                    severity: .error,
                    code: .actionFailed,
                    message: "The Active Profile was persisted, but its hardware plan did not complete: \(error.localizedDescription)"
                )
                currentStatus.diagnostics = baseDiagnostics + [diagnostic]
                log("[PROFILE] activation hardware application failed after persistence: \(error.localizedDescription)")
            }
        }

        refreshCatalogStatus()
        let resultProfile = activeProfile ?? activatedProfile
        var resultPreview = preview
        resultPreview.profile = resultProfile
        resultPreview.profileSource = currentStatus.activeProfileGenerationSource ?? preview.profileSource
        resultPreview.primaryErrorDescription = currentStatus.persistenceErrorDescription
        let actionCodes: Set<RuntimeDiagnosticCode> = [
            .actionFailed, .actionSuppressed, .safetyRecovery, .statePersistenceFailed
        ]
        let result = ProfileActivationResult(
            activeProfile: resultProfile,
            preview: resultPreview,
            hardwareOutcome: hardwareOutcome,
            actionDiagnostics: currentStatus.diagnostics.filter { actionCodes.contains($0.code) }
        )
        currentStatus.lastProfileActivation = result
        restartPolling()
        restartSafetyGuard()
        publishStatus()
        return result
    }

    @discardableResult
    func createBlankProfile(named name: String) throws -> DisplayProfile {
        lock.lock()
        defer { lock.unlock() }
        try recoverRuntimeStatePersistenceIfNeeded()
        let profile = try configurationStore.createBlankProfile(named: name)
        refreshCatalogStatus()
        publishStatus()
        return profile
    }

    @discardableResult
    func duplicateProfile(id: UUID, named name: String) throws -> DisplayProfile {
        lock.lock()
        defer { lock.unlock() }
        try recoverRuntimeStatePersistenceIfNeeded()
        let profile = try configurationStore.duplicateProfile(id: id, named: name)
        refreshCatalogStatus()
        publishStatus()
        return profile
    }

    @discardableResult
    func renameProfile(id: UUID, to name: String) throws -> DisplayProfile {
        lock.lock()
        defer { lock.unlock() }
        try recoverRuntimeStatePersistenceIfNeeded()
        let profile = try configurationStore.renameProfile(id: id, to: name)
        if activeProfile?.id == id {
            markActiveProfilePersistedPrimary(profile)
        }
        refreshCatalogStatus()
        publishStatus()
        return profile
    }

    func deleteInactiveProfile(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try recoverRuntimeStatePersistenceIfNeeded()
        guard activeProfile?.id != id else {
            throw ConfigurationStoreError.cannotDeleteActiveProfile
        }
        try configurationStore.deleteProfile(id: id)
        refreshCatalogStatus()
        publishStatus()
    }

    @discardableResult
    func saveProfile(_ profile: DisplayProfile, applyImmediately: Bool) throws -> AutomationRuntimeStatus {
        lock.lock()
        defer { lock.unlock() }
        try profile.validate()
        try recoverRuntimeStatePersistenceIfNeeded()
        try configurationStore.saveProfile(profile)
        refreshCatalogStatus()

        guard activeProfile?.id == profile.id else {
            publishStatus()
            return currentStatus
        }

        markActiveProfilePersistedPrimary(profile)
        configuration = AppConfiguration(
            settings: configuration.applicationSettings(activeProfileID: profile.id),
            profile: profile
        )
        currentStatus.configuration = configuration
        restartPolling()
        if applyImmediately {
            currentStatus.pauseReason = nil
            manualTopologyBaseline = nil
            manualRecoverySelfTopologyChanges = nil
            _ = try evaluateAndMaybeApply(trigger: "save-and-apply", applyActions: true)
        } else {
            publishStatus()
        }
        return currentStatus
    }
    @discardableResult
    func restoreProfileFromLastKnownGood(id: UUID) throws -> DisplayProfile {
        lock.lock()
        defer { lock.unlock() }
        try recoverRuntimeStatePersistenceIfNeeded()
        let profile = try configurationStore.restoreProfileFromLastKnownGood(id: id)
        if activeProfile?.id == id {
            configuration = AppConfiguration(
                settings: configuration.applicationSettings(activeProfileID: id),
                profile: profile
            )
            markActiveProfilePersistedPrimary(profile)
            currentStatus.configuration = configuration
            restartPolling()
        }
        refreshCatalogStatus()
        publishStatus()
        return profile
    }

    @discardableResult
    func removeInvalidProfile(fileName: String) throws -> AutomationRuntimeStatus {
        lock.lock()
        defer { lock.unlock() }
        try recoverRuntimeStatePersistenceIfNeeded()
        try configurationStore.removeInvalidProfile(fileName: fileName)
        refreshCatalogStatus()
        publishStatus()
        return currentStatus
    }

    @discardableResult
    func reloadProfileCatalog() -> AutomationRuntimeStatus {
        lock.lock()
        defer { lock.unlock() }
        refreshCatalogStatus()
        currentStatus.externalApplicationSettings = nil
        currentStatus.externalSettingsGenerationSource = nil
        currentStatus.externalSettingsErrorDescription = nil
        currentStatus.externalActiveProfileID = nil

        var diskSettings: ApplicationSettingsLoadResult?
        do {
            let loaded = try configurationStore.loadApplicationSettings()
            diskSettings = loaded
            currentStatus.externalSettingsGenerationSource = loaded.source
            currentStatus.externalSettingsErrorDescription = loaded.primaryErrorDescription
            if let liveID = liveApplicationSettingsActiveProfileID {
                let live = configuration.applicationSettings(activeProfileID: liveID)
                if loaded.settings != live {
                    currentStatus.externalApplicationSettings = loaded.settings
                }
                if loaded.settings.activeProfileID != liveID {
                    currentStatus.externalActiveProfileID = loaded.settings.activeProfileID
                }
            } else {
                currentStatus.externalApplicationSettings = loaded.settings
                currentStatus.externalActiveProfileID = loaded.settings.activeProfileID
            }
        } catch {
            currentStatus.externalSettingsErrorDescription = error.localizedDescription
        }

        do {
            let disk = try configurationStore.reloadFromDisk()
            if disk.activeProfile.id != activeProfile?.id || disk.activeProfile != activeProfile {
                currentStatus.externalActiveProfileID = disk.activeProfile.id
            }
        } catch {
            if let diskSettings,
               activeProfile == nil || diskSettings.settings.activeProfileID == activeProfile?.id {
                currentStatus.externalActiveProfileID = diskSettings.settings.activeProfileID
            }
        }
        currentStatus.lastTrigger = "profile-catalog-reload"
        publishStatus()
        return currentStatus
    }

    @discardableResult
    func updateConfiguration(_ candidate: AppConfiguration, applyImmediately: Bool) throws -> AutomationRuntimeStatus {
        lock.lock()
        defer { lock.unlock() }
        try candidate.validate()
        try recoverRuntimeStatePersistenceIfNeeded()
        let profileFieldsChanged = candidate.automatic != configuration.automatic
            || candidate.polling != configuration.polling
            || candidate.rules != configuration.rules
        let settingsFieldsChanged = candidate.hotKey != configuration.hotKey
            || candidate.deviceHistory != configuration.deviceHistory
        let profile: DisplayProfile?
        if let activeProfile {
            let candidateProfile = candidate.displayProfile(id: activeProfile.id, name: activeProfile.name)
            if candidateProfile != activeProfile {
                try configurationStore.saveProfile(candidateProfile)
                markActiveProfilePersistedPrimary(candidateProfile)
            }
            profile = candidateProfile
        } else {
            guard !profileFieldsChanged else { throw ConfigurationStoreError.configurationMissing }
            profile = nil
        }
        if settingsFieldsChanged {
            let disk = try configurationStore.loadApplicationSettings()
            var settings = disk.settings
            settings.hotKey = candidate.hotKey
            settings.deviceHistory = candidate.deviceHistory
            try configurationStore.saveApplicationSettings(settings)
            settingsIsWritable = true
            currentStatus.settingsGenerationSource = .primary
            refreshPersistenceRepairState()
        }
        configuration = candidate
        self.activeProfile = profile
        currentStatus.activeProfile = profile
        currentStatus.configuration = candidate
        refreshCatalogStatus()
        restartPolling()
        restartSafetyGuard()

        if applyImmediately {
            currentStatus.pauseReason = nil
            manualTopologyBaseline = nil
            manualRecoverySelfTopologyChanges = nil
            _ = try evaluateAndMaybeApply(trigger: "save-and-apply", applyActions: true)
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
        safetyGuardTask?.cancel()
        safetyGuardTask = nil
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
        restartSafetyGuard()
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

    /// Re-observes the topology while automation is running, unpaused, and the app
    /// holds a display disabled, so a missed screen event (unplug while the built-in
    /// is closed) still re-enables it. The repeating tick terminates itself once no
    /// recovery evidence remains, automation stops, or the app pauses.
    private func restartSafetyGuard() {
        safetyGuardTask?.cancel()
        safetyGuardTask = nil
        guard configuration.automatic.isEnabled, currentStatus.pauseReason == nil else { return }
        guard hasRecoveryEvidence else { return }
        safetyGuardTask = scheduler.schedule(after: guardIntervalSeconds, repeating: guardIntervalSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.configuration.automatic.isEnabled, self.currentStatus.pauseReason == nil else {
                self.safetyGuardTask?.cancel()
                self.safetyGuardTask = nil
                return
            }
            guard self.hasRecoveryEvidence else {
                self.safetyGuardTask?.cancel()
                self.safetyGuardTask = nil
                return
            }
            self.handleObservedTrigger(trigger: "safety-guard", delay: 0)
        }
    }

    private var hasRecoveryEvidence: Bool {
        !runtimeState.appDisabledDisplays.isEmpty
            || !runtimeState.pendingDisableDisplays.isEmpty
            || !runtimeState.pendingRecoveryDisplays.isEmpty
    }

    private func handleObservedTrigger(trigger: String, delay: TimeInterval) {
        do {
            let snapshot = try observeAndNormalize()
            currentStatus.inventory = snapshot
            resumeManualPauseIfTopologyChanged(snapshot)
            if configuration.automatic.isEnabled {
                scheduleEvaluation(after: delay, trigger: trigger)
            }
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
        restartSafetyGuard()
        log("[AUTO] manual pause ended after an actual online identity topology change")
    }

    @discardableResult
    private func evaluateAndMaybeApply(
        trigger: String,
        applyActions: Bool,
        forceActions: Bool = false,
        reconcileRecoveryEvidence: Bool = false,
        requiredInitialFingerprint: DisplayPolicySnapshotFingerprint? = nil,
        requiredProfileGeneration: ConfirmedProfileGeneration? = nil,
        allowedActionIntents: Set<ConfirmedActionIntent>? = nil
    ) throws -> ProfileHardwareApplicationOutcome {
        var diagnostics = baseDiagnostics
        var snapshot = try observeAndNormalize()
        var confirmationIsStale = requiredInitialFingerprint.map {
            policyFingerprint(snapshot) != $0
        } ?? false
        if let requiredProfileGeneration {
            do {
                let disk = try configurationStore.loadProfile(id: requiredProfileGeneration.profile.id)
                confirmationIsStale = confirmationIsStale
                    || disk.profile != requiredProfileGeneration.profile
                    || disk.source != requiredProfileGeneration.source
            } catch {
                confirmationIsStale = true
            }
        }
        if confirmationIsStale {
            let diagnostic = RuntimeDiagnostic(
                severity: .error,
                code: .actionFailed,
                message: "Hardware was not applied because the confirmed Profile or display topology became stale after Profile selection."
            )
            currentStatus.inventory = snapshot
            currentStatus.lastTrigger = trigger
            currentStatus.diagnostics = diagnostics + [diagnostic]
            publishStatus()
            return .failed
        }
        var evaluationConfiguration = configurationForEvaluation(configuration, forceActions: forceActions)
        let analysis = cycleAnalyzer.analyze(configuration: evaluationConfiguration, initialSnapshot: snapshot)
        currentStatus.lastCycleAnalysis = analysis

        if analysis.status == .cycleDetected && !analysis.involvedRuleIDs.isEmpty {
            let involved = Set(analysis.involvedRuleIDs)
            var safeConfiguration = configuration
            for index in safeConfiguration.rules.indices where involved.contains(safeConfiguration.rules[index].id) {
                safeConfiguration.rules[index].isEnabled = false
            }
            if activeProfileIsWritable, let profile = activeProfile {
                do {
                    let safeProfile = safeConfiguration.displayProfile(id: profile.id, name: profile.name)
                    try configurationStore.saveProfile(safeProfile)
                    markActiveProfilePersistedPrimary(safeProfile)
                    diagnostics.removeAll { $0.code == .configurationFallback }
                } catch {
                    activeProfileIsWritable = false
                    diagnostics.append(RuntimeDiagnostic(
                        severity: .error,
                        code: .configurationUnavailable,
                        message: "Cycle participants were disabled in memory but the Active Profile could not be persisted: \(error.localizedDescription)"
                    ))
                }
            }
            configuration = safeConfiguration
            if let profile = activeProfile {
                let effectiveProfile = safeConfiguration.displayProfile(id: profile.id, name: profile.name)
                activeProfile = effectiveProfile
                currentStatus.activeProfile = effectiveProfile
            }
            diagnostics.append(RuntimeDiagnostic(
                severity: .warning,
                code: .cycleRulesDisabled,
                message: "Rules participating in a runtime cycle were disabled: \(analysis.involvedRuleIDs.map(\.uuidString).joined(separator: ", "))."
            ))
        }
        evaluationConfiguration = configurationForEvaluation(configuration, forceActions: forceActions)

        let plan = evaluator.evaluate(configuration: evaluationConfiguration, snapshot: snapshot)
        currentStatus.configuration = configuration
        currentStatus.inventory = snapshot
        let previousEvaluation = currentStatus.lastEvaluation
        currentStatus.lastEvaluation = plan
        // The safety guard re-observes every few seconds while a display stays
        // disabled; an unchanged plan is a no-op and must not spam the log or
        // overwrite the last meaningful trigger shown in the UI.
        let quietGuardEvaluation = trigger == "safety-guard" && plan == previousEvaluation
        if !quietGuardEvaluation {
            currentStatus.lastTrigger = trigger
            logEvaluation(trigger: trigger, snapshot: snapshot, plan: plan)
        }

        guard applyActions,
              (forceActions || configuration.automatic.isEnabled),
              currentStatus.pauseReason == nil else {
            if currentStatus.pauseReason != nil {
                diagnostics.append(RuntimeDiagnostic(
                    severity: .info,
                    code: .automationPaused,
                    message: "Automatic actions were not applied because automation is paused."
                ))
            }
            currentStatus.diagnostics = diagnostics
            publishStatus()
            return .notNeeded
        }

        let boundFingerprint = policyFingerprint(snapshot)
        let now = scheduler.now
        let oldSuppressionCount = runtimeState.failureSuppressions.count
        runtimeState.failureSuppressions.removeAll { $0.suppressedUntil <= now }
        if oldSuppressionCount != runtimeState.failureSuppressions.count { try persistRuntimeState() }

        let hasTransitionRestores = reconcileRecoveryEvidence && !recoveryPlan(for: snapshot).isEmpty
        let hasSafetyBlocks = !plan.safetyBlocks.isEmpty
        if hasSafetyBlocks {
            diagnostics.append(RuntimeDiagnostic(
                severity: .warning,
                code: .safetyRecovery,
                message: "One or more Profile actions were blocked to preserve an active usable display."
            ))
        }
        guard !plan.winningActions.isEmpty || hasTransitionRestores else {
            currentStatus.diagnostics = diagnostics
            publishStatus()
            return hasSafetyBlocks ? .blockedBySafety : .notNeeded
        }

        let report = try applyWithRetries(
            initialSnapshot: snapshot,
            initialPlan: plan,
            boundFingerprint: boundFingerprint,
            reconcileRecoveryEvidence: reconcileRecoveryEvidence,
            forceActions: forceActions,
            allowedActionIntents: allowedActionIntents,
            quietIdempotentLogs: trigger == "safety-guard"
        )
        diagnostics.append(contentsOf: report.diagnostics)
        currentStatus.diagnostics = diagnostics
        if report.outcome != .notNeeded {
            do {
                snapshot = try observeAndNormalize()
                currentStatus.inventory = snapshot
            } catch {
                diagnostics.append(RuntimeDiagnostic(
                    severity: .error,
                    code: .actionFailed,
                    message: "Hardware actions completed, but the final inventory refresh failed: \(error.localizedDescription)"
                ))
                currentStatus.diagnostics = diagnostics
            }
        }
        publishStatus()
        if hasSafetyBlocks && report.outcome == .applied { return .partiallyFailed }
        if hasSafetyBlocks && report.outcome == .notNeeded { return .blockedBySafety }
        return report.outcome
    }

    private func applyWithRetries(
        initialSnapshot: ObservedDisplaySnapshot,
        initialPlan: RuleEvaluationPlan,
        boundFingerprint: DisplayPolicySnapshotFingerprint,
        reconcileRecoveryEvidence: Bool,
        forceActions: Bool,
        allowedActionIntents: Set<ConfirmedActionIntent>?,
        quietIdempotentLogs: Bool = false
    ) throws -> HardwareApplicationReport {
        var finalFailures: [DisplayActionResult] = []
        var diagnostics: [RuntimeDiagnostic] = []
        var settledActions: [EvaluatedDisplayKey: DisplayAction] = [:]
        var attemptedAnyAction = false
        var confirmedAnyAction = false
        var safetyBlocked = false
        var stalePlanExhausted = false
        let initialMatchesBinding = policyFingerprint(initialSnapshot) == boundFingerprint

        for attempt in 1...maximumActionAttempts {
            let freshSnapshot = try observeAndNormalize()
            let freshFingerprint = policyFingerprint(freshSnapshot)
            let plan = attempt == 1 && initialMatchesBinding && freshFingerprint == boundFingerprint
                ? initialPlan
                : evaluator.evaluate(
                    configuration: configurationForEvaluation(configuration, forceActions: forceActions),
                    snapshot: freshSnapshot
                )
            currentStatus.inventory = freshSnapshot
            currentStatus.lastEvaluation = plan

            // Both ordinary rule actions and activation transition restores are
            // derived again from this exact observation on every attempt.
            var requests = requestsForEvaluation(
                plan,
                snapshot: freshSnapshot,
                reconcileRecoveryEvidence: reconcileRecoveryEvidence,
                allowedProfileActionIntents: allowedActionIntents
            )
            requests.removeAll { request in
                guard settledActions[request.display] == request.action,
                      let observed = freshSnapshot.displays.first(where: {
                          $0.runtimeID == request.display.runtimeID
                              && $0.stableIdentity == request.display.stableIdentity
                              && $0.family == request.display.family
                      }) else { return false }
                switch request.action {
                case .noAction:
                    return true
                case .enable:
                    return observed.state.isOnline
                case .disable:
                    return !observed.state.isOnline
                }
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
            attemptedAnyAction = true

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
            let idempotentNoop = !outcome.transactionWasCommitted
                && !outcome.results.contains { !$0.wasIdempotent || !$0.succeeded }
            if !(quietIdempotentLogs && idempotentNoop) {
                logTransactionOutcome(
                    attempt: attempt,
                    outcome: outcome,
                    afterWasObserved: afterWasObserved
                )
            }
            if outcome.requiresReevaluation {
                try clearPendingForKnownUncommittedFailures(outcome)
                if attempt == maximumActionAttempts { stalePlanExhausted = true }
                continue
            }
            try applyConfirmedResults(outcome.results)
            try clearPendingForKnownUncommittedFailures(outcome)
            for result in outcome.results where result.succeeded {
                settledActions[result.request.display] = result.request.action
                confirmedAnyAction = true
            }
            if let safety = try recoverIfCommittedWithoutActiveDisplay(
                outcome: outcome,
                disableRequests: requests
            ) {
                diagnostics.append(safety)
                safetyBlocked = true
                finalFailures = []
                break
            }

            finalFailures = outcome.results.filter { !$0.succeeded }
            if finalFailures.isEmpty { break }
            log("[AUTO] display action attempt \(attempt)/\(maximumActionAttempts) failed for runtime IDs \(finalFailures.map { $0.request.display.runtimeID })")
        }

        if !finalFailures.isEmpty {
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
        }
        if stalePlanExhausted {
            diagnostics.append(RuntimeDiagnostic(
                severity: .error,
                code: .actionFailed,
                message: "Display actions were not applied because the observed policy snapshot changed on every retry."
            ))
        }

        let outcome: ProfileHardwareApplicationOutcome
        if safetyBlocked {
            outcome = .blockedBySafety
        } else if stalePlanExhausted {
            outcome = confirmedAnyAction ? .partiallyFailed : .failed
        } else if !finalFailures.isEmpty {
            outcome = confirmedAnyAction ? .partiallyFailed : .failed
        } else if diagnostics.contains(where: { $0.code == .actionSuppressed }) {
            outcome = confirmedAnyAction ? .partiallyFailed : .failed
        } else {
            outcome = attemptedAnyAction ? .applied : .notNeeded
        }
        return HardwareApplicationReport(outcome: outcome, diagnostics: diagnostics)
    }

    private func requestsForEvaluation(
        _ plan: RuleEvaluationPlan,
        snapshot: ObservedDisplaySnapshot,
        reconcileRecoveryEvidence: Bool,
        allowedProfileActionIntents: Set<ConfirmedActionIntent>? = nil
    ) -> [DisplayActionRequest] {
        var profileRequests = plan.winningActions.map {
            DisplayActionRequest(display: $0.display, action: $0.action)
        }
        if let allowedProfileActionIntents {
            profileRequests.removeAll {
                !allowedProfileActionIntents.contains(
                    ConfirmedActionIntent(display: $0.display, action: $0.action)
                )
            }
        }
        var requests = Dictionary(uniqueKeysWithValues: profileRequests.map { ($0.display, $0) })
        if reconcileRecoveryEvidence {
            for target in recoveryPlan(for: snapshot).targets {
                if requests[target.display]?.action == .disable { continue }
                requests[target.display] = DisplayActionRequest(display: target.display, action: .enable)
            }
        }
        return requests.values.sorted { lhs, rhs in lhs.display < rhs.display }
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
        if changed {
            try persistRuntimeState()
            restartSafetyGuard()
        }
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

        if updateDisplayHistory(from: snapshot) {
            snapshot = try adapter.observe(configuration: configuration, runtimeState: runtimeState)
        }
        seedDefaultExternalRulesIfNeeded(snapshot: snapshot)
        currentStatus.recoveryPlan = recoveryPlan(for: snapshot)
        return snapshot
    }

    private func updateDisplayHistory(from snapshot: ObservedDisplaySnapshot) -> Bool {
        guard runtimeStateIsWritable else { return false }
        var changed = false

        if settingsIsWritable {
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
            if updated.deviceHistory != configuration.deviceHistory {
                do {
                    try configurationStore.saveApplicationSettings(from: updated)
                    configuration.deviceHistory = updated.deviceHistory
                    currentStatus.configuration = configuration
                    currentStatus.settingsGenerationSource = .primary
                    changed = true
                } catch {
                    settingsIsWritable = false
                    baseDiagnostics.append(RuntimeDiagnostic(
                        severity: .error,
                        code: .configurationUnavailable,
                        message: "Display History Records could not be persisted: \(error.localizedDescription)"
                    ))
                }
            }
        }

        return changed
    }

    /// A fresh install starts with an empty default Profile and Automation off.
    /// The built-in display target is only knowable once the first observation
    /// reports it, so on that observation the two default external-display rules
    /// are seeded into the pristine Profile and persisted. Automation stays off;
    /// the rules are inert until the user enables it.
    private func seedDefaultExternalRulesIfNeeded(snapshot: ObservedDisplaySnapshot) {
        guard runtimeStateIsWritable,
              activeProfileIsWritable,
              currentStatus.configurationLoadSource == .createdBlankProfile,
              let profile = activeProfile,
              profile.rules.isEmpty,
              let builtIn = snapshot.displays.first(where: {
                  $0.isBuiltIn && $0.state.isOnline && $0.family.isValid
              }) else { return }
        let target: DisplayTarget = builtIn.stableIdentity.map(DisplayTarget.exact)
            ?? .family(builtIn.family)

        var seeded = profile
        seeded.rules = LegacyConfigurationMigrator.defaultExternalRules(target: target)
        do {
            try seeded.validate()
            try configurationStore.saveProfile(seeded)
            markActiveProfilePersistedPrimary(seeded)
            configuration = AppConfiguration(
                settings: configuration.applicationSettings(activeProfileID: seeded.id),
                profile: seeded
            )
            currentStatus.configuration = configuration
            refreshCatalogStatus()
            log("[RULES] seeded the default external-display rules into the fresh default profile")
        } catch {
            log("[RULES] could not seed the default external-display rules: \(error.localizedDescription)")
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

    private func markActiveProfilePersistedPrimary(_ profile: DisplayProfile) {
        activeProfile = profile
        activeProfileIsWritable = true
        currentStatus.activeProfile = profile
        currentStatus.activeProfileGenerationSource = .primary
        refreshPersistenceRepairState()
    }

    private func refreshPersistenceRepairState() {
        guard currentStatus.settingsGenerationSource == .primary,
              currentStatus.activeProfileGenerationSource == .primary else { return }
        currentStatus.configurationLoadSource = .primary
        currentStatus.persistenceErrorDescription = nil
        baseDiagnostics.removeAll { $0.code == .configurationFallback }
        currentStatus.diagnostics.removeAll { $0.code == .configurationFallback }
    }

    private func configurationForEvaluation(
        _ source: AppConfiguration,
        forceActions: Bool
    ) -> AppConfiguration {
        guard forceActions else { return source }
        var forced = source
        forced.automatic.isEnabled = true
        return forced
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

    private func refreshCatalogStatus() {
        currentStatus.profileCatalog = configurationStore.catalog()
    }

    private func recordRuntimeError(_ code: RuntimeDiagnosticCode, _ message: String) {
        currentStatus.diagnostics = baseDiagnostics + [RuntimeDiagnostic(severity: .error, code: code, message: message)]
        log("[AUTO] \(message)")
        publishStatus()
    }

    private func publishStatus() {
        currentStatus.configuration = configuration
        currentStatus.activeProfile = activeProfile
        onStatusChange?()
    }
}
