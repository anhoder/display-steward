import Darwin
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private struct TestRunner {
    private(set) var failures: [String] = []
    private(set) var count = 0

    mutating func run(_ name: String, _ body: () throws -> Void) {
        count += 1
        do {
            try body()
            print("PASS \(name)")
        } catch {
            failures.append("\(name): \(error)")
            print("FAIL \(name): \(error)")
        }
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("\(count) Phase 1 tests passed")
            exit(0)
        }
        print("\(failures.count) of \(count) Phase 1 tests failed")
        failures.forEach { print($0) }
        exit(1)
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw TestFailure(description: "\(message); actual=\(actual), expected=\(expected)")
    }
}

private let builtInFamily = DisplayFamily(vendorID: 100, modelID: 10)
private let externalFamily = DisplayFamily(vendorID: 200, modelID: 20)
private let builtInIdentity = StableDisplayIdentity(family: builtInFamily, serialNumber: 1)
private let externalIdentity1 = StableDisplayIdentity(family: externalFamily, serialNumber: 11)
private let externalIdentity2 = StableDisplayIdentity(family: externalFamily, serialNumber: 12)

private func id(_ suffix: String) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
}

private func display(
    _ runtimeID: UInt32?,
    identity: StableDisplayIdentity?,
    family: DisplayFamily,
    builtIn: Bool = false,
    main: Bool = false,
    state: ObservableDisplayState = .active
) -> ObservedDisplay {
    ObservedDisplay(
        runtimeID: runtimeID,
        stableIdentity: identity,
        family: family,
        isBuiltIn: builtIn,
        isMain: main,
        state: state
    )
}

private func rule(
    _ ruleID: UUID,
    priority: Int = 0,
    conditions: [RuleCondition] = [.always],
    actions: [TargetAction] = []
) -> DisplayRule {
    DisplayRule(
        id: ruleID,
        name: "Rule \(ruleID.uuidString.suffix(4))",
        isEnabled: true,
        priority: priority,
        conditions: conditions,
        actions: actions
    )
}

private func configuration(_ rules: [DisplayRule]) -> AppConfiguration {
    var result = AppConfiguration.default
    result.rules = rules
    return result
}

private func activeSnapshot() -> ObservedDisplaySnapshot {
    ObservedDisplaySnapshot(displays: [
        display(1, identity: builtInIdentity, family: builtInFamily, builtIn: true, main: true),
        display(2, identity: externalIdentity1, family: externalFamily),
        display(3, identity: externalIdentity2, family: externalFamily, state: .online)
    ])
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("display-steward-phase1-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url)
}

@main
private enum Phase1TestMain {
    static func main() {
        var runner = TestRunner()

        runner.run("count comparisons, scopes, and AND conditions") {
            let expectedIDs = [
                id("000000000001"), id("000000000002"), id("000000000003"),
                id("000000000004"), id("000000000005"), id("000000000006")
            ]
            let rules = [
                rule(expectedIDs[0], conditions: [.count(.init(kind: .online, scope: .external, comparison: .equal, value: 2))]),
                rule(expectedIDs[1], conditions: [.count(.init(kind: .online, scope: .external, comparison: .greaterThan, value: 1))]),
                rule(expectedIDs[2], conditions: [.count(.init(kind: .active, scope: .all, comparison: .greaterThanOrEqual, value: 2))]),
                rule(expectedIDs[3], conditions: [.count(.init(kind: .active, scope: .external, comparison: .lessThan, value: 2))]),
                rule(expectedIDs[4], conditions: [.count(.init(kind: .online, scope: .all, comparison: .lessThanOrEqual, value: 3))]),
                rule(expectedIDs[5], conditions: [
                    .count(.init(kind: .online, scope: .external, comparison: .equal, value: 2)),
                    .exactState(identity: builtInIdentity, state: .online)
                ]),
                rule(id("000000000007"), conditions: [
                    .count(.init(kind: .online, scope: .external, comparison: .equal, value: 2)),
                    .exactState(identity: builtInIdentity, state: .disabledByThisAppConnectionUnknown)
                ])
            ]
            let plan = RuleEvaluator().evaluate(configuration: configuration(rules), snapshot: activeSnapshot())
            try expectEqual(plan.matchedRuleIDs, expectedIDs, "comparison or AND semantics changed")
        }

        runner.run("exact and family matching expand deterministically") {
            let exactRuleID = id("000000000011")
            let familyRuleID = id("000000000012")
            let missingRuleID = id("000000000013")
            let missingIdentity = StableDisplayIdentity(family: externalFamily, serialNumber: 99)
            let rules = [
                rule(exactRuleID, priority: 20, conditions: [.exactState(identity: externalIdentity1, state: .online)], actions: [
                    .init(target: .exact(externalIdentity1), action: .enable)
                ]),
                rule(familyRuleID, priority: 10, conditions: [.familyState(family: externalFamily, state: .online)], actions: [
                    .init(target: .family(externalFamily), action: .disable)
                ]),
                rule(missingRuleID, actions: [.init(target: .exact(missingIdentity), action: .enable)])
            ]
            let plan = RuleEvaluator().evaluate(configuration: configuration(rules), snapshot: activeSnapshot())
            try expectEqual(plan.matchedRuleIDs, [exactRuleID, familyRuleID, missingRuleID], "state matching should include active as online")
            try expectEqual(plan.winningActions.count, 2, "family target should affect every observed family member")
            let actionByID = Dictionary(uniqueKeysWithValues: plan.winningActions.map { ($0.display.runtimeID, $0.action) })
            try expectEqual(actionByID[2], .enable, "higher-priority exact action should win")
            try expectEqual(actionByID[3], .disable, "family action should cover the second display")
            try expectEqual(plan.unavailableTargets.map(\.ruleID), [missingRuleID], "absent exact target should not claim state")
        }

        runner.run("priority merge, conflicts, and no-action fallthrough") {
            let low = id("000000000021")
            let highNoAction = id("000000000022")
            let high = id("000000000023")
            let plan = RuleEvaluator().evaluate(
                configuration: configuration([
                    rule(low, priority: 10, actions: [.init(target: .exact(externalIdentity1), action: .disable)]),
                    rule(highNoAction, priority: 100, actions: [.init(target: .exact(externalIdentity1), action: .noAction)]),
                    rule(high, priority: 20, actions: [.init(target: .exact(externalIdentity1), action: .enable)])
                ]),
                snapshot: activeSnapshot()
            )
            let external = try unwrap(plan.winningActions.first { $0.display.runtimeID == 2 }, "missing merged action")
            try expectEqual(external.action, .enable, "highest-priority explicit action should win")
            try expectEqual(external.ruleIDs, [high], "no-action must not claim the target")

            let conflictPlan = RuleEvaluator().evaluate(
                configuration: configuration([
                    rule(low, priority: 40, actions: [.init(target: .exact(externalIdentity1), action: .disable)]),
                    rule(high, priority: 40, actions: [.init(target: .exact(externalIdentity1), action: .enable)])
                ]),
                snapshot: activeSnapshot()
            )
            try expectEqual(conflictPlan.conflicts.count, 1, "equal-priority opposite actions must conflict")
            try expect(!conflictPlan.winningActions.contains { $0.display.runtimeID == 2 }, "a conflict must not produce an arbitrary winner")
        }

        runner.run("hard safety applies priority, main, built-in, and identity order") {
            let equalDisable = rule(id("000000000031"), priority: 50, actions: [
                .init(target: .exact(builtInIdentity), action: .disable),
                .init(target: .exact(externalIdentity1), action: .disable)
            ])
            let externalMainPlan = RuleEvaluator().evaluate(
                configuration: configuration([equalDisable]),
                snapshot: ObservedDisplaySnapshot(displays: [
                    display(1, identity: builtInIdentity, family: builtInFamily, builtIn: true),
                    display(2, identity: externalIdentity1, family: externalFamily, main: true)
                ])
            )
            try expectEqual(externalMainPlan.safetyBlocks[0].display?.runtimeID, 2, "current external main must outrank built-in at equal priority")

            let builtInPlan = RuleEvaluator().evaluate(
                configuration: configuration([equalDisable]),
                snapshot: ObservedDisplaySnapshot(displays: [
                    display(1, identity: builtInIdentity, family: builtInFamily, builtIn: true),
                    display(2, identity: externalIdentity1, family: externalFamily)
                ])
            )
            try expectEqual(builtInPlan.safetyBlocks[0].display?.runtimeID, 1, "built-in must win when equal-priority displays have no current main")

            let priorityPlan = RuleEvaluator().evaluate(
                configuration: configuration([
                    rule(id("000000000032"), priority: 100, actions: [
                        .init(target: .exact(builtInIdentity), action: .disable)
                    ]),
                    rule(id("000000000033"), priority: 10, actions: [
                        .init(target: .exact(externalIdentity1), action: .disable)
                    ])
                ]),
                snapshot: ObservedDisplaySnapshot(displays: [
                    display(1, identity: builtInIdentity, family: builtInFamily, builtIn: true, main: true),
                    display(2, identity: externalIdentity1, family: externalFamily)
                ])
            )
            try expectEqual(priorityPlan.safetyBlocks[0].display?.runtimeID, 2, "lower-priority disable must yield before main/built-in tie-breaks")
            try expectEqual(priorityPlan.winningActions.map(\.display.runtimeID), [1], "higher-priority disable should remain planned")

            let identityPlan = RuleEvaluator().evaluate(
                configuration: configuration([
                    rule(id("000000000034"), priority: 50, actions: [
                        .init(target: .family(externalFamily), action: .disable)
                    ])
                ]),
                snapshot: ObservedDisplaySnapshot(displays: [
                    display(9, identity: externalIdentity2, family: externalFamily),
                    display(10, identity: externalIdentity1, family: externalFamily)
                ])
            )
            try expectEqual(identityPlan.safetyBlocks[0].display?.runtimeID, 10, "stable identity must break a full priority/main/built-in tie")
            try expectEqual(identityPlan.safetyBlocks[0].display?.stableIdentity, externalIdentity1, "lowest stable identity should be retained")
        }

        runner.run("sleep state defers every automatic action") {
            let plan = RuleEvaluator().evaluate(
                configuration: configuration([
                    rule(id("000000000041"), actions: [.init(target: .exact(builtInIdentity), action: .disable)])
                ]),
                snapshot: ObservedDisplaySnapshot(displays: [
                    display(1, identity: builtInIdentity, family: builtInFamily, builtIn: true, state: .online)
                ])
            )
            try expect(plan.winningActions.isEmpty, "sleep deferral must return no actions")
            try expectEqual(plan.safetyBlocks.map(\.reason), [.onlineDisplaysHaveNoActiveDisplay], "sleep deferral reason changed")
        }

        runner.run("cycle analysis distinguishes deferred, invalid, and indeterminate") {
            let automaticRule = rule(id("000000000042"), actions: [
                .init(target: .exact(builtInIdentity), action: .disable)
            ])
            let sleepingSnapshot = ObservedDisplaySnapshot(displays: [
                display(1, identity: builtInIdentity, family: builtInFamily, builtIn: true, state: .online)
            ])
            let deferred = RuleCycleAnalyzer().analyze(
                configuration: configuration([automaticRule]),
                initialSnapshot: sleepingSnapshot
            )
            try expectEqual(deferred.status, .deferred, "sleep deferral must not be labeled convergence")

            let zeroIDSnapshot = ObservedDisplaySnapshot(displays: [
                display(0, identity: builtInIdentity, family: builtInFamily, builtIn: true, main: true)
            ])
            let invalidPlan = RuleEvaluator().evaluate(
                configuration: configuration([automaticRule]),
                snapshot: zeroIDSnapshot
            )
            try expect(invalidPlan.diagnostics.contains { $0.code == .invalidSnapshot }, "runtime display ID zero must invalidate a snapshot")
            let invalid = RuleCycleAnalyzer().analyze(
                configuration: configuration([automaticRule]),
                initialSnapshot: zeroIDSnapshot
            )
            try expectEqual(invalid.status, .invalidInput, "invalid evaluation must not be labeled convergence")

            let conflictConfiguration = configuration([
                rule(id("000000000043"), priority: 20, actions: [
                    .init(target: .exact(externalIdentity1), action: .enable)
                ]),
                rule(id("000000000044"), priority: 20, actions: [
                    .init(target: .exact(externalIdentity1), action: .disable)
                ])
            ])
            let indeterminate = RuleCycleAnalyzer().analyze(
                configuration: conflictConfiguration,
                initialSnapshot: activeSnapshot()
            )
            try expectEqual(indeterminate.status, .indeterminate, "conflicted evaluation must not be labeled convergence")
        }

        runner.run("enable simulation preserves active and online states") {
            let enableRule = rule(id("000000000045"), actions: [
                .init(target: .exact(externalIdentity1), action: .enable)
            ])
            let active = RuleCycleAnalyzer().analyze(
                configuration: configuration([enableRule]),
                initialSnapshot: activeSnapshot()
            )
            try expectEqual(active.status, .converged, "already-active enable should converge")
            try expectEqual(active.stateSequence.count, 1, "enable must not downgrade active to online")

            let online = RuleCycleAnalyzer().analyze(
                configuration: configuration([enableRule]),
                initialSnapshot: ObservedDisplaySnapshot(displays: [
                    display(1, identity: builtInIdentity, family: builtInFamily, builtIn: true, main: true),
                    display(2, identity: externalIdentity1, family: externalFamily, state: .online)
                ])
            )
            try expectEqual(online.status, .converged, "already-online enable should converge")
            try expectEqual(online.stateSequence.count, 1, "enable must preserve online state")
        }

        runner.run("bounded simulation detects a two-state cycle") {
            let disableRuleID = id("000000000051")
            let enableRuleID = id("000000000052")
            let config = configuration([
                rule(disableRuleID, conditions: [.exactState(identity: externalIdentity1, state: .online)], actions: [
                    .init(target: .exact(externalIdentity1), action: .disable)
                ]),
                rule(enableRuleID, conditions: [.exactState(identity: externalIdentity1, state: .disabledByThisAppConnectionUnknown)], actions: [
                    .init(target: .exact(externalIdentity1), action: .enable)
                ])
            ])
            let analysis = RuleCycleAnalyzer().analyze(
                configuration: config,
                initialSnapshot: ObservedDisplaySnapshot(displays: [
                    display(1, identity: builtInIdentity, family: builtInFamily, builtIn: true, main: true),
                    display(2, identity: externalIdentity1, family: externalFamily)
                ]),
                maximumTransitions: 4
            )
            try expectEqual(analysis.status, .cycleDetected, "cycle should be detected before the bound")
            try expectEqual(analysis.involvedRuleIDs, [disableRuleID, enableRuleID], "cycle should identify both transition rules")
            try expectEqual(analysis.stateSequence.count, 3, "sequence should include repeated closing state")
            try expectEqual(analysis.stateSequence.first, analysis.stateSequence.last, "cycle sequence must close")
        }

        runner.run("configuration JSON round-trips through injected root") {
            try withTemporaryDirectory { root in
                let config = configuration([
                    rule(id("000000000061"), priority: 7, actions: [.init(target: .exact(builtInIdentity), action: .enable)])
                ])
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(config)
                let loaded = try store.load()
                try expectEqual(loaded.configuration, config, "saved configuration did not round-trip")
                try expectEqual(loaded.source, .primary, "valid primary should be preferred")
                try expect(FileManager.default.fileExists(atPath: store.backupURL.path), "save should create backup")
            }
        }

        runner.run("corrupt primary falls back without silent overwrite") {
            try withTemporaryDirectory { root in
                var config = AppConfiguration.default
                config.polling.intervalSeconds = 17
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(config)
                let corrupt = Data("not-json".utf8)
                try corrupt.write(to: store.configurationURL)
                let loaded = try store.load()
                try expectEqual(loaded.configuration, config, "backup should retain last valid configuration")
                try expectEqual(loaded.source, .lastKnownGoodBackup, "fallback source should be explicit")
                try expect(loaded.primaryErrorDescription != nil, "fallback should expose primary error")
                try expectEqual(try Data(contentsOf: store.configurationURL), corrupt, "load must not overwrite corrupt primary")
            }
        }

        runner.run("semantic-invalid primary falls back and invalid save preserves generation") {
            try withTemporaryDirectory { root in
                var valid = AppConfiguration.default
                valid.polling.intervalSeconds = 23
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(valid)

                var unsupported = valid
                unsupported.schemaVersion = AppConfiguration.currentSchemaVersion + 1
                let unsupportedData = try JSONEncoder().encode(unsupported)
                try unsupportedData.write(to: store.configurationURL)
                let fallback = try store.load()
                try expectEqual(fallback.source, .lastKnownGoodBackup, "decodable unsupported schema must use backup")
                try expectEqual(fallback.configuration, valid, "semantic-invalid primary must not escape validation")
                try expectEqual(try Data(contentsOf: store.configurationURL), unsupportedData, "fallback must not rewrite semantic-invalid primary")
            }

            try withTemporaryDirectory { root in
                var valid = AppConfiguration.default
                valid.polling.intervalSeconds = 31
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(valid)
                let primaryBefore = try Data(contentsOf: store.configurationURL)
                let backupBefore = try Data(contentsOf: store.backupURL)

                var invalid = valid
                invalid.polling.intervalSeconds = 0
                var rejected = false
                do {
                    try store.save(invalid)
                } catch {
                    rejected = true
                }
                try expect(rejected, "semantic-invalid configuration save must fail")
                try expectEqual(try Data(contentsOf: store.configurationURL), primaryBefore, "invalid save must preserve primary generation")
                try expectEqual(try Data(contentsOf: store.backupURL), backupBefore, "invalid save must preserve backup generation")
            }
        }

        runner.run("legacy defaults migrate once without runtime display IDs") {
            try withTemporaryDirectory { root in
                let suite = "display-steward-phase1-\(UUID().uuidString)"
                let defaults = try unwrap(UserDefaults(suiteName: suite), "could not create isolated defaults suite")
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.set(false, forKey: "automaticDisplayPolicy")
                defaults.set(false, forKey: "pollingEnabled")
                defaults.set(9.5, forKey: "pollingInterval")
                defaults.set(7, forKey: "hotKeyKeyCode")
                defaults.set(1234, forKey: "hotKeyModifiers")
                defaults.set(Int(builtInFamily.vendorID), forKey: "lastBuiltinVendor")
                defaults.set(Int(builtInFamily.modelID), forKey: "lastBuiltinModel")
                defaults.set(Int(builtInIdentity.serialNumber), forKey: "lastBuiltinSerial")
                defaults.set(987654, forKey: "lastBuiltinDisplayID")

                let store = ConfigurationStore(rootURL: root, legacyDefaults: defaults)
                let migrated = try store.loadOrMigrate()
                try expectEqual(migrated.source, .migratedLegacyDefaults, "legacy input should be identified")
                try expectEqual(migrated.configuration.automatic.isEnabled, false, "automatic preference was lost")
                try expectEqual(migrated.configuration.polling, .init(isEnabled: false, intervalSeconds: 9.5), "polling preferences were lost")
                try expectEqual(migrated.configuration.hotKey, .init(keyCode: 7, modifiers: 1234), "hotkey preference was lost")
                try expectEqual(migrated.configuration.rules.count, 2, "reliable identity should produce legacy-equivalent rules")
                try expectEqual(migrated.configuration.deviceHistory, [
                    .init(target: .exact(builtInIdentity), name: "Built-in Display", isBuiltIn: true)
                ], "device history should persist hardware identity only")

                defaults.set(true, forKey: "automaticDisplayPolicy")
                let secondLoad = try store.loadOrMigrate()
                try expectEqual(secondLoad.source, .primary, "existing JSON must prevent second import")
                try expectEqual(secondLoad.configuration.automatic.isEnabled, false, "JSON must remain sole source")
            }
        }

        runner.run("stale boot runtime state is downgraded without trusting IDs") {
            try withTemporaryDirectory { root in
                let oldStore = RuntimeStateStore(rootURL: root, bootIdentifierProvider: { "boot-old" })
                let oldState = RuntimeState(
                    schemaVersion: RuntimeState.currentSchemaVersion,
                    bootIdentifier: "boot-old",
                    appDisabledDisplays: [.init(runtimeID: 44, stableIdentity: externalIdentity1, family: externalFamily)],
                    legacyBuiltInRecovery: .init(runtimeID: 1, stableIdentity: builtInIdentity, family: builtInFamily),
                    failureSuppressions: [.init(
                        target: .exact(externalIdentity1),
                        action: .disable,
                        consecutiveFailureCount: 2,
                        suppressedUntil: Date(timeIntervalSince1970: 1000),
                        lastError: "failure"
                    )]
                )
                try oldStore.save(oldState)

                let newStore = RuntimeStateStore(rootURL: root, bootIdentifierProvider: { "boot-new" })
                let loaded = try newStore.load()
                try expect(loaded.discardedStaleBootState, "boot mismatch should be surfaced")
                try expectEqual(loaded.state, .empty(bootIdentifier: "boot-new"), "stale boot-scoped fields must be cleared")
                let persisted = try JSONDecoder().decode(RuntimeState.self, from: Data(contentsOf: newStore.runtimeStateURL))
                try expectEqual(persisted.bootIdentifier, "boot-old", "stale-state load must not silently rewrite disk")
            }
        }

        runner.finish()
    }
}

private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw TestFailure(description: message) }
    return value
}
