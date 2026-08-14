import Darwin
import Foundation

struct AppDisabledDisplayRecord: Codable, Equatable {
    var runtimeID: UInt32
    var stableIdentity: StableDisplayIdentity?
    var family: DisplayFamily
}

enum PendingDisablePhase: String, Codable, Equatable {
    case uncommittedIntent
    case committedUncertain
}

struct PendingDisableRecord: Codable, Equatable {
    var runtimeID: UInt32
    var stableIdentity: StableDisplayIdentity?
    var family: DisplayFamily
    var phase: PendingDisablePhase

    init(
        runtimeID: UInt32,
        stableIdentity: StableDisplayIdentity?,
        family: DisplayFamily,
        phase: PendingDisablePhase = .uncommittedIntent
    ) {
        self.runtimeID = runtimeID
        self.stableIdentity = stableIdentity
        self.family = family
        self.phase = phase
    }

    var disabledRecord: AppDisabledDisplayRecord {
        AppDisabledDisplayRecord(
            runtimeID: runtimeID,
            stableIdentity: stableIdentity,
            family: family
        )
    }
}

struct LegacyBuiltInRecoveryMarker: Codable, Equatable {
    var runtimeID: UInt32?
    var stableIdentity: StableDisplayIdentity?
    var family: DisplayFamily
}

struct FailureSuppressionRecord: Codable, Equatable {
    var target: DisplayTarget
    var action: DisplayAction
    var consecutiveFailureCount: Int
    var suppressedUntil: Date
    var lastError: String
}

struct RuntimeState: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var bootIdentifier: String
    var appDisabledDisplays: [AppDisabledDisplayRecord]
    var pendingDisableDisplays: [PendingDisableRecord]
    var pendingRecoveryDisplays: [AppDisabledDisplayRecord]
    var legacyBuiltInRecovery: LegacyBuiltInRecoveryMarker?
    var failureSuppressions: [FailureSuppressionRecord]

    init(
        schemaVersion: Int,
        bootIdentifier: String,
        appDisabledDisplays: [AppDisabledDisplayRecord],
        legacyBuiltInRecovery: LegacyBuiltInRecoveryMarker?,
        failureSuppressions: [FailureSuppressionRecord],
        pendingDisableDisplays: [PendingDisableRecord] = [],
        pendingRecoveryDisplays: [AppDisabledDisplayRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.bootIdentifier = bootIdentifier
        self.appDisabledDisplays = appDisabledDisplays
        self.pendingDisableDisplays = pendingDisableDisplays
        self.pendingRecoveryDisplays = pendingRecoveryDisplays
        self.legacyBuiltInRecovery = legacyBuiltInRecovery
        self.failureSuppressions = failureSuppressions
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case bootIdentifier
        case appDisabledDisplays
        case pendingDisableDisplays
        case pendingRecoveryDisplays
        case legacyBuiltInRecovery
        case failureSuppressions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            bootIdentifier: try container.decode(String.self, forKey: .bootIdentifier),
            appDisabledDisplays: try container.decode([AppDisabledDisplayRecord].self, forKey: .appDisabledDisplays),
            legacyBuiltInRecovery: try container.decodeIfPresent(LegacyBuiltInRecoveryMarker.self, forKey: .legacyBuiltInRecovery),
            failureSuppressions: try container.decode([FailureSuppressionRecord].self, forKey: .failureSuppressions),
            pendingDisableDisplays: try Self.decodePendingRecords(from: container),
            pendingRecoveryDisplays: try container.decodeIfPresent(
                [AppDisabledDisplayRecord].self,
                forKey: .pendingRecoveryDisplays
            ) ?? []
        )
    }

    private static func decodePendingRecords(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [PendingDisableRecord] {
        if let records = try? container.decode([PendingDisableRecord].self, forKey: .pendingDisableDisplays) {
            return records
        }
        return try container.decodeIfPresent(
            [AppDisabledDisplayRecord].self,
            forKey: .pendingDisableDisplays
        )?.map {
            PendingDisableRecord(
                runtimeID: $0.runtimeID,
                stableIdentity: $0.stableIdentity,
                family: $0.family
            )
        } ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(bootIdentifier, forKey: .bootIdentifier)
        try container.encode(appDisabledDisplays, forKey: .appDisabledDisplays)
        try container.encode(pendingDisableDisplays, forKey: .pendingDisableDisplays)
        try container.encode(pendingRecoveryDisplays, forKey: .pendingRecoveryDisplays)
        try container.encodeIfPresent(legacyBuiltInRecovery, forKey: .legacyBuiltInRecovery)
        try container.encode(failureSuppressions, forKey: .failureSuppressions)
    }

    static func empty(bootIdentifier: String) -> RuntimeState {
        RuntimeState(
            schemaVersion: currentSchemaVersion,
            bootIdentifier: bootIdentifier,
            appDisabledDisplays: [],
            legacyBuiltInRecovery: nil,
            failureSuppressions: []
        )
    }

    func validate(expectedBootIdentifier: String) throws {
        var issues: [String] = []
        if schemaVersion != Self.currentSchemaVersion {
            issues.append("unsupported schema version \(schemaVersion)")
        }
        if bootIdentifier.isEmpty {
            issues.append("bootIdentifier must not be empty")
        }
        if bootIdentifier != expectedBootIdentifier {
            issues.append("runtime state belongs to another boot session")
        }

        var runtimeIDs = Set<UInt32>()
        for display in appDisabledDisplays {
            if display.runtimeID == 0 {
                issues.append("app-disabled display runtime ID must be nonzero")
            } else if !runtimeIDs.insert(display.runtimeID).inserted {
                issues.append("app-disabled display runtime IDs must be unique")
            }
            if !display.family.isValid {
                issues.append("app-disabled display family must be valid")
            }
            if let identity = display.stableIdentity, !identity.isReliable {
                issues.append("app-disabled stable identity must be reliable")
            }
        }

        var pendingRuntimeIDs = Set<UInt32>()
        for display in pendingDisableDisplays {
            if display.runtimeID == 0 {
                issues.append("pending-disable display runtime ID must be nonzero")
            } else if !pendingRuntimeIDs.insert(display.runtimeID).inserted {
                issues.append("pending-disable display runtime IDs must be unique")
            } else if runtimeIDs.contains(display.runtimeID) {
                issues.append("a runtime ID cannot be both pending-disable and app-disabled")
            }
            if !display.family.isValid {
                issues.append("pending-disable display family must be valid")
            }
            if let identity = display.stableIdentity, !identity.isReliable {
                issues.append("pending-disable stable identity must be reliable")
            }
        }

        var pendingRecoveryRuntimeIDs = Set<UInt32>()
        for display in pendingRecoveryDisplays {
            if display.runtimeID == 0 {
                issues.append("pending-recovery display runtime ID must be nonzero")
            } else if !pendingRecoveryRuntimeIDs.insert(display.runtimeID).inserted {
                issues.append("pending-recovery display runtime IDs must be unique")
            } else if runtimeIDs.contains(display.runtimeID) || pendingRuntimeIDs.contains(display.runtimeID) {
                issues.append("a runtime ID cannot have more than one recovery evidence record")
            }
            if !display.family.isValid {
                issues.append("pending-recovery display family must be valid")
            }
            if let identity = display.stableIdentity, !identity.isReliable {
                issues.append("pending-recovery stable identity must be reliable")
            }
        }

        if let marker = legacyBuiltInRecovery {
            if !marker.family.isValid {
                issues.append("legacy built-in recovery family must be valid")
            }
            if let runtimeID = marker.runtimeID, runtimeID == 0 {
                issues.append("legacy built-in recovery runtime ID must be nonzero")
            }
            if let identity = marker.stableIdentity, !identity.isReliable {
                issues.append("legacy built-in recovery identity must be reliable")
            }
        }

        for suppression in failureSuppressions {
            if suppression.action == .noAction {
                issues.append("failure suppression must refer to an explicit action")
            }
            if suppression.consecutiveFailureCount <= 0 {
                issues.append("failure suppression count must be positive")
            }
            if suppression.lastError.isEmpty {
                issues.append("failure suppression error must not be empty")
            }
        }

        if !issues.isEmpty {
            throw RuntimeStateValidationError(issues: issues)
        }
    }
}

struct RuntimeStateValidationError: Error, LocalizedError, Equatable {
    var issues: [String]

    var errorDescription: String? { issues.joined(separator: "; ") }
}

struct RuntimeStateLoadResult: Equatable {
    var state: RuntimeState
    var discardedStaleBootState: Bool
    var fileWasMissing: Bool
    var importedLegacyMarker: Bool
}

enum RuntimeStateStoreError: Error, LocalizedError {
    case bootIdentifierUnavailable

    var errorDescription: String? {
        "The current macOS boot-session identifier is unavailable."
    }
}

enum SystemBootIdentifier {
    static func current() throws -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1 else {
            throw RuntimeStateStoreError.bootIdentifierUnavailable
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            throw RuntimeStateStoreError.bootIdentifierUnavailable
        }
        let identifier = String(cString: buffer)
        guard !identifier.isEmpty else {
            throw RuntimeStateStoreError.bootIdentifierUnavailable
        }
        return identifier
    }
}

final class RuntimeStateStore {
    let runtimeStateURL: URL

    private let fileManager: FileManager
    private let bootIdentifierProvider: () throws -> String
    private let encoder: JSONEncoder
    private let legacyDefaults: UserDefaults?
    private let decoder: JSONDecoder
    private let saveOverride: ((RuntimeState) throws -> Void)?

    init(
        rootURL: URL = ConfigurationStore.defaultRootURL,
        fileManager: FileManager = .default,
        legacyDefaults: UserDefaults? = LegacyScreenManagerMigration.defaults,
        bootIdentifierProvider: @escaping () throws -> String = SystemBootIdentifier.current,
        saveOverride: ((RuntimeState) throws -> Void)? = nil
    ) {
        runtimeStateURL = rootURL.appendingPathComponent("runtime-state.json")
        self.fileManager = fileManager
        self.bootIdentifierProvider = bootIdentifierProvider
        self.legacyDefaults = legacyDefaults
        self.saveOverride = saveOverride
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func load(importLegacyMarker: Bool = false) throws -> RuntimeStateLoadResult {
        let bootIdentifier = try bootIdentifierProvider()
        guard fileManager.fileExists(atPath: runtimeStateURL.path) else {
            var state = RuntimeState.empty(bootIdentifier: bootIdentifier)
            state.legacyBuiltInRecovery = importLegacyMarker ? legacyRecoveryMarker() : nil
            if state.legacyBuiltInRecovery != nil {
                try save(state)
            }
            return RuntimeStateLoadResult(
                state: state,
                discardedStaleBootState: false,
                fileWasMissing: true,
                importedLegacyMarker: state.legacyBuiltInRecovery != nil
            )
        }

        let data = try Data(contentsOf: runtimeStateURL)
        let persisted = try decoder.decode(RuntimeState.self, from: data)
        if persisted.bootIdentifier != bootIdentifier {
            return RuntimeStateLoadResult(
                state: .empty(bootIdentifier: bootIdentifier),
                discardedStaleBootState: true,
                fileWasMissing: false,
                importedLegacyMarker: false
            )
        }

        try persisted.validate(expectedBootIdentifier: bootIdentifier)
        return RuntimeStateLoadResult(
            state: persisted,
            discardedStaleBootState: false,
            fileWasMissing: false,
            importedLegacyMarker: false
        )
    }

    func save(_ state: RuntimeState) throws {
        let bootIdentifier = try bootIdentifierProvider()
        try state.validate(expectedBootIdentifier: bootIdentifier)
        try saveOverride?(state)
        let data = try encoder.encode(state)
        try AtomicFileWriter.write(data, to: runtimeStateURL, fileManager: fileManager)
    }

    func freshState() throws -> RuntimeState {
        .empty(bootIdentifier: try bootIdentifierProvider())
    }

    private func legacyRecoveryMarker() -> LegacyBuiltInRecoveryMarker? {
        guard let defaults = legacyDefaults,
              let vendor = unsigned32(defaults.object(forKey: "lastBuiltinVendor")),
              let model = unsigned32(defaults.object(forKey: "lastBuiltinModel")),
              vendor != 0,
              model != 0 else { return nil }
        let family = DisplayFamily(vendorID: vendor, modelID: model)
        let serial = unsigned32(defaults.object(forKey: "lastBuiltinSerial")) ?? 0
        let identity = StableDisplayIdentity(family: family, serialNumber: serial)
        return LegacyBuiltInRecoveryMarker(
            runtimeID: nil,
            stableIdentity: identity.isReliable ? identity : nil,
            family: family
        )
    }

    private func unsigned32(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.int64Value
        guard raw >= 0 && raw <= Int64(UInt32.max) else { return nil }
        return UInt32(raw)
    }
}
