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
    var updateCount = 0
    var manualCalls: [(UInt32, DisplayAction)] = []
    var lastApplyImmediately: Bool?
    var restoreCalls: [DisplayRecoveryPlan] = []

    init(configuration: AppConfiguration = baseConfiguration(), displays: [ObservedDisplay]) {
        current = AutomationRuntimeStatus(
            configuration: configuration,
            inventory: ObservedDisplaySnapshot(displays: displays),
            lastEvaluation: .empty,
            lastCycleAnalysis: nil,
            lastTrigger: nil,
            pauseReason: nil,
            diagnostics: [],
            configurationLoadSource: .primary
        )
    }

    var status: AutomationRuntimeStatus { current }

    func previewConfigurationReadOnly(
        _ configuration: AppConfiguration,
        observation: ObservedDisplaySnapshot?
    ) throws -> ConfigurationPreview {
        previewCount += 1
        previewObservations.append(observation)
        try configuration.validate()
        let snapshot = observation ?? current.inventory
        return ConfigurationPreview(
            evaluation: RuleEvaluator().evaluate(configuration: configuration, snapshot: snapshot),
            cycleAnalysis: RuleCycleAnalyzer().analyze(configuration: configuration, initialSnapshot: snapshot)
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
    let model = RulesEditorViewModel(runtime: runtime)
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
    let model = RulesEditorViewModel(runtime: runtime)
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
    let model = RulesEditorViewModel(runtime: runtime)
    model.deleteSelectedRule()
    _ = try model.saveAndApply()
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

runner.run("controllers expose concise hierarchy without fixed builtin buttons") {
    _ = NSApplication.shared
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let main = MainWindowController(runtime: runtime, shortcutProvider: { KeyShortcut(keyCode: 2, modifiers: 0x1A00) }, shortcutSetter: { _ in true }, shortcutResetter: { true }, onOpenManagement: {})
    guard let content = main.window?.contentView else { throw Failure(description: "main content missing") }
    let buttonTitles = allSubviews(of: content).compactMap { ($0 as? NSButton)?.title }
    try expect(buttonTitles.contains("管理自动规则与显示器…"), "management entry missing")
    try expect(buttonTitles.contains("启用自动规则"), "automatic master missing")
    try expect(!buttonTitles.contains("关闭内置显示器") && !buttonTitles.contains("恢复内置显示器"), "fixed built-in buttons survived")
    let management = ManagementWindowController(runtime: runtime, onLastActiveSafetyBlock: {})
    guard let managementContent = management.window?.contentView else { throw Failure(description: "management content missing") }
    let navigation = allSubviews(of: managementContent).compactMap { $0 as? NSSegmentedControl }.first
    try equal(navigation?.label(forSegment: 0), "自动规则", "rules navigation missing")
    try equal(navigation?.label(forSegment: 1), "显示器", "displays navigation missing")
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
    let model = RulesEditorViewModel(runtime: runtime)
    model.updateSelectedRule { $0.name = "规则草稿" }
    runtime.current.configuration.polling.intervalSeconds = 73
    runtime.current.configuration.hotKey = HotKeyConfiguration(keyCode: 12, modifiers: 0x100)
    runtime.current.configuration.deviceHistory[0].alias = "运行时新别名"
    _ = try model.saveAndApply()
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
    let model = RulesEditorViewModel(runtime: runtime)
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
    let options = RulesEditorViewModel(runtime: runtime).targetOptions().map(\.target)
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
    try equal(PresentationText.overview(status: runtime.status).recoveryCount, 1, "overview omitted recovery count")
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

runner.run("controllers expose aggregate recovery controls without requiring a target") {
    _ = NSApplication.shared
    let runtime = FakeRuntime(displays: [display(1, builtInIdentity, builtIn: true, main: true, state: .active, name: "Built-in")])
    let main = MainWindowController(runtime: runtime, shortcutProvider: { KeyShortcut(keyCode: 2, modifiers: 0x1A00) }, shortcutSetter: { _ in true }, shortcutResetter: { true }, onOpenManagement: {})
    let mainButtons = allSubviews(of: main.window!.contentView!).compactMap { ($0 as? NSButton)?.title }
    try expect(mainButtons.contains(PresentationText.restoreAllTitle), "overview recovery control missing")

    let management = ManagementWindowController(runtime: runtime, onLastActiveSafetyBlock: {})
    let displayButtons = allSubviews(of: management.displaysController.view).compactMap { ($0 as? NSButton)?.title }
    try expect(displayButtons.contains(PresentationText.restoreAllTitle), "displays recovery control missing")
}

runner.finish()
    }
}
