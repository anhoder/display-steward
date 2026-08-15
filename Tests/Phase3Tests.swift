import AppKit
import Foundation

private struct Failure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(description: message) }
}
private func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected { throw Failure(description: "\(message): expected \(expected), got \(actual)") }
}
private struct Runner {
    var failures: [String] = []
    var count = 0
    mutating func run(_ name: String, _ body: () throws -> Void) {
        count += 1
        do { try body(); print("PASS \(name)") } catch { failures.append("FAIL \(name): \(error)") }
    }
    func finish() -> Never {
        failures.forEach { print($0) }
        if failures.isEmpty { print("Passed \(count) Phase 3 tests"); exit(0) }
        exit(1)
    }
}

private let builtInFamily = DisplayFamily(vendorID: 100, modelID: 10)
private let externalFamily = DisplayFamily(vendorID: 200, modelID: 20)
private let builtInIdentity = StableDisplayIdentity(family: builtInFamily, serialNumber: 1)
private let externalIdentity = StableDisplayIdentity(family: externalFamily, serialNumber: 2)

private func display(_ id: UInt32?, _ identity: StableDisplayIdentity?, builtIn: Bool, main: Bool = false, state: ObservableDisplayState, name: String, family: DisplayFamily? = nil) -> ObservedDisplay {
    ObservedDisplay(
        runtimeID: id,
        stableIdentity: identity,
        family: family ?? identity?.family ?? externalFamily,
        name: name,
        isBuiltIn: builtIn,
        isMain: main,
        state: state,
        mode: DisplayModeDetails(
            logicalWidth: 1920,
            logicalHeight: 1080,
            pixelWidth: 3840,
            pixelHeight: 2160,
            refreshRate: 60,
            rotationDegrees: 0,
            scaleFactor: 2
        )
    )
}

private func baseConfiguration() -> AppConfiguration {
    var configuration = AppConfiguration.default
    configuration.deviceHistory = [
        KnownDisplay(target: .exact(builtInIdentity), name: "Built-in Retina Display", isBuiltIn: true, alias: "工作台"),
        KnownDisplay(target: .exact(externalIdentity), name: "Studio Display", isBuiltIn: false)
    ]
    configuration.rules = [DisplayRule(
        id: UUID(),
        name: "默认规则",
        isEnabled: true,
        priority: 10,
        conditions: [.always],
        actions: [
            TargetAction(target: .exact(builtInIdentity), action: .noAction),
            TargetAction(target: .exact(externalIdentity), action: .noAction)
        ]
    )]
    return configuration
}

private final class FakeRuntime: DisplayManagingRuntime {
    var current: AutomationRuntimeStatus
    var previewCount = 0
    var previewObservations: [ObservedDisplaySnapshot?] = []
    var lastPreviewConfiguration: AppConfiguration?
    var profilePreviewCalls: [UUID] = []
    var profilePreviewObservations: [ObservedDisplaySnapshot?] = []
    var updateCount = 0
    var manualCalls: [(UInt32, DisplayAction)] = []
    var lastApplyImmediately: Bool?
    var saveProfileCalls: [(id: UUID, applyImmediately: Bool)] = []
    var activationCalls: [UUID] = []
    var nextActivationHardwareOutcome: ProfileHardwareApplicationOutcome = .notNeeded
    var restoreCalls: [DisplayRecoveryPlan] = []
    var profiles: [UUID: DisplayProfile]
    var invalidProfiles: [InvalidDisplayProfile] = []
    var lastGoodProfiles: [UUID: DisplayProfile] = [:]
    var simulatedExternalActiveProfileID: UUID?
    var simulatedExternalApplicationSettings: ApplicationSettings?
    var simulatedExternalSettingsGenerationSource: PersistenceGenerationSource?
    var simulatedExternalSettingsErrorDescription: String?
    var reloadProfileCatalogCount = 0
    init(configuration: AppConfiguration = baseConfiguration(), displays: [ObservedDisplay]) {
        let profile = configuration.displayProfile(id: UUID(), name: "默认")
        profiles = [profile.id: profile]
        current = AutomationRuntimeStatus(
            configuration: configuration,
            inventory: ObservedDisplaySnapshot(displays: displays),
            lastEvaluation: .empty,
            lastCycleAnalysis: nil,
            lastTrigger: nil,
            pauseReason: nil,
            diagnostics: [],
            configurationLoadSource: .primary,
            activeProfile: profile,
            profileCatalog: DisplayProfileCatalog(profiles: [profile], invalidProfiles: []),
            settingsGenerationSource: .primary,
            activeProfileGenerationSource: .primary
        )
    }

    var status: AutomationRuntimeStatus { current }

    func previewConfigurationReadOnly(
        _ configuration: AppConfiguration,
        observation: ObservedDisplaySnapshot?
    ) throws -> ConfigurationPreview {
        previewCount += 1
        previewObservations.append(observation)
        lastPreviewConfiguration = configuration
        try configuration.validate()
        let snapshot = observation ?? current.inventory
        return ConfigurationPreview(
            evaluation: RuleEvaluator().evaluate(configuration: configuration, snapshot: snapshot),
            cycleAnalysis: RuleCycleAnalyzer().analyze(configuration: configuration, initialSnapshot: snapshot)
        )
    }
    func previewProfileActivation(
        id: UUID,
        observation: ObservedDisplaySnapshot?
    ) throws -> ProfileActivationPreview {
        profilePreviewCalls.append(id)
        profilePreviewObservations.append(observation)
        guard let profile = profiles[id] else { throw ConfigurationStoreError.profileNotFound(id) }
        let candidate = AppConfiguration(
            settings: current.configuration.applicationSettings(activeProfileID: id),
            profile: profile
        )
        let snapshot = observation ?? current.inventory
        return ProfileActivationPreview(
            profile: profile,
            evaluation: RuleEvaluator().evaluate(configuration: candidate, snapshot: snapshot),
            cycleAnalysis: RuleCycleAnalyzer().analyze(configuration: candidate, initialSnapshot: snapshot),
            profileSource: .primary,
            primaryErrorDescription: nil,
            policyFingerprint: DisplayPolicySnapshotFingerprint(snapshot: snapshot)
        )
    }

    func activateProfile(id: UUID) throws -> ProfileActivationResult {
        activationCalls.append(id)
        let preview = try previewProfileActivation(id: id, observation: nil)
        current.configuration = AppConfiguration(
            settings: current.configuration.applicationSettings(activeProfileID: id),
            profile: preview.profile
        )
        current.activeProfile = preview.profile
        current.pauseReason = nil
        current.externalActiveProfileID = nil
        let result = ProfileActivationResult(
            activeProfile: preview.profile,
            preview: preview,
            hardwareOutcome: nextActivationHardwareOutcome,
            actionDiagnostics: nextActivationHardwareOutcome == .notNeeded || nextActivationHardwareOutcome == .applied
                ? []
                : [RuntimeDiagnostic(severity: .error, code: .actionFailed, message: "simulated hardware outcome")]
        )
        current.lastProfileActivation = result
        refreshFakeCatalog()
        return result
    }
    func activateProfile(
        id: UUID,
        confirmedPreview: ProfileActivationPreview
    ) throws -> ProfileActivationResult {
        let currentPreview = try previewProfileActivation(id: id, observation: nil)
        guard currentPreview.profile == confirmedPreview.profile,
              currentPreview.policyFingerprint == confirmedPreview.policyFingerprint else {
            throw AutomationCoordinatorError.staleProfileActivationPreview
        }
        return try activateProfile(id: id)
    }


    func createBlankProfile(named name: String) throws -> DisplayProfile {
        let profile = DisplayProfile.blank(name: name)
        profiles[profile.id] = profile
        refreshFakeCatalog()
        return profile
    }

    func duplicateProfile(id: UUID, named name: String) throws -> DisplayProfile {
        guard let source = profiles[id] else { throw ConfigurationStoreError.profileNotFound(id) }
        var profile = DisplayProfile(
            schemaVersion: DisplayProfile.currentSchemaVersion,
            id: UUID(),
            name: name,
            automatic: source.automatic,
            polling: source.polling,
            rules: source.rules
        )
        for index in profile.rules.indices { profile.rules[index].id = UUID() }
        profiles[profile.id] = profile
        refreshFakeCatalog()
        return profile
    }

    func renameProfile(id: UUID, to name: String) throws -> DisplayProfile {
        guard var profile = profiles[id] else { throw ConfigurationStoreError.profileNotFound(id) }
        profile.name = name
        try profile.validate()
        profiles[id] = profile
        if current.activeProfile?.id == id { current.activeProfile = profile }
        refreshFakeCatalog()
        return profile
    }

    func deleteInactiveProfile(id: UUID) throws {
        guard current.activeProfile?.id != id else { throw ConfigurationStoreError.cannotDeleteActiveProfile }
        guard profiles.removeValue(forKey: id) != nil else { throw ConfigurationStoreError.profileNotFound(id) }
        refreshFakeCatalog()
    }

    func saveProfile(_ profile: DisplayProfile, applyImmediately: Bool) throws -> AutomationRuntimeStatus {
        try profile.validate()
        guard profiles[profile.id] != nil else { throw ConfigurationStoreError.profileNotFound(profile.id) }
        saveProfileCalls.append((profile.id, applyImmediately))
        lastApplyImmediately = applyImmediately
        profiles[profile.id] = profile
        if current.activeProfile?.id == profile.id {
            current.activeProfile = profile
            current.configuration = AppConfiguration(
                settings: current.configuration.applicationSettings(activeProfileID: profile.id),
                profile: profile
            )
            current.lastTrigger = applyImmediately ? "save-and-apply" : "save"
        }
        refreshFakeCatalog()
        return current
    }
    func restoreProfileFromLastKnownGood(id: UUID) throws -> DisplayProfile {
        guard let profile = lastGoodProfiles[id] ?? profiles[id] else {
            throw ConfigurationStoreError.profileRestoreUnavailable(id, "missing fake backup")
        }
        profiles[id] = profile
        invalidProfiles.removeAll { $0.profileID == id }
        if current.activeProfile?.id == id {
            current.activeProfile = profile
            current.configuration = AppConfiguration(
                settings: current.configuration.applicationSettings(activeProfileID: id),
                profile: profile
            )
            current.activeProfileGenerationSource = .primary
        }
        refreshFakeCatalog()
        return profile
    }

    func removeInvalidProfile(fileName: String) throws -> AutomationRuntimeStatus {
        guard invalidProfiles.contains(where: { $0.fileName == fileName }) else {
            throw ConfigurationStoreError.invalidProfileNotFound(fileName)
        }
        invalidProfiles.removeAll { $0.fileName == fileName }
        refreshFakeCatalog()
        return current
    }

    func reloadProfileCatalog() -> AutomationRuntimeStatus {
        reloadProfileCatalogCount += 1
        refreshFakeCatalog()
        current.externalActiveProfileID = simulatedExternalActiveProfileID
        current.externalApplicationSettings = simulatedExternalApplicationSettings
        current.externalSettingsGenerationSource = simulatedExternalSettingsGenerationSource
        current.externalSettingsErrorDescription = simulatedExternalSettingsErrorDescription
        current.lastTrigger = "profile-catalog-reload"
        return current
    }

    private func refreshFakeCatalog() {
        current.profileCatalog = DisplayProfileCatalog(
            profiles: profiles.values.sorted(by: DisplayProfile.orderedByName),
            invalidProfiles: invalidProfiles
        )
    }

    func updateConfiguration(_ configuration: AppConfiguration, applyImmediately: Bool) throws -> AutomationRuntimeStatus {
        updateCount += 1
        lastApplyImmediately = applyImmediately
        try configuration.validate()
        current.configuration = configuration
        current.pauseReason = applyImmediately ? nil : current.pauseReason
        current.lastTrigger = applyImmediately ? "save-and-apply" : "save"
        return current
    }

    func performManualAction(runtimeID: UInt32, action: DisplayAction) throws -> AutomationRuntimeStatus {
        manualCalls.append((runtimeID, action))
        current.pauseReason = .manualDisplayAction
        return current
    }
    func prepareDisplayRecovery(only targets: [DisplayRecoveryTarget]?) throws -> DisplayRecoveryPlan {
        let available = current.recoveryPlan
        guard let targets else { return available }
        let keys = Set(targets.map(\.display))
        return DisplayRecoveryPlan(targets: available.targets.filter { keys.contains($0.display) })
    }

    func restoreDisplays(_ plan: DisplayRecoveryPlan) -> DisplayRecoveryBatchResult {
        restoreCalls.append(plan)
        let result = DisplayRecoveryBatchResult(items: plan.targets.map {
            DisplayRecoveryItemResult(target: $0, disposition: .restored, explanation: "restored")
        })
        current.pauseReason = .manualDisplayAction
        current.lastRecoveryResult = result
        current.recoveryPlan = .empty
        return result
    }

    func pause() { current.pauseReason = .explicit }
    func resume() { current.pauseReason = nil }
    func refresh() throws -> AutomationRuntimeStatus { current.lastTrigger = "refresh"; return current }
}

private final class FakeNotificationDelivery: SevereNotificationDelivering {
    var deliveries: [(String, String, String)] = []
    func requestAuthorization() {}
    func deliver(identifier: String, title: String, body: String) { deliveries.append((identifier, title, body)) }
}
private final class ReadOnlyPreviewAdapter: DisplayRuntimeAdapting {
    var snapshot: ObservedDisplaySnapshot
    var observeCount = 0

    init(snapshot: ObservedDisplaySnapshot) {
        self.snapshot = snapshot
    }

    func observe(
        configuration: AppConfiguration,
        runtimeState: RuntimeState
    ) throws -> ObservedDisplaySnapshot {
        observeCount += 1
        return snapshot
    }

    func apply(
        requests: [DisplayActionRequest],
        expectedFingerprint: DisplayPolicySnapshotFingerprint,
        configuration: AppConfiguration,
        runtimeState: RuntimeState,
        didCommit: () throws -> Void
    ) throws -> DisplayTransactionOutcome {
        throw Failure(description: "read-only preview attempted a display transaction")
    }
}


private func allSubviews(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(allSubviews)
}

@main
private enum Phase3TestMain {
    static func main() {
var runner = Runner()

runner.run("truthful observable state labels") {
    try equal(ObservableDisplayState.online.presentationName, "在线", "online wording changed")
    try equal(ObservableDisplayState.active.presentationName, "活动且可绘制", "active wording changed")
    try equal(ObservableDisplayState.disabledByThisAppConnectionUnknown.presentationName, "由本应用关闭（连接未知）", "app-disabled wording asserted connection")
    try equal(ObservableDisplayState.notObserved.presentationName, "当前未观察到", "history wording asserted connection")
}

runner.run("rule draft is copied and preview is non-destructive") {
    let runtime = FakeRuntime(displays: [
        display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in Retina Display"),
        display(2, externalIdentity, builtIn: false, state: .active, name: "Studio Display")
    ])
    let model = ProfileManagementViewModel(runtime: runtime)
    _ = try model.duplicateSelectedRule()
    model.updateSelectedRule { $0.name = "副本已修改" }
    try equal(runtime.status.configuration.rules.count, 1, "editing mutated the live configuration")
    _ = try model.preview()
    try equal(runtime.previewCount, 1, "preview seam was not used")
    try equal(runtime.updateCount, 0, "preview persisted configuration")
    try equal(runtime.manualCalls.count, 0, "preview performed a display action")
}

runner.run("rule validation blocks empty and unreliable edits") {
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, state: .active, name: "Built-in")])
    let model = ProfileManagementViewModel(runtime: runtime)
    model.updateSelectedRule { $0.actions = [] }
    do {
        try model.validateDraft()
        throw Failure(description: "empty actions were accepted")
    } catch PresentationError.emptyActions {}
    model.updateSelectedRule {
        $0.actions = [TargetAction(target: .exact(builtInIdentity), action: .noAction)]
        $0.conditions = [.exactState(
            identity: StableDisplayIdentity(family: DisplayFamily(vendorID: 0, modelID: 0), serialNumber: 0),
            state: .active
        )]
    }
    do {
        try model.validateDraft()
        throw Failure(description: "unreliable exact identity was accepted")
    } catch is ConfigurationValidationError {}
}

runner.run("deleting every rule persists an intentional empty list") {
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, state: .active, name: "Built-in")])
    let model = ProfileManagementViewModel(runtime: runtime)
    model.deleteSelectedRule()
    _ = try model.saveSelectedProfile()
    try expect(runtime.status.configuration.rules.isEmpty, "empty global rule list was repopulated")
    try equal(runtime.lastApplyImmediately, true, "Save and Apply did not use the apply seam")
}

runner.run("menu enablement follows truthful actionable states") {
    var configuration = baseConfiguration()
    let historyIdentity = StableDisplayIdentity(family: DisplayFamily(vendorID: 300, modelID: 30), serialNumber: 3)
    configuration.deviceHistory.append(KnownDisplay(target: .exact(historyIdentity), name: "Old Display", isBuiltIn: false))
    let runtime = FakeRuntime(configuration: configuration, displays: [
        display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in Retina Display"),
        display(2, externalIdentity, builtIn: false, state: .disabledByThisAppConnectionUnknown, name: "Studio Display"),
        display(nil, historyIdentity, builtIn: false, state: .notObserved, name: "Old Display")
    ])
    let menu = PresentationText.menu(status: runtime.status)
    try equal(menu.displays.first(where: { $0.runtimeID == 1 })?.manualAction, .disable, "active display was not closable")
    try equal(menu.displays.first(where: { $0.runtimeID == 2 })?.manualAction, .enable, "app-disabled display was not restorable")
    try equal(menu.displays.first(where: { $0.state == .notObserved })?.manualAction, nil, "history was made manually actionable")
    try expect(menu.displays.first(where: { $0.runtimeID == 2 })?.rowDetail.contains("连接未知") == true, "app-disabled menu row implied physical connection")
}

runner.run("aliases persist and referenced history cannot be forgotten") {
    var configuration = baseConfiguration()
    configuration.rules[0].conditions = [.familyState(family: externalFamily, state: .notObserved)]
    let runtime = FakeRuntime(configuration: configuration, displays: [display(nil, externalIdentity, builtIn: false, state: .notObserved, name: "Studio Display")])
    let model = DisplaysViewModel(runtime: runtime)
    let row = try { () throws -> DisplayPresentationRow in
        guard let row = model.rows.first else { throw Failure(description: "missing history row") }
        return row
    }()
    try expect(!row.canForget, "referenced historical display was forgettable")
    do {
        _ = try model.forget(rowID: row.id)
        throw Failure(description: "referenced historical display was forgotten")
    } catch PresentationError.historicalDisplayReferenced {}
    _ = try model.setAlias("演示屏", for: row.id)
    try equal(runtime.status.configuration.deviceHistory.first(where: { $0.target == .exact(externalIdentity) })?.alias, "演示屏", "alias was not persisted through configuration")
}

runner.run("settings window unifies summary, rules, and displays") {
    _ = NSApplication.shared
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let settings = SettingsWindowController(
        runtime: runtime,
        shortcutProvider: { KeyShortcut(keyCode: 2, modifiers: 0x1A00) },
        shortcutSetter: { _ in true },
        shortcutResetter: { true },
        onLastActiveSafetyBlock: {}
    )
    guard let content = settings.window?.contentView else { throw Failure(description: "settings content missing") }
    try equal(settings.window?.title, "Display Steward 设置", "settings title changed")
    let buttonTitles = allSubviews(of: content).compactMap { ($0 as? NSButton)?.title }
    try expect(buttonTitles.contains("启用自动化"), "automation master missing")
    try expect(buttonTitles.contains("编辑规则…"), "rules summary entry missing")
    try expect(buttonTitles.contains("管理显示器…"), "displays summary entry missing")
    try expect(!buttonTitles.contains("关闭内置显示器") && !buttonTitles.contains("恢复内置显示器"), "fixed built-in buttons survived")
    try expect(allSubviews(of: content).compactMap { $0 as? NSSegmentedControl }.isEmpty, "separate management navigation survived")
    content.layoutSubtreeIfNeeded()
    let cardIDs = Set(allSubviews(of: content).compactMap { $0.identifier?.rawValue })
    let expectedCardIDs = Set(["settingsStatusCard", "settingsAutomationCard", "settingsRulesCard", "settingsDisplaysCard", "settingsApplicationCard"])
    try expect(expectedCardIDs.isSubset(of: cardIDs), "settings summary sections are not visually grouped")
    let cards = allSubviews(of: content).filter { view in
        guard let identifier = view.identifier?.rawValue else { return false }
        return expectedCardIDs.contains(identifier)
    }
    let cardFrames = cards.map { $0.convert($0.bounds, to: content) }
    try expect(cardFrames.allSatisfy { $0.minX >= InterfaceMetrics.space5 && $0.maxX <= content.bounds.width - InterfaceMetrics.space5 }, "settings cards touch the window edge")

    settings.showDetail(.rules)
    try equal(settings.activeDetail, .rules, "rules did not open in the settings detail layer")
    try expect(settings.rulesController.view.superview != nil, "rules detail was not attached to settings")
    let ruleDocumentStacks = allSubviews(of: settings.rulesController.view).compactMap { ($0 as? NSScrollView)?.documentView as? NSStackView }
    try expect(!ruleDocumentStacks.isEmpty && ruleDocumentStacks.allSatisfy { $0.isFlipped }, "rule editor starts away from the top edge")
    settings.showDetail(.displays)
    try equal(settings.activeDetail, .displays, "displays did not open in the settings detail layer")
    try expect(settings.displaysController.view.superview != nil, "displays detail was not attached to settings")
    let displayDocumentStacks = allSubviews(of: settings.displaysController.view).compactMap { ($0 as? NSScrollView)?.documentView as? NSStackView }
    try expect(!displayDocumentStacks.isEmpty && displayDocumentStacks.allSatisfy { $0.isFlipped }, "display details start away from the top edge")
    settings.showSummary()
    try equal(settings.activeDetail, nil, "settings summary did not return")
}

runner.run("severe notifications deduplicate unchanged diagnostics") {
    let runtime = FakeRuntime(displays: [])
    runtime.current.diagnostics = [RuntimeDiagnostic(severity: .error, code: .configurationUnavailable, message: "same")]
    let delivery = FakeNotificationDelivery()
    let presenter = SevereNotificationPresenter(delivery: delivery)
    presenter.present(status: runtime.status)
    presenter.present(status: runtime.status)
    try equal(delivery.deliveries.count, 1, "unchanged severe diagnostic notified twice")
    runtime.current.diagnostics = []
    presenter.present(status: runtime.status)
    runtime.current.diagnostics = [RuntimeDiagnostic(severity: .error, code: .configurationUnavailable, message: "same")]
    presenter.present(status: runtime.status)
    try equal(delivery.deliveries.count, 2, "recurring diagnostic after recovery was not notified")
}

runner.run("rule save merges only draft rules into current settings") {
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, state: .active, name: "Built-in")])
    let model = ProfileManagementViewModel(runtime: runtime)
    model.updateSelectedRule { $0.name = "规则草稿" }
    model.setPollingInterval(73)
    runtime.current.configuration.hotKey = HotKeyConfiguration(keyCode: 12, modifiers: 0x100)
    runtime.current.configuration.deviceHistory[0].alias = "运行时新别名"
    _ = try model.saveSelectedProfile()
    try equal(runtime.status.configuration.polling.intervalSeconds, 73, "rule save overwrote current polling settings")
    try equal(runtime.status.configuration.hotKey.keyCode, 12, "rule save overwrote current shortcut")
    try equal(runtime.status.configuration.deviceHistory[0].alias, "运行时新别名", "rule save overwrote current alias")
    try equal(runtime.status.configuration.rules.first?.name, "规则草稿", "draft rules were not saved")
}

runner.run("display rows stay distinct for repeated family runtime IDs") {
    let runtime = FakeRuntime(displays: [
        display(41, nil, builtIn: false, state: .active, name: "Dock A", family: externalFamily),
        display(42, nil, builtIn: false, state: .active, name: "Dock B", family: externalFamily),
        display(43, nil, builtIn: false, state: .active, name: "Invalid", family: DisplayFamily(vendorID: 0, modelID: 0))
    ])
    let rows = PresentationText.displayRows(status: runtime.status)
    let repeatedFamilyIDs = rows.filter { $0.family == externalFamily }.map(\.id)
    try equal(Set(repeatedFamilyIDs).count, 2, "same-family current rows shared an ID")
    try expect(repeatedFamilyIDs.allSatisfy { $0.contains("runtime:") }, "current row ID omitted runtime ID")
    try equal(rows.first(where: { $0.runtimeID == 43 })?.manualAction, nil, "invalid-family current row exposed a doomed action")
}

runner.run("rule priorities change only on explicit reorder") {
    func makeRule(_ name: String, priority: Int) -> DisplayRule {
        DisplayRule(
            id: UUID(),
            name: name,
            isEnabled: true,
            priority: priority,
            conditions: [.always],
            actions: [TargetAction(target: .exact(builtInIdentity), action: .noAction)]
        )
    }
    var configuration = baseConfiguration()
    configuration.rules = [makeRule("低", priority: 10), makeRule("高", priority: 50), makeRule("中", priority: 30)]
    let runtime = FakeRuntime(configuration: configuration, displays: [display(1, builtInIdentity, builtIn: true, state: .active, name: "Built-in")])
    let model = ProfileManagementViewModel(runtime: runtime)
    try equal(model.draftConfiguration.rules.map(\.priority), [50, 30, 10], "rule list was not sorted by numeric priority")
    let original = Dictionary(uniqueKeysWithValues: model.draftConfiguration.rules.map { ($0.id, $0.priority) })
    _ = try model.addRule()
    for (id, priority) in original {
        try equal(model.draftConfiguration.rules.first(where: { $0.id == id })?.priority, priority, "add changed an existing priority")
    }
    let beforeDuplicate = Dictionary(uniqueKeysWithValues: model.draftConfiguration.rules.map { ($0.id, $0.priority) })
    _ = try model.duplicateSelectedRule()
    for (id, priority) in beforeDuplicate {
        try equal(model.draftConfiguration.rules.first(where: { $0.id == id })?.priority, priority, "duplicate changed an existing priority")
    }
    model.deleteSelectedRule()
    for (id, priority) in beforeDuplicate {
        try equal(model.draftConfiguration.rules.first(where: { $0.id == id })?.priority, priority, "delete changed a retained priority")
    }
    model.moveRule(from: 0, to: model.draftConfiguration.rules.count)
    let rebalanced = model.draftConfiguration.rules.map(\.priority)
    try expect(zip(rebalanced, rebalanced.dropFirst()).allSatisfy { pair in pair.0 > pair.1 }, "explicit reorder did not rebalance numeric priority")
}

runner.run("matrix exposes exact and deduplicated family targets") {
    let runtime = FakeRuntime(displays: [display(2, externalIdentity, builtIn: false, state: .active, name: "Studio Display")])
    let options = ProfileManagementViewModel(runtime: runtime).targetOptions().map(\.target)
    try expect(options.contains(.exact(externalIdentity)), "reliable exact target missing from matrix")
    try expect(options.contains(.family(externalFamily)), "family target missing beside reliable exact target")
    try equal(options.filter { $0 == .family(externalFamily) }.count, 1, "family matrix target was duplicated")
}

runner.run("no-action references do not block forgetting history") {
    var configuration = baseConfiguration()
    configuration.deviceHistory = [KnownDisplay(target: .exact(externalIdentity), name: "Old", isBuiltIn: false)]
    configuration.rules = [DisplayRule(
        id: UUID(),
        name: "无意见",
        isEnabled: true,
        priority: 10,
        conditions: [.always],
        actions: [TargetAction(target: .exact(externalIdentity), action: .noAction)]
    )]
    let runtime = FakeRuntime(configuration: configuration, displays: [display(nil, externalIdentity, builtIn: false, state: .notObserved, name: "Old")])
    let row = try { () throws -> DisplayPresentationRow in
        guard let row = DisplaysViewModel(runtime: runtime).rows.first else { throw Failure(description: "history row missing") }
        return row
    }()
    try expect(row.canForget, "no-action entry incorrectly blocked Forget")
}

runner.run("safety recovery is severe deduplicated and neutrally worded") {
    let runtime = FakeRuntime(displays: [])
    let diagnostic = RuntimeDiagnostic(severity: .error, code: .safetyRecovery, message: "committed disable left no active display")
    runtime.current.diagnostics = [diagnostic]
    let delivery = FakeNotificationDelivery()
    let presenter = SevereNotificationPresenter(delivery: delivery)
    presenter.present(status: runtime.status)
    presenter.present(status: runtime.status)
    try equal(delivery.deliveries.count, 1, "unchanged safety recovery notified twice")
    let wording = PresentationText.runtimeDiagnostic(diagnostic)
    try expect(!wording.contains("已恢复"), "safety recovery presentation claimed success")
    try expect(wording.contains("已暂停"), "safety recovery presentation omitted failure guidance")
}

runner.run("every menu disable has confirmation with stronger main copy") {
    let ordinary = PresentationText.manualDisableConfirmation(displayName: "Studio Display", isMain: false)
    let main = PresentationText.manualDisableConfirmation(displayName: "Built-in", isMain: true)
    try expect(!ordinary.isCritical, "ordinary display used main-screen severity")
    try expect(ordinary.title.contains("Studio Display"), "ordinary confirmation omitted display name")
    try expect(main.isCritical, "main-screen confirmation was not stronger")
    try expect(main.title.contains("主显示器"), "main-screen confirmation did not identify risk")
}

runner.run("coordinator preview is read-only and uses injected observation") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-phase3-preview-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    var configuration = baseConfiguration()
    let ruleID = UUID()
    configuration.rules = [DisplayRule(
        id: ruleID,
        name: "注入快照",
        isEnabled: true,
        priority: 10,
        conditions: [.exactState(identity: builtInIdentity, state: .active)],
        actions: [TargetAction(target: .exact(builtInIdentity), action: .disable)]
    )]
    let configurationStore = ConfigurationStore(rootURL: root, legacyDefaults: nil)
    try configurationStore.save(configuration)
    let stateStore = RuntimeStateStore(rootURL: root, legacyDefaults: nil, bootIdentifierProvider: { "boot" })
    try stateStore.save(.empty(bootIdentifier: "boot"))
    let configurationBefore = try Data(contentsOf: configurationStore.configurationURL)
    let runtimeBefore = try Data(contentsOf: stateStore.runtimeStateURL)
    let adapter = ReadOnlyPreviewAdapter(snapshot: .init(displays: []))
    let coordinator = try AutomationCoordinator(
        configurationStore: configurationStore,
        runtimeStateStore: stateStore,
        adapter: adapter
    )
    let injected = ObservedDisplaySnapshot(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let preview = try coordinator.previewConfigurationReadOnly(configuration, observation: injected)
    try expect(preview.evaluation.matchedRuleIDs.contains(ruleID), "preview ignored injected observation")
    try equal(adapter.observeCount, 0, "preview performed adapter observation instead of using current/injected state")
    try equal(try Data(contentsOf: configurationStore.configurationURL), configurationBefore, "preview persisted configuration")
    try equal(try Data(contentsOf: stateStore.runtimeStateURL), runtimeBefore, "preview persisted runtime state")
}

runner.run("menu commands re-resolve row and expected identity") {
    let runtime = FakeRuntime(displays: [
        display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in"),
        display(2, externalIdentity, builtIn: false, state: .active, name: "External")
    ])
    guard let original = PresentationText.menu(status: runtime.status).displays.first(where: { $0.runtimeID == 2 }),
          let expectedTarget = original.target,
          let expectedAction = original.manualAction else {
        throw Failure(description: "initial menu command was unavailable")
    }
    let resolved = try PresentationText.resolveManualDisplayCommand(
        status: runtime.status,
        rowID: original.id,
        expectedTarget: expectedTarget,
        expectedAction: expectedAction
    )
    try equal(resolved.runtimeID, 2, "current menu command did not resolve")

    runtime.current.inventory = ObservedDisplaySnapshot(displays: [
        display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in"),
        display(3, externalIdentity, builtIn: false, state: .active, name: "External")
    ])
    do {
        _ = try PresentationText.resolveManualDisplayCommand(
            status: runtime.status,
            rowID: original.id,
            expectedTarget: expectedTarget,
            expectedAction: expectedAction
        )
        throw Failure(description: "stale runtime ID command was accepted")
    } catch PresentationError.staleManualDisplayCommand {}

    let replacementIdentity = StableDisplayIdentity(
        family: DisplayFamily(vendorID: 300, modelID: 30),
        serialNumber: 3
    )
    runtime.current.inventory = ObservedDisplaySnapshot(displays: [
        display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in"),
        display(2, replacementIdentity, builtIn: false, state: .active, name: "Replacement")
    ])
    do {
        _ = try PresentationText.resolveManualDisplayCommand(
            status: runtime.status,
            rowID: original.id,
            expectedTarget: expectedTarget,
            expectedAction: expectedAction
        )
        throw Failure(description: "reused runtime ID command was accepted")
    } catch PresentationError.staleManualDisplayCommand {}
}

runner.run("recovery presentation exposes pending confirmation and aggregate entry states") {
    let runtime = FakeRuntime(displays: [
        display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in"),
        display(2, externalIdentity, builtIn: false, state: .online, name: "Studio Display")
    ])
    let target = DisplayRecoveryTarget(
        display: EvaluatedDisplayKey(runtimeID: 2, stableIdentity: externalIdentity, family: externalFamily),
        name: "Studio Display",
        isBuiltIn: false,
        observedState: .online,
        evidence: .pendingConfirmation
    )
    runtime.current.recoveryPlan = DisplayRecoveryPlan(targets: [target])

    let row = try { () throws -> DisplayPresentationRow in
        guard let row = PresentationText.displayRows(status: runtime.status).first(where: { $0.runtimeID == 2 }) else {
            throw Failure(description: "pending recovery row missing")
        }
        return row
    }()
    try equal(row.state, .online, "pending recovery falsified the online observation")
    try equal(row.stateSummary, "在线 · 恢复待确认", "pending recovery marker missing")
    try equal(row.manualAction, .enable, "pending recovery still offered disable")
    try equal(row.manualActionTitle, "确认恢复", "pending recovery action title changed")
    try equal(PresentationText.settingsSummary(status: runtime.status).recoveryCount, 1, "settings summary omitted recovery count")
    try expect(PresentationText.menu(status: runtime.status).restoreAllEnabled, "menu aggregate recovery stayed disabled")

    runtime.current.recoveryPlan = .empty
    let emptyMenu = PresentationText.menu(status: runtime.status)
    try expect(!emptyMenu.restoreAllEnabled, "empty recovery menu entry stayed enabled")
    try equal(emptyMenu.restoreAllExplanation, "当前没有由 Display Steward 管理的可恢复显示器", "empty recovery explanation changed")
}

runner.run("recovery confirmation and partial result copy remain explicit") {
    let first = DisplayRecoveryTarget(
        display: EvaluatedDisplayKey(runtimeID: 1, stableIdentity: builtInIdentity, family: builtInFamily),
        name: "Built-in",
        isBuiltIn: true,
        observedState: .disabledByThisAppConnectionUnknown,
        evidence: .disabledByApplication
    )
    let second = DisplayRecoveryTarget(
        display: EvaluatedDisplayKey(runtimeID: 2, stableIdentity: externalIdentity, family: externalFamily),
        name: "Studio Display",
        isBuiltIn: false,
        observedState: .online,
        evidence: .pendingConfirmation
    )
    let confirmation = PresentationText.displayRecoveryConfirmation(DisplayRecoveryPlan(targets: [first, second]))
    try equal(confirmation.confirmTitle, "恢复全部", "bulk confirmation action changed")
    try expect(confirmation.details.contains("已关闭") && confirmation.details.contains("恢复待确认"), "confirmation omitted target evidence states")
    try expect(confirmation.details.contains("200:20:2"), "confirmation omitted stable display identity")

    let result = DisplayRecoveryBatchResult(items: [
        .init(target: first, disposition: .restored, explanation: "restored"),
        .init(target: second, disposition: .unresolved, explanation: "still unresolved")
    ])
    let presentation = PresentationText.displayRecoveryResult(result)
    try equal(presentation.severity, .warning, "partial result severity changed")
    try expect(presentation.retryAvailable, "partial result omitted retry")
    try expect(presentation.details.contains("已恢复") && presentation.details.contains("仍需恢复"), "partial result omitted per-display outcomes")
}

runner.run("settings exposes aggregate and per-display recovery controls") {
    _ = NSApplication.shared
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let settings = SettingsWindowController(
        runtime: runtime,
        shortcutProvider: { KeyShortcut(keyCode: 2, modifiers: 0x1A00) },
        shortcutSetter: { _ in true },
        shortcutResetter: { true },
        onLastActiveSafetyBlock: {}
    )
    let summaryButtons = allSubviews(of: settings.window!.contentView!).compactMap { ($0 as? NSButton)?.title }
    try expect(summaryButtons.contains(PresentationText.restoreAllTitle), "settings recovery control missing")

    let displayButtons = allSubviews(of: settings.displaysController.view).compactMap { ($0 as? NSButton)?.title }
    try expect(displayButtons.contains(PresentationText.restoreAllTitle), "displays recovery control missing")
}

runner.run("Profile selection is independent from Active Profile") {
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let activeID = runtime.status.activeProfile!.id
    let inactive = try runtime.createBlankProfile(named: "演示")
    let model = ProfileManagementViewModel(runtime: runtime)

    let selectedInactive = try model.selectProfile(id: inactive.id)
    try expect(selectedInactive, "inactive Profile could not be selected")
    try equal(model.selectedProfileID, inactive.id, "selected Profile identity did not change")
    try equal(model.activeProfileID, activeID, "list navigation changed Active Profile")
    try expect(runtime.activationCalls.isEmpty && runtime.saveProfileCalls.isEmpty, "list navigation caused persistence or hardware activation")

    let entries = PresentationText.profileMenuEntries(status: runtime.status)
    try expect(entries.first(where: { $0.id == activeID })?.isActive == true, "menu did not mark Active Profile")
    try expect(entries.first(where: { $0.id == inactive.id })?.isActive == false, "menu confused selected Profile with Active Profile")
}

runner.run("Profile dirtiness covers name automation polling and rules") {
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, state: .active, name: "Built-in")])
    let model = ProfileManagementViewModel(runtime: runtime)
    let original = model.draftProfile!

    model.setProfileName("改名")
    try expect(model.isDirty, "name did not dirty the Profile draft")
    model.discardDraft()
    model.setAutomaticEnabled(!original.automatic.isEnabled)
    try expect(model.isDirty, "Automation did not dirty the Profile draft")
    model.discardDraft()
    model.setPollingEnabled(!original.polling.isEnabled)
    model.setPollingInterval(original.polling.intervalSeconds + 17)
    try expect(model.isDirty, "polling did not dirty the Profile draft")
    model.discardDraft()
    model.updateSelectedRule { $0.name += " 草稿" }
    try expect(model.isDirty, "Rules did not dirty the Profile draft")
    model.discardDraft()

    model.updateDraft { $0.id = UUID() }
    try equal(model.draftProfile, original, "draft identity mutation escaped the selected-Profile boundary")
    try expect(!model.isDirty, "rejected identity mutation dirtied the draft")
}

runner.run("Profile preview assembles latest global settings without stale overlay") {
    let runtime = FakeRuntime(displays: [
        display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in"),
        display(2, externalIdentity, builtIn: false, state: .active, name: "External")
    ])
    let activeID = runtime.status.activeProfile!.id
    let inactive = try runtime.duplicateProfile(id: activeID, named: "外接办公")
    let model = ProfileManagementViewModel(runtime: runtime)
    _ = try model.selectProfile(id: inactive.id)
    model.updateSelectedRule { $0.name = "未激活草稿规则" }
    runtime.current.configuration.hotKey = HotKeyConfiguration(keyCode: 44, modifiers: 0x200)
    runtime.current.configuration.deviceHistory[0].alias = "最新全局别名"

    _ = try model.preview()
    try equal(runtime.lastPreviewConfiguration?.hotKey.keyCode, 44, "preview used stale global hotkey")
    try equal(runtime.lastPreviewConfiguration?.deviceHistory[0].alias, "最新全局别名", "preview used stale display history")
    try equal(runtime.lastPreviewConfiguration?.rules.first?.name, "未激活草稿规则", "preview omitted selected Profile draft")

    let refused = try model.selectProfile(id: activeID)
    try expect(!refused, "dirty selection changed without save/discard/cancel")
    try equal(model.selectedProfileID, inactive.id, "dirty transition overlaid the draft onto another Profile")
    let discardedForSelection = try model.selectProfile(id: activeID, resolvingDirtyWith: .discard)
    try expect(discardedForSelection, "discard did not permit selection")
    model.setProfileName("只改当前所选")
    _ = try model.saveSelectedProfile()
    try equal(runtime.saveProfileCalls.last?.id, activeID, "stale inactive draft saved into the new selection")
}

runner.run("inactive save is isolated from Active Profile and hardware") {
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let activeID = runtime.status.activeProfile!.id
    let inactive = try runtime.duplicateProfile(id: activeID, named: "旅行")
    let liveBefore = runtime.status.configuration
    let model = ProfileManagementViewModel(runtime: runtime)
    _ = try model.selectProfile(id: inactive.id)
    model.setProfileName("旅行修改")
    model.setAutomaticEnabled(false)
    model.setPollingInterval(91)
    model.updateSelectedRule { $0.name = "旅行规则" }

    _ = try model.saveSelectedProfile()
    try equal(runtime.saveProfileCalls.last?.id, inactive.id, "inactive save targeted another Profile")
    try equal(runtime.saveProfileCalls.last?.applyImmediately, false, "inactive save requested immediate apply")
    try equal(runtime.status.configuration, liveBefore, "inactive save changed live Active configuration")
    try equal(runtime.status.activeProfile?.id, activeID, "inactive save changed Active Profile")
    try expect(runtime.activationCalls.isEmpty, "inactive save activated hardware")
}

runner.run("save-and-activate persists draft then changes Active selection") {
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let inactive = try runtime.createBlankProfile(named: "手动")
    let model = ProfileManagementViewModel(runtime: runtime)
    _ = try model.selectProfile(id: inactive.id)
    model.setAutomaticEnabled(true)
    model.setPollingEnabled(true)
    model.setPollingInterval(37)

    _ = try model.saveSelectedProfile()
    let confirmedPreview = try model.previewSelectedProfileActivation()
    try expect(runtime.profilePreviewObservations.count == 1 && runtime.profilePreviewObservations[0] == nil, "save-and-activate injected a stale Settings snapshot instead of requesting a fresh runtime preview")
    let result = try model.activateSelectedProfile(confirmedPreview: confirmedPreview)
    try equal(runtime.saveProfileCalls.last?.id, inactive.id, "save-and-activate did not persist selected draft")
    try equal(runtime.saveProfileCalls.last?.applyImmediately, false, "inactive pre-activation save applied hardware")
    try equal(runtime.activationCalls, [inactive.id], "save-and-activate used the wrong activation target")
    try equal(runtime.status.activeProfile?.id, inactive.id, "save-and-activate did not persist Active selection")
    try equal(result.activeProfile.polling.intervalSeconds, 37, "activation did not use the saved draft")
}

runner.run("confirmed activation refuses topology and Profile drift before applying") {
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let originalActiveID = runtime.status.activeProfile!.id
    let inactive = try runtime.createBlankProfile(named: "待确认")
    let model = ProfileManagementViewModel(runtime: runtime)
    _ = try model.selectProfile(id: inactive.id)
    _ = try model.saveSelectedProfile()

    let topologyPreview = try model.previewSelectedProfileActivation()
    runtime.current.inventory = ObservedDisplaySnapshot(displays: [])
    do {
        _ = try model.activateSelectedProfile(confirmedPreview: topologyPreview)
        throw Failure(description: "stale topology preview activated")
    } catch AutomationCoordinatorError.staleProfileActivationPreview {}
    try equal(runtime.status.activeProfile?.id, originalActiveID, "stale topology preview changed Active selection")
    try expect(runtime.activationCalls.isEmpty, "stale topology preview applied hardware")

    let profilePreview = try model.previewSelectedProfileActivation()
    runtime.profiles[inactive.id]!.name = "磁盘已修改"
    do {
        _ = try model.activateSelectedProfile(confirmedPreview: profilePreview)
        throw Failure(description: "stale Profile preview activated")
    } catch AutomationCoordinatorError.staleProfileActivationPreview {}
    try equal(runtime.status.activeProfile?.id, originalActiveID, "stale Profile preview changed Active selection")
    try expect(runtime.activationCalls.isEmpty, "stale Profile preview applied hardware")
    let staleCopy = PresentationText.error(AutomationCoordinatorError.staleProfileActivationPreview)
    try expect(staleCopy.contains("预览已过期") && staleCopy.contains("未切换当前配置档") && staleCopy.contains("未执行显示器操作"), "stale-preview refusal was not surfaced truthfully")
}

runner.run("Active Profile save uses save-and-apply seam") {
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let model = ProfileManagementViewModel(runtime: runtime)
    let activeID = model.activeProfileID!
    model.setProfileName("当前已修改")
    model.setAutomaticEnabled(false)
    model.setPollingInterval(43)
    model.updateSelectedRule { $0.name = "当前规则草稿" }

    _ = try model.saveSelectedProfile()
    try equal(runtime.saveProfileCalls.last?.id, activeID, "Active save targeted another Profile")
    try equal(runtime.saveProfileCalls.last?.applyImmediately, true, "Active save did not use save-and-apply")
    try equal(runtime.status.activeProfile?.name, "当前已修改", "Active save did not publish saved Profile")
    try expect(!model.isDirty, "successful Active save left draft dirty")
}

runner.run("dirty transition guard supports save discard and cancel") {
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let model = ProfileManagementViewModel(runtime: runtime)
    let baselineName = model.draftProfile!.name
    model.setProfileName("取消保留")
    let cancelled = try model.prepareForExternalProfileActivation(resolve: { .cancel })
    try expect(!cancelled, "cancel permitted external activation")
    try equal(model.draftProfile?.name, "取消保留", "cancel discarded the draft")
    try expect(runtime.saveProfileCalls.isEmpty, "cancel saved the draft")

    let discarded = try model.prepareForExternalProfileActivation(resolve: { .discard })
    try expect(discarded, "discard did not permit transition")
    try equal(model.draftProfile?.name, baselineName, "discard did not restore baseline")
    model.setProfileName("保存通过")
    let saved = try model.prepareForExternalProfileActivation(resolve: { .save })
    try expect(saved, "save did not permit transition")
    try equal(runtime.status.activeProfile?.name, "保存通过", "guard save did not persist draft")
    try expect(!model.isDirty, "guard save left draft dirty")
}

runner.run("Profile lifecycle keeps new copy duplicate and delete inactive") {
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let model = ProfileManagementViewModel(runtime: runtime)
    let activeID = model.activeProfileID!
    let sourceRuleIDs = Set(model.draftProfile!.rules.map(\.id))

    let copy = try model.createProfileCopy(named: "当前副本")
    try equal(model.selectedProfileID, copy.id, "new copy was not selected for editing")
    try equal(model.activeProfileID, activeID, "new copy became Active")
    try expect(Set(copy.rules.map(\.id)).isDisjoint(with: sourceRuleIDs), "copied Profile reused Rule identities")
    try model.deleteSelectedProfile()
    try expect(runtime.profiles[copy.id] == nil, "inactive copy was not deleted")

    let blank = try model.createBlankProfile(named: "空白")
    try expect(!blank.automatic.isEnabled && !blank.polling.isEnabled && blank.rules.isEmpty, "new blank Profile was not blank and Automation-off")
    try equal(model.activeProfileID, activeID, "new blank Profile became Active")
    try model.deleteSelectedProfile()
    do {
        try model.deleteSelectedProfile()
        throw Failure(description: "Active Profile was deletable")
    } catch ConfigurationStoreError.cannotDeleteActiveProfile {}
}

runner.run("invalid Profiles require explicit restore or exact removal") {
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let restorableID = UUID()
    let restorable = DisplayProfile.blank(id: restorableID, name: "可恢复")
    let restorableError = InvalidDisplayProfile(fileName: "\(restorableID.uuidString.lowercased()).json", profileID: restorableID, profileName: "可恢复", errorDescription: "主文件损坏")
    let removalError = InvalidDisplayProfile(fileName: "broken-profile.json", profileID: nil, profileName: nil, errorDescription: "无法解码")
    runtime.lastGoodProfiles[restorableID] = restorable
    runtime.invalidProfiles = [restorableError, removalError]
    _ = runtime.reloadProfileCatalog()
    let model = ProfileManagementViewModel(runtime: runtime)

    _ = try model.restoreInvalidProfile(restorableError)
    try equal(runtime.profiles[restorableID], restorable, "last-good restore did not create canonical Profile")
    try expect(!runtime.status.profileCatalog.invalidProfiles.contains(where: { $0.fileName == restorableError.fileName }), "restored invalid row remained")
    try expect(runtime.status.profileCatalog.invalidProfiles.contains(where: { $0.fileName == removalError.fileName }), "restore silently removed another invalid row")
    _ = try model.removeInvalidProfile(removalError)
    try expect(runtime.status.profileCatalog.invalidProfiles.isEmpty, "exact invalid removal left requested row")
    try expect(runtime.activationCalls.isEmpty, "invalid restore/removal activated hardware")
}

runner.run("Profile catalog reload surfaces drift without silent apply") {
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let originalActiveID = runtime.status.activeProfile!.id
    let diskTarget = try runtime.createBlankProfile(named: "磁盘选择")
    runtime.simulatedExternalActiveProfileID = diskTarget.id
    let model = ProfileManagementViewModel(runtime: runtime)

    _ = try model.reloadProfileCatalog()
    try equal(runtime.reloadProfileCatalogCount, 1, "dedicated Profile reload seam was not used")
    try equal(runtime.status.activeProfile?.id, originalActiveID, "catalog reload silently changed Active Profile")
    try expect(runtime.activationCalls.isEmpty, "catalog reload applied hardware")
    try equal(model.externalActiveProfileID, diskTarget.id, "external Active drift was not surfaced")
    model.keepCurrentProfileAfterExternalDrift()
    try expect(!model.hasExternalActiveProfileDrift, "explicit keep-current decision stayed actionable")
    try equal(runtime.status.activeProfile?.id, originalActiveID, "keep-current changed Active Profile")

    _ = try model.reloadProfileCatalog()
    try equal(model.externalActiveProfileID, diskTarget.id, "next explicit reload did not resurface repeated same-ID drift")
    let preview = try model.previewExternalProfileReload()
    try equal(preview?.profile.id, diskTarget.id, "reload-and-apply did not preview disk target")
    guard let preview else { throw Failure(description: "external reload preview missing") }
    runtime.current.externalActiveProfileID = nil
    do {
        _ = try model.reloadAndApplyExternalProfile(confirmedPreview: preview)
        throw Failure(description: "vanished external drift activated")
    } catch AutomationCoordinatorError.staleProfileActivationPreview {}
    try equal(runtime.status.activeProfile?.id, originalActiveID, "stale external preview changed Active Profile")
    try expect(runtime.activationCalls.isEmpty, "stale external preview applied hardware")

    _ = try model.reloadProfileCatalog()
    guard let refreshedPreview = try model.previewExternalProfileReload() else {
        throw Failure(description: "refreshed external preview missing")
    }
    _ = try model.reloadAndApplyExternalProfile(confirmedPreview: refreshedPreview)
    try equal(runtime.status.activeProfile?.id, diskTarget.id, "explicit reload-and-apply did not update Active Profile")
    try equal(runtime.activationCalls.last, diskTarget.id, "reload-and-apply activated another Profile")
}

runner.run("activation confirmation classifies disable conflict cycle and safety") {
    let profile = DisplayProfile.blank(name: "确认")
    let key = EvaluatedDisplayKey(runtimeID: 1, stableIdentity: builtInIdentity, family: builtInFamily)
    func preview(plan: RuleEvaluationPlan, cycle: CycleAnalysisStatus = .converged) -> ProfileActivationPreview {
        ProfileActivationPreview(
            profile: profile,
            evaluation: plan,
            cycleAnalysis: CycleAnalysis(status: cycle, involvedRuleIDs: [], stateSequence: [], diagnostics: []),
            profileSource: .primary,
            primaryErrorDescription: nil,
            policyFingerprint: DisplayPolicySnapshotFingerprint(snapshot: .init(displays: []))
        )
    }
    let enable = RuleEvaluationPlan(matchedRuleIDs: [], winningActions: [.init(display: key, action: .enable, priority: 1, ruleIDs: [])], conflicts: [], unavailableTargets: [], safetyBlocks: [], diagnostics: [])
    try expect(!PresentationText.profileActivationConfirmation(preview(plan: enable)).requiresConfirmation, "ordinary enable activation required confirmation")
    try expect(!PresentationText.profileActivationConfirmation(preview(plan: .empty)).requiresConfirmation, "no-op activation required confirmation")

    var disable = enable
    disable.winningActions[0].action = .disable
    let disablePresentation = PresentationText.profileActivationConfirmation(preview(plan: disable))
    try expect(disablePresentation.requiresConfirmation && disablePresentation.isCritical, "winning disable was not critical-confirmed")
    var conflict = RuleEvaluationPlan.empty
    conflict.conflicts = [.init(display: key, priority: 1, ruleIDs: [], actions: [.enable, .disable])]
    try expect(PresentationText.profileActivationConfirmation(preview(plan: conflict)).requiresConfirmation, "conflict did not require confirmation")
    var safety = RuleEvaluationPlan.empty
    safety.safetyBlocks = [.init(reason: .retainedLastActiveDisplay, display: key, blockedRuleIDs: [])]
    try expect(PresentationText.profileActivationConfirmation(preview(plan: safety)).requiresConfirmation, "safety warning did not require confirmation")
    try expect(PresentationText.profileActivationConfirmation(preview(plan: .empty, cycle: .cycleDetected)).requiresConfirmation, "cycle warning did not require confirmation")
}

runner.run("activation result copy separates selection from hardware outcome") {
    let profile = DisplayProfile.blank(name: "旅行")
    let preview = ProfileActivationPreview(
        profile: profile,
        evaluation: .empty,
        cycleAnalysis: .init(status: .converged, involvedRuleIDs: [], stateSequence: [], diagnostics: []),
        profileSource: .primary,
        primaryErrorDescription: nil,
        policyFingerprint: DisplayPolicySnapshotFingerprint(snapshot: .init(displays: []))
    )
    func text(_ outcome: ProfileHardwareApplicationOutcome) -> String {
        PresentationText.profileActivationResult(.init(activeProfile: profile, preview: preview, hardwareOutcome: outcome, actionDiagnostics: []))
    }
    try expect(text(.applied).contains("已设为当前配置档") && text(.applied).contains("全部应用"), "applied copy did not separate selection and hardware")
    try expect(text(.partiallyFailed).contains("选择仍已保留") && text(.partiallyFailed).contains("部分"), "partial copy lost persisted selection truth")
    try expect(text(.failed).contains("选择仍已保留") && !text(.failed).contains("激活失败"), "failed hardware copy falsely reported activation failure")
    try expect(text(.blockedBySafety).contains("安全约束阻止") && text(.blockedBySafety).contains("选择仍已保留") && !text(.blockedBySafety).contains("激活失败"), "safety-blocked copy lost persisted selection truth")
}

runner.run("Settings exposes Profile hierarchy identifiers and cancel guard") {
    _ = NSApplication.shared
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let inactive = try runtime.createBlankProfile(named: "未激活")
    let settings = SettingsWindowController(
        runtime: runtime,
        shortcutProvider: { KeyShortcut(keyCode: 2, modifiers: 0x1A00) },
        shortcutSetter: { _ in true },
        shortcutResetter: { true },
        onLastActiveSafetyBlock: {},
        dirtyDraftResolutionProvider: { .cancel }
    )
    let content = settings.window!.contentView!
    let identifiers = Set(allSubviews(of: content).compactMap { $0.identifier?.rawValue })
    for identifier in ["settingsProfileSplit", "settingsProfileSidebar", "settingsProfileList", "profileNameField", "saveProfileButton", "saveAndActivateProfileButton", "reloadProfilesButton"] {
        try expect(identifiers.contains(identifier), "Settings hierarchy omitted \(identifier)")
    }
    let labels = allSubviews(of: content).compactMap { ($0 as? NSTextField)?.stringValue }
    try expect(labels.contains(where: { $0.contains("当前配置档") }), "Settings omitted visible Active indicator")
    try expect(labels.contains(where: { $0.contains("正在编辑") }), "Settings omitted visible selected indicator")
    let selectedInactive = try settings.profileViewModel.selectProfile(id: inactive.id)
    try expect(selectedInactive, "Settings could not select inactive Profile")
    settings.refresh()
    let inactiveButtons = allSubviews(of: content).compactMap { ($0 as? NSButton)?.title }
    try expect(inactiveButtons.contains("保存") && inactiveButtons.contains("保存并激活"), "inactive Profile actions omitted save or save-and-activate")
    try equal(runtime.status.activeProfile?.id == inactive.id, false, "Settings selection activated the inactive Profile")
    settings.profileViewModel.setProfileName("未保存")
    settings.refresh()
    try expect(!settings.prepareForExternalProfileActivation(), "controller cancel guard permitted external activation")
    try expect(settings.profileViewModel.isDirty, "controller cancel guard discarded draft")
    try expect(runtime.activationCalls.isEmpty, "controller guard activated hardware")
}

runner.run("Settings discard reacquires persisted Profile before delete confirmation") {
    _ = NSApplication.shared
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let inactive = try runtime.createBlankProfile(named: "持久化名称")
    let settings = SettingsWindowController(
        runtime: runtime,
        shortcutProvider: { KeyShortcut(keyCode: 2, modifiers: 0x1A00) },
        shortcutSetter: { _ in true },
        shortcutResetter: { true },
        onLastActiveSafetyBlock: {},
        dirtyDraftResolutionProvider: { .discard }
    )
    _ = try settings.profileViewModel.selectProfile(id: inactive.id)
    settings.refresh()
    settings.profileViewModel.setProfileName("仅草稿改名")
    settings.refresh()

    var confirmedName: String?
    let deleted = settings.deleteSelectedProfile { profile in
        confirmedName = profile.name
        return true
    }

    try expect(deleted, "discarded draft did not proceed to delete")
    try equal(confirmedName, "持久化名称", "delete confirmation used the discarded draft name")
    try expect(runtime.profiles[inactive.id] == nil, "delete did not target the reacquired persisted Profile")
    try expect(runtime.activationCalls.isEmpty, "delete flow activated hardware")
}

runner.run("invalid pending deletion copy is bounded and truthful") {
    let text = PresentationText.error(ConfigurationStoreError.deletionStateInvalid("corrupt pending state"))
    try expect(text.contains("无法安全继续") && text.contains("已停止删除"), "invalid deletion state copy did not explain the safe stop")
    try expect(!text.contains("已删除"), "invalid deletion state copy claimed deletion completed")
}

runner.run("application settings reload presentation distinguishes fallback unreadable and global drift") {
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let liveBefore = runtime.status.configuration

    runtime.current.externalApplicationSettings = nil
    runtime.current.externalSettingsGenerationSource = .lastKnownGoodBackup
    runtime.current.externalSettingsErrorDescription = "primary invalid"
    let fallback = PresentationText.applicationSettingsReloadNotices(status: runtime.status)
    try equal(fallback.count, 1, "matching settings fallback was not surfaced")
    try equal(fallback[0].severity, .warning, "settings fallback used wrong severity")
    try expect(!fallback[0].blocksProfileReloadApply, "matching settings fallback unnecessarily blocked Profile reload")
    try expect(fallback[0].explanation.contains("当前运行设置保持不变"), "fallback copy claimed disk settings were applied")

    runtime.current.externalSettingsGenerationSource = nil
    runtime.current.externalSettingsErrorDescription = "both generations unreadable"
    let unreadable = PresentationText.applicationSettingsReloadNotices(status: runtime.status)
    try equal(unreadable.count, 1, "unreadable settings error was not surfaced")
    try equal(unreadable[0].severity, .critical, "unreadable settings was not critical")
    try expect(unreadable[0].blocksProfileReloadApply, "unreadable settings allowed disk Profile apply")
    try expect(unreadable[0].explanation.contains("没有注册磁盘中的快捷键"), "unreadable settings copy implied external hotkey registration")

    var external = runtime.status.configuration.applicationSettings(activeProfileID: runtime.status.activeProfile!.id)
    external.hotKey = HotKeyConfiguration(keyCode: 12, modifiers: 0x100)
    let extraIdentity = StableDisplayIdentity(family: DisplayFamily(vendorID: 300, modelID: 30), serialNumber: 3)
    external.deviceHistory.append(KnownDisplay(target: .exact(extraIdentity), name: "Disk Display", isBuiltIn: false, alias: "磁盘别名"))
    runtime.current.externalApplicationSettings = external
    runtime.current.externalSettingsGenerationSource = .primary
    runtime.current.externalSettingsErrorDescription = nil
    let drift = PresentationText.applicationSettingsReloadNotices(status: runtime.status)
    guard let globalDrift = drift.first(where: { $0.blocksProfileReloadApply }) else {
        throw Failure(description: "global application settings drift was not surfaced")
    }
    try expect(globalDrift.explanation.contains("全局快捷键") && globalDrift.explanation.contains("显示器历史与别名"), "global drift copy omitted changed fields")
    try expect(globalDrift.explanation.contains("当前运行值保持不变") && globalDrift.explanation.contains("重启应用"), "global drift copy omitted current-state and restart guidance")
    try equal(runtime.status.configuration, liveBefore, "presentation seam applied external application settings")
}

runner.run("Settings visibly retains explicit application settings reload warnings") {
    _ = NSApplication.shared
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let liveBefore = runtime.status.configuration
    var shortcutSetCount = 0
    let settings = SettingsWindowController(
        runtime: runtime,
        shortcutProvider: { KeyShortcut(keyCode: 2, modifiers: 0x1A00) },
        shortcutSetter: { _ in shortcutSetCount += 1; return true },
        shortcutResetter: { true },
        onLastActiveSafetyBlock: {}
    )

    runtime.simulatedExternalSettingsGenerationSource = .lastKnownGoodBackup
    runtime.simulatedExternalSettingsErrorDescription = "primary invalid"
    _ = try settings.profileViewModel.reloadProfileCatalog()
    settings.refresh()
    guard let notice = allSubviews(of: settings.window!.contentView!).compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "profileReloadNotice" }) else {
        throw Failure(description: "Settings reload notice seam missing")
    }
    try expect(!notice.isHidden && notice.stringValue.contains("上次可用版本"), "Settings hid same-Profile settings fallback")

    runtime.simulatedExternalSettingsGenerationSource = nil
    runtime.simulatedExternalSettingsErrorDescription = "both generations unreadable"
    _ = try settings.profileViewModel.reloadProfileCatalog()
    settings.refresh()
    try expect(!notice.isHidden && notice.stringValue.contains("无法读取磁盘应用设置"), "Settings hid unreadable application settings")

    var external = runtime.status.configuration.applicationSettings(activeProfileID: runtime.status.activeProfile!.id)
    external.hotKey = HotKeyConfiguration(keyCode: 44, modifiers: 0x200)
    runtime.simulatedExternalApplicationSettings = external
    runtime.simulatedExternalSettingsGenerationSource = .primary
    runtime.simulatedExternalSettingsErrorDescription = nil
    _ = try settings.profileViewModel.reloadProfileCatalog()
    settings.refresh()
    try expect(!notice.isHidden && notice.stringValue.contains("当前运行值不同"), "Settings hid global application settings drift")
    try equal(runtime.status.configuration, liveBefore, "Settings reload applied external global settings")
    try equal(shortcutSetCount, 0, "Settings reload registered the external hotkey")
    try expect(runtime.activationCalls.isEmpty, "Settings reload warning applied Profile hardware")
}

runner.finish()
    }
}
