import Darwin
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}


private struct TestConfigurationMigrationState: Codable {
    var schemaVersion: Int
    var configuration: AppConfiguration
    var source: PersistenceGenerationSource
    var resultSource: ConfigurationLoadSource
    var settingsPrimaryData: Data?
    var settingsBackupData: Data?
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

private func expectThrows(_ message: String, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch {
        return
    }
    throw TestFailure(description: message)
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

        runner.run("Profile and Application Settings schemas round-trip and validate identity") {
            let profileID = id("000000000061")
            let settings = ApplicationSettings(
                schemaVersion: ApplicationSettings.currentSchemaVersion,
                activeProfileID: profileID,
                hotKey: .default,
                deviceHistory: [.init(target: .exact(builtInIdentity), name: "Built-in", isBuiltIn: true)]
            )
            let profile = DisplayProfile(
                schemaVersion: DisplayProfile.currentSchemaVersion,
                id: profileID,
                name: "Desk",
                automatic: .default,
                polling: .default,
                rules: [rule(id("000000000062"))]
            )
            try settings.validate()
            try profile.validate()
            try expectEqual(
                try JSONDecoder().decode(ApplicationSettings.self, from: JSONEncoder().encode(settings)),
                settings,
                "Application Settings schema did not round-trip"
            )
            try expectEqual(
                try JSONDecoder().decode(DisplayProfile.self, from: JSONEncoder().encode(profile)),
                profile,
                "Profile schema did not round-trip"
            )
            let assembled = AppConfiguration(settings: settings, profile: profile)
            try expectEqual(assembled.rules, profile.rules, "assembled runtime view lost Profile Rules")
            try expectEqual(assembled.deviceHistory, settings.deviceHistory, "assembled runtime view lost global history")

            let blank = DisplayProfile.blank(name: "Blank")
            try expect(!blank.automatic.isEnabled, "new blank Profile must start with Automation off")
            try expect(!blank.polling.isEnabled, "new blank Profile must start with polling off")
            try expect(blank.rules.isEmpty, "new blank Profile must not synthesize Rules")
            var invalidIdentity = blank
            invalidIdentity.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            try expectThrows("zero Profile identity must fail validation") { try invalidIdentity.validate() }
            var invalidName = blank
            invalidName.name = " \n "
            try expectThrows("empty Profile name must fail validation") { try invalidName.validate() }
        }

        runner.run("assembled configuration persists through separate canonical boundaries") {
            try withTemporaryDirectory { root in
                var config = configuration([
                    rule(id("000000000063"), priority: 7, actions: [
                        .init(target: .exact(builtInIdentity), action: .enable)
                    ])
                ])
                config.hotKey = .init(keyCode: 7, modifiers: 1234)
                config.deviceHistory = [.init(target: .exact(builtInIdentity), name: "Built-in", isBuiltIn: true)]
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(config)

                let settings = try JSONDecoder().decode(
                    ApplicationSettings.self,
                    from: Data(contentsOf: store.configurationURL)
                )
                let profile = try JSONDecoder().decode(
                    DisplayProfile.self,
                    from: Data(contentsOf: store.profileURL(for: settings.activeProfileID))
                )
                try expectEqual(settings.hotKey, config.hotKey, "hotkey was not persisted globally")
                try expectEqual(settings.deviceHistory, config.deviceHistory, "history was not persisted globally")
                try expectEqual(profile.rules, config.rules, "Rules were not persisted in the Profile")
                try expect(FileManager.default.fileExists(atPath: store.backupURL.path), "global backup is missing")
                try expect(
                    FileManager.default.fileExists(atPath: store.profileBackupURL(for: profile.id).path),
                    "Profile backup is missing"
                )
                let loaded = try store.load()
                try expectEqual(loaded.configuration, config, "assembled configuration did not round-trip")
                try expectEqual(loaded.activeProfile.id, profile.id, "active Profile metadata was lost")
                try expectEqual(loaded.source, .primary, "valid canonical generations should be preferred")
            }
        }

        runner.run("global and Profile fallback generations are independent and non-repairing") {
            try withTemporaryDirectory { root in
                var config = AppConfiguration.default
                config.polling.intervalSeconds = 17
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(config)
                let activeID = try store.load().activeProfile.id

                let corruptGlobal = Data("not-global-json".utf8)
                try corruptGlobal.write(to: store.configurationURL)
                let globalFallback = try store.load()
                try expectEqual(globalFallback.settingsSource, .lastKnownGoodBackup, "global fallback source was hidden")
                try expectEqual(globalFallback.profileSource, .primary, "global corruption must not force Profile fallback")
                try expectEqual(try Data(contentsOf: store.configurationURL), corruptGlobal, "global fallback repaired evidence")

                try Data(contentsOf: store.backupURL).write(to: store.configurationURL)
                var invalidProfile = try store.loadProfile(id: activeID).profile
                invalidProfile.polling.intervalSeconds = 0
                let invalidData = try JSONEncoder().encode(invalidProfile)
                try invalidData.write(to: store.profileURL(for: activeID))
                let profileFallback = try store.load()
                try expectEqual(profileFallback.settingsSource, .primary, "Profile corruption must not force global fallback")
                try expectEqual(profileFallback.profileSource, .lastKnownGoodBackup, "Profile fallback source was hidden")
                try expectEqual(profileFallback.configuration, config, "Profile backup changed assembled behavior")
                try expectEqual(
                    try Data(contentsOf: store.profileURL(for: activeID)),
                    invalidData,
                    "Profile fallback silently repaired the canonical file"
                )
            }
        }

        runner.run("invalid save preserves both global and Profile generations") {
            try withTemporaryDirectory { root in
                var valid = AppConfiguration.default
                valid.polling.intervalSeconds = 31
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(valid)
                let activeID = try store.load().activeProfile.id
                let globalPrimary = try Data(contentsOf: store.configurationURL)
                let globalBackup = try Data(contentsOf: store.backupURL)
                let profilePrimary = try Data(contentsOf: store.profileURL(for: activeID))
                let profileBackup = try Data(contentsOf: store.profileBackupURL(for: activeID))

                var invalid = valid
                invalid.polling.intervalSeconds = 0
                try expectThrows("semantic-invalid assembled save must fail") { try store.save(invalid) }
                try expectEqual(try Data(contentsOf: store.configurationURL), globalPrimary, "invalid save changed global primary")
                try expectEqual(try Data(contentsOf: store.backupURL), globalBackup, "invalid save changed global backup")
                try expectEqual(try Data(contentsOf: store.profileURL(for: activeID)), profilePrimary, "invalid save changed Profile primary")
                try expectEqual(try Data(contentsOf: store.profileBackupURL(for: activeID)), profileBackup, "invalid save changed Profile backup")
            }
        }

        runner.run("catalog surfaces invalid and duplicate external files") {
            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                let duplicateIDFile = id("000000000064")
                try JSONEncoder().encode(active).write(to: store.profileURL(for: duplicateIDFile))

                var duplicateName = active
                duplicateName.id = id("000000000065")
                duplicateName.name = active.name.uppercased()
                try JSONEncoder().encode(duplicateName).write(to: store.profileURL(for: duplicateName.id))
                try Data("invalid-profile".utf8).write(to: store.profileURL(for: id("000000000066")))

                let catalog = store.catalog()
                try expect(catalog.invalidProfiles.count >= 3, "invalid external Profile files were hidden")
                try expect(
                    catalog.invalidProfiles.contains { $0.errorDescription.contains("duplicate Profile ID") },
                    "duplicate Profile IDs were not surfaced"
                )
                try expect(
                    catalog.invalidProfiles.contains { $0.errorDescription.contains("duplicate Profile name") },
                    "case-insensitive duplicate Profile names were not surfaced"
                )
                try expect(
                    catalog.invalidProfiles.contains { $0.fileName.contains("000000000066") },
                    "invalid JSON file was not surfaced"
                )
            }
        }

        runner.run("Profile CRUD enforces defaults, identity regeneration, activation, and stable ordering") {
            try withTemporaryDirectory { root in
                let originalRuleID = id("000000000067")
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(configuration([rule(originalRuleID)]))
                let original = try store.load().activeProfile
                let zeta = try store.createBlankProfile(named: "zeta")
                let alpha = try store.createBlankProfile(named: "Alpha")
                _ = try store.createBlankProfile(named: "beta")
                try expect(!zeta.automatic.isEnabled && !zeta.polling.isEnabled && zeta.rules.isEmpty, "blank lifecycle defaults changed")
                try expectEqual(
                    Array(store.catalog().profiles.map(\.name).prefix(3)),
                    ["Alpha", "beta", "zeta"],
                    "Profile list order is not stable and case-insensitive"
                )

                let duplicate = try store.duplicateProfile(id: original.id, named: "Copy")
                try expect(duplicate.id != original.id, "duplication reused Profile identity")
                try expectEqual(duplicate.rules.count, original.rules.count, "duplication lost Rules")
                try expect(
                    Set(duplicate.rules.map(\.id)).isDisjoint(with: Set(original.rules.map(\.id))),
                    "duplication reused Rule identities"
                )
                let renamed = try store.renameProfile(id: alpha.id, to: "Gamma")
                try expectEqual(renamed.name, "Gamma", "rename did not persist")
                try expectThrows("case-insensitive duplicate name must be rejected") {
                    _ = try store.createBlankProfile(named: "gAmMa")
                }
                try expectThrows("Active Profile deletion must be rejected") {
                    try store.deleteProfile(id: original.id)
                }

                _ = try store.activateProfile(id: duplicate.id)
                try expectEqual(try store.reloadFromDisk().activeProfile.id, duplicate.id, "active identity did not persist")
                try store.deleteProfile(id: original.id)
                try expect(!store.catalog().profiles.contains { $0.id == original.id }, "inactive deletion left a catalog Profile")
            }
        }

        runner.run("missing active Profile never falls back to another Profile") {
            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let original = try store.load().activeProfile
                var settings = try JSONDecoder().decode(
                    ApplicationSettings.self,
                    from: Data(contentsOf: store.configurationURL)
                )
                settings.activeProfileID = id("000000000068")
                let data = try JSONEncoder().encode(settings)
                try data.write(to: store.configurationURL)
                try data.write(to: store.backupURL)
                try expectThrows("missing active identity selected an arbitrary Profile") { _ = try store.load() }
                try expectThrows("last remaining Profile deletion must be rejected") {
                    try store.deleteProfile(id: original.id)
                }
            }
        }

        runner.run("monolithic configuration migration is ordinary and restart-safe") {
            try withTemporaryDirectory { root in
                var legacy = AppConfiguration.default
                legacy.automatic.isEnabled = false
                legacy.polling = .init(isEnabled: false, intervalSeconds: 9.5)
                legacy.hotKey = .init(keyCode: 7, modifiers: 1234)
                legacy.deviceHistory = [.init(target: .exact(builtInIdentity), name: "Built-in", isBuiltIn: true)]
                legacy.rules = [rule(id("000000000069"))]
                let legacyData = try JSONEncoder().encode(legacy)
                try legacyData.write(to: root.appendingPathComponent("config.json"))
                try legacyData.write(to: root.appendingPathComponent("config.last-good.json"))

                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                let migrated = try store.loadOrMigrate()
                try expectEqual(migrated.source, .migratedMonolithicConfiguration, "monolithic migration was not surfaced")
                try expectEqual(migrated.configuration, legacy, "migration changed existing behavior")
                try expectEqual(migrated.activeProfile.id, ConfigurationStore.migratedDefaultProfileID, "migration identity is not restart-stable")
                try expectEqual(migrated.activeProfile.name, "默认", "migration did not create an ordinary default Profile")
                let settings = try JSONDecoder().decode(ApplicationSettings.self, from: Data(contentsOf: store.configurationURL))
                try expectEqual(settings.hotKey, legacy.hotKey, "migration did not make hotkey global")
                try expectEqual(settings.deviceHistory, legacy.deviceHistory, "migration did not make history global")
                let restarted = try store.loadOrMigrate()
                try expectEqual(restarted.source, .primary, "completed migration was repeated")
                try expectEqual(restarted.configuration, legacy, "restart changed migrated behavior")
            }

            try withTemporaryDirectory { root in
                var legacy = AppConfiguration.default
                legacy.polling.intervalSeconds = 44
                let legacyData = try JSONEncoder().encode(legacy)
                try legacyData.write(to: root.appendingPathComponent("config.json"))
                try legacyData.write(to: root.appendingPathComponent("config.last-good.json"))

                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try FileManager.default.createDirectory(
                    at: store.profileBackupsDirectoryURL,
                    withIntermediateDirectories: true
                )
                let partialProfile = legacy.displayProfile(
                    id: ConfigurationStore.migratedDefaultProfileID,
                    name: "默认"
                )
                try JSONEncoder().encode(partialProfile).write(
                    to: store.profileBackupURL(for: partialProfile.id)
                )
                let marker = TestConfigurationMigrationState(
                    schemaVersion: 1,
                    configuration: legacy,
                    source: .primary,
                    resultSource: .migratedMonolithicConfiguration,
                    settingsPrimaryData: legacyData,
                    settingsBackupData: legacyData
                )
                try JSONEncoder().encode(marker).write(to: store.migrationStateURL)

                let resumed = try store.loadOrMigrate()
                try expectEqual(resumed.configuration, legacy, "interrupted migration did not resume from Profile backup")
                try expect(
                    FileManager.default.fileExists(atPath: store.profileURL(for: partialProfile.id).path),
                    "resumed migration did not complete the Profile canonical generation"
                )
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

        runner.run("empty root creates a disabled blank default Profile") {
            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                let created = try store.loadOrMigrate()
                try expectEqual(created.source, .createdBlankProfile, "fresh blank creation source was hidden")
                try expect(!created.configuration.automatic.isEnabled, "fresh root enabled Automation")
                try expect(!created.configuration.polling.isEnabled, "fresh root enabled polling")
                try expect(created.configuration.rules.isEmpty, "fresh root synthesized Rules")
                try expectEqual(created.activeProfile.name, "默认", "fresh root did not create 默认")
            }
        }

        runner.run("fresh and UserDefaults Profile-only migration prefixes resume") {
            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                let profile = DisplayProfile.blank(
                    id: ConfigurationStore.migratedDefaultProfileID,
                    name: "默认"
                )
                let settings = ApplicationSettings(
                    schemaVersion: ApplicationSettings.currentSchemaVersion,
                    activeProfileID: profile.id,
                    hotKey: .default,
                    deviceHistory: []
                )
                let configuration = AppConfiguration(settings: settings, profile: profile)
                let marker = TestConfigurationMigrationState(
                    schemaVersion: 1,
                    configuration: configuration,
                    source: .primary,
                    resultSource: .createdBlankProfile,
                    settingsPrimaryData: nil,
                    settingsBackupData: nil
                )
                try JSONEncoder().encode(marker).write(to: store.migrationStateURL)
                try FileManager.default.createDirectory(
                    at: store.profileBackupsDirectoryURL,
                    withIntermediateDirectories: true
                )
                try JSONEncoder().encode(profile).write(to: store.profileBackupURL(for: profile.id))

                let resumed = try store.loadOrMigrate()
                try expectEqual(resumed.source, .createdBlankProfile, "fresh Profile-only prefix did not resume")
                try expect(!FileManager.default.fileExists(atPath: store.migrationStateURL.path), "fresh migration marker was not retired")
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                var configuration = AppConfiguration.default
                configuration.automatic.isEnabled = false
                configuration.hotKey = .init(keyCode: 9, modifiers: 456)
                let profile = configuration.displayProfile(
                    id: ConfigurationStore.migratedDefaultProfileID,
                    name: "默认"
                )
                let marker = TestConfigurationMigrationState(
                    schemaVersion: 1,
                    configuration: configuration,
                    source: .primary,
                    resultSource: .migratedLegacyDefaults,
                    settingsPrimaryData: nil,
                    settingsBackupData: nil
                )
                try JSONEncoder().encode(marker).write(to: store.migrationStateURL)
                try FileManager.default.createDirectory(
                    at: store.profilesDirectoryURL,
                    withIntermediateDirectories: true
                )
                try JSONEncoder().encode(profile).write(to: store.profileURL(for: profile.id))

                let resumed = try store.loadOrMigrate()
                try expectEqual(resumed.source, .migratedLegacyDefaults, "UserDefaults Profile-only prefix did not resume")
                try expectEqual(resumed.configuration.hotKey, configuration.hotKey, "resumed UserDefaults values changed")
            }
        }

        runner.run("settings-backup migration prefix completes only with its marker") {
            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                let profile = DisplayProfile.blank(
                    id: ConfigurationStore.migratedDefaultProfileID,
                    name: "默认"
                )
                let settings = ApplicationSettings(
                    schemaVersion: ApplicationSettings.currentSchemaVersion,
                    activeProfileID: profile.id,
                    hotKey: .default,
                    deviceHistory: []
                )
                let configuration = AppConfiguration(settings: settings, profile: profile)
                let marker = TestConfigurationMigrationState(
                    schemaVersion: 1,
                    configuration: configuration,
                    source: .primary,
                    resultSource: .createdBlankProfile,
                    settingsPrimaryData: nil,
                    settingsBackupData: nil
                )
                try JSONEncoder().encode(marker).write(to: store.migrationStateURL)
                try FileManager.default.createDirectory(at: store.profileBackupsDirectoryURL, withIntermediateDirectories: true)
                let profileData = try JSONEncoder().encode(profile)
                try profileData.write(to: store.profileURL(for: profile.id))
                try profileData.write(to: store.profileBackupURL(for: profile.id))
                try JSONEncoder().encode(settings).write(to: store.backupURL)

                let resumed = try store.loadOrMigrate()
                try expectEqual(resumed.configuration, configuration, "settings-backup prefix did not resume")
                try expect(FileManager.default.fileExists(atPath: store.configurationURL.path), "settings canonical was not completed")
                try expect(!FileManager.default.fileExists(atPath: store.migrationStateURL.path), "completed marker was not removed")
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let corrupt = Data("ordinary-corrupt-settings".utf8)
                try corrupt.write(to: store.configurationURL)
                let fallback = try store.loadOrMigrate()
                try expectEqual(fallback.source, .lastKnownGoodBackup, "ordinary corruption was treated as migration")
                try expectEqual(try Data(contentsOf: store.configurationURL), corrupt, "ordinary fallback was repaired without a marker")
                try expect(!FileManager.default.fileExists(atPath: store.migrationStateURL.path), "ordinary corruption created migration intent")
            }
        }

        runner.run("migration rejects conflicting reserved backup and catalog name") {
            try withTemporaryDirectory { root in
                let legacy = AppConfiguration.default
                let legacyData = try JSONEncoder().encode(legacy)
                try legacyData.write(to: root.appendingPathComponent("config.json"))
                try legacyData.write(to: root.appendingPathComponent("config.last-good.json"))
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                let expected = legacy.displayProfile(
                    id: ConfigurationStore.migratedDefaultProfileID,
                    name: "默认"
                )
                var conflicting = expected
                conflicting.automatic.isEnabled.toggle()
                try FileManager.default.createDirectory(at: store.profileBackupsDirectoryURL, withIntermediateDirectories: true)
                try JSONEncoder().encode(expected).write(to: store.profileURL(for: expected.id))
                let conflictingData = try JSONEncoder().encode(conflicting)
                try conflictingData.write(to: store.profileBackupURL(for: expected.id))

                try expectThrows("migration overwrote a conflicting reserved backup") {
                    _ = try store.loadOrMigrate()
                }
                try expectEqual(
                    try Data(contentsOf: store.profileBackupURL(for: expected.id)),
                    conflictingData,
                    "migration rewrote conflicting backup evidence"
                )
                try expect(!FileManager.default.fileExists(atPath: store.migrationStateURL.path), "conflicting migration wrote intent")
            }

            try withTemporaryDirectory { root in
                let legacy = AppConfiguration.default
                let data = try JSONEncoder().encode(legacy)
                try data.write(to: root.appendingPathComponent("config.json"))
                try data.write(to: root.appendingPathComponent("config.last-good.json"))
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                let external = DisplayProfile.blank(id: id("000000000070"), name: "默认")
                try FileManager.default.createDirectory(at: store.profilesDirectoryURL, withIntermediateDirectories: true)
                try JSONEncoder().encode(external).write(to: store.profileURL(for: external.id))

                try expectThrows("migration created a duplicate 默认") { _ = try store.loadOrMigrate() }
                try expect(
                    !FileManager.default.fileExists(atPath: store.profileURL(for: ConfigurationStore.migratedDefaultProfileID).path),
                    "catalog-conflicting migration wrote its reserved Profile"
                )
            }
        }

        runner.run("wrong-ID Profile canonical falls back only to its own backup") {
            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                var wrong = active
                wrong.id = id("000000000071")
                let wrongData = try JSONEncoder().encode(wrong)
                try wrongData.write(to: store.profileURL(for: active.id))

                let loaded = try store.loadProfile(id: active.id)
                try expectEqual(loaded.source, .lastKnownGoodBackup, "wrong-ID canonical did not use matching backup")
                try expectEqual(loaded.profile.id, active.id, "fallback loaded another Profile identity")
                try expectEqual(try Data(contentsOf: store.profileURL(for: active.id)), wrongData, "fallback repaired wrong-ID evidence")
            }
        }

        runner.run("Active fallback Profile participates in name uniqueness") {
            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                let corrupt = Data("corrupt-active-profile".utf8)
                try corrupt.write(to: store.profileURL(for: active.id))

                try expectThrows("fallback Profile name was ignored during uniqueness validation") {
                    _ = try store.createBlankProfile(named: active.name.uppercased())
                }
                try expectEqual(try Data(contentsOf: store.profileURL(for: active.id)), corrupt, "uniqueness check repaired Active fallback")
            }
        }

        runner.run("scoped saves preserve inactive routing and unrelated fallback evidence") {
            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(configuration([rule(id("000000000072"))]))
                let activeBefore = try store.load().activeProfile
                let inactive = try store.createBlankProfile(named: "Inactive")
                let settingsBefore = try Data(contentsOf: store.configurationURL)
                var inactiveDraft = try store.previewProfile(id: inactive.id)
                inactiveDraft.automatic.isEnabled = true
                inactiveDraft.rules = [rule(id("000000000073"))]
                try store.saveProfileConfiguration(inactiveDraft, profileID: inactive.id)

                try expectEqual(try store.load().activeProfile, activeBefore, "inactive draft overwrote Active Profile")
                try expectEqual(try store.loadProfile(id: inactive.id).profile.rules, inactiveDraft.rules, "inactive draft was not saved")
                try expectEqual(try Data(contentsOf: store.configurationURL), settingsBefore, "Profile-only save rewrote Settings")
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let loaded = try store.load()
                let corruptProfile = Data("corrupt-profile-primary".utf8)
                try corruptProfile.write(to: store.profileURL(for: loaded.activeProfile.id))
                var settings = loaded.configuration.applicationSettings(activeProfileID: loaded.activeProfile.id)
                settings.hotKey.keyCode = 11
                try store.saveApplicationSettings(settings)
                try expectEqual(
                    try Data(contentsOf: store.profileURL(for: loaded.activeProfile.id)),
                    corruptProfile,
                    "Settings-only save rewrote Profile fallback evidence"
                )
                var activeUpdate = try store.load().configuration
                activeUpdate.hotKey.keyCode = 12
                try store.save(activeUpdate)
                try expectEqual(
                    try Data(contentsOf: store.profileURL(for: loaded.activeProfile.id)),
                    corruptProfile,
                    "active convenience save rewrote unchanged Profile fallback evidence"
                )
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                var profile = try store.load().activeProfile
                let corruptSettings = Data("corrupt-settings-primary".utf8)
                try corruptSettings.write(to: store.configurationURL)
                profile.automatic.isEnabled.toggle()
                try store.saveProfile(profile)
                try expectEqual(
                    try Data(contentsOf: store.configurationURL),
                    corruptSettings,
                    "Profile-only save rewrote Settings fallback evidence"
                )
                var activeUpdate = try store.load().configuration
                activeUpdate.polling.intervalSeconds = 19
                try store.save(activeUpdate)
                try expectEqual(
                    try Data(contentsOf: store.configurationURL),
                    corruptSettings,
                    "active convenience save rewrote unchanged Settings fallback evidence"
                )
            }
        }

        runner.run("explicit Profile restore uses only a validated matching backup") {
            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                let backupBefore = try Data(contentsOf: store.profileBackupURL(for: active.id))
                try Data("corrupt-canonical".utf8).write(to: store.profileURL(for: active.id))

                let restored = try store.restoreProfileFromLastKnownGood(id: active.id)
                try expectEqual(restored, active, "restore changed the backup Profile")
                try expectEqual(
                    try JSONDecoder().decode(DisplayProfile.self, from: Data(contentsOf: store.profileURL(for: active.id))),
                    active,
                    "restore did not repair the canonical Profile"
                )
                try expectEqual(
                    try Data(contentsOf: store.profileBackupURL(for: active.id)),
                    backupBefore,
                    "restore rewrote last-known-good evidence"
                )
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                try FileManager.default.removeItem(at: store.profileBackupURL(for: active.id))
                let corrupt = Data("corrupt-without-backup".utf8)
                try corrupt.write(to: store.profileURL(for: active.id))
                try expectThrows("restore without a backup succeeded") {
                    _ = try store.restoreProfileFromLastKnownGood(id: active.id)
                }
                try expectEqual(try Data(contentsOf: store.profileURL(for: active.id)), corrupt, "failed restore changed canonical evidence")
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                var wrongCanonical = active
                wrongCanonical.id = id("000000000074")
                try JSONEncoder().encode(wrongCanonical).write(to: store.profileURL(for: active.id))
                let restored = try store.restoreProfileFromLastKnownGood(id: active.id)
                try expectEqual(restored.id, active.id, "wrong-ID canonical selected another Profile")
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                let corrupt = Data("corrupt-canonical".utf8)
                try corrupt.write(to: store.profileURL(for: active.id))
                var wrongBackup = active
                wrongBackup.id = id("000000000075")
                let wrongBackupData = try JSONEncoder().encode(wrongBackup)
                try wrongBackupData.write(to: store.profileBackupURL(for: active.id))
                try expectThrows("wrong-ID backup repaired a different Profile") {
                    _ = try store.restoreProfileFromLastKnownGood(id: active.id)
                }
                try expectEqual(
                    try Data(contentsOf: store.profileBackupURL(for: active.id)),
                    wrongBackupData,
                    "wrong-ID backup was rewritten"
                )
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                let other = try store.createBlankProfile(named: "Other")
                var activeConflict = active
                activeConflict.name = "Duplicate"
                var otherConflict = other
                otherConflict.name = "duplicate"
                try JSONEncoder().encode(activeConflict).write(to: store.profileURL(for: active.id))
                try JSONEncoder().encode(otherConflict).write(to: store.profileURL(for: other.id))
                try expect(store.catalog().profiles.isEmpty, "duplicate setup did not invalidate both canonicals")

                let restored = try store.restoreProfileFromLastKnownGood(id: active.id)
                try expectEqual(restored.name, active.name, "unique older backup did not repair catalog-invalid canonical")
                try expectEqual(store.catalog().profiles.count, 2, "restore did not resolve duplicate-name catalog")
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                let other = try store.createBlankProfile(named: "Other")
                var activeConflict = active
                activeConflict.name = "Duplicate"
                var otherConflict = other
                otherConflict.name = "duplicate"
                try JSONEncoder().encode(activeConflict).write(to: store.profileURL(for: active.id))
                try JSONEncoder().encode(activeConflict).write(to: store.profileBackupURL(for: active.id))
                try JSONEncoder().encode(otherConflict).write(to: store.profileURL(for: other.id))
                try expectThrows("conflicting schema-valid backup repaired duplicate canonical") {
                    _ = try store.restoreProfileFromLastKnownGood(id: active.id)
                }
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                try Data("invalid-canonical".utf8).write(to: store.profileURL(for: active.id))
                try Data("invalid-backup".utf8).write(to: store.profileBackupURL(for: active.id))
                try expectThrows("invalid backup repaired canonical") {
                    _ = try store.restoreProfileFromLastKnownGood(id: active.id)
                }
            }
        }

        runner.run("invalid Profile removal is exact, safe, and preserves a valid catalog") {
            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                _ = try store.createBlankProfile(named: "Valid survivor")
                let corrupt = Data("corrupt-active".utf8)
                try corrupt.write(to: store.profileURL(for: active.id))
                let activeFileName = store.profileURL(for: active.id).lastPathComponent
                try expectThrows("invalid Active Profile was removed") {
                    try store.removeInvalidProfile(fileName: activeFileName)
                }
                try expect(FileManager.default.fileExists(atPath: store.profileURL(for: active.id).path), "Active refusal removed canonical")
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let outside = root.appendingPathComponent("escape.json")
                try Data("outside".utf8).write(to: outside)
                try expectThrows("path traversal was accepted") {
                    try store.removeInvalidProfile(fileName: "../escape.json")
                }
                try expect(FileManager.default.fileExists(atPath: outside.path), "traversal removed an outside file")
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                let invalidID = id("000000000076")
                let invalidURL = store.profileURL(for: invalidID)
                try Data("invalid-profile".utf8).write(to: invalidURL)
                let safetyProfile = DisplayProfile.blank(id: invalidID, name: "Invalid safety")
                try JSONEncoder().encode(safetyProfile).write(to: store.profileBackupURL(for: invalidID))

                try store.removeInvalidProfile(fileName: invalidURL.lastPathComponent)
                try expect(!FileManager.default.fileExists(atPath: invalidURL.path), "explicit removal left invalid canonical")
                try expect(
                    !FileManager.default.fileExists(atPath: store.profileBackupURL(for: invalidID).path),
                    "explicit removal left associated safety artifact"
                )
                try expectEqual(store.catalog().profiles.map(\.id), [active.id], "invalid removal changed the valid catalog")
                try expectThrows("valid catalog Profile was accepted as invalid") {
                    try store.removeInvalidProfile(fileName: store.profileURL(for: active.id).lastPathComponent)
                }
                try expect(FileManager.default.fileExists(atPath: store.profileURL(for: active.id).path), "valid Profile was removed")
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                try Data("invalid-active".utf8).write(to: store.profileURL(for: active.id))
                let otherID = id("000000000077")
                let otherURL = store.profileURL(for: otherID)
                try Data("other-invalid".utf8).write(to: otherURL)
                try expectThrows("invalid removal proceeded with no valid catalog Profile") {
                    try store.removeInvalidProfile(fileName: otherURL.lastPathComponent)
                }
                try expect(FileManager.default.fileExists(atPath: otherURL.path), "last-valid guard removed invalid file")
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                let inactive = try store.createBlankProfile(named: "Other")
                var conflicting = inactive
                conflicting.name = active.name.uppercased()
                try JSONEncoder().encode(conflicting).write(to: store.profileURL(for: inactive.id))
                try expect(store.catalog().profiles.isEmpty, "duplicate setup did not invalidate every participant")

                try store.removeInvalidProfile(
                    fileName: store.profileURL(for: inactive.id).lastPathComponent
                )
                try expectEqual(store.catalog().profiles.map(\.id), [active.id], "post-removal catalog was not restored")
                try expect(
                    !FileManager.default.fileExists(atPath: store.profileBackupURL(for: inactive.id).path),
                    "conflicting Profile safety artifact remained after removal"
                )
            }
        }

        runner.run("settings fallback is referential to its selected Profile") {
            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                var configuration = AppConfiguration.default
                configuration.hotKey = .init(keyCode: 13, modifiers: 789)
                configuration.deviceHistory = [
                    .init(target: .exact(builtInIdentity), name: "Built-in", isBuiltIn: true)
                ]
                try store.save(configuration)
                let backupSettings = try JSONDecoder().decode(
                    ApplicationSettings.self,
                    from: Data(contentsOf: store.backupURL)
                )
                var unusablePrimary = backupSettings
                unusablePrimary.activeProfileID = id("000000000078")
                try JSONEncoder().encode(unusablePrimary).write(to: store.configurationURL)

                let loaded = try store.load()
                try expectEqual(loaded.settingsSource, .lastKnownGoodBackup, "unusable primary selector did not fall back")
                try expectEqual(loaded.activeProfile.id, backupSettings.activeProfileID, "fallback selected a Profile outside backup Settings")
                try expectEqual(loaded.configuration.hotKey, configuration.hotKey, "referential fallback lost global hotkey")
                try expect(loaded.primaryErrorDescription != nil, "referential primary failure was not surfaced")
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                var configuration = AppConfiguration.default
                configuration.hotKey = .init(keyCode: 14, modifiers: 987)
                configuration.deviceHistory = [
                    .init(target: .exact(builtInIdentity), name: "Remembered", isBuiltIn: true)
                ]
                try store.save(configuration)
                var settings = try JSONDecoder().decode(
                    ApplicationSettings.self,
                    from: Data(contentsOf: store.configurationURL)
                )
                settings.activeProfileID = id("000000000079")
                let data = try JSONEncoder().encode(settings)
                try data.write(to: store.configurationURL)
                try data.write(to: store.backupURL)

                try expectThrows("combined load accepted unusable Active Profile") { _ = try store.load() }
                let settingsOnly = try store.loadApplicationSettings()
                try expectEqual(settingsOnly.settings.hotKey, configuration.hotKey, "settings-only load lost hotkey")
                try expectEqual(settingsOnly.settings.deviceHistory, configuration.deviceHistory, "settings-only load lost history")
                try expectEqual(settingsOnly.source, .primary, "valid primary Settings source was hidden")
            }
        }

        runner.run("former monolith migrates into empty and runtime-only existing roots") {
            try withTemporaryDirectory { base in
                let legacyRoot = base.appendingPathComponent("legacy", isDirectory: true)
                let destination = base.appendingPathComponent("destination", isDirectory: true)
                try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                var legacy = AppConfiguration.default
                legacy.polling.intervalSeconds = 27
                legacy.rules = [rule(id("000000000080"))]
                let data = try JSONEncoder().encode(legacy)
                try data.write(to: legacyRoot.appendingPathComponent("config.json"))
                try data.write(to: legacyRoot.appendingPathComponent("config.last-good.json"))

                let migrated = try ConfigurationStore(
                    rootURL: destination,
                    legacyRootURL: legacyRoot,
                    legacyDefaults: nil
                ).loadOrMigrate()
                try expectEqual(migrated.source, .migratedMonolithicConfiguration, "existing empty root skipped monolith")
                try expectEqual(migrated.configuration, legacy, "empty-root import changed monolith")
            }

            try withTemporaryDirectory { base in
                let legacyRoot = base.appendingPathComponent("legacy", isDirectory: true)
                let destination = base.appendingPathComponent("destination", isDirectory: true)
                try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let runtimeURL = destination.appendingPathComponent("runtime-state.json")
                let runtimeBytes = Data("runtime-only-evidence".utf8)
                try runtimeBytes.write(to: runtimeURL)
                var legacy = AppConfiguration.default
                legacy.automatic.isEnabled = false
                let data = try JSONEncoder().encode(legacy)
                try data.write(to: legacyRoot.appendingPathComponent("config.json"))
                try data.write(to: legacyRoot.appendingPathComponent("config.last-good.json"))

                let migrated = try ConfigurationStore(
                    rootURL: destination,
                    legacyRootURL: legacyRoot,
                    legacyDefaults: nil
                ).loadOrMigrate()
                try expectEqual(migrated.configuration, legacy, "runtime-only destination skipped monolith")
                try expectEqual(try Data(contentsOf: runtimeURL), runtimeBytes, "migration changed runtime-only evidence")
            }

            try withTemporaryDirectory { base in
                let legacyRoot = base.appendingPathComponent("legacy", isDirectory: true)
                let destination = base.appendingPathComponent("destination", isDirectory: true)
                try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(AppConfiguration.default)
                try data.write(to: legacyRoot.appendingPathComponent("config.json"))
                let store = ConfigurationStore(rootURL: destination, legacyRootURL: legacyRoot, legacyDefaults: nil)
                let external = DisplayProfile.blank(id: id("000000000081"), name: "External")
                try FileManager.default.createDirectory(at: store.profilesDirectoryURL, withIntermediateDirectories: true)
                try JSONEncoder().encode(external).write(to: store.profileURL(for: external.id))

                try expectThrows("legacy migration overwrote destination Profile artifacts") {
                    _ = try store.loadOrMigrate()
                }
                try expect(!FileManager.default.fileExists(atPath: store.migrationStateURL.path), "conflicting destination created migration intent")
                try expect(FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("config.json").path), "conflict removed legacy source")
            }
        }

        runner.run("invalid operation identity comes from Profile filename") {
            try withTemporaryDirectory { root in
                let store = ConfigurationStore(rootURL: root, legacyDefaults: nil)
                try store.save(AppConfiguration.default)
                let active = try store.load().activeProfile
                var embedded = active
                embedded.id = id("000000000082")
                try JSONEncoder().encode(embedded).write(to: store.profileURL(for: active.id))

                let invalid = try unwrap(
                    store.catalog().invalidProfiles.first { $0.fileName == store.profileURL(for: active.id).lastPathComponent },
                    "wrong-ID canonical was not surfaced"
                )
                try expectEqual(invalid.profileID, active.id, "operation identity did not use filename UUID")
                try expectEqual(invalid.embeddedProfileID, embedded.id, "embedded mismatch diagnostic was lost")
                let restored = try store.restoreProfileFromLastKnownGood(
                    id: try unwrap(invalid.profileID, "UUID filename did not expose Restore identity")
                )
                try expectEqual(restored.id, active.id, "Restore followed embedded mismatched identity")
            }
        }

        runner.run("delete failure cannot strand a canonical without backup") {
            try withTemporaryDirectory { root in
                var removalCount = 0
                let store = ConfigurationStore(
                    rootURL: root,
                    legacyDefaults: nil,
                    removeFile: { url in
                        removalCount += 1
                        if removalCount == 2 {
                            throw TestFailure(description: "injected second removal failure")
                        }
                        try FileManager.default.removeItem(at: url)
                    }
                )
                try store.save(AppConfiguration.default)
                let activeID = try store.load().activeProfile.id
                let inactive = try store.createBlankProfile(named: "Delete target")
                try expectThrows("injected delete failure was not surfaced") {
                    try store.deleteProfile(id: inactive.id)
                }
                try expect(
                    !FileManager.default.fileExists(atPath: store.profileURL(for: inactive.id).path),
                    "failed delete left a surviving canonical"
                )
                try expect(
                    FileManager.default.fileExists(atPath: store.profileBackupURL(for: inactive.id).path),
                    "failed delete destroyed prior backup while canonical survived"
                )
                try expect(FileManager.default.fileExists(atPath: store.profileDeletionStateURL.path), "failed delete lost resumable intent")
                try expectThrows("pending deletion Profile was activated") {
                    _ = try store.activateProfile(id: inactive.id)
                }
                try expectThrows("completed pending deletion remained loadable") {
                    _ = try store.loadProfile(id: inactive.id)
                }
                try expectEqual(try store.load().activeProfile.id, activeID, "pending deletion changed Active selector")
                try expect(!FileManager.default.fileExists(atPath: store.profileBackupURL(for: inactive.id).path), "resumed delete left backup")
                try expect(!FileManager.default.fileExists(atPath: store.profileDeletionStateURL.path), "resumed delete left intent")
            }

            try withTemporaryDirectory { root in
                let store = ConfigurationStore(
                    rootURL: root,
                    legacyDefaults: nil,
                    removeFile: { _ in
                        throw TestFailure(description: "injected first removal failure")
                    }
                )
                try store.save(AppConfiguration.default)
                let activeID = try store.load().activeProfile.id
                let inactive = try store.createBlankProfile(named: "First failure target")
                try expectThrows("first delete failure was not surfaced") {
                    try store.deleteProfile(id: inactive.id)
                }
                try expect(FileManager.default.fileExists(atPath: store.profileURL(for: inactive.id).path), "first failure removed canonical")
                try expect(FileManager.default.fileExists(atPath: store.profileBackupURL(for: inactive.id).path), "first failure removed backup")
                try expect(FileManager.default.fileExists(atPath: store.profileDeletionStateURL.path), "first failure lost resumable intent")
                try expect(!store.catalog().profiles.contains { $0.id == inactive.id }, "pending deletion remained in catalog")
                try expectThrows("first-failure pending Profile was loadable") {
                    _ = try store.loadProfile(id: inactive.id)
                }
                let settings = try JSONDecoder().decode(
                    ApplicationSettings.self,
                    from: Data(contentsOf: store.configurationURL)
                )
                try expectEqual(settings.activeProfileID, activeID, "failed pending access changed Active selector")
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
