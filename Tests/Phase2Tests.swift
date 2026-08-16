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
        if failures.isEmpty { print("Passed \(count) Phase 2 tests"); exit(0) }
        exit(1)
    }
}

private let builtInFamily = DisplayFamily(vendorID: 100, modelID: 10)
private let externalFamily = DisplayFamily(vendorID: 200, modelID: 20)
private let absentFamily = DisplayFamily(vendorID: 300, modelID: 30)
private let builtIn = StableDisplayIdentity(family: builtInFamily, serialNumber: 1)
private let external1 = StableDisplayIdentity(family: externalFamily, serialNumber: 11)
private let external2 = StableDisplayIdentity(family: externalFamily, serialNumber: 12)
private let absent = StableDisplayIdentity(family: absentFamily, serialNumber: 21)

private func display(
    _ id: UInt32?, _ identity: StableDisplayIdentity?, _ family: DisplayFamily,
    builtIn isBuiltIn: Bool = false, main: Bool = false,
    state: ObservableDisplayState = .active, mirror: UInt32? = nil
) -> ObservedDisplay {
    ObservedDisplay(
        runtimeID: id, stableIdentity: identity, family: family,
        name: isBuiltIn ? "Built-in" : "External", isBuiltIn: isBuiltIn,
        isMain: main, state: state, mirrorsRuntimeID: mirror
    )
}

private func makeRule(
    _ name: String, conditions: [RuleCondition] = [.always],
    actions: [TargetAction]
) -> DisplayRule {
    DisplayRule(id: UUID(), name: name, isEnabled: true, priority: 100, conditions: conditions, actions: actions)
}

private func config(
    _ rules: [DisplayRule], automatic: Bool = true, stabilization: TimeInterval = 0
) -> AppConfiguration {
    var value = AppConfiguration.default
    value.automatic = .init(
        isEnabled: automatic,
        startupStabilizationSeconds: stabilization,
        wakeStabilizationSeconds: stabilization
    )
    value.polling.isEnabled = false
    value.deviceHistory = [
        .init(target: .exact(builtIn), name: "Built-in", isBuiltIn: true),
        .init(target: .exact(external1), name: "External 1", isBuiltIn: false),
        .init(target: .exact(external2), name: "External 2", isBuiltIn: false)
    ]
    value.rules = rules
    return value
}

private final class Facts: CoreGraphicsInventorySource {
    let values: [CoreGraphicsDisplayFact]
    init(_ values: [CoreGraphicsDisplayFact]) { self.values = values }
    func readOnlineDisplayFacts() throws -> [CoreGraphicsDisplayFact] { values }
}

private final class Scheduled: AutomationScheduledTask {
    var date: Date
    let interval: TimeInterval?
    let action: () -> Void
    var cancelled = false
    init(_ date: Date, _ interval: TimeInterval?, _ action: @escaping () -> Void) {
        self.date = date; self.interval = interval; self.action = action
    }
    func cancel() { cancelled = true }
}

private final class Clock: AutomationScheduling {
    var now = Date(timeIntervalSince1970: 1_000)
    var tasks: [Scheduled] = []
    func schedule(after delay: TimeInterval, repeating interval: TimeInterval?, _ action: @escaping () -> Void) -> AutomationScheduledTask {
        let task = Scheduled(now.addingTimeInterval(max(0, delay)), interval, action)
        tasks.append(task)
        return task
    }
    func advance(_ seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let task = tasks.filter({ !$0.cancelled && $0.date <= end }).sorted(by: { $0.date < $1.date }).first {
            now = task.date
            if let interval = task.interval { task.date = task.date.addingTimeInterval(interval) } else { task.cancelled = true }
            task.action()
        }
        now = end
    }
}

private final class FakeAdapter: DisplayRuntimeAdapting {
    var templates: [UInt32: ObservedDisplay]
    var live: [UInt32: ObservableDisplayState]
    var transactions: [[DisplayActionRequest]] = []
    var failuresRemaining = 0
    var uncertainDisableCount = 0
    var beforeTransactionObservation: ((FakeAdapter) -> Void)?
    var afterKnownFailure: ((FakeAdapter) -> Void)?
    var afterCommit: ((FakeAdapter, [DisplayActionRequest]) -> Void)?
    var enableStates: [UInt32: ObservableDisplayState] = [:]
    var pendingIDsSeenAtApply: [Set<UInt32>] = []
    var uncertainDisableRemainsOnline = false
    var delayedOfflineIDs = Set<UInt32>()
    var failedEnableIDs = Set<UInt32>()
    var uncertainEnableCount = 0
    var failObservationAfterUncertainEnable = false
    var uncertainEnableChangesState = true
    var uncertainEnableImmediateIDs: Set<UInt32>?
    var observationFailuresRemaining = 0
    var observationCount = 0
    var failObservationCall: Int?
    var failCoordinatorRefreshAfterApply = false
    var afterObservation: ((FakeAdapter, Int) -> Void)?

    init(_ displays: [ObservedDisplay]) {
        templates = Dictionary(uniqueKeysWithValues: displays.compactMap { item in item.runtimeID.map { ($0, item) } })
        live = Dictionary(uniqueKeysWithValues: displays.compactMap { item in
            guard let id = item.runtimeID, item.state.isOnline else { return nil }
            return (id, item.state)
        })
    }

    func add(_ item: ObservedDisplay) {
        guard let id = item.runtimeID else { return }
        templates[id] = item
        if item.state.isOnline { live[id] = item.state }
    }

    func setState(_ state: ObservableDisplayState?, runtimeID: UInt32) {
        live[runtimeID] = state
    }

    func observe(configuration: AppConfiguration, runtimeState: RuntimeState) throws -> ObservedDisplaySnapshot {
        observationCount += 1
        if failObservationCall == observationCount {
            throw Failure(description: "injected numbered observation failure")
        }
        if observationFailuresRemaining > 0 {
            observationFailuresRemaining -= 1
            throw Failure(description: "injected observation failure")
        }
        var result = live.keys.sorted().compactMap { id -> ObservedDisplay? in
            guard var item = templates[id], let state = live[id] else { return nil }
            item.state = state
            item.isMain = item.isMain && state.isActive
            return item
        }
        let recoveryRecords = runtimeState.appDisabledDisplays
            + runtimeState.pendingDisableDisplays.map(\.disabledRecord)
            + runtimeState.pendingRecoveryDisplays
        for record in recoveryRecords where live[record.runtimeID] == nil {
            var item = templates[record.runtimeID] ?? display(record.runtimeID, record.stableIdentity, record.family)
            item.state = .disabledByThisAppConnectionUnknown
            item.isMain = false
            result.append(item)
        }
        for known in configuration.deviceHistory where !represented(known, in: result) {
            let identity: StableDisplayIdentity?
            let family: DisplayFamily
            switch known.target {
            case .exact(let value): identity = value; family = value.family
            case .family(let value): identity = nil; family = value
            }
            result.append(ObservedDisplay(
                runtimeID: nil, stableIdentity: identity, family: family,
                name: known.name, isBuiltIn: known.isBuiltIn, isMain: false, state: .notObserved
            ))
        }
        let snapshot = ObservedDisplaySnapshot(displays: result)
        afterObservation?(self, observationCount)
        return snapshot
    }

    func apply(
        requests: [DisplayActionRequest],
        expectedFingerprint: DisplayPolicySnapshotFingerprint,
        configuration: AppConfiguration,
        runtimeState: RuntimeState,
        didCommit: () throws -> Void
    ) throws -> DisplayTransactionOutcome {
        pendingIDsSeenAtApply.append(Set(runtimeState.pendingDisableDisplays.map(\.runtimeID)))
        beforeTransactionObservation?(self)
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
        if uncertainEnableCount > 0 {
            uncertainEnableCount -= 1
            if uncertainEnableChangesState {
                for request in requests where request.action == .enable
                    && (uncertainEnableImmediateIDs?.contains(request.display.runtimeID) ?? true) {
                    live[request.display.runtimeID] = enableStates[request.display.runtimeID] ?? .online
                }
            }
            if failObservationAfterUncertainEnable {
                observationFailuresRemaining = 1
            }
            throw DisplayActionAdapterError.committedOutcomeUnknown("injected uncertain recovery")
        }
        if uncertainDisableCount > 0 {
            uncertainDisableCount -= 1
            for request in requests where request.action == .disable {
                if uncertainDisableRemainsOnline {
                    delayedOfflineIDs.insert(request.display.runtimeID)
                } else {
                    live.removeValue(forKey: request.display.runtimeID)
                }
            }
            afterCommit?(self, requests)
            try didCommit()
            throw DisplayActionAdapterError.committedOutcomeUnknown("injected uncertain commit")
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            afterKnownFailure?(self)
            return .init(
                before: before, after: before,
                results: requests.map { .init(request: $0, succeeded: false, wasIdempotent: false, errorDescription: "injected") },
                transactionWasCommitted: false
            )
        }
        let results = requests.map { request -> DisplayActionResult in
            switch request.action {
            case .noAction:
                return .init(request: request, succeeded: false, wasIdempotent: false, errorDescription: "no action")
            case .disable:
                if live.removeValue(forKey: request.display.runtimeID) != nil {
                    return .init(request: request, succeeded: true, wasIdempotent: false, errorDescription: nil)
                }
                let owned = runtimeState.appDisabledDisplays.contains { $0.runtimeID == request.display.runtimeID }
                return .init(request: request, succeeded: owned, wasIdempotent: owned, errorDescription: owned ? nil : "not online")
            case .enable:
                if failedEnableIDs.contains(request.display.runtimeID) {
                    return .init(request: request, succeeded: false, wasIdempotent: false, errorDescription: "injected enable failure")
                }
                let explicitRecovery = runtimeState.pendingDisableDisplays.contains {
                    $0.phase == .committedUncertain
                        && $0.runtimeID == request.display.runtimeID
                } || runtimeState.pendingRecoveryDisplays.contains {
                    $0.runtimeID == request.display.runtimeID
                        && $0.stableIdentity == request.display.stableIdentity
                        && $0.family == request.display.family
                }
                if explicitRecovery {
                    live[request.display.runtimeID] = enableStates[request.display.runtimeID] ?? .online
                    delayedOfflineIDs.remove(request.display.runtimeID)
                    return .init(request: request, succeeded: true, wasIdempotent: false, errorDescription: nil)
                }
                if live[request.display.runtimeID] != nil {
                    return .init(request: request, succeeded: true, wasIdempotent: true, errorDescription: nil)
                }
                let owned = (runtimeState.appDisabledDisplays + runtimeState.pendingDisableDisplays.map(\.disabledRecord) + runtimeState.pendingRecoveryDisplays).contains {
                    $0.runtimeID == request.display.runtimeID
                        && $0.stableIdentity == request.display.stableIdentity
                        && $0.family == request.display.family
                }
                if owned { live[request.display.runtimeID] = enableStates[request.display.runtimeID] ?? .online }
                return .init(request: request, succeeded: owned, wasIdempotent: false, errorDescription: owned ? nil : "not app-disabled this boot")
            }
        }
        let committed = results.contains { $0.succeeded && !$0.wasIdempotent }
        if committed { try didCommit() }
        for runtimeID in delayedOfflineIDs {
            live.removeValue(forKey: runtimeID)
        }
        delayedOfflineIDs.removeAll()
        afterCommit?(self, requests)
        let after = try observe(configuration: configuration, runtimeState: runtimeState)
        if failCoordinatorRefreshAfterApply {
            failCoordinatorRefreshAfterApply = false
            observationFailuresRemaining = 1
        }
        return .init(
            before: before,
            after: after,
            results: results,
            transactionWasCommitted: committed
        )
    }

    private func represented(_ known: KnownDisplay, in items: [ObservedDisplay]) -> Bool {
        switch known.target {
        case .exact(let identity): return items.contains { $0.stableIdentity == identity }
        case .family(let family): return items.contains { $0.family == family }
        }
    }
}

private struct Fixture {
    let root: URL
    let configurationStore: ConfigurationStore
    let stateStore: RuntimeStateStore
    let adapter: FakeAdapter
    let clock: Clock
    let coordinator: AutomationCoordinator
}

private func fixture(
    _ configuration: AppConfiguration, _ displays: [ObservedDisplay],
    state: RuntimeState? = nil, attempts: Int = 3
) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-phase2-\(UUID().uuidString)")
    let configStore = ConfigurationStore(rootURL: root, legacyDefaults: nil)
    try configStore.save(configuration)
    let stateStore = RuntimeStateStore(rootURL: root, legacyDefaults: nil, bootIdentifierProvider: { "boot" })
    if let state { try stateStore.save(state) }
    let adapter = FakeAdapter(displays)
    let clock = Clock()
    let coordinator = try AutomationCoordinator(
        configurationStore: configStore, runtimeStateStore: stateStore,
        adapter: adapter, scheduler: clock, debounceSeconds: 1,
        maximumActionAttempts: attempts, suppressionSeconds: 30
    )
    return .init(
        root: root,
        configurationStore: configStore,
        stateStore: stateStore,
        adapter: adapter,
        clock: clock,
        coordinator: coordinator
    )
}

@main
private enum Phase2Tests {
    static func main() {
        var runner = Runner()

        runner.run("inventory truth includes active online mirror disabled and history states") {
            let source = Facts([
                .init(runtimeID: 1, isActive: true, isMain: true, isBuiltIn: true, vendorID: 100, modelID: 10, serialNumber: 1, name: "Built-in", mirrorsRuntimeID: nil, mode: .init(logicalWidth: 100, logicalHeight: 100, pixelWidth: 200, pixelHeight: 200, refreshRate: 60, rotationDegrees: 0, scaleFactor: 2)),
                .init(runtimeID: 2, isActive: false, isMain: false, isBuiltIn: false, vendorID: 200, modelID: 20, serialNumber: 11, name: "External", mirrorsRuntimeID: 1, mode: nil)
            ])
            var configuration = AppConfiguration.default
            configuration.deviceHistory = [.init(target: .exact(absent), name: "Absent", isBuiltIn: false)]
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.appDisabledDisplays = [.init(runtimeID: 3, stableIdentity: external2, family: externalFamily)]
            let snapshot = try CoreGraphicsDisplayInventory(source: source).snapshot(configuration: configuration, runtimeState: state)
            try equal(snapshot.displays.first { $0.runtimeID == 1 }?.state, .active, "active fact lost")
            try equal(snapshot.displays.first { $0.runtimeID == 2 }?.state, .online, "online fact was mislabeled")
            try equal(snapshot.displays.first { $0.runtimeID == 2 }?.mirrorsRuntimeID, 1, "mirror relation lost")
            try equal(snapshot.displays.first { $0.runtimeID == 3 }?.state, .disabledByThisAppConnectionUnknown, "disabled record claimed connection")
            try equal(snapshot.displays.first { $0.stableIdentity == absent }?.state, .notObserved, "history claimed disconnection")
        }

        runner.run("boot-stale disabled IDs are downgraded and persisted by coordinator") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-stale-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let old = RuntimeStateStore(rootURL: root, legacyDefaults: nil, bootIdentifierProvider: { "old" })
            var stale = RuntimeState.empty(bootIdentifier: "old")
            stale.appDisabledDisplays = [.init(runtimeID: 99, stableIdentity: builtIn, family: builtInFamily)]
            try old.save(stale)
            let configurationStore = ConfigurationStore(rootURL: root, legacyDefaults: nil)
            try configurationStore.save(config([makeRule("none", actions: [.init(target: .exact(builtIn), action: .noAction)])], automatic: false))
            let current = RuntimeStateStore(rootURL: root, legacyDefaults: nil, bootIdentifierProvider: { "new" })
            _ = try AutomationCoordinator(configurationStore: configurationStore, runtimeStateStore: current, adapter: FakeAdapter([]), scheduler: Clock())
            let persisted = try JSONDecoder().decode(RuntimeState.self, from: Data(contentsOf: current.runtimeStateURL))
            try equal(persisted, .empty(bootIdentifier: "new"), "stale boot state survived runtime bootstrap")
        }

        runner.run("generic family plan is one transaction and manual safety is independent") {
            let value = try fixture(
                config([makeRule("disable family", actions: [.init(target: .family(externalFamily), action: .disable)])]),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily), display(3, external2, externalFamily)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            value.coordinator.start(); value.clock.advance(0)
            try equal(value.adapter.transactions.count, 1, "plan crossed multiple transactions")
            try equal(Set(value.adapter.transactions[0].map { $0.display.runtimeID }), Set([2, 3]), "family plan was not generic")

            let last = try fixture(
                config([makeRule("none", actions: [.init(target: .exact(builtIn), action: .noAction)])]),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true)]
            )
            defer { try? FileManager.default.removeItem(at: last.root) }
            last.coordinator.start()
            var blocked = false
            do { _ = try last.coordinator.performManualAction(runtimeID: 1, action: .disable) }
            catch AutomationCoordinatorError.lastActiveDisplay { blocked = true }
            try expect(blocked && last.adapter.transactions.isEmpty, "manual path did not preserve the last active display")
        }

        runner.run("restore requires current-boot ownership and clears it only after online confirmation") {
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.appDisabledDisplays = [.init(runtimeID: 1, stableIdentity: builtIn, family: builtInFamily)]
            let restore = makeRule("restore", actions: [.init(target: .exact(builtIn), action: .enable)])
            let value = try fixture(
                config([restore]),
                [display(1, builtIn, builtInFamily, builtIn: true, state: .notObserved), display(2, external1, externalFamily, main: true)],
                state: state
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            value.coordinator.start(); value.clock.advance(0)
            try equal(value.adapter.transactions.first?.first?.action, .enable, "owned display was not restored")
            let restoredState = try value.stateStore.load().state
            try expect(restoredState.appDisabledDisplays.isEmpty, "confirmed restore did not clear ownership")

            let absentValue = try fixture(config([restore]), [display(2, external1, externalFamily, main: true)])
            defer { try? FileManager.default.removeItem(at: absentValue.root) }
            absentValue.coordinator.start(); absentValue.clock.advance(0)
            try expect(absentValue.adapter.transactions.isEmpty, "history-only display was treated as restore eligible")
        }

        runner.run("external disconnect while built-in app-disabled auto-re-enables built-in") {
            let present = makeRule(
                "external present",
                conditions: [.count(.init(kind: .online, scope: .external, comparison: .greaterThan, value: 0))],
                actions: [.init(target: .exact(builtIn), action: .disable)]
            )
            let absent = makeRule(
                "external absent",
                conditions: [.count(.init(kind: .online, scope: .external, comparison: .equal, value: 0))],
                actions: [.init(target: .exact(builtIn), action: .enable)]
            )
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.appDisabledDisplays = [.init(runtimeID: 1, stableIdentity: builtIn, family: builtInFamily)]
            let value = try fixture(
                config([present, absent]),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, state: .disabledByThisAppConnectionUnknown),
                    display(2, external1, externalFamily, main: true)
                ],
                state: state
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            value.coordinator.start(); value.clock.advance(0)
            try equal(value.adapter.transactions.last?.first?.action, .disable, "external-present disable was not applied")
            value.adapter.setState(nil, runtimeID: 2)
            value.coordinator.handleDisplayEvent()
            value.clock.advance(1)
            try expect(
                value.adapter.transactions.contains { $0.contains { $0.action == .enable && $0.display.runtimeID == 1 } },
                "built-in was not re-enabled after external disconnect"
            )
            let finalState = try value.stateStore.load().state
            try expect(finalState.appDisabledDisplays.isEmpty, "confirmed automatic re-enable did not retire app-disabled evidence")
        }

        runner.run("manual pause topology resume master off and save-apply semantics") {
            let noAction = config([makeRule("none", actions: [.init(target: .exact(builtIn), action: .noAction)])])
            let value = try fixture(noAction, [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)])
            defer { try? FileManager.default.removeItem(at: value.root) }
            value.coordinator.start(); value.clock.advance(0)
            _ = try value.coordinator.performManualAction(runtimeID: 1, action: .disable)
            value.coordinator.handleDisplayEvent(); value.clock.advance(1)
            try equal(value.coordinator.status.pauseReason, .manualDisplayAction, "self event resumed manual pause")
            value.adapter.add(display(3, external2, externalFamily))
            value.coordinator.handleDisplayEvent()
            try equal(value.coordinator.status.pauseReason, nil, "actual topology change did not resume")
            _ = try value.coordinator.performManualAction(runtimeID: 3, action: .disable)
            _ = try value.coordinator.updateConfiguration(noAction, applyImmediately: true)
            try expect(!value.coordinator.status.isPaused, "Save and Apply did not end pause")

            let off = try fixture(
                config([makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)]
            )
            defer { try? FileManager.default.removeItem(at: off.root) }
            off.coordinator.start(); off.clock.advance(0)
            try expect(off.adapter.transactions.isEmpty, "master off still applied actions")
        }

        runner.run("startup stabilization and per-action suppression are deterministic") {
            let disable = makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])
            let stable = try fixture(
                config([disable], stabilization: 5),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)]
            )
            defer { try? FileManager.default.removeItem(at: stable.root) }
            stable.coordinator.start(); stable.clock.advance(4.9)
            try expect(stable.adapter.transactions.isEmpty, "startup acted before stabilization")
            stable.clock.advance(0.1)
            try equal(stable.adapter.transactions.count, 1, "startup did not act after stabilization")

            let failed = try fixture(
                config([disable]),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)],
                attempts: 3
            )
            defer { try? FileManager.default.removeItem(at: failed.root) }
            failed.adapter.failuresRemaining = 3
            failed.coordinator.start(); failed.clock.advance(0)
            try equal(failed.adapter.transactions.count, 3, "bounded retry count changed")
            failed.coordinator.resume()
            try equal(failed.adapter.transactions.count, 3, "suppressed action retried immediately")
            let suppressedState = try failed.stateStore.load().state
            try equal(suppressedState.failureSuppressions.count, 1, "suppression was not persisted")
        }

        runner.run("migration creates two family defaults and never trusts legacy runtime ID") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-migrate-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = "display-steward-phase2-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(100, forKey: "lastBuiltinVendor")
            defaults.set(10, forKey: "lastBuiltinModel")
            defaults.set(0, forKey: "lastBuiltinSerial")
            defaults.set(987654, forKey: "lastBuiltinDisplayID")
            let migrated = try ConfigurationStore(rootURL: root, legacyDefaults: defaults).loadOrMigrate().configuration
            try equal(migrated.rules.count, 2, "explicit default rule count changed")
            try expect(migrated.rules.allSatisfy { $0.actions.first?.target == .family(builtInFamily) }, "family migration target changed")
            let runtime = try RuntimeStateStore(rootURL: root, legacyDefaults: defaults, bootIdentifierProvider: { "boot" }).load(importLegacyMarker: true).state
            try equal(runtime.legacyBuiltInRecovery?.runtimeID, nil, "legacy runtime ID was trusted")
        }

        runner.run("sleeping deferral and no-hidden-policy produce no adapter actions") {
            let disable = makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])
            let sleeping = try fixture(
                config([disable]),
                [display(1, builtIn, builtInFamily, builtIn: true, state: .online), display(2, external1, externalFamily, state: .online)]
            )
            defer { try? FileManager.default.removeItem(at: sleeping.root) }
            sleeping.coordinator.start(); sleeping.clock.advance(0)
            try expect(sleeping.adapter.transactions.isEmpty, "online>0 active=0 was not deferred")
            try expect(sleeping.coordinator.status.lastEvaluation.safetyBlocks.contains { $0.reason == .onlineDisplaysHaveNoActiveDisplay }, "deferral diagnostic missing")

            let unmatched = makeRule(
                "unmatched",
                conditions: [.count(.init(kind: .online, scope: .external, comparison: .greaterThan, value: 99))],
                actions: [.init(target: .exact(builtIn), action: .disable)]
            )
            let hidden = try fixture(
                config([unmatched]),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)]
            )
            defer { try? FileManager.default.removeItem(at: hidden.root) }
            hidden.coordinator.start(); hidden.clock.advance(0)
            try expect(hidden.adapter.transactions.isEmpty, "fixed external-present policy survived engine cutover")
        }

        runner.run("pending disable journal survives interruption and reconciles on startup") {
            var onlineState = RuntimeState.empty(bootIdentifier: "boot")
            onlineState.pendingDisableDisplays = [.init(runtimeID: 1, stableIdentity: builtIn, family: builtInFamily)]
            let inert = config([makeRule("none", actions: [.init(target: .exact(builtIn), action: .noAction)])], automatic: false)
            let online = try fixture(inert, [display(1, builtIn, builtInFamily, builtIn: true, main: true)], state: onlineState)
            defer { try? FileManager.default.removeItem(at: online.root) }
            online.coordinator.start()
            let cleared = try online.stateStore.load().state
            try expect(cleared.pendingDisableDisplays.isEmpty && cleared.appDisabledDisplays.isEmpty, "online pending journal was not cleared")

            var committedState = RuntimeState.empty(bootIdentifier: "boot")
            committedState.pendingDisableDisplays = [.init(
                runtimeID: 1,
                stableIdentity: builtIn,
                family: builtInFamily,
                phase: .committedUncertain
            )]
            let committed = try fixture(inert, [display(1, builtIn, builtInFamily, builtIn: true, main: true)], state: committedState)
            defer { try? FileManager.default.removeItem(at: committed.root) }
            committed.coordinator.start()
            let retained = try committed.stateStore.load().state
            try equal(retained.pendingDisableDisplays.first?.phase, .committedUncertain, "one online sample cleared a committed-uncertain handle")
            committed.adapter.setState(nil, runtimeID: 1)
            committed.coordinator.handleDisplayEvent()
            let asynchronouslyMissing = try committed.stateStore.load().state
            try equal(asynchronouslyMissing.appDisabledDisplays.first?.runtimeID, 1, "asynchronous offline transition lost committed recovery")

            var missingState = RuntimeState.empty(bootIdentifier: "boot")
            missingState.pendingDisableDisplays = [.init(runtimeID: 1, stableIdentity: builtIn, family: builtInFamily)]
            let missing = try fixture(inert, [display(2, external1, externalFamily, main: true)], state: missingState)
            defer { try? FileManager.default.removeItem(at: missing.root) }
            missing.coordinator.start()
            let promoted = try missing.stateStore.load().state
            try expect(promoted.pendingDisableDisplays.isEmpty, "missing pending journal was not resolved")
            try equal(promoted.appDisabledDisplays.first?.runtimeID, 1, "missing pending journal lost its recovery handle")

            let uncertainRule = makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])
            let uncertain = try fixture(
                config([uncertainRule]),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)],
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: uncertain.root) }
            uncertain.adapter.uncertainDisableCount = 1
            uncertain.adapter.failuresRemaining = 1
            uncertain.coordinator.start(); uncertain.clock.advance(0)
            try expect(uncertain.adapter.pendingIDsSeenAtApply.first?.contains(1) == true, "disable journal was not persisted before the adapter call")
            let recovered = try uncertain.stateStore.load().state
            try equal(recovered.appDisabledDisplays.first?.runtimeID, 1, "uncertain commit discarded the recovery handle")
        }

        runner.run("post-commit active safety compensates when retained display becomes inactive") {
            let disable = makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])
            let value = try fixture(
                config([disable]),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            value.adapter.enableStates[1] = .active
            value.adapter.afterCommit = { adapter, requests in
                if requests.contains(where: { $0.action == .disable }) {
                    adapter.setState(.online, runtimeID: 2)
                }
            }
            value.coordinator.start(); value.clock.advance(0)
            try equal(value.adapter.transactions.compactMap { $0.first?.action }, [.disable, .enable], "unsafe commit did not trigger compensating restore")
            try equal(value.coordinator.status.pauseReason, .explicit, "automation did not pause after post-commit safety failure")
            try expect(value.coordinator.status.diagnostics.contains { $0.code == .safetyRecovery }, "safety recovery diagnostic missing")
        }

        runner.run("manual committed-unknown runs zero-active compensation before throwing") {
            let inert = config([makeRule("none", actions: [.init(target: .exact(builtIn), action: .noAction)])])
            let value = try fixture(
                inert,
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            value.coordinator.start(); value.clock.advance(0)
            value.adapter.uncertainDisableCount = 1
            value.adapter.uncertainDisableRemainsOnline = true
            value.adapter.enableStates[1] = .active
            value.adapter.afterCommit = { adapter, requests in
                if requests.contains(where: { $0.action == .disable }) {
                    adapter.setState(.online, runtimeID: 2)
                }
            }
            do {
                _ = try value.coordinator.performManualAction(runtimeID: 1, action: .disable)
            } catch {
                // The manual caller still receives the committed-unknown failure after recovery.
            }
            try equal(value.adapter.transactions.compactMap { $0.first?.action }, [.disable, .enable], "manual committed-unknown skipped compensation")
            try equal(value.coordinator.status.pauseReason, .explicit, "manual committed-unknown did not pause automation")
            try expect(value.coordinator.status.diagnostics.contains { $0.code == .safetyRecovery }, "manual safety recovery diagnostic missing")
            try expect(value.adapter.pendingIDsSeenAtApply.last?.contains(1) == true, "committed journal was cleared before explicit recovery enable")
            let settledState = try value.stateStore.load().state
            try expect(settledState.pendingDisableDisplays.isEmpty, "settled explicit recovery left a stale committed journal")
            try expect(value.coordinator.status.inventory.activeCount > 0, "delayed-offline recovery did not finish active-safe")
        }

        runner.run("snapshot fingerprint and every retry force fresh evaluation") {
            let conditional = makeRule(
                "external present",
                conditions: [.count(.init(kind: .online, scope: .external, comparison: .greaterThan, value: 0))],
                actions: [.init(target: .exact(builtIn), action: .disable)]
            )
            let stale = try fixture(
                config([conditional]),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)]
            )
            defer { try? FileManager.default.removeItem(at: stale.root) }
            stale.adapter.beforeTransactionObservation = { adapter in
                adapter.setState(nil, runtimeID: 2)
                adapter.beforeTransactionObservation = nil
            }
            stale.coordinator.start(); stale.clock.advance(0)
            try expect(stale.adapter.transactions.isEmpty, "plan applied after its policy snapshot changed")

            let retry = try fixture(
                config([conditional]),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)],
                attempts: 3
            )
            defer { try? FileManager.default.removeItem(at: retry.root) }
            retry.adapter.failuresRemaining = 1
            retry.adapter.afterKnownFailure = { adapter in
                adapter.setState(nil, runtimeID: 2)
                adapter.afterKnownFailure = nil
            }
            retry.coordinator.start(); retry.clock.advance(0)
            try equal(retry.adapter.transactions.count, 1, "retry reused a stale plan instead of reevaluating")
        }

        runner.run("shared not-before empty rules and polling topology resume remain authoritative") {
            var delayedConfig = config([
                makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])
            ], stabilization: 5)
            delayedConfig.polling = .init(isEnabled: true, intervalSeconds: 1)
            let delayed = try fixture(
                delayedConfig,
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)]
            )
            defer { try? FileManager.default.removeItem(at: delayed.root) }
            delayed.coordinator.start(); delayed.clock.advance(4.9)
            try expect(delayed.adapter.transactions.isEmpty, "poll trigger bypassed the shared startup deadline")

            let empty = try fixture(config([]), [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)])
            defer { try? FileManager.default.removeItem(at: empty.root) }
            empty.coordinator.start(); empty.clock.advance(0)
            try expect(empty.coordinator.status.configuration.rules.isEmpty, "intentional empty rules were replaced with defaults")
            try expect(empty.adapter.transactions.isEmpty, "intentional empty rules triggered a hidden policy")

            var pollingConfig = config([makeRule("none", actions: [.init(target: .exact(builtIn), action: .noAction)])])
            pollingConfig.polling = .init(isEnabled: true, intervalSeconds: 1)
            let polling = try fixture(pollingConfig, [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)])
            defer { try? FileManager.default.removeItem(at: polling.root) }
            polling.coordinator.start(); polling.clock.advance(0)
            _ = try polling.coordinator.performManualAction(runtimeID: 1, action: .disable)
            polling.adapter.add(display(3, external2, externalFamily))
            polling.clock.advance(1)
            try equal(polling.coordinator.status.pauseReason, nil, "poll observation did not resume after topology change")
        }

        runner.run("corrupt runtime state must recover before configuration can enable automation") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-state-recovery-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let configurationStore = ConfigurationStore(rootURL: root, legacyDefaults: nil)
            let disabled = config([], automatic: false)
            try configurationStore.save(disabled)
            let stateStore = RuntimeStateStore(rootURL: root, legacyDefaults: nil, bootIdentifierProvider: { "boot" })
            try Data("corrupt-runtime".utf8).write(to: stateStore.runtimeStateURL)
            let coordinator = try AutomationCoordinator(
                configurationStore: configurationStore,
                runtimeStateStore: stateStore,
                adapter: FakeAdapter([]),
                scheduler: Clock()
            )
            try expect(coordinator.status.diagnostics.contains { $0.code == .runtimeStateUnavailable }, "corrupt runtime state was not surfaced")
            var enabled = disabled
            enabled.automatic.isEnabled = true
            let recovered = try coordinator.updateConfiguration(enabled, applyImmediately: false)
            try expect(recovered.configuration.automatic.isEnabled, "successful fresh-state persistence did not enable automation")
            try expect(!recovered.diagnostics.contains { $0.code == .runtimeStateUnavailable }, "runtime-state diagnostic survived successful recovery")
            _ = try stateStore.load()
            let savedEnabled = try configurationStore.load().configuration.automatic.isEnabled
            try expect(savedEnabled, "configuration was not saved after runtime recovery")

            let blockedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-state-blocked-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: blockedRoot) }
            let blockedConfigurationStore = ConfigurationStore(rootURL: blockedRoot, legacyDefaults: nil)
            try blockedConfigurationStore.save(disabled)
            let blockedStateStore = RuntimeStateStore(
                rootURL: blockedRoot,
                legacyDefaults: nil,
                bootIdentifierProvider: { "boot" },
                saveOverride: { _ in throw Failure(description: "injected runtime-state write failure") }
            )
            try Data("corrupt-runtime".utf8).write(to: blockedStateStore.runtimeStateURL)
            let blocked = try AutomationCoordinator(
                configurationStore: blockedConfigurationStore,
                runtimeStateStore: blockedStateStore,
                adapter: FakeAdapter([]),
                scheduler: Clock()
            )
            var rejected = false
            do {
                _ = try blocked.updateConfiguration(enabled, applyImmediately: false)
            } catch {
                rejected = true
            }
            try expect(rejected, "automatic enable succeeded without writable runtime state")
            try expect(!blocked.status.configuration.automatic.isEnabled, "failed recovery left UI automation enabled")
            try expect(blocked.status.diagnostics.contains { $0.code == .runtimeStateUnavailable }, "failed recovery cleared its diagnostic")
            let blockedSavedEnabled = try blockedConfigurationStore.load().configuration.automatic.isEnabled
            try expect(!blockedSavedEnabled, "failed recovery saved the enable request")
        }

        runner.run("committed recovery discards a reused runtime ID identity") {
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.pendingDisableDisplays = [PendingDisableRecord(
                runtimeID: 1,
                stableIdentity: builtIn,
                family: builtInFamily,
                phase: .committedUncertain
            )]
            let inert = config([makeRule("none", actions: [.init(target: .exact(builtIn), action: .noAction)])], automatic: false)
            let value = try fixture(
                inert,
                [display(1, external1, externalFamily, main: true)],
                state: state
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            value.coordinator.start()
            let quarantined = try value.stateStore.load().state
            try expect(quarantined.pendingDisableDisplays.isEmpty, "reused runtime ID retained committed recovery")
            try expect(quarantined.appDisabledDisplays.isEmpty, "reused runtime ID became actionable recovery")
            try expect(value.coordinator.status.diagnostics.contains { $0.code == .staleRuntimeIdentityDiscarded }, "runtime ID reuse was not surfaced")
            do {
                _ = try value.coordinator.performManualAction(
                    runtimeID: 1,
                    action: .disable,
                    expectedTarget: .exact(builtIn)
                )
                throw Failure(description: "identity-bound manual action accepted reused runtime ID")
            } catch AutomationCoordinatorError.displayIdentityChanged(let runtimeID) {
                try equal(runtimeID, 1, "identity mismatch reported wrong runtime ID")
            }
            value.adapter.setState(nil, runtimeID: 1)
            value.coordinator.handleDisplayEvent()
            let afterOffline = try value.stateStore.load().state
            try expect(afterOffline.pendingDisableDisplays.isEmpty && afterOffline.appDisabledDisplays.isEmpty, "quarantined recovery was later promoted")
            try expect(value.adapter.transactions.isEmpty, "reused runtime ID triggered a display action")
        }

        runner.run("transient runtime persistence failure clears after successful recovery") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-state-transient-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let disable = makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])
            let desired = config([disable], automatic: true)
            let configurationStore = ConfigurationStore(rootURL: root, legacyDefaults: nil)
            try configurationStore.save(desired)
            var saveAttempts = 0
            let stateStore = RuntimeStateStore(
                rootURL: root,
                legacyDefaults: nil,
                bootIdentifierProvider: { "boot" },
                saveOverride: { _ in
                    saveAttempts += 1
                    if saveAttempts == 1 {
                        throw Failure(description: "injected transient runtime-state failure")
                    }
                }
            )
            let adapter = FakeAdapter([
                display(1, builtIn, builtInFamily, builtIn: true, main: true),
                display(2, external1, externalFamily)
            ])
            let clock = Clock()
            let coordinator = try AutomationCoordinator(
                configurationStore: configurationStore,
                runtimeStateStore: stateStore,
                adapter: adapter,
                scheduler: clock,
                maximumActionAttempts: 1
            )
            coordinator.start(); clock.advance(0)
            try expect(coordinator.status.diagnostics.contains { $0.code == .statePersistenceFailed }, "transient state failure was not surfaced")
            try expect(!coordinator.status.configuration.automatic.isEnabled, "state failure left UI automatic enabled")
            try expect(adapter.transactions.isEmpty, "action reached adapter after journal persistence failed")

            coordinator.resume()
            let recovered = coordinator.status
            try expect(recovered.configuration.automatic.isEnabled, "successful recovery did not restore requested automatic state")
            try expect(!recovered.diagnostics.contains { $0.code == .runtimeStateUnavailable || $0.code == .statePersistenceFailed }, "stale runtime-state diagnostic survived recovery")
            try expect(adapter.transactions.count == 1, "Save and Apply did not resume after state recovery")
            let persistedAutomatic = try configurationStore.load().configuration.automatic.isEnabled
            try equal(persistedAutomatic, recovered.configuration.automatic.isEnabled, "persisted and UI automatic states diverged")
        }

        runner.run("bulk recovery restores owned and committed-uncertain displays in one transaction") {
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.appDisabledDisplays = [
                .init(runtimeID: 1, stableIdentity: builtIn, family: builtInFamily)
            ]
            state.pendingDisableDisplays = [
                .init(
                    runtimeID: 2,
                    stableIdentity: external1,
                    family: externalFamily,
                    phase: .committedUncertain
                )
            ]
            let value = try fixture(
                config([], automatic: false),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, state: .notObserved),
                    display(2, external1, externalFamily, state: .online),
                    display(3, external2, externalFamily, main: true)
                ],
                state: state,
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            value.coordinator.start()
            let plan = try value.coordinator.prepareDisplayRecovery(only: nil)
            try equal(Set(plan.targets.map { $0.display.runtimeID }), Set([1, 2]), "bulk preview omitted a recoverable display")
            try equal(plan.targets.first(where: { $0.display.runtimeID == 2 })?.evidence, .pendingConfirmation, "online committed uncertainty lost its recovery state")

            var publications = 0
            value.coordinator.onStatusChange = { publications += 1 }
            let result = value.coordinator.restoreDisplays(plan)

            try equal(value.adapter.transactions.count, 1, "bulk recovery crossed multiple transactions")
            try equal(Set(value.adapter.transactions[0].map { $0.display.runtimeID }), Set([1, 2]), "bulk transaction changed the confirmed target set")
            try expect(value.adapter.transactions[0].allSatisfy { $0.action == .enable }, "bulk recovery issued a non-enable action")
            try expect(result.items.allSatisfy { $0.disposition == .restored }, "successful bulk recovery reported a non-restored result")
            let persisted = try value.stateStore.load().state
            try expect(persisted.appDisabledDisplays.isEmpty && persisted.pendingDisableDisplays.isEmpty && persisted.pendingRecoveryDisplays.isEmpty, "bulk recovery left settled evidence")
            try equal(value.coordinator.status.pauseReason, .manualDisplayAction, "bulk recovery did not keep automation paused")
            try expect(value.coordinator.status.recoveryPlan.targets.isEmpty, "bulk recovery status retained settled targets")
            try equal(publications, 1, "bulk recovery published more than one unified result")
        }

        runner.run("bulk recovery preserves failed evidence and reports partial success") {
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.appDisabledDisplays = [
                .init(runtimeID: 1, stableIdentity: builtIn, family: builtInFamily),
                .init(runtimeID: 2, stableIdentity: external1, family: externalFamily)
            ]
            let value = try fixture(
                config([], automatic: false),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, state: .notObserved),
                    display(2, external1, externalFamily, state: .notObserved),
                    display(3, external2, externalFamily, main: true)
                ],
                state: state,
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            value.adapter.failedEnableIDs = [2]
            let plan = try value.coordinator.prepareDisplayRecovery(only: nil)
            let result = value.coordinator.restoreDisplays(plan)

            try equal(result.items.first(where: { $0.target.display.runtimeID == 1 })?.disposition, .restored, "successful target was not reported restored")
            try equal(result.items.first(where: { $0.target.display.runtimeID == 2 })?.disposition, .unresolved, "failed target was not reported unresolved")
            try equal(result.unresolvedTargets.map { $0.display.runtimeID }, [2], "retry set included a settled target")
            let persisted = try value.stateStore.load().state
            try expect(!persisted.appDisabledDisplays.contains { $0.runtimeID == 1 }, "successful evidence was not retired")
            try expect(
                persisted.appDisabledDisplays.contains { $0.runtimeID == 2 }
                    || persisted.pendingRecoveryDisplays.contains { $0.runtimeID == 2 },
                "failed recovery evidence was discarded"
            )
        }

        runner.run("bulk recovery freezes confirmation targets and skips reused runtime identities") {
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.appDisabledDisplays = [
                .init(runtimeID: 1, stableIdentity: builtIn, family: builtInFamily)
            ]
            let value = try fixture(
                config([], automatic: false),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, state: .notObserved),
                    display(2, external1, externalFamily, main: true)
                ],
                state: state,
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let plan = try value.coordinator.prepareDisplayRecovery(only: nil)
            value.adapter.templates[1] = display(1, external2, externalFamily)
            value.adapter.live[1] = .active

            let result = value.coordinator.restoreDisplays(plan)

            try equal(result.items.first?.disposition, .skipped, "reused runtime identity was not skipped")
            try expect(value.adapter.transactions.isEmpty, "reused runtime identity reached CoreGraphics")
            try equal(value.coordinator.status.pauseReason, .manualDisplayAction, "confirmed empty execution did not keep automation paused")
        }

        runner.run("bulk recovery keeps evidence uncertain when cleanup persistence fails") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-bulk-persistence-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let configurationStore = ConfigurationStore(rootURL: root, legacyDefaults: nil)
            try configurationStore.save(config([], automatic: false))
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.appDisabledDisplays = [
                .init(runtimeID: 1, stableIdentity: builtIn, family: builtInFamily)
            ]
            let readableStore = RuntimeStateStore(rootURL: root, legacyDefaults: nil, bootIdentifierProvider: { "boot" })
            try readableStore.save(state)
            var saveAttempts = 0
            let failingStore = RuntimeStateStore(
                rootURL: root,
                legacyDefaults: nil,
                bootIdentifierProvider: { "boot" },
                saveOverride: { _ in
                    saveAttempts += 1
                    if saveAttempts == 2 {
                        throw Failure(description: "injected cleanup persistence failure")
                    }
                }
            )
            let adapter = FakeAdapter([
                display(1, builtIn, builtInFamily, builtIn: true, state: .notObserved),
                display(2, external1, externalFamily, main: true)
            ])
            let coordinator = try AutomationCoordinator(
                configurationStore: configurationStore,
                runtimeStateStore: failingStore,
                adapter: adapter,
                scheduler: Clock(),
                maximumActionAttempts: 1
            )
            let plan = try coordinator.prepareDisplayRecovery(only: nil)
            let result = coordinator.restoreDisplays(plan)

            try equal(result.items.first?.disposition, .uncertain, "cleanup persistence failure claimed a restored display")
            try equal(result.unresolvedTargets.first?.display.runtimeID, 1, "uncertain target was not retryable")
            let persisted = try readableStore.load().state
            try expect(
                persisted.appDisabledDisplays.contains { $0.runtimeID == 1 }
                    || persisted.pendingRecoveryDisplays.contains { $0.runtimeID == 1 },
                "cleanup persistence failure discarded durable evidence"
            )
            try expect(coordinator.status.recoveryPlan.targets.contains { $0.display.runtimeID == 1 }, "uncertain recovery disappeared from status")
            try expect(coordinator.status.diagnostics.contains { $0.code == .statePersistenceFailed }, "cleanup persistence failure was not surfaced")
            try equal(coordinator.status.pauseReason, .manualDisplayAction, "cleanup persistence failure did not preserve manual pause")
            let retryPlan = try coordinator.prepareDisplayRecovery(only: result.unresolvedTargets)
            try equal(retryPlan.targets.map { $0.display.runtimeID }, [1], "uncertain target disappeared before retry confirmation")
        }

        runner.run("bulk recovery skips a target whose confirmed recovery state changed") {
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.pendingDisableDisplays = [
                .init(
                    runtimeID: 1,
                    stableIdentity: builtIn,
                    family: builtInFamily,
                    phase: .committedUncertain
                )
            ]
            let value = try fixture(
                config([], automatic: false),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, state: .online),
                    display(2, external1, externalFamily, main: true)
                ],
                state: state,
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let plan = try value.coordinator.prepareDisplayRecovery(only: nil)
            value.adapter.setState(nil, runtimeID: 1)

            let result = value.coordinator.restoreDisplays(plan)

            try equal(result.items.first?.disposition, .skipped, "changed recovery evidence remained executable")
            try expect(value.adapter.transactions.isEmpty, "changed recovery evidence reached CoreGraphics")
        }

        runner.run("uncertain committed recovery self-events cannot resume automation") {
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.appDisabledDisplays = [
                .init(runtimeID: 1, stableIdentity: builtIn, family: builtInFamily)
            ]
            let value = try fixture(
                config([], automatic: false),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, state: .notObserved),
                    display(2, external1, externalFamily, main: true)
                ],
                state: state,
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let plan = try value.coordinator.prepareDisplayRecovery(only: nil)
            value.adapter.uncertainEnableCount = 1
            value.adapter.failObservationAfterUncertainEnable = true
            let result = value.coordinator.restoreDisplays(plan)
            try equal(result.items.first?.disposition, .uncertain, "committed-unknown recovery did not report uncertainty")

            value.coordinator.handleDisplayEvent()

            try equal(value.coordinator.status.pauseReason, .manualDisplayAction, "self-generated uncertain recovery event resumed automation")
            let retryPlan = try value.coordinator.prepareDisplayRecovery(only: result.unresolvedTargets)
            try equal(retryPlan.targets.map { $0.display.runtimeID }, [1], "committed-unknown target was not available for confirmed retry")
        }
        runner.run("unrelated first topology event resumes uncertain recovery pause") {
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.appDisabledDisplays = [
                .init(runtimeID: 1, stableIdentity: builtIn, family: builtInFamily)
            ]
            let value = try fixture(
                config([], automatic: false),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, state: .notObserved),
                    display(2, external1, externalFamily, main: true)
                ],
                state: state,
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let plan = try value.coordinator.prepareDisplayRecovery(only: nil)
            value.adapter.uncertainEnableCount = 1
            value.adapter.uncertainEnableChangesState = false
            value.adapter.failObservationAfterUncertainEnable = true
            _ = value.coordinator.restoreDisplays(plan)
            value.adapter.add(display(3, external2, externalFamily))

            value.coordinator.handleDisplayEvent()

            try equal(value.coordinator.status.pauseReason, nil, "unrelated real topology change was consumed as a recovery self-event")
        }

        runner.run("disable actions reuse unresolved recovery evidence without duplicate journals") {
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.pendingRecoveryDisplays = [
                .init(runtimeID: 1, stableIdentity: builtIn, family: builtInFamily)
            ]
            let disable = makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])

            let failed = try fixture(
                config([disable]),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, main: true),
                    display(2, external1, externalFamily)
                ],
                state: state,
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: failed.root) }
            failed.adapter.failuresRemaining = 1
            failed.coordinator.start(); failed.clock.advance(0)
            let retained = try failed.stateStore.load().state
            try equal(retained.pendingRecoveryDisplays.map(\.runtimeID), [1], "known uncommitted disable lost prior recovery evidence")
            try expect(retained.pendingDisableDisplays.isEmpty, "known uncommitted disable created a duplicate journal")

            let succeeded = try fixture(
                config([disable]),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, main: true),
                    display(2, external1, externalFamily)
                ],
                state: state,
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: succeeded.root) }
            succeeded.coordinator.start(); succeeded.clock.advance(0)
            let settled = try succeeded.stateStore.load().state
            try expect(settled.pendingRecoveryDisplays.isEmpty && settled.pendingDisableDisplays.isEmpty, "confirmed disable retained an obsolete recovery journal")
            try equal(settled.appDisabledDisplays.map(\.runtimeID), [1], "confirmed disable did not become app-disabled evidence")
        }


        runner.run("no-delta online recovery event does not mask a later real target change") {
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.pendingDisableDisplays = [
                .init(
                    runtimeID: 1,
                    stableIdentity: builtIn,
                    family: builtInFamily,
                    phase: .committedUncertain
                )
            ]
            let value = try fixture(
                config([], automatic: false),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, state: .online),
                    display(2, external1, externalFamily, main: true)
                ],
                state: state,
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let plan = try value.coordinator.prepareDisplayRecovery(only: nil)
            value.adapter.uncertainEnableCount = 1
            _ = value.coordinator.restoreDisplays(plan)

            value.coordinator.handleDisplayEvent()
            try equal(value.coordinator.status.pauseReason, .manualDisplayAction, "no-delta recovery event resumed automation")
            value.adapter.setState(nil, runtimeID: 1)
            value.coordinator.handleDisplayEvent()

            try equal(value.coordinator.status.pauseReason, nil, "later real target topology change was masked as recovery-generated")
        }

        runner.run("single recovery confirmation pauses after failure and uncertainty") {
            func recoveryState() -> RuntimeState {
                var state = RuntimeState.empty(bootIdentifier: "boot")
                state.pendingDisableDisplays = [
                    .init(
                        runtimeID: 1,
                        stableIdentity: builtIn,
                        family: builtInFamily,
                        phase: .committedUncertain
                    )
                ]
                return state
            }

            let failed = try fixture(
                config([], automatic: false),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, state: .online),
                    display(2, external1, externalFamily, main: true)
                ],
                state: recoveryState(),
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: failed.root) }
            failed.adapter.failuresRemaining = 1
            do {
                _ = try failed.coordinator.performManualAction(runtimeID: 1, action: .enable)
            } catch {}
            try equal(failed.coordinator.status.pauseReason, .manualDisplayAction, "known recovery failure did not pause automation")
            try equal((try failed.stateStore.load().state).pendingRecoveryDisplays.map(\.runtimeID), [1], "known recovery failure lost retry evidence")

            let uncertain = try fixture(
                config([], automatic: false),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, state: .online),
                    display(2, external1, externalFamily, main: true)
                ],
                state: recoveryState(),
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: uncertain.root) }
            uncertain.adapter.uncertainEnableCount = 1
            uncertain.adapter.failObservationAfterUncertainEnable = true
            do {
                _ = try uncertain.coordinator.performManualAction(runtimeID: 1, action: .enable)
            } catch {}
            uncertain.coordinator.handleDisplayEvent()
            try equal(uncertain.coordinator.status.pauseReason, .manualDisplayAction, "uncertain single recovery self-event resumed automation")
        }

        runner.run("staged uncertain recovery self-events keep automation paused") {
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.appDisabledDisplays = [
                .init(runtimeID: 1, stableIdentity: builtIn, family: builtInFamily),
                .init(runtimeID: 2, stableIdentity: external1, family: externalFamily)
            ]
            let value = try fixture(
                config([], automatic: false),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, state: .notObserved),
                    display(2, external1, externalFamily, state: .notObserved),
                    display(3, external2, externalFamily, main: true)
                ],
                state: state,
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let plan = try value.coordinator.prepareDisplayRecovery(only: nil)
            value.adapter.uncertainEnableCount = 1
            value.adapter.uncertainEnableImmediateIDs = [1]
            value.adapter.failObservationAfterUncertainEnable = true
            _ = value.coordinator.restoreDisplays(plan)

            value.coordinator.handleDisplayEvent()
            try equal(value.coordinator.status.pauseReason, .manualDisplayAction, "first staged recovery event resumed automation")
            value.adapter.setState(.online, runtimeID: 2)
            value.coordinator.handleDisplayEvent()

            try equal(value.coordinator.status.pauseReason, .manualDisplayAction, "second staged recovery event resumed automation")
        }

        runner.run("single recovery cleanup failure retains retryable evidence") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-single-persistence-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let configurationStore = ConfigurationStore(rootURL: root, legacyDefaults: nil)
            try configurationStore.save(config([], automatic: false))
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.pendingDisableDisplays = [
                .init(
                    runtimeID: 1,
                    stableIdentity: builtIn,
                    family: builtInFamily,
                    phase: .committedUncertain
                )
            ]
            let readableStore = RuntimeStateStore(rootURL: root, legacyDefaults: nil, bootIdentifierProvider: { "boot" })
            try readableStore.save(state)
            var saveAttempts = 0
            let failingStore = RuntimeStateStore(
                rootURL: root,
                legacyDefaults: nil,
                bootIdentifierProvider: { "boot" },
                saveOverride: { _ in
                    saveAttempts += 1
                    if saveAttempts == 2 {
                        throw Failure(description: "injected single cleanup failure")
                    }
                }
            )
            let coordinator = try AutomationCoordinator(
                configurationStore: configurationStore,
                runtimeStateStore: failingStore,
                adapter: FakeAdapter([
                    display(1, builtIn, builtInFamily, builtIn: true, state: .online),
                    display(2, external1, externalFamily, main: true)
                ]),
                scheduler: Clock(),
                maximumActionAttempts: 1
            )
            do {
                _ = try coordinator.performManualAction(runtimeID: 1, action: .enable)
            } catch {}

            let persisted = try readableStore.load().state
            try equal(persisted.pendingRecoveryDisplays.map(\.runtimeID), [1], "single cleanup failure lost durable recovery evidence")
            try equal(coordinator.status.recoveryPlan.targets.map { $0.display.runtimeID }, [1], "single cleanup failure lost in-memory recovery evidence")
            try equal(coordinator.status.pauseReason, .manualDisplayAction, "single cleanup failure did not preserve manual pause")
            try expect(coordinator.status.diagnostics.contains { $0.code == .statePersistenceFailed }, "single cleanup failure was not surfaced")
            let retry = try coordinator.prepareDisplayRecovery(only: coordinator.status.recoveryPlan.targets)
            try equal(retry.targets.map { $0.display.runtimeID }, [1], "single cleanup failure target was not retryable")
        }

        runner.run("single recovery success pauses before optional refresh") {
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.pendingDisableDisplays = [
                .init(
                    runtimeID: 1,
                    stableIdentity: builtIn,
                    family: builtInFamily,
                    phase: .committedUncertain
                )
            ]
            let value = try fixture(
                config([], automatic: false),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, state: .online),
                    display(2, external1, externalFamily, main: true)
                ],
                state: state,
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            value.adapter.failObservationCall = 5

            let status = try value.coordinator.performManualAction(runtimeID: 1, action: .enable)

            try equal(status.pauseReason, .manualDisplayAction, "successful single recovery did not pause automation")
            try equal(value.adapter.observationCount, 4, "successful single recovery performed a failure-prone extra refresh")
            let persisted = try value.stateStore.load().state
            try expect(persisted.pendingRecoveryDisplays.isEmpty && persisted.pendingDisableDisplays.isEmpty, "successful single recovery retained settled evidence")
        }

        runner.run("fresh root stays Automation-off without startup work and seeds the default rules") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-fresh-profile-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
            let stateStore = RuntimeStateStore(rootURL: root, legacyDefaults: nil, bootIdentifierProvider: { "boot" })
            let clock = Clock()
            let coordinator = try AutomationCoordinator(
                configurationStore: store,
                runtimeStateStore: stateStore,
                adapter: FakeAdapter([display(1, builtIn, builtInFamily, builtIn: true, main: true)]),
                scheduler: clock
            )

            try equal(coordinator.status.configurationLoadSource, .createdBlankProfile, "fresh creation source was hidden")

            coordinator.start()

            try expect(coordinator.status.activeProfile != nil, "fresh root did not expose its Active Profile")
            try equal(coordinator.status.configurationLoadSource, .primary, "seeding did not repair the fresh Profile source")
            try expect(!coordinator.status.configuration.automatic.isEnabled, "fresh root enabled Automation")
            try expect(!coordinator.status.configuration.automatic.isEnabled, "fresh root enabled Automation")
            try equal(
                coordinator.status.configuration.rules,
                LegacyConfigurationMigrator.defaultExternalRules(target: .exact(builtIn)),
                "fresh root did not seed the default external-display rules"
            )
            try equal(coordinator.status.configuration.rules.map(\.name), ["检测到外接显示器", "未检测到外接显示器"], "default rule names changed")
            try equal(coordinator.status.configuration.rules.map { $0.actions.first?.action }, [.disable, .enable], "default rule actions changed")
            try equal(coordinator.status.configuration.rules.map { $0.conditions }, [[.count(DisplayCountCondition(kind: .online, scope: .external, comparison: .greaterThan, value: 0))], [.count(DisplayCountCondition(kind: .online, scope: .external, comparison: .equal, value: 0))]], "default rule conditions changed")
            try expect(clock.tasks.filter { !$0.cancelled }.isEmpty, "Automation-off startup scheduled hidden work")
            let freshPersisted = try store.load().activeProfile
            try equal(freshPersisted.rules, coordinator.status.configuration.rules, "fresh observation did not persist the seeded rules")
            try expect(!freshPersisted.automatic.isEnabled, "fresh default enabled Automation after seeding")
        }

        runner.run("Active Profile persists across coordinator restart with generation status") {
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            var target = try value.configurationStore.createBlankProfile(named: "Office")
            target.rules = [makeRule("inert", actions: [.init(target: .exact(builtIn), action: .noAction)])]
            try value.configurationStore.saveProfile(target)
            _ = try value.coordinator.activateProfile(id: target.id)

            let restarted = try AutomationCoordinator(
                configurationStore: value.configurationStore,
                runtimeStateStore: value.stateStore,
                adapter: FakeAdapter([display(1, builtIn, builtInFamily, builtIn: true, main: true)]),
                scheduler: Clock()
            )

            try equal(restarted.status.activeProfile?.id, target.id, "restart selected a different Profile")
            try equal(restarted.status.activeProfile?.name, "Office", "restart lost Active Profile data")
            try equal(restarted.status.settingsGenerationSource, .primary, "settings generation source was not surfaced")
            try equal(restarted.status.activeProfileGenerationSource, .primary, "Profile generation source was not surfaced")
            try expect(restarted.status.isCatalogValid, "valid Profile catalog was reported invalid")
        }

        runner.run("manual activation is immediate while Automation-off clears pause and replaces polling") {
            var initial = config([], automatic: true)
            initial.polling = .init(isEnabled: true, intervalSeconds: 10)
            let value = try fixture(
                initial,
                [
                    display(1, builtIn, builtInFamily, builtIn: true, main: true),
                    display(2, external1, externalFamily)
                ]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            value.coordinator.start()
            value.coordinator.pause()
            var offTarget = try value.configurationStore.createBlankProfile(named: "Manual only")
            offTarget.rules = [makeRule("disable built-in", actions: [.init(target: .exact(builtIn), action: .disable)])]
            try value.configurationStore.saveProfile(offTarget)

            let activation = try value.coordinator.activateProfile(id: offTarget.id)

            try equal(activation.hardwareOutcome, .applied, "forced activation hardware result was not separated from selection")
            try equal(value.adapter.transactions.last?.first?.action, .disable, "Automation-off activation did not evaluate immediately")
            try expect(!value.coordinator.status.configuration.automatic.isEnabled, "forced activation persisted Automation-on")
            try equal(value.coordinator.status.pauseReason, nil, "Profile activation did not clear pause")
            try equal(try value.configurationStore.load().activeProfile.automatic.isEnabled, false, "forced activation rewrote target Automation")
            try expect(value.clock.tasks.filter { !$0.cancelled && $0.interval != nil }.isEmpty, "old polling survived Automation-off activation")

            var pollingTarget = try value.configurationStore.createBlankProfile(named: "Polling")
            pollingTarget.automatic.isEnabled = true
            pollingTarget.polling = .init(isEnabled: true, intervalSeconds: 2)
            try value.configurationStore.saveProfile(pollingTarget)
            _ = try value.coordinator.activateProfile(id: pollingTarget.id)
            let repeating = value.clock.tasks.filter { !$0.cancelled }.compactMap(\.interval)
            try equal(repeating, [2], "polling did not restart from the newly Active Profile")
        }

        runner.run("inactive Profile save is isolated from Active Profile and hardware") {
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let activeID = value.coordinator.status.activeProfile!.id
            let activeBefore = value.coordinator.status.configuration
            var inactive = try value.coordinator.createBlankProfile(named: "Draft")
            inactive.automatic.isEnabled = true
            inactive.rules = [makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])]

            _ = try value.coordinator.saveProfile(inactive, applyImmediately: true)

            try equal(value.coordinator.status.activeProfile?.id, activeID, "inactive save switched Active Profile")
            try equal(value.coordinator.status.configuration, activeBefore, "inactive draft was written into Active Profile")
            try expect(value.adapter.transactions.isEmpty, "inactive save had a hardware effect")
            try equal(try value.configurationStore.loadProfile(id: inactive.id).profile.rules, inactive.rules, "inactive target was not saved")
            try equal(try value.configurationStore.load().activeProfile.id, activeID, "inactive save changed persisted selector")
        }

        runner.run("activation persists identity before hardware failure and reports both outcomes") {
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)],
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            var target = try value.configurationStore.createBlankProfile(named: "Failing")
            target.rules = [makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])]
            try value.configurationStore.saveProfile(target)
            var selectorSeenAtApply: UUID?
            value.adapter.beforeTransactionObservation = { _ in
                selectorSeenAtApply = try? value.configurationStore.load().activeProfile.id
            }
            value.adapter.failuresRemaining = 1

            let result = try value.coordinator.activateProfile(id: target.id)

            try equal(selectorSeenAtApply, target.id, "hardware application preceded Active Profile persistence")
            try equal(result.activeProfile.id, target.id, "activation result lost persisted selection")
            try equal(result.hardwareOutcome, .failed, "hardware failure was reported as activation failure")
            try equal(value.coordinator.status.activeProfile?.id, target.id, "hardware failure rolled back Active Profile")
            try equal(try value.configurationStore.load().activeProfile.id, target.id, "hardware failure rolled back durable selector")
            try expect(result.actionDiagnostics.contains { $0.code == .actionFailed }, "hardware failure diagnostics were not attached to activation")
        }

        runner.run("activation keeps explicit disables and restores no-action or empty transitions") {
            func makeOwnedFixture() throws -> Fixture {
                var state = RuntimeState.empty(bootIdentifier: "boot")
                state.appDisabledDisplays = [.init(runtimeID: 1, stableIdentity: builtIn, family: builtInFamily)]
                return try fixture(
                    config([], automatic: false),
                    [
                        display(1, builtIn, builtInFamily, builtIn: true, state: .notObserved),
                        display(2, external1, externalFamily, main: true)
                    ],
                    state: state,
                    attempts: 1
                )
            }

            let keep = try makeOwnedFixture()
            defer { try? FileManager.default.removeItem(at: keep.root) }
            var disabling = try keep.configurationStore.createBlankProfile(named: "Keep disabled")
            disabling.rules = [makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])]
            try keep.configurationStore.saveProfile(disabling)
            _ = try keep.coordinator.activateProfile(id: disabling.id)
            try equal(keep.adapter.transactions.last?.first?.action, .disable, "explicit winning disable was replaced by transition restore")
            try equal((try keep.stateStore.load().state).appDisabledDisplays.map(\.runtimeID), [1], "kept disable retired recovery evidence")

            for (name, rules) in [
                ("No action", [makeRule("none", actions: [.init(target: .exact(builtIn), action: .noAction)])]),
                ("Empty", [])
            ] {
                let restore = try makeOwnedFixture()
                defer { try? FileManager.default.removeItem(at: restore.root) }
                var target = try restore.configurationStore.createBlankProfile(named: name)
                target.rules = rules
                try restore.configurationStore.saveProfile(target)
                _ = try restore.coordinator.activateProfile(id: target.id)
                try equal(restore.adapter.transactions.last?.first?.action, .enable, "\(name) Profile did not restore obsolete disable")
                let state = try restore.stateStore.load().state
                try expect(state.appDisabledDisplays.isEmpty && state.pendingDisableDisplays.isEmpty && state.pendingRecoveryDisplays.isEmpty, "\(name) restore did not retire confirmed evidence")
            }
        }

        runner.run("activation retry reobserves and drops a stale transition restore") {
            var state = RuntimeState.empty(bootIdentifier: "boot")
            state.appDisabledDisplays = [.init(runtimeID: 1, stableIdentity: builtIn, family: builtInFamily)]
            let value = try fixture(
                config([], automatic: false),
                [
                    display(1, builtIn, builtInFamily, builtIn: true, state: .notObserved),
                    display(2, external1, externalFamily, main: true)
                ],
                state: state,
                attempts: 3
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let target = try value.configurationStore.createBlankProfile(named: "Empty")
            value.adapter.failuresRemaining = 1
            value.adapter.afterKnownFailure = { adapter in
                adapter.setState(.online, runtimeID: 1)
                adapter.afterKnownFailure = nil
            }

            _ = try value.coordinator.activateProfile(id: target.id)

            try equal(value.adapter.transactions.count, 1, "retry reused a stale transition restore")
            let reconciledState = try value.stateStore.load().state
            try expect(reconciledState.appDisabledDisplays.isEmpty, "fresh online observation did not settle transition evidence")
        }

        runner.run("catalog reload surfaces disk state without applying external Active selector") {
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let liveID = value.coordinator.status.activeProfile!.id
            let externalTarget = try value.configurationStore.createBlankProfile(named: "External edit")
            _ = try value.configurationStore.activateProfile(id: externalTarget.id)
            let invalidURL = value.configurationStore.profilesDirectoryURL.appendingPathComponent("invalid.json")
            try Data("invalid".utf8).write(to: invalidURL)

            let reloaded = value.coordinator.reloadProfileCatalog()

            try equal(reloaded.activeProfile?.id, liveID, "catalog reload silently applied external Active selector")
            try equal(reloaded.configuration, value.coordinator.status.configuration, "catalog reload replaced live configuration")
            try equal(reloaded.externalActiveProfileID, externalTarget.id, "ignored external selector was not surfaced")
            try expect(!reloaded.isCatalogValid && reloaded.profileCatalog.invalidProfiles.count == 1, "invalid catalog state was not surfaced")
            try equal(try value.configurationStore.load().activeProfile.id, externalTarget.id, "test did not establish external selector change")
            try expect(value.adapter.transactions.isEmpty, "catalog reload applied hardware actions")
        }

        runner.run("global Display History survives activation and implicit writes stay scoped") {
            let extraFamily = DisplayFamily(vendorID: 400, modelID: 40)
            let extraIdentity = StableDisplayIdentity(family: extraFamily, serialNumber: 41)
            var initial = config([], automatic: false)
            initial.deviceHistory = []
            let value = try fixture(
                initial,
                [display(4, extraIdentity, extraFamily, main: true)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let activeID = value.coordinator.status.activeProfile!.id
            let profileBefore = try Data(contentsOf: value.configurationStore.profileURL(for: activeID))
            let target = try value.configurationStore.createBlankProfile(named: "Other")

            value.coordinator.start()
            let profileAfterHistory = try Data(contentsOf: value.configurationStore.profileURL(for: activeID))
            try equal(profileAfterHistory, profileBefore, "implicit history write rewrote the Active Profile generation")
            let persistedHistory = try value.configurationStore.load().configuration.deviceHistory
            try expect(persistedHistory.contains { $0.target == .exact(extraIdentity) }, "implicit history was not persisted globally")
            _ = try value.coordinator.activateProfile(id: target.id)
            try expect(value.coordinator.status.configuration.deviceHistory.contains { $0.target == .exact(extraIdentity) }, "Profile activation lost global history")

            let fallbackRoot = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-scoped-fallback-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: fallbackRoot) }
            let fallbackStore = ConfigurationStore(rootURL: fallbackRoot, legacyDefaults: nil)
            try fallbackStore.save(initial)
            let fallbackID = try fallbackStore.load().activeProfile.id
            let corrupt = Data("corrupt-profile-primary".utf8)
            try corrupt.write(to: fallbackStore.profileURL(for: fallbackID))
            let fallbackCoordinator = try AutomationCoordinator(
                configurationStore: fallbackStore,
                runtimeStateStore: RuntimeStateStore(rootURL: fallbackRoot, legacyDefaults: nil, bootIdentifierProvider: { "boot" }),
                adapter: FakeAdapter([display(4, extraIdentity, extraFamily, main: true)]),
                scheduler: Clock()
            )
            fallbackCoordinator.start()
            try equal(fallbackCoordinator.status.settingsGenerationSource, .primary, "global generation source changed unexpectedly")
            try equal(fallbackCoordinator.status.activeProfileGenerationSource, .lastKnownGoodBackup, "Profile fallback source was not surfaced")
            try equal(try Data(contentsOf: fallbackStore.profileURL(for: fallbackID)), corrupt, "global implicit write repaired or rewrote Profile fallback")
            let fallbackHistory = try fallbackStore.load().configuration.deviceHistory
            try expect(fallbackHistory.contains { $0.target == .exact(extraIdentity) }, "Profile fallback blocked writable global history")
        }

        runner.run("Profile lifecycle APIs and invalid targets never disturb live runtime") {
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let activeID = value.coordinator.status.activeProfile!.id
            let blank = try value.coordinator.createBlankProfile(named: "Blank")
            let copy = try value.coordinator.duplicateProfile(id: blank.id, named: "Copy")
            let renamed = try value.coordinator.renameProfile(id: copy.id, to: "Renamed")
            try equal(renamed.name, "Renamed", "rename API did not return updated Profile")
            try value.coordinator.deleteInactiveProfile(id: blank.id)
            try expect(!value.coordinator.status.profileCatalog.profiles.contains { $0.id == blank.id }, "delete API left inactive Profile in catalog")

            var missingRefused = false
            do { _ = try value.coordinator.activateProfile(id: UUID()) } catch { missingRefused = true }
            try expect(missingRefused, "missing activation target was accepted")

            try Data("invalid".utf8).write(to: value.configurationStore.profileURL(for: renamed.id))
            try Data("invalid".utf8).write(to: value.configurationStore.profileBackupURL(for: renamed.id))
            var invalidRefused = false
            do { _ = try value.coordinator.activateProfile(id: renamed.id) } catch { invalidRefused = true }
            try expect(invalidRefused, "invalid activation target was accepted")
            try equal(value.coordinator.status.activeProfile?.id, activeID, "refused target changed live Active Profile")
            try equal(try value.configurationStore.load().activeProfile.id, activeID, "refused target changed durable selector")
            try expect(value.adapter.transactions.isEmpty, "refused target reached hardware")
        }

        runner.run("compatibility save writes only changed persistence domains") {
            let fallbackRoot = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-explicit-scope-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: fallbackRoot) }
            let fallbackStore = ConfigurationStore(rootURL: fallbackRoot, legacyDefaults: nil)
            let initial = config([], automatic: false)
            try fallbackStore.save(initial)
            let fallbackID = try fallbackStore.load().activeProfile.id
            let corruptProfile = Data("corrupt-active-primary".utf8)
            try corruptProfile.write(to: fallbackStore.profileURL(for: fallbackID))
            let fallbackCoordinator = try AutomationCoordinator(
                configurationStore: fallbackStore,
                runtimeStateStore: RuntimeStateStore(rootURL: fallbackRoot, legacyDefaults: nil, bootIdentifierProvider: { "boot" }),
                adapter: FakeAdapter([]),
                scheduler: Clock()
            )
            var settingsOnly = fallbackCoordinator.status.configuration
            settingsOnly.hotKey = .init(keyCode: 9, modifiers: 456)

            _ = try fallbackCoordinator.updateConfiguration(settingsOnly, applyImmediately: false)

            let profilePrimaryAfterSettings = try Data(contentsOf: fallbackStore.profileURL(for: fallbackID))
            try equal(profilePrimaryAfterSettings, corruptProfile, "settings-only save rewrote fallback Profile primary")
            try equal(fallbackCoordinator.status.activeProfileGenerationSource, .lastKnownGoodBackup, "settings-only save repaired unrelated Profile fallback")

            let profileOnly = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true)]
            )
            defer { try? FileManager.default.removeItem(at: profileOnly.root) }
            let settingsBefore = try Data(contentsOf: profileOnly.configurationStore.configurationURL)
            var profileCandidate = profileOnly.coordinator.status.configuration
            profileCandidate.polling.intervalSeconds = 17

            _ = try profileOnly.coordinator.updateConfiguration(profileCandidate, applyImmediately: false)

            let settingsAfter = try Data(contentsOf: profileOnly.configurationStore.configurationURL)
            try equal(settingsAfter, settingsBefore, "Profile-only save rewrote Application Settings")
            try equal(try profileOnly.configurationStore.load().configuration.polling.intervalSeconds, 17, "Profile-only save did not persist target Profile")
        }

        runner.run("stale fingerprint exhaustion reports failed or partial with settled actions") {
            func toggleExtraDisplay(_ adapter: FakeAdapter) {
                if adapter.live[3] == nil {
                    adapter.add(display(3, external2, externalFamily))
                } else {
                    adapter.setState(nil, runtimeID: 3)
                }
            }

            let exhausted = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)],
                attempts: 2
            )
            defer { try? FileManager.default.removeItem(at: exhausted.root) }
            var staleTarget = try exhausted.configurationStore.createBlankProfile(named: "Always stale")
            staleTarget.rules = [makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])]
            try exhausted.configurationStore.saveProfile(staleTarget)
            exhausted.adapter.beforeTransactionObservation = toggleExtraDisplay

            let failed = try exhausted.coordinator.activateProfile(id: staleTarget.id)

            try equal(failed.hardwareOutcome, .failed, "exhausted stale plans were reported applied")
            try expect(failed.actionDiagnostics.contains { $0.code == .actionFailed && $0.message.contains("every retry") }, "stale exhaustion diagnostic missing")
            try expect(exhausted.adapter.transactions.isEmpty, "stale fingerprint reached hardware commit")

            let partial = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)],
                attempts: 3
            )
            defer { try? FileManager.default.removeItem(at: partial.root) }
            var mixedTarget = try partial.configurationStore.createBlankProfile(named: "Partial stale")
            mixedTarget.rules = [makeRule("mixed", actions: [
                .init(target: .exact(builtIn), action: .disable),
                .init(target: .exact(external1), action: .enable)
            ])]
            try partial.configurationStore.saveProfile(mixedTarget)
            partial.adapter.failedEnableIDs = [2]
            var firstCommitted = false
            partial.adapter.afterCommit = { _, _ in firstCommitted = true }
            partial.adapter.beforeTransactionObservation = { adapter in
                if firstCommitted { toggleExtraDisplay(adapter) }
            }

            let partiallyFailed = try partial.coordinator.activateProfile(id: mixedTarget.id)

            try equal(partiallyFailed.hardwareOutcome, .partiallyFailed, "settled action was lost during stale exhaustion")
            try equal(partial.adapter.transactions.count, 1, "settled disable was reapplied during stale retries")
        }

        runner.run("post-commit refresh failure preserves applied activation result") {
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)],
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            var target = try value.configurationStore.createBlankProfile(named: "Committed")
            target.rules = [makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])]
            try value.configurationStore.saveProfile(target)
            value.adapter.failCoordinatorRefreshAfterApply = true

            let result = try value.coordinator.activateProfile(id: target.id)

            try equal(result.hardwareOutcome, .applied, "final refresh failure erased confirmed hardware success")
            try expect(result.actionDiagnostics.contains { $0.message.contains("final inventory refresh failed") }, "post-commit refresh diagnostic missing")
            try equal(value.adapter.transactions.count, 1, "confirmed action was not committed")
        }

        runner.run("Active Profile save and rename repair fallback runtime state") {
            func fallbackCoordinator(named suffix: String) throws -> (URL, ConfigurationStore, AutomationCoordinator) {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-fallback-repair-\(suffix)-\(UUID().uuidString)")
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(config([], automatic: false))
                let id = try store.load().activeProfile.id
                try Data("corrupt".utf8).write(to: store.profileURL(for: id))
                let coordinator = try AutomationCoordinator(
                    configurationStore: store,
                    runtimeStateStore: RuntimeStateStore(rootURL: root, legacyDefaults: nil, bootIdentifierProvider: { "boot" }),
                    adapter: FakeAdapter([]),
                    scheduler: Clock()
                )
                return (root, store, coordinator)
            }

            let saved = try fallbackCoordinator(named: "save")
            defer { try? FileManager.default.removeItem(at: saved.0) }
            try equal(saved.2.status.activeProfileGenerationSource, .lastKnownGoodBackup, "fallback setup did not load backup")
            _ = try saved.2.saveProfile(saved.2.status.activeProfile!, applyImmediately: false)
            try equal(saved.2.status.activeProfileGenerationSource, .primary, "Active save did not repair Profile source")
            try equal(saved.2.status.configurationLoadSource, .primary, "Active save left overall fallback source")
            try expect(!saved.2.status.diagnostics.contains { $0.code == .configurationFallback }, "Active save left fallback diagnostic")
            try expect(saved.2.status.persistenceErrorDescription == nil, "Active save left fallback error")

            let renamed = try fallbackCoordinator(named: "rename")
            defer { try? FileManager.default.removeItem(at: renamed.0) }
            let renamedProfile = try renamed.2.renameProfile(id: renamed.2.status.activeProfile!.id, to: "Repaired")
            try equal(renamed.2.status.activeProfileGenerationSource, .primary, "Active rename did not repair Profile source")
            try equal(renamed.2.status.configurationLoadSource, .primary, "Active rename left overall fallback source")
            try expect(!renamed.2.status.diagnostics.contains { $0.code == .configurationFallback }, "Active rename left fallback diagnostic")
            var editable = renamedProfile
            editable.polling.intervalSeconds = 19
            _ = try renamed.2.saveProfile(editable, applyImmediately: false)
            try equal(try renamed.1.load().activeProfile.polling.intervalSeconds, 19, "rename repair left Active Profile unwritable")
        }

        runner.run("cycle-disabled activation result and catalog use persisted Profile") {
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)],
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            var target = try value.configurationStore.createBlankProfile(named: "Cycle")
            target.rules = [
                makeRule(
                    "disable external",
                    conditions: [.exactState(identity: external1, state: .online)],
                    actions: [.init(target: .exact(external1), action: .disable)]
                ),
                makeRule(
                    "enable external",
                    conditions: [.exactState(identity: external1, state: .disabledByThisAppConnectionUnknown)],
                    actions: [.init(target: .exact(external1), action: .enable)]
                )
            ]
            try value.configurationStore.saveProfile(target)

            let result = try value.coordinator.activateProfile(id: target.id)

            try expect(result.activeProfile.rules.allSatisfy { !$0.isEnabled }, "activation result exposed pre-cycle Profile")
            try expect(result.preview.profile.rules.allSatisfy { !$0.isEnabled }, "activation preview data exposed pre-cycle Profile")
            let persisted = try value.configurationStore.load().activeProfile
            try equal(result.activeProfile, persisted, "activation result diverged from persisted cycle-disabled Profile")
            try equal(value.coordinator.status.profileCatalog.profiles.first { $0.id == target.id }, persisted, "catalog was not refreshed after cycle persistence")
        }

        runner.run("last-good restore repairs inactive and Active Profiles without applying") {
            let inactive = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true)]
            )
            defer { try? FileManager.default.removeItem(at: inactive.root) }
            let activeID = inactive.coordinator.status.activeProfile!.id
            let activeConfiguration = inactive.coordinator.status.configuration
            let inactiveProfile = try inactive.coordinator.createBlankProfile(named: "Recover me")
            try Data("corrupt-inactive".utf8).write(to: inactive.configurationStore.profileURL(for: inactiveProfile.id))

            let restoredInactive = try inactive.coordinator.restoreProfileFromLastKnownGood(id: inactiveProfile.id)

            try equal(restoredInactive, inactiveProfile, "inactive restore changed backup content")
            try equal(inactive.coordinator.status.activeProfile?.id, activeID, "inactive restore changed Active selector")
            try equal(inactive.coordinator.status.configuration, activeConfiguration, "inactive restore changed live configuration")
            try expect(inactive.adapter.transactions.isEmpty, "inactive restore applied hardware")
            try equal(inactive.coordinator.status.profileCatalog.profiles.first { $0.id == inactiveProfile.id }, inactiveProfile, "inactive restore did not refresh catalog")

            let activeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-active-restore-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: activeRoot) }
            let activeStore = ConfigurationStore(rootURL: activeRoot, legacyDefaults: nil)
            try activeStore.save(config([], automatic: false))
            let fallbackProfile = try activeStore.load().activeProfile
            try Data("corrupt-active".utf8).write(to: activeStore.profileURL(for: fallbackProfile.id))
            let activeAdapter = FakeAdapter([display(1, builtIn, builtInFamily, builtIn: true, main: true)])
            let activeCoordinator = try AutomationCoordinator(
                configurationStore: activeStore,
                runtimeStateStore: RuntimeStateStore(rootURL: activeRoot, legacyDefaults: nil, bootIdentifierProvider: { "boot" }),
                adapter: activeAdapter,
                scheduler: Clock()
            )

            _ = try activeCoordinator.restoreProfileFromLastKnownGood(id: fallbackProfile.id)

            try equal(activeCoordinator.status.activeProfileGenerationSource, .primary, "Active restore left fallback Profile source")
            try equal(activeCoordinator.status.configurationLoadSource, .primary, "Active restore left overall fallback source")
            try expect(!activeCoordinator.status.diagnostics.contains { $0.code == .configurationFallback }, "Active restore left fallback diagnostic")
            try expect(activeCoordinator.status.persistenceErrorDescription == nil, "Active restore left fallback error")
            try equal(try activeStore.load().activeProfile.id, fallbackProfile.id, "Active restore changed durable selector")
            try expect(activeAdapter.transactions.isEmpty, "Active restore applied hardware")
        }

        runner.run("invalid Profile removal refreshes catalog without selector or hardware changes") {
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let activeID = value.coordinator.status.activeProfile!.id
            let invalidFileName = "remove-me.json"
            try Data("invalid".utf8).write(
                to: value.configurationStore.profilesDirectoryURL.appendingPathComponent(invalidFileName)
            )
            _ = value.coordinator.reloadProfileCatalog()
            try expect(value.coordinator.status.profileCatalog.invalidProfiles.contains { $0.fileName == invalidFileName }, "invalid setup was not cataloged")

            let status = try value.coordinator.removeInvalidProfile(fileName: invalidFileName)

            try expect(!status.profileCatalog.invalidProfiles.contains { $0.fileName == invalidFileName }, "invalid removal did not refresh catalog")
            try equal(status.activeProfile?.id, activeID, "invalid removal changed Active selector")
            try equal(try value.configurationStore.load().activeProfile.id, activeID, "invalid removal changed durable selector")
            try expect(value.adapter.transactions.isEmpty, "invalid removal applied hardware")
        }

        runner.run("catalog reload flags same-ID external Active Profile content changes") {
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let activeID = value.coordinator.status.activeProfile!.id
            let livePolling = value.coordinator.status.configuration.polling.intervalSeconds
            var externalEdit = try value.configurationStore.load().activeProfile
            externalEdit.polling.intervalSeconds = 23
            try value.configurationStore.saveProfile(externalEdit)

            let status = value.coordinator.reloadProfileCatalog()

            try equal(status.externalActiveProfileID, activeID, "same-ID external content change was not flagged")
            try equal(status.activeProfile?.id, activeID, "same-ID reload changed Active identity")
            try equal(status.configuration.polling.intervalSeconds, livePolling, "same-ID reload silently applied external Profile content")
            try expect(value.adapter.transactions.isEmpty, "same-ID reload applied hardware")
        }

        runner.run("activation preview nil observation reads fresh topology") {
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            var target = try value.configurationStore.createBlankProfile(named: "Fresh preview")
            target.rules = [makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])]
            try value.configurationStore.saveProfile(target)
            try expect(value.coordinator.status.inventory.displays.isEmpty, "preview test unexpectedly had cached inventory")

            let preview = try value.coordinator.previewProfileActivation(id: target.id, observation: nil)

            try equal(value.adapter.observationCount, 1, "nil activation preview did not make one fresh read-only observation")
            try expect(!preview.evaluation.winningActions.isEmpty, "fresh preview reused empty cached inventory")
            try expect(preview.policyFingerprint != DisplayPolicySnapshotFingerprint(snapshot: .init(displays: [])), "fresh preview returned empty cached fingerprint")
            try expect(value.adapter.transactions.isEmpty, "read-only preview applied hardware")
        }

        runner.run("guarded activation refuses topology drift before selector or hardware") {
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let oldID = value.coordinator.status.activeProfile!.id
            let target = try value.configurationStore.createBlankProfile(named: "Topology token")
            let preview = try value.coordinator.previewProfileActivation(id: target.id, observation: nil)
            value.adapter.add(display(3, external2, externalFamily))
            var refused = false

            do {
                _ = try value.coordinator.activateProfile(id: target.id, confirmedPreview: preview)
            } catch AutomationCoordinatorError.staleProfileActivationPreview {
                refused = true
            }

            try expect(refused, "guarded activation accepted changed topology")
            try equal(value.coordinator.status.activeProfile?.id, oldID, "topology-stale activation changed live selector")
            try equal(try value.configurationStore.load().activeProfile.id, oldID, "topology-stale activation changed durable selector")
            try expect(value.adapter.transactions.isEmpty, "topology-stale activation reached hardware")
        }

        runner.run("guarded activation refuses target disk drift before selector or hardware") {
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let oldID = value.coordinator.status.activeProfile!.id
            var target = try value.configurationStore.createBlankProfile(named: "Disk token")
            let preview = try value.coordinator.previewProfileActivation(id: target.id, observation: nil)
            target.polling.intervalSeconds = 27
            try value.configurationStore.saveProfile(target)
            var refused = false

            do {
                _ = try value.coordinator.activateProfile(id: target.id, confirmedPreview: preview)
            } catch AutomationCoordinatorError.staleProfileActivationPreview {
                refused = true
            }

            try expect(refused, "guarded activation accepted changed target Profile")
            try equal(value.coordinator.status.activeProfile?.id, oldID, "disk-stale activation changed live selector")
            try equal(try value.configurationStore.load().activeProfile.id, oldID, "disk-stale activation changed durable selector")
            try expect(value.adapter.transactions.isEmpty, "disk-stale activation reached hardware")
        }

        runner.run("guarded activation refuses generation-source fallback drift") {
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let oldID = value.coordinator.status.activeProfile!.id
            let target = try value.configurationStore.createBlankProfile(named: "Source token")
            let preview = try value.coordinator.previewProfileActivation(id: target.id, observation: nil)
            try equal(preview.profileSource, .primary, "source-drift setup did not preview primary")
            try Data("corrupt-primary".utf8).write(to: value.configurationStore.profileURL(for: target.id))
            var refused = false

            do {
                _ = try value.coordinator.activateProfile(id: target.id, confirmedPreview: preview)
            } catch AutomationCoordinatorError.staleProfileActivationPreview {
                refused = true
            }

            try expect(refused, "guarded activation accepted an unconfirmed backup fallback")
            try equal(value.coordinator.status.activeProfile?.id, oldID, "source-stale activation changed live selector")
            try equal(try value.configurationStore.load().activeProfile.id, oldID, "source-stale activation changed durable selector")
            try expect(value.adapter.transactions.isEmpty, "source-stale activation reached hardware")
        }

        runner.run("guarded activation stops post-selector topology and Profile drift") {
            let topology = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)]
            )
            defer { try? FileManager.default.removeItem(at: topology.root) }
            var topologyTarget = try topology.configurationStore.createBlankProfile(named: "Post selector topology")
            topologyTarget.rules = [makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])]
            try topology.configurationStore.saveProfile(topologyTarget)
            let topologyPreview = try topology.coordinator.previewProfileActivation(id: topologyTarget.id, observation: nil)
            topology.adapter.afterObservation = { adapter, count in
                if count == 2 { adapter.add(display(3, external2, externalFamily)) }
            }

            let topologyResult = try topology.coordinator.activateProfile(
                id: topologyTarget.id,
                confirmedPreview: topologyPreview
            )

            try equal(topologyResult.hardwareOutcome, .failed, "post-selector topology drift was not stale")
            try equal(try topology.configurationStore.load().activeProfile.id, topologyTarget.id, "stale hardware check rolled back selector")
            try expect(topology.adapter.transactions.isEmpty, "post-selector topology drift reached hardware")

            let profile = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)]
            )
            defer { try? FileManager.default.removeItem(at: profile.root) }
            var profileTarget = try profile.configurationStore.createBlankProfile(named: "Post selector Profile")
            profileTarget.rules = [makeRule("disable", actions: [.init(target: .exact(builtIn), action: .disable)])]
            try profile.configurationStore.saveProfile(profileTarget)
            let profilePreview = try profile.coordinator.previewProfileActivation(id: profileTarget.id, observation: nil)
            profile.adapter.afterObservation = { _, count in
                guard count == 3 else { return }
                profileTarget.polling.intervalSeconds = 29
                try? profile.configurationStore.saveProfile(profileTarget)
            }

            let profileResult = try profile.coordinator.activateProfile(
                id: profileTarget.id,
                confirmedPreview: profilePreview
            )

            try equal(profileResult.hardwareOutcome, .failed, "post-selector Profile drift was not stale")
            try equal(try profile.configurationStore.load().activeProfile.id, profileTarget.id, "Profile-stale hardware check rolled back selector")
            try expect(profile.adapter.transactions.isEmpty, "post-selector Profile drift reached hardware")
        }

        runner.run("guarded retries never introduce unconfirmed action intents") {
            let conditional = makeRule(
                "new disable",
                conditions: [.count(.init(kind: .online, scope: .external, comparison: .greaterThan, value: 1))],
                actions: [.init(target: .exact(builtIn), action: .disable)]
            )
            let confirmed = makeRule("confirmed disable", actions: [.init(target: .exact(external1), action: .disable)])
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)],
                attempts: 3
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            var target = try value.configurationStore.createBlankProfile(named: "Intent envelope")
            target.rules = [confirmed, conditional]
            try value.configurationStore.saveProfile(target)
            let preview = try value.coordinator.previewProfileActivation(id: target.id, observation: nil)
            try expect(!preview.evaluation.winningActions.contains { $0.display.runtimeID == 1 }, "unconfirmed intent existed in preview")
            value.adapter.beforeTransactionObservation = { adapter in
                adapter.add(display(3, external2, externalFamily))
                adapter.beforeTransactionObservation = nil
            }

            _ = try value.coordinator.activateProfile(id: target.id, confirmedPreview: preview)

            try equal(value.adapter.transactions.count, 1, "confirmed action did not settle after stale binding")
            try expect(value.adapter.transactions[0].allSatisfy { $0.display.runtimeID == 2 }, "retry introduced an action absent from confirmed preview")
        }

        runner.run("hotkey-only legacy migration stays rule-empty") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-hotkey-migration-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = "display-steward-hotkey-only-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(9, forKey: "hotKeyKeyCode")
            let store = ConfigurationStore(rootURL: root, legacyDefaults: defaults)
            let clock = Clock()
            let adapter = FakeAdapter([
                display(1, builtIn, builtInFamily, builtIn: true, main: true),
                display(2, external1, externalFamily)
            ])
            let coordinator = try AutomationCoordinator(
                configurationStore: store,
                runtimeStateStore: RuntimeStateStore(rootURL: root, legacyDefaults: defaults, bootIdentifierProvider: { "boot" }),
                adapter: adapter,
                scheduler: clock
            )

            coordinator.start(); clock.advance(3)

            try equal(coordinator.status.configurationLoadSource, .migratedLegacyDefaults, "legacy migration source was not retained")
            try expect(coordinator.status.configuration.rules.isEmpty, "hotkey-only migration synthesized Rules")
            let migratedProfile = try store.load().activeProfile
            try expect(migratedProfile.rules.isEmpty, "hotkey-only migration persisted synthesized Rules")
            try expect(adapter.transactions.isEmpty, "hotkey-only migration applied hidden display policy")
        }

        runner.run("Profile-only startup failure preserves writable global settings") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("display-steward-settings-only-startup-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
            var initial = config([], automatic: true)
            initial.hotKey = .init(keyCode: 8, modifiers: 456)
            initial.deviceHistory = [.init(target: .exact(absent), name: "Remembered", isBuiltIn: false)]
            try store.save(initial)
            let brokenID = try store.load().activeProfile.id
            try Data("bad-primary".utf8).write(to: store.profileURL(for: brokenID))
            try Data("bad-backup".utf8).write(to: store.profileBackupURL(for: brokenID))
            let coordinator = try AutomationCoordinator(
                configurationStore: store,
                runtimeStateStore: RuntimeStateStore(rootURL: root, legacyDefaults: nil, bootIdentifierProvider: { "boot" }),
                adapter: FakeAdapter([]),
                scheduler: Clock()
            )

            try equal(coordinator.status.configuration.hotKey, initial.hotKey, "Profile failure replaced global hotkey")
            try equal(coordinator.status.configuration.deviceHistory, initial.deviceHistory, "Profile failure replaced Display History")
            try expect(!coordinator.status.configuration.automatic.isEnabled, "Profile failure left Automation enabled")
            try expect(coordinator.status.activeProfile == nil, "unusable Active Profile was presented as live")
            try equal(coordinator.status.settingsGenerationSource, .primary, "settings writability/source was lost")

            let replacement = try store.createBlankProfile(named: "Replacement")
            _ = try coordinator.activateProfile(id: replacement.id)
            try equal(coordinator.status.configuration.hotKey, initial.hotKey, "valid activation did not reuse retained globals")
            try equal(coordinator.status.configuration.deviceHistory, initial.deviceHistory, "valid activation lost retained history")
        }

        runner.run("settings-only writes preserve external durable selector") {
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true)]
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            let liveID = value.coordinator.status.activeProfile!.id
            let external = try value.configurationStore.createBlankProfile(named: "Durable external")
            _ = try value.configurationStore.activateProfile(id: external.id)
            _ = value.coordinator.reloadProfileCatalog()
            var globalEdit = value.coordinator.status.configuration
            globalEdit.hotKey = .init(keyCode: 7, modifiers: 456)
            globalEdit.deviceHistory.append(.init(target: .exact(absent), name: "Alias", isBuiltIn: false))

            _ = try value.coordinator.updateConfiguration(globalEdit, applyImmediately: false)

            try equal(try value.configurationStore.load().activeProfile.id, external.id, "settings-only write erased external selector")
            try equal(value.coordinator.status.activeProfile?.id, liveID, "settings-only write applied external selector")
            try equal(value.coordinator.status.configuration.hotKey, globalEdit.hotKey, "settings-only hotkey was not retained live")
        }

        runner.run("activation outcomes report evaluator safety blocks") {
            let blocked = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true)],
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: blocked.root) }
            var blockedTarget = try blocked.configurationStore.createBlankProfile(named: "All blocked")
            blockedTarget.rules = [makeRule("disable last", actions: [.init(target: .exact(builtIn), action: .disable)])]
            try blocked.configurationStore.saveProfile(blockedTarget)

            let blockedResult = try blocked.coordinator.activateProfile(id: blockedTarget.id)

            try equal(blockedResult.hardwareOutcome, .blockedBySafety, "all safety-blocked work was reported not-needed")
            try expect(blockedResult.actionDiagnostics.contains { $0.code == .safetyRecovery }, "all-blocked safety diagnostic missing")
            try expect(blocked.adapter.transactions.isEmpty, "all-blocked plan reached hardware")

            let mixed = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)],
                attempts: 1
            )
            defer { try? FileManager.default.removeItem(at: mixed.root) }
            var mixedTarget = try mixed.configurationStore.createBlankProfile(named: "Partially blocked")
            mixedTarget.rules = [makeRule("disable all", actions: [
                .init(target: .exact(builtIn), action: .disable),
                .init(target: .exact(external1), action: .disable)
            ])]
            try mixed.configurationStore.saveProfile(mixedTarget)

            let mixedResult = try mixed.coordinator.activateProfile(id: mixedTarget.id)

            try equal(mixedResult.hardwareOutcome, .partiallyFailed, "mixed safety block was reported fully applied")
            try expect(mixedResult.actionDiagnostics.contains { $0.code == .safetyRecovery }, "mixed safety diagnostic missing")
            try equal(mixed.adapter.transactions.first?.map { $0.display.runtimeID }, [2], "mixed plan did not apply only unblocked action")
        }

        runner.run("explicit reload surfaces settings fallback unreadable and global drift") {
            let fallback = try fixture(config([], automatic: false), [])
            defer { try? FileManager.default.removeItem(at: fallback.root) }
            try Data("bad-settings-primary".utf8).write(to: fallback.configurationStore.configurationURL)

            let fallbackStatus = fallback.coordinator.reloadProfileCatalog()

            try equal(fallbackStatus.externalSettingsGenerationSource, .lastKnownGoodBackup, "settings fallback source was suppressed")
            try expect(fallbackStatus.externalSettingsErrorDescription != nil, "settings primary fallback error was suppressed")
            try expect(fallbackStatus.externalApplicationSettings == nil, "matching fallback settings were reported as content drift")

            try Data("bad-settings-backup".utf8).write(to: fallback.configurationStore.backupURL)
            let unreadableStatus = fallback.coordinator.reloadProfileCatalog()
            try expect(unreadableStatus.externalSettingsGenerationSource == nil, "unreadable settings retained stale source")
            try expect(unreadableStatus.externalSettingsErrorDescription != nil, "unreadable settings error was suppressed")

            let drift = try fixture(config([], automatic: false), [])
            defer { try? FileManager.default.removeItem(at: drift.root) }
            var externalSettings = try drift.configurationStore.loadApplicationSettings().settings
            externalSettings.hotKey = .init(keyCode: 6, modifiers: 456)
            externalSettings.deviceHistory.append(.init(target: .exact(absent), name: "External", isBuiltIn: false))
            try drift.configurationStore.saveApplicationSettings(externalSettings)

            let driftStatus = drift.coordinator.reloadProfileCatalog()

            try equal(driftStatus.externalApplicationSettings, externalSettings, "external global settings drift was not surfaced")
            try equal(driftStatus.externalSettingsGenerationSource, .primary, "external global settings source was wrong")
            try expect(driftStatus.externalSettingsErrorDescription == nil, "clean external settings reported an error")
            try expect(drift.adapter.transactions.isEmpty, "explicit settings reload applied hardware")
        }

        runner.run("guarded retry restores newly obsolete confirmed disable") {
            let disable = makeRule(
                "disable while active",
                conditions: [.exactState(identity: builtIn, state: .active)],
                actions: [.init(target: .exact(builtIn), action: .disable)]
            )
            let failing = makeRule(
                "failing peer",
                actions: [.init(target: .exact(external1), action: .enable)]
            )
            let value = try fixture(
                config([], automatic: false),
                [display(1, builtIn, builtInFamily, builtIn: true, main: true), display(2, external1, externalFamily)],
                attempts: 3
            )
            defer { try? FileManager.default.removeItem(at: value.root) }
            var target = try value.configurationStore.createBlankProfile(named: "Retry reconciliation")
            target.rules = [disable, failing]
            try value.configurationStore.saveProfile(target)
            let preview = try value.coordinator.previewProfileActivation(id: target.id, observation: nil)
            value.adapter.failedEnableIDs = [2]

            let result = try value.coordinator.activateProfile(id: target.id, confirmedPreview: preview)

            try equal(result.hardwareOutcome, .partiallyFailed, "peer failure erased settled disable/restore outcome")
            try expect(value.adapter.transactions.count >= 2, "retry did not execute transition reconciliation")
            try expect(value.adapter.transactions[1].contains { $0.display.runtimeID == 1 && $0.action == .enable }, "confirmed disable was stranded by intent filtering")
            let settled = try value.stateStore.load().state
            try expect(!settled.appDisabledDisplays.contains { $0.runtimeID == 1 }, "restored display retained app-owned disable evidence")
            try expect(!settled.pendingDisableDisplays.contains { $0.runtimeID == 1 }, "restored display retained pending disable evidence")
            try expect(!settled.pendingRecoveryDisplays.contains { $0.runtimeID == 1 }, "restored display retained recovery evidence")
        }

        runner.finish()
    }
}
