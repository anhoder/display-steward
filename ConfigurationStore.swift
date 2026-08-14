import Foundation

enum ConfigurationLoadSource: String, Equatable {
    case primary
    case lastKnownGoodBackup
    case migratedLegacyDefaults
    case createdDefaults
}

struct ConfigurationLoadResult: Equatable {
    var configuration: AppConfiguration
    var source: ConfigurationLoadSource
    var primaryErrorDescription: String?
}

enum ConfigurationStoreError: Error, LocalizedError {
    case configurationMissing
    case unreadablePrimaryAndBackup(primary: String, backup: String?)

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "No configuration file exists."
        case .unreadablePrimaryAndBackup(let primary, let backup):
            if let backup {
                return "The primary configuration is invalid (\(primary)); the last-known-good backup is also invalid (\(backup))."
            }
            return "The primary configuration is invalid and no usable last-known-good backup exists: \(primary)"
        }
    }
}
enum LegacyScreenManagerMigration {
    static let bundleIdentifier = "com.anhoder.screen-manager"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: bundleIdentifier)
    }
}


final class ConfigurationStore {
    static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("display-steward", isDirectory: true)
    }

    static var legacyDefaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("screen-manager", isDirectory: true)
    }

    let rootURL: URL
    let configurationURL: URL
    let backupURL: URL

    private let legacyRootURL: URL?
    private let fileManager: FileManager
    private let legacyDefaults: UserDefaults?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    convenience init() {
        self.init(
            rootURL: Self.defaultRootURL,
            legacyRootURL: Self.legacyDefaultRootURL,
            legacyDefaults: LegacyScreenManagerMigration.defaults,
            fileManager: .default
        )
    }

    init(
        rootURL: URL,
        legacyRootURL: URL? = nil,
        legacyDefaults: UserDefaults? = .standard,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.legacyRootURL = legacyRootURL
        configurationURL = rootURL.appendingPathComponent("config.json")
        backupURL = rootURL.appendingPathComponent("config.last-good.json")
        self.fileManager = fileManager
        self.legacyDefaults = legacyDefaults

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func load() throws -> ConfigurationLoadResult {
        let hasPrimary = fileManager.fileExists(atPath: configurationURL.path)
        let hasBackup = fileManager.fileExists(atPath: backupURL.path)
        guard hasPrimary || hasBackup else { throw ConfigurationStoreError.configurationMissing }

        var primaryError: Error?
        if hasPrimary {
            do {
                return ConfigurationLoadResult(
                    configuration: try decodeConfiguration(at: configurationURL),
                    source: .primary,
                    primaryErrorDescription: nil
                )
            } catch {
                primaryError = error
            }
        }

        if hasBackup {
            do {
                return ConfigurationLoadResult(
                    configuration: try decodeConfiguration(at: backupURL),
                    source: .lastKnownGoodBackup,
                    primaryErrorDescription: primaryError?.localizedDescription
                )
            } catch {
                throw ConfigurationStoreError.unreadablePrimaryAndBackup(
                    primary: primaryError?.localizedDescription ?? "primary file is missing",
                    backup: error.localizedDescription
                )
            }
        }

        throw ConfigurationStoreError.unreadablePrimaryAndBackup(
            primary: primaryError?.localizedDescription ?? "primary file is missing",
            backup: nil
        )
    }

    func loadOrMigrate() throws -> ConfigurationLoadResult {
        try migrateLegacyRootIfNeeded()
        if fileManager.fileExists(atPath: configurationURL.path)
            || fileManager.fileExists(atPath: backupURL.path) {
            return try load()
        }

        let migration = LegacyConfigurationMigrator.migrate(defaults: legacyDefaults)
        try save(migration.configuration)
        return ConfigurationLoadResult(
            configuration: migration.configuration,
            source: migration.didReadLegacyValues ? .migratedLegacyDefaults : .createdDefaults,
            primaryErrorDescription: nil
        )
    }

    func save(_ configuration: AppConfiguration) throws {
        try configuration.validate()
        let data = try encoder.encode(configuration)
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Both files contain a fully validated generation. Writing the backup first
        // leaves at least one valid generation if the process stops between replaces.
        try AtomicFileWriter.write(data, to: backupURL, fileManager: fileManager)
        try AtomicFileWriter.write(data, to: configurationURL, fileManager: fileManager)
    }
    private func migrateLegacyRootIfNeeded() throws {
        guard !fileManager.fileExists(atPath: configurationURL.path),
              !fileManager.fileExists(atPath: backupURL.path),
              let legacyRootURL,
              legacyRootURL.standardizedFileURL != rootURL.standardizedFileURL,
              fileManager.fileExists(atPath: legacyRootURL.path),
              !fileManager.fileExists(atPath: rootURL.path) else {
            return
        }

        try fileManager.createDirectory(
            at: rootURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try fileManager.moveItem(at: legacyRootURL, to: rootURL)
    }

    private func decodeConfiguration(at url: URL) throws -> AppConfiguration {
        let data = try Data(contentsOf: url)
        let configuration = try decoder.decode(AppConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }
}

struct LegacyMigrationResult: Equatable {
    var configuration: AppConfiguration
    var didReadLegacyValues: Bool
}

enum LegacyConfigurationMigrator {
    private static let automaticKey = "automaticDisplayPolicy"
    private static let pollingEnabledKey = "pollingEnabled"
    private static let pollingIntervalKey = "pollingInterval"
    private static let hotKeyCodeKey = "hotKeyKeyCode"
    private static let hotKeyModifiersKey = "hotKeyModifiers"
    private static let builtinVendorKey = "lastBuiltinVendor"
    private static let builtinModelKey = "lastBuiltinModel"
    private static let builtinSerialKey = "lastBuiltinSerial"

    static func migrate(defaults: UserDefaults?) -> LegacyMigrationResult {
        guard let defaults else {
            return LegacyMigrationResult(configuration: .default, didReadLegacyValues: false)
        }

        let keys = [
            automaticKey,
            pollingEnabledKey,
            pollingIntervalKey,
            hotKeyCodeKey,
            hotKeyModifiersKey,
            builtinVendorKey,
            builtinModelKey,
            builtinSerialKey
        ]
        let didReadLegacyValues = keys.contains { defaults.object(forKey: $0) != nil }

        let automatic = bool(defaults, key: automaticKey) ?? true
        let pollingEnabled = bool(defaults, key: pollingEnabledKey) ?? true
        let rawPollingInterval = number(defaults, key: pollingIntervalKey)?.doubleValue ?? 3
        let pollingInterval = rawPollingInterval.isFinite && (1...3600).contains(rawPollingInterval)
            ? rawPollingInterval
            : 3
        let keyCode = unsigned32(defaults, key: hotKeyCodeKey) ?? HotKeyConfiguration.default.keyCode
        let modifiers = unsigned32(defaults, key: hotKeyModifiersKey)
            .flatMap { $0 == 0 ? nil : $0 }
            ?? HotKeyConfiguration.default.modifiers

        var history: [KnownDisplay] = []
        var rules: [DisplayRule] = []
        if let vendor = unsigned32(defaults, key: builtinVendorKey),
           let model = unsigned32(defaults, key: builtinModelKey),
           vendor != 0,
           model != 0 {
            let family = DisplayFamily(vendorID: vendor, modelID: model)
            let serial = unsigned32(defaults, key: builtinSerialKey) ?? 0
            let target: DisplayTarget
            if serial != 0 {
                target = .exact(StableDisplayIdentity(family: family, serialNumber: serial))
            } else {
                target = .family(family)
            }
            history.append(KnownDisplay(target: target, name: "Built-in Display", isBuiltIn: true))

            rules = defaultExternalRules(target: target)
        }

        let configuration = AppConfiguration(
            schemaVersion: AppConfiguration.currentSchemaVersion,
            automatic: AutomaticConfiguration(
                isEnabled: automatic,
                startupStabilizationSeconds: AutomaticConfiguration.default.startupStabilizationSeconds,
                wakeStabilizationSeconds: AutomaticConfiguration.default.wakeStabilizationSeconds
            ),
            polling: PollingConfiguration(
                isEnabled: pollingEnabled,
                intervalSeconds: pollingInterval
            ),
            hotKey: HotKeyConfiguration(keyCode: keyCode, modifiers: modifiers),
            deviceHistory: history,
            rules: rules
        )
        return LegacyMigrationResult(
            configuration: configuration,
            didReadLegacyValues: didReadLegacyValues
        )
    }

    static func defaultExternalRules(target: DisplayTarget) -> [DisplayRule] {
        [
            DisplayRule(
                id: UUID(uuidString: "9A2F10CC-6359-4A81-A9E6-C93ED83A4B01")!,
                name: "检测到外接显示器",
                isEnabled: true,
                priority: 100,
                conditions: [.count(DisplayCountCondition(
                    kind: .online,
                    scope: .external,
                    comparison: .greaterThan,
                    value: 0
                ))],
                actions: [TargetAction(target: target, action: .disable)]
            ),
            DisplayRule(
                id: UUID(uuidString: "2CE98F47-15A9-4E49-993D-6AB5BCE2780C")!,
                name: "未检测到外接显示器",
                isEnabled: true,
                priority: 100,
                conditions: [.count(DisplayCountCondition(
                    kind: .online,
                    scope: .external,
                    comparison: .equal,
                    value: 0
                ))],
                actions: [TargetAction(target: target, action: .enable)]
            )
        ]
    }

    private static func bool(_ defaults: UserDefaults, key: String) -> Bool? {
        guard let value = defaults.object(forKey: key) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func number(_ defaults: UserDefaults, key: String) -> NSNumber? {
        defaults.object(forKey: key) as? NSNumber
    }

    private static func unsigned32(_ defaults: UserDefaults, key: String) -> UInt32? {
        guard let number = number(defaults, key: key) else { return nil }
        let value = number.int64Value
        guard value >= 0 && value <= Int64(UInt32.max) else { return nil }
        return UInt32(value)
    }
}

enum AtomicFileWriter {
    static func write(_ data: Data, to destination: URL, fileManager: FileManager) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )

        do {
            try data.write(to: temporary, options: [])
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
