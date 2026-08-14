import Foundation

private struct Failure: Error, CustomStringConvertible { let description: String }

private struct Runner {
    private(set) var count = 0
    private(set) var failures: [String] = []

    mutating func run(_ name: String, _ body: () throws -> Void) {
        count += 1
        do {
            try body()
            print("PASS: \(name)")
        } catch {
            failures.append("\(name): \(error)")
            print("FAIL: \(name): \(error)")
        }
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("Phase 4 integration: \(count)/\(count) passed")
            exit(0)
        }
        print("Phase 4 integration: \(count - failures.count)/\(count) passed")
        exit(1)
    }
}

private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(description: message) }
}

private func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw Failure(description: "\(message): expected \(expected), got \(actual)")
    }
}

private let builtInFamily = DisplayFamily(vendorID: 100, modelID: 10)
private let externalFamily = DisplayFamily(vendorID: 200, modelID: 20)
private let builtInIdentity = StableDisplayIdentity(family: builtInFamily, serialNumber: 1)
private let externalIdentity = StableDisplayIdentity(family: externalFamily, serialNumber: 2)

private func display(
    runtimeID: UInt32,
    identity: StableDisplayIdentity,
    builtIn: Bool,
    main: Bool = false,
    state: ObservableDisplayState = .active,
    name: String
) -> ObservedDisplay {
    ObservedDisplay(
        runtimeID: runtimeID,
        stableIdentity: identity,
        family: identity.family,
        name: name,
        isBuiltIn: builtIn,
        isMain: main,
        state: state
    )
}

private func stableConfiguration(automatic: Bool = false) -> AppConfiguration {
    var configuration = AppConfiguration.default
    configuration.automatic = AutomaticConfiguration(
        isEnabled: automatic,
        startupStabilizationSeconds: 0,
        wakeStabilizationSeconds: 0
    )
    configuration.polling = PollingConfiguration(isEnabled: false, intervalSeconds: 3)
    configuration.deviceHistory = [
        KnownDisplay(target: .exact(builtInIdentity), name: "Built-in", isBuiltIn: true),
        KnownDisplay(target: .exact(externalIdentity), name: "External", isBuiltIn: false)
    ]
    configuration.rules = [DisplayRule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
        name: "集成规则",
        isEnabled: true,
        priority: 100,
        conditions: [.always],
        actions: [TargetAction(target: .exact(builtInIdentity), action: .noAction)]
    )]
    return configuration
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("display-steward-phase4-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private final class ScheduledTask: AutomationScheduledTask {
    var deadline: Date
    let interval: TimeInterval?
    let action: () -> Void
    var cancelled = false

    init(deadline: Date, interval: TimeInterval?, action: @escaping () -> Void) {
        self.deadline = deadline
        self.interval = interval
        self.action = action
    }

    func cancel() { cancelled = true }
}

private final class TestScheduler: AutomationScheduling {
    var now = Date(timeIntervalSince1970: 1_000)
    private var tasks: [ScheduledTask] = []

    func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval?,
        _ action: @escaping () -> Void
    ) -> AutomationScheduledTask {
        let task = ScheduledTask(
            deadline: now.addingTimeInterval(max(0, delay)),
            interval: interval,
            action: action
        )
        tasks.append(task)
        return task
    }

    func advance(_ seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let task = tasks
            .filter({ !$0.cancelled && $0.deadline <= end })
            .sorted(by: { $0.deadline < $1.deadline })
            .first {
            now = task.deadline
            if let interval = task.interval {
                task.deadline = task.deadline.addingTimeInterval(interval)
            } else {
                task.cancelled = true
            }
            task.action()
        }
        now = end
    }
}

private final class IntegrationAdapter: DisplayRuntimeAdapting {
    private var templates: [UInt32: ObservedDisplay]
    private var liveStates: [UInt32: ObservableDisplayState]
    private(set) var observeCount = 0
    private(set) var transactions: [[DisplayActionRequest]] = []

    init(displays: [ObservedDisplay]) {
        templates = Dictionary(uniqueKeysWithValues: displays.compactMap { item in
            item.runtimeID.map { ($0, item) }
        })
        liveStates = Dictionary(uniqueKeysWithValues: displays.compactMap { item in
            guard let runtimeID = item.runtimeID, item.state.isOnline else { return nil }
            return (runtimeID, item.state)
        })
    }

    func observe(
        configuration: AppConfiguration,
        runtimeState: RuntimeState
    ) throws -> ObservedDisplaySnapshot {
        observeCount += 1
        var displays = liveStates.keys.sorted().compactMap { runtimeID -> ObservedDisplay? in
            guard var item = templates[runtimeID], let state = liveStates[runtimeID] else { return nil }
            item.state = state
            item.isMain = item.isMain && state.isActive
            return item
        }
        let recovery = runtimeState.appDisabledDisplays
            + runtimeState.pendingDisableDisplays.map(\.disabledRecord)
            + runtimeState.pendingRecoveryDisplays
        for record in recovery where liveStates[record.runtimeID] == nil {
            var item = templates[record.runtimeID] ?? ObservedDisplay(
                runtimeID: record.runtimeID,
                stableIdentity: record.stableIdentity,
                family: record.family,
                name: nil,
                isBuiltIn: false,
                isMain: false,
                state: .disabledByThisAppConnectionUnknown
            )
            item.state = .disabledByThisAppConnectionUnknown
            item.isMain = false
            displays.append(item)
        }
        return ObservedDisplaySnapshot(displays: displays)
    }

    func apply(
        requests: [DisplayActionRequest],
        expectedFingerprint: DisplayPolicySnapshotFingerprint,
        configuration: AppConfiguration,
        runtimeState: RuntimeState,
        didCommit: () throws -> Void
    ) throws -> DisplayTransactionOutcome {
        let before = try observe(configuration: configuration, runtimeState: runtimeState)
        guard DisplayPolicySnapshotFingerprint(snapshot: before) == expectedFingerprint else {
            return DisplayTransactionOutcome(
                before: before,
                after: before,
                results: requests.map {
                    DisplayActionResult(
                        request: $0,
                        succeeded: false,
                        wasIdempotent: false,
                        errorDescription: "snapshot changed"
                    )
                },
                transactionWasCommitted: false,
                requiresReevaluation: true
            )
        }

        transactions.append(requests)
        var changed = false
        let results = requests.map { request -> DisplayActionResult in
            switch request.action {
            case .noAction:
                return DisplayActionResult(
                    request: request,
                    succeeded: false,
                    wasIdempotent: false,
                    errorDescription: "no action is not transactional"
                )
            case .disable:
                if liveStates.removeValue(forKey: request.display.runtimeID) != nil {
                    changed = true
                    return DisplayActionResult(
                        request: request,
                        succeeded: true,
                        wasIdempotent: false,
                        errorDescription: nil
                    )
                }
                return DisplayActionResult(
                    request: request,
                    succeeded: true,
                    wasIdempotent: true,
                    errorDescription: nil
                )
            case .enable:
                if liveStates[request.display.runtimeID] != nil {
                    return DisplayActionResult(
                        request: request,
                        succeeded: true,
                        wasIdempotent: true,
                        errorDescription: nil
                    )
                }
                liveStates[request.display.runtimeID] = .active
                changed = true
                return DisplayActionResult(
                    request: request,
                    succeeded: true,
                    wasIdempotent: false,
                    errorDescription: nil
                )
            }
        }
        if changed { try didCommit() }
        let after = try observe(configuration: configuration, runtimeState: runtimeState)
        return DisplayTransactionOutcome(
            before: before,
            after: after,
            results: results,
            transactionWasCommitted: changed
        )
    }
}

private func coordinator(
    root: URL,
    defaults: UserDefaults? = nil,
    boot: String = "boot",
    adapter: IntegrationAdapter,
    scheduler: TestScheduler = TestScheduler(),
    log: @escaping (String) -> Void = { _ in }
) throws -> AutomationCoordinator {
    try AutomationCoordinator(
        configurationStore: ConfigurationStore(rootURL: root, legacyDefaults: defaults),
        runtimeStateStore: RuntimeStateStore(
            rootURL: root,
            legacyDefaults: defaults,
            bootIdentifierProvider: { boot }
        ),
        adapter: adapter,
        scheduler: scheduler,
        debounceSeconds: 0,
        maximumActionAttempts: 1,
        log: log
    )
}

@main
private enum Phase4IntegrationTests {
    static func main() {
        var runner = Runner()

        runner.run("legacy defaults import once into the injected JSON root") {
            try withTemporaryDirectory { root in
                let suite = "display-steward-phase4-\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: suite) else {
                    throw Failure(description: "could not create isolated defaults")
                }
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.set(false, forKey: "automaticDisplayPolicy")
                defaults.set(false, forKey: "pollingEnabled")
                defaults.set(19.5, forKey: "pollingInterval")
                defaults.set(7, forKey: "hotKeyKeyCode")
                defaults.set(0x1200, forKey: "hotKeyModifiers")
                defaults.set(Int(builtInFamily.vendorID), forKey: "lastBuiltinVendor")
                defaults.set(Int(builtInFamily.modelID), forKey: "lastBuiltinModel")
                defaults.set(Int(builtInIdentity.serialNumber), forKey: "lastBuiltinSerial")
                defaults.set(999_999, forKey: "lastBuiltinDisplayID")

                let first = try coordinator(
                    root: root,
                    defaults: defaults,
                    adapter: IntegrationAdapter(displays: [])
                )
                let migrated = first.status.configuration
                try equal(first.status.configurationLoadSource, .migratedLegacyDefaults, "first load source")
                try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path), "config.json missing")
                try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.last-good.json").path), "config.last-good.json missing")
                try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime-state.json").path), "runtime-state.json missing")
                try equal(migrated.automatic.isEnabled, false, "automatic preference not imported")
                try equal(migrated.polling, PollingConfiguration(isEnabled: false, intervalSeconds: 19.5), "polling preferences not imported")
                try equal(migrated.hotKey, HotKeyConfiguration(keyCode: 7, modifiers: 0x1200), "hotkey not imported")
                try equal(migrated.deviceHistory.first?.target, .exact(builtInIdentity), "built-in identity not imported")
                let importedRuntime = try JSONDecoder().decode(
                    RuntimeState.self,
                    from: Data(contentsOf: root.appendingPathComponent("runtime-state.json"))
                )
                try equal(importedRuntime.legacyBuiltInRecovery?.stableIdentity, builtInIdentity, "built-in recovery identity not imported")
                try equal(importedRuntime.legacyBuiltInRecovery?.runtimeID, nil, "legacy runtime ID was trusted")
                try equal(migrated.rules.map(\.name), ["检测到外接显示器", "未检测到外接显示器"], "Chinese default rules changed")
                try equal(migrated.rules.map { $0.actions.first?.action }, [.disable, .enable], "default rule actions changed")
                try expect(migrated.rules.allSatisfy { $0.actions.first?.target == .exact(builtInIdentity) }, "default rules lost migrated target")

                defaults.set(true, forKey: "automaticDisplayPolicy")
                defaults.set(2, forKey: "pollingInterval")
                defaults.set(44, forKey: "hotKeyKeyCode")
                defaults.set(999, forKey: "lastBuiltinVendor")
                defaults.set(888, forKey: "lastBuiltinModel")
                defaults.set(777, forKey: "lastBuiltinSerial")
                try FileManager.default.removeItem(at: root.appendingPathComponent("runtime-state.json"))

                let second = try coordinator(
                    root: root,
                    defaults: defaults,
                    adapter: IntegrationAdapter(displays: [])
                )
                try equal(second.status.configurationLoadSource, .primary, "subsequent launch did not use JSON")
                try equal(second.status.configuration, migrated, "changed legacy defaults affected JSON configuration")
                try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime-state.json").path), "subsequent launch re-imported legacy runtime identity")
            }
        }

        runner.run("former Screen Manager config directory migrates once") {
            try withTemporaryDirectory { parent in
                let legacyRoot = parent.appendingPathComponent("screen-manager", isDirectory: true)
                let newRoot = parent.appendingPathComponent("display-steward", isDirectory: true)
                let expected = stableConfiguration(automatic: false)
                try ConfigurationStore(rootURL: legacyRoot, legacyDefaults: nil).save(expected)

                let migrated = try ConfigurationStore(
                    rootURL: newRoot,
                    legacyRootURL: legacyRoot,
                    legacyDefaults: nil
                ).loadOrMigrate()

                try equal(migrated.source, .primary, "moved configuration did not load as primary")
                try equal(migrated.configuration, expected, "moved configuration changed")
                try expect(FileManager.default.fileExists(atPath: newRoot.appendingPathComponent("config.json").path), "new Display Steward config is missing")
                try expect(!FileManager.default.fileExists(atPath: legacyRoot.path), "former config directory was not moved")
            }
        }

        runner.run("an intentional empty rule list survives launch without hidden policy") {
            try withTemporaryDirectory { root in
                var configuration = stableConfiguration(automatic: true)
                configuration.rules = []
                try ConfigurationStore(rootURL: root, legacyDefaults: nil).save(configuration)
                let scheduler = TestScheduler()
                let adapter = IntegrationAdapter(displays: [
                    display(runtimeID: 1, identity: builtInIdentity, builtIn: true, main: true, name: "Built-in"),
                    display(runtimeID: 2, identity: externalIdentity, builtIn: false, name: "External")
                ])
                var logs: [String] = []
                let runtime = try coordinator(
                    root: root,
                    adapter: adapter,
                    scheduler: scheduler,
                    log: { logs.append($0) }
                )
                runtime.start()
                scheduler.advance(0)
                try expect(runtime.status.configuration.rules.isEmpty, "empty rules were repopulated")
                try expect(adapter.transactions.isEmpty, "hidden automatic policy performed an action")
                guard let evaluationLog = logs.first(where: { $0.contains("evaluation trigger=startup") }) else {
                    throw Failure(description: "no-op evaluation summary was not logged")
                }
                try expect(evaluationLog.contains("online=2 active=2"), "evaluation log omitted snapshot counts")
                try expect(evaluationLog.contains("matched=[] winning=[] conflicts=[] safety=[]"), "no-op evaluation log omitted plan fields")
                let persisted = try ConfigurationStore(rootURL: root, legacyDefaults: nil).load().configuration
                try expect(persisted.rules.isEmpty, "empty rules were not persisted")
            }
        }

        runner.run("corrupt generations fall back or disable automation without overwrite") {
            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                let valid = stableConfiguration(automatic: true)
                try store.save(valid)
                let badPrimary = Data("corrupt-primary".utf8)
                try badPrimary.write(to: store.configurationURL)

                let fallback = try coordinator(root: root, adapter: IntegrationAdapter(displays: []))
                try equal(fallback.status.configurationLoadSource, .lastKnownGoodBackup, "valid backup was not selected")
                try equal(fallback.status.configuration, valid, "fallback changed the last-good generation")
                try expect(fallback.status.diagnostics.contains { $0.code == .configurationFallback }, "fallback diagnostic missing")
                try equal(try Data(contentsOf: store.configurationURL), badPrimary, "fallback overwrote corrupt primary")

                let badBackup = Data("corrupt-backup".utf8)
                try badBackup.write(to: store.backupURL)
                let primaryBefore = try Data(contentsOf: store.configurationURL)
                let backupBefore = try Data(contentsOf: store.backupURL)
                let unavailable = try coordinator(root: root, adapter: IntegrationAdapter(displays: []))
                try expect(!unavailable.status.configuration.automatic.isEnabled, "automation stayed enabled with no valid generation")
                try equal(unavailable.status.configurationLoadSource, nil, "corrupt generations reported a writable source")
                try expect(unavailable.status.diagnostics.contains { $0.code == .configurationUnavailable }, "unavailable diagnostic missing")
                try equal(try Data(contentsOf: store.configurationURL), primaryBefore, "unavailable load overwrote primary")
                try equal(try Data(contentsOf: store.backupURL), backupBefore, "unavailable load overwrote backup")
            }
        }

        runner.run("boot downgrade clears stale handles and retains same-boot committed recovery") {
            try withTemporaryDirectory { root in
                try ConfigurationStore(rootURL: root, legacyDefaults: nil).save(stableConfiguration())
                let oldStore = RuntimeStateStore(
                    rootURL: root,
                    legacyDefaults: nil,
                    bootIdentifierProvider: { "old-boot" }
                )
                var old = RuntimeState.empty(bootIdentifier: "old-boot")
                old.appDisabledDisplays = [AppDisabledDisplayRecord(
                    runtimeID: 99,
                    stableIdentity: builtInIdentity,
                    family: builtInFamily
                )]
                try oldStore.save(old)

                let downgraded = try coordinator(
                    root: root,
                    boot: "new-boot",
                    adapter: IntegrationAdapter(displays: [])
                )
                try expect(downgraded.status.diagnostics.contains { $0.code == .staleBootStateDiscarded }, "stale boot downgrade was not reported")
                let newStore = RuntimeStateStore(
                    rootURL: root,
                    legacyDefaults: nil,
                    bootIdentifierProvider: { "new-boot" }
                )
                try equal(try newStore.load().state, .empty(bootIdentifier: "new-boot"), "stale boot handles survived")
            }

            try withTemporaryDirectory { root in
                try ConfigurationStore(rootURL: root, legacyDefaults: nil).save(stableConfiguration())
                let stateStore = RuntimeStateStore(
                    rootURL: root,
                    legacyDefaults: nil,
                    bootIdentifierProvider: { "same-boot" }
                )
                var state = RuntimeState.empty(bootIdentifier: "same-boot")
                state.pendingDisableDisplays = [PendingDisableRecord(
                    runtimeID: 1,
                    stableIdentity: builtInIdentity,
                    family: builtInFamily,
                    phase: .committedUncertain
                )]
                try stateStore.save(state)
                let adapter = IntegrationAdapter(displays: [
                    display(runtimeID: 1, identity: builtInIdentity, builtIn: true, main: true, name: "Built-in"),
                    display(runtimeID: 2, identity: externalIdentity, builtIn: false, name: "External")
                ])
                let runtime = try coordinator(root: root, boot: "same-boot", adapter: adapter)
                _ = try runtime.refresh()
                let retained = try stateStore.load().state.pendingDisableDisplays
                try equal(retained.count, 1, "committed-uncertain recovery was discarded after one online observation")
                try equal(retained.first?.phase, .committedUncertain, "committed recovery phase was downgraded")
            }
        }

        runner.run("read-only preview performs no config runtime or adapter writes") {
            try withTemporaryDirectory { root in
                let configurationStore = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                var configuration = stableConfiguration(automatic: true)
                configuration.rules[0].actions[0].action = .disable
                try configurationStore.save(configuration)
                let stateStore = RuntimeStateStore(
                    rootURL: root,
                    legacyDefaults: nil,
                    bootIdentifierProvider: { "boot" }
                )
                try stateStore.save(.empty(bootIdentifier: "boot"))
                let primaryBefore = try Data(contentsOf: configurationStore.configurationURL)
                let backupBefore = try Data(contentsOf: configurationStore.backupURL)
                let runtimeBefore = try Data(contentsOf: stateStore.runtimeStateURL)
                let adapter = IntegrationAdapter(displays: [])
                let runtime = try coordinator(root: root, adapter: adapter)
                let observation = ObservedDisplaySnapshot(displays: [
                    display(runtimeID: 1, identity: builtInIdentity, builtIn: true, main: true, name: "Built-in"),
                    display(runtimeID: 2, identity: externalIdentity, builtIn: false, name: "External")
                ])

                let preview = try runtime.previewConfigurationReadOnly(configuration, observation: observation)
                try expect(!preview.evaluation.matchedRuleIDs.isEmpty, "preview ignored injected observation")
                try equal(adapter.observeCount, 0, "preview observed the runtime adapter")
                try expect(adapter.transactions.isEmpty, "preview applied a display transaction")
                try equal(try Data(contentsOf: configurationStore.configurationURL), primaryBefore, "preview wrote config.json")
                try equal(try Data(contentsOf: configurationStore.backupURL), backupBefore, "preview wrote config.last-good.json")
                try equal(try Data(contentsOf: stateStore.runtimeStateURL), runtimeBefore, "preview wrote runtime-state.json")
            }
        }

        runner.run("overview displays rules and menu presentation share current configuration") {
            try withTemporaryDirectory { root in
                let configurationStore = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try configurationStore.save(stableConfiguration())
                let adapter = IntegrationAdapter(displays: [
                    display(runtimeID: 1, identity: builtInIdentity, builtIn: true, main: true, name: "Built-in"),
                    display(runtimeID: 2, identity: externalIdentity, builtIn: false, name: "External")
                ])
                let runtime = try coordinator(root: root, adapter: adapter)
                _ = try runtime.refresh()

                let rules = RulesEditorViewModel(runtime: runtime)
                rules.updateSelectedRule { $0.name = "规则页面更新" }
                let overview = OverviewViewModel(runtime: runtime)
                _ = try overview.setPollingInterval(41)
                let displays = DisplaysViewModel(runtime: runtime)
                guard let externalRow = displays.rows.first(where: { $0.runtimeID == 2 }) else {
                    throw Failure(description: "external display row missing")
                }
                _ = try displays.setAlias("演示屏", for: externalRow.id)
                _ = try rules.saveAndApply()
                _ = try overview.setAutomaticEnabled(true)

                let status = runtime.status
                try equal(status.configuration.polling.intervalSeconds, 41, "rule save overwrote overview polling update")
                try equal(status.configuration.deviceHistory.first(where: { $0.target == .exact(externalIdentity) })?.alias, "演示屏", "rule save overwrote display alias")
                try equal(status.configuration.rules.first?.name, "规则页面更新", "later status update overwrote rule draft")
                try expect(status.configuration.automatic.isEnabled, "overview automatic update was lost")
                let menu = PresentationText.menu(status: status)
                try expect(menu.automaticEnabled, "menu presentation saw a different configuration")
                try equal(menu.displays.first(where: { $0.runtimeID == 2 })?.title, "演示屏", "menu presentation missed display update")
                let persisted = try configurationStore.load().configuration
                try equal(persisted, status.configuration, "status and JSON diverged")
            }
        }

        runner.run("one coordinator publishes one automatic transaction to every presentation seam") {
            try withTemporaryDirectory { root in
                var configuration = stableConfiguration(automatic: true)
                configuration.rules = LegacyConfigurationMigrator.defaultExternalRules(target: .exact(builtInIdentity))
                try ConfigurationStore(rootURL: root, legacyDefaults: nil).save(configuration)
                let scheduler = TestScheduler()
                let adapter = IntegrationAdapter(displays: [
                    display(runtimeID: 1, identity: builtInIdentity, builtIn: true, main: true, name: "Built-in"),
                    display(runtimeID: 2, identity: externalIdentity, builtIn: false, name: "External")
                ])
                var logs: [String] = []
                let runtime = try coordinator(
                    root: root,
                    adapter: adapter,
                    scheduler: scheduler,
                    log: { logs.append($0) }
                )
                var publications = 0
                runtime.onStatusChange = { publications += 1 }
                runtime.start()
                scheduler.advance(0)

                try equal(adapter.transactions.count, 1, "automatic rule used duplicate coordinator paths")
                try equal(adapter.transactions.first?.map(\.action), [.disable], "automatic path applied an unexpected batch")
                try expect(publications > 0, "coordinator did not publish status")
                try expect(logs.contains { $0.contains("evaluation trigger=startup") && $0.contains("winning=[1:disable]") }, "automatic evaluation summary omitted winning action")
                try expect(logs.contains { $0.contains("transaction attempt=1/1") && $0.contains("committed=true") && $0.contains("success=[1:disable]") && $0.contains("failure=[]") && $0.contains("afterActive=1") }, "transaction outcome summary omitted commit, result, or postcondition")
                let status = runtime.status
                try equal(status.inventory.displays.first(where: { $0.runtimeID == 1 })?.state, .disabledByThisAppConnectionUnknown, "status did not expose automatic result")
                try equal(OverviewViewModel(runtime: runtime).presentation.automaticEnabled, true, "overview was not bound to coordinator status")
                try equal(DisplaysViewModel(runtime: runtime).rows.first(where: { $0.runtimeID == 1 })?.state, .disabledByThisAppConnectionUnknown, "display UI was not bound to coordinator status")
                try equal(PresentationText.menu(status: status).displays.first(where: { $0.runtimeID == 1 })?.state, .disabledByThisAppConnectionUnknown, "menu was not bound to coordinator status")
            }
        }

        runner.run("legacy one-shot flags still select the locked menu-bar entry") {
            let ordinary = ApplicationEntryPolicy.decision(arguments: ["DisplaySteward"])
            let formerEnable = ApplicationEntryPolicy.decision(arguments: ["DisplaySteward", "--enable-once"])
            let formerDisable = ApplicationEntryPolicy.decision(arguments: ["DisplaySteward", "--disable-once"])
            try equal(ordinary.mode, .menuBarApplication, "ordinary launch mode changed")
            try equal(formerEnable, ordinary, "obsolete enable flag selected a display-operation entry")
            try equal(formerDisable, ordinary, "obsolete disable flag selected a display-operation entry")
            try expect(ordinary.requiresSingleInstanceLockBeforeRuntime, "entry policy permits runtime construction before lock")
        }

        runner.finish()
    }
}
