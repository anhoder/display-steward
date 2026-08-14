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
        return .init(displays: result)
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
        return .init(
            before: before,
            after: try observe(configuration: configuration, runtimeState: runtimeState),
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
    return .init(root: root, stateStore: stateStore, adapter: adapter, clock: clock, coordinator: coordinator)
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

        runner.finish()
    }
}
