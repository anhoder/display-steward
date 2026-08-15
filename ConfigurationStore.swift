import Foundation

enum ConfigurationLoadSource: String, Codable, Equatable {
    case primary
    case lastKnownGoodBackup
    case migratedLegacyDefaults
    case migratedMonolithicConfiguration
    case createdBlankProfile
    case createdDefaults
}

enum PersistenceGenerationSource: String, Codable, Equatable {
    case primary
    case lastKnownGoodBackup
}

struct ConfigurationLoadResult: Equatable {
    var configuration: AppConfiguration
    var source: ConfigurationLoadSource
    var primaryErrorDescription: String?
    var activeProfile: DisplayProfile
    var settingsSource: PersistenceGenerationSource
    var profileSource: PersistenceGenerationSource
}

struct DisplayProfileLoadResult: Equatable {
    var profile: DisplayProfile
    var source: PersistenceGenerationSource
    var primaryErrorDescription: String?
}

struct ApplicationSettingsLoadResult: Equatable {
    var settings: ApplicationSettings
    var source: PersistenceGenerationSource
    var primaryErrorDescription: String?
}

struct InvalidDisplayProfile: Equatable {
    var fileName: String
    var profileID: UUID?
    var embeddedProfileID: UUID? = nil
    var profileName: String?
    var errorDescription: String

    init(
        fileName: String,
        profileID: UUID?,
        embeddedProfileID: UUID? = nil,
        profileName: String?,
        errorDescription: String
    ) {
        self.fileName = fileName
        self.profileID = profileID
        self.embeddedProfileID = embeddedProfileID
        self.profileName = profileName
        self.errorDescription = errorDescription
    }
}

struct DisplayProfileCatalog: Equatable {
    var profiles: [DisplayProfile]
    var invalidProfiles: [InvalidDisplayProfile]
}

private struct ConfigurationMigrationState: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var configuration: AppConfiguration
    var source: PersistenceGenerationSource
    var resultSource: ConfigurationLoadSource
    var settingsPrimaryData: Data?
    var settingsBackupData: Data?

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ConfigurationStoreError.migrationStateInvalid(
                "unsupported schema version \(schemaVersion)"
            )
        }
        switch resultSource {
        case .migratedLegacyDefaults, .migratedMonolithicConfiguration, .createdBlankProfile:
            break
        case .primary, .lastKnownGoodBackup, .createdDefaults:
            throw ConfigurationStoreError.migrationStateInvalid(
                "invalid result source \(resultSource.rawValue)"
            )
        }
        try configuration.validate()
    }
}

private struct ProfileDeletionState: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var profileID: UUID
}

enum ConfigurationStoreError: Error, LocalizedError {
    case configurationMissing
    case unreadablePrimaryAndBackup(primary: String, backup: String?)
    case activeProfileUnavailable(id: UUID, reason: String)
    case profileNotFound(UUID)
    case profileCatalogConflict(UUID, String)
    case profileNameAlreadyExists(String)
    case cannotDeleteActiveProfile
    case cannotDeleteLastProfile
    case profileRestoreNotNeeded(UUID)
    case profileRestoreUnavailable(UUID, String)
    case invalidProfileFileName(String)
    case deletionStateInvalid(String)
    case invalidProfileNotFound(String)
    case migrationProfileConflict(UUID)
    case migrationSettingsConflict
    case migrationCatalogConflict(String)
    case migrationStateInvalid(String)

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "No application settings generation exists."
        case .unreadablePrimaryAndBackup(let primary, let backup):
            if let backup {
                return "The primary generation is invalid (\(primary)); the last-known-good generation is also invalid (\(backup))."
            }
            return "The primary generation is invalid and no usable last-known-good generation exists: \(primary)"
        case .activeProfileUnavailable(let id, let reason):
            return "Active Profile \(id.uuidString) is unavailable: \(reason)"
        case .profileNotFound(let id):
            return "Display Profile \(id.uuidString) does not exist."
        case .profileCatalogConflict(let id, let reason):
            return "Display Profile \(id.uuidString) conflicts with the on-disk catalog: \(reason)"
        case .profileNameAlreadyExists(let name):
            return "A Display Profile named \(name) already exists."
        case .cannotDeleteActiveProfile:
            return "The Active Profile cannot be deleted."
        case .cannotDeleteLastProfile:
            return "At least one Display Profile must remain."
        case .profileRestoreNotNeeded(let id):
            return "Display Profile \(id.uuidString) already has a valid canonical generation."
        case .profileRestoreUnavailable(let id, let reason):
            return "Display Profile \(id.uuidString) cannot be restored from last-known-good: \(reason)"
        case .invalidProfileFileName(let fileName):
            return "Invalid Profile file name: \(fileName)"
        case .invalidProfileNotFound(let fileName):
            return "The current invalid Profile catalog has no exact entry named \(fileName)."
        case .deletionStateInvalid(let reason):
            return "The pending Profile deletion is invalid: \(reason)"
        case .migrationProfileConflict(let id):
            return "Legacy migration cannot reuse Profile identity \(id.uuidString) because its safety generations contain different data."
        case .migrationSettingsConflict:
            return "Migration cannot replace an unrelated Application Settings generation."
        case .migrationCatalogConflict(let reason):
            return "Migration conflicts with the on-disk Profile catalog: \(reason)"
        case .migrationStateInvalid(let reason):
            return "The pending configuration migration is invalid: \(reason)"
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
    static let migratedDefaultProfileID = UUID(uuidString: "D1501A7E-4F4F-4A11-8A3E-000000000001")!

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
    let profilesDirectoryURL: URL
    let profileBackupsDirectoryURL: URL
    let migrationStateURL: URL

    let profileDeletionStateURL: URL
    private let legacyRootURL: URL?
    private let fileManager: FileManager
    private let legacyDefaults: UserDefaults?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let removeFile: (URL) throws -> Void

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
        fileManager: FileManager = .default,
        removeFile: ((URL) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.legacyRootURL = legacyRootURL
        configurationURL = rootURL.appendingPathComponent("config.json")
        backupURL = rootURL.appendingPathComponent("config.last-good.json")
        profilesDirectoryURL = rootURL.appendingPathComponent("profiles", isDirectory: true)
        profileBackupsDirectoryURL = profilesDirectoryURL.appendingPathComponent("last-good", isDirectory: true)
        migrationStateURL = rootURL.appendingPathComponent("migration-state.json")
        profileDeletionStateURL = rootURL.appendingPathComponent("profile-deletion-state.json")
        self.fileManager = fileManager
        self.legacyDefaults = legacyDefaults
        self.removeFile = removeFile ?? { url in
            try fileManager.removeItem(at: url)
        }

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func profileURL(for id: UUID) -> URL {
        profilesDirectoryURL.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    func profileBackupURL(for id: UUID) -> URL {
        profileBackupsDirectoryURL.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    func load() throws -> ConfigurationLoadResult {
        try resumePendingProfileDeletion()
        let hasPrimary = fileManager.fileExists(atPath: configurationURL.path)
        let hasBackup = fileManager.fileExists(atPath: backupURL.path)
        guard hasPrimary || hasBackup else {
            throw ConfigurationStoreError.configurationMissing
        }

        var primaryError: Error?
        if hasPrimary {
            do {
                return try loadConfiguration(
                    settingsURL: configurationURL,
                    settingsSource: .primary
                )
            } catch {
                primaryError = error
            }
        }

        if hasBackup {
            do {
                var result = try loadConfiguration(
                    settingsURL: backupURL,
                    settingsSource: .lastKnownGoodBackup
                )
                let missingPrimaryDescription: String? = hasPrimary
                    ? primaryError?.localizedDescription
                    : "primary settings are missing"
                let errors = [missingPrimaryDescription, result.primaryErrorDescription]
                    .compactMap { $0 }
                result.source = .lastKnownGoodBackup
                result.primaryErrorDescription = errors.isEmpty ? nil : errors.joined(separator: "; ")
                return result
            } catch {
                throw ConfigurationStoreError.unreadablePrimaryAndBackup(
                    primary: primaryError?.localizedDescription ?? "primary settings are missing",
                    backup: error.localizedDescription
                )
            }
        }

        throw ConfigurationStoreError.unreadablePrimaryAndBackup(
            primary: primaryError?.localizedDescription ?? "primary settings are missing",
            backup: nil
        )
    }

    func loadApplicationSettings() throws -> ApplicationSettingsLoadResult {
        try resumePendingProfileDeletion()
        let loaded = try loadSettings()
        return ApplicationSettingsLoadResult(
            settings: loaded.value,
            source: loaded.source,
            primaryErrorDescription: loaded.primaryErrorDescription
        )
    }
    func reloadFromDisk() throws -> ConfigurationLoadResult {
        try load()
    }

    func loadOrMigrate() throws -> ConfigurationLoadResult {
        try resumePendingProfileDeletion()
        if fileManager.fileExists(atPath: migrationStateURL.path) {
            return try resumePendingMigration()
        }
        if let migrated = try migrateLegacyRootIfNeeded() {
            return migrated
        }
        if fileManager.fileExists(atPath: migrationStateURL.path) {
            return try resumePendingMigration()
        }

        let hasSettingsGeneration = fileManager.fileExists(atPath: configurationURL.path)
            || fileManager.fileExists(atPath: backupURL.path)
        if hasSettingsGeneration {
            do {
                return try load()
            } catch let splitError {
                if (try? loadSettings()) != nil { throw splitError }
                let legacy: StoredGeneration<AppConfiguration>
                do {
                    legacy = try loadLegacyMonolithicConfiguration()
                } catch {
                    throw splitError
                }
                return try beginMigration(
                    configuration: legacy.value,
                    source: legacy.source,
                    resultSource: .migratedMonolithicConfiguration
                )
            }
        }
        guard !hasAnyProfileArtifacts() else {
            throw ConfigurationStoreError.configurationMissing
        }

        let migration = LegacyConfigurationMigrator.migrate(defaults: legacyDefaults)
        if migration.didReadLegacyValues {
            return try beginMigration(
                configuration: migration.configuration,
                source: .primary,
                resultSource: .migratedLegacyDefaults
            )
        }

        let profile = DisplayProfile.blank(id: Self.migratedDefaultProfileID, name: "默认")
        let settings = ApplicationSettings(
            schemaVersion: ApplicationSettings.currentSchemaVersion,
            activeProfileID: profile.id,
            hotKey: .default,
            deviceHistory: []
        )
        return try beginMigration(
            configuration: AppConfiguration(settings: settings, profile: profile),
            source: .primary,
            resultSource: .createdBlankProfile
        )
    }

    // Compatibility seam for existing runtime callers. The destination is always
    // the Active Profile; new callers editing another Profile must use the scoped API.
    func save(_ configuration: AppConfiguration) throws {
        try saveActiveConfiguration(configuration)
    }

    func saveActiveConfiguration(_ configuration: AppConfiguration) throws {
        try configuration.validate()
        if fileManager.fileExists(atPath: configurationURL.path)
            || fileManager.fileExists(atPath: backupURL.path) {
            let existingSettings = try loadSettings().value
            let existingProfile = try loadProfile(id: existingSettings.activeProfileID).profile
            let settings = configuration.applicationSettings(activeProfileID: existingSettings.activeProfileID)
            let profile = configuration.displayProfile(id: existingProfile.id, name: existingProfile.name)
            try settings.validate()
            try profile.validate()
            try ensureUniqueProfile(profile, excluding: profile.id)
            if profile != existingProfile { try writeProfile(profile) }
            if settings != existingSettings { try writeSettings(settings) }
            return
        }

        guard !hasAnyProfileArtifacts() else { throw ConfigurationStoreError.configurationMissing }
        let id = UUID()
        let settings = configuration.applicationSettings(activeProfileID: id)
        let profile = configuration.displayProfile(id: id, name: "默认")
        try settings.validate()
        try profile.validate()
        try writeProfile(profile)
        try writeSettings(settings)
    }

    func saveApplicationSettings(_ settings: ApplicationSettings) throws {
        try settings.validate()
        _ = try loadProfile(id: settings.activeProfileID)
        try writeSettings(settings)
    }

    func saveApplicationSettings(from configuration: AppConfiguration) throws {
        try configuration.validate()
        let activeID = try loadSettings().value.activeProfileID
        try saveApplicationSettings(configuration.applicationSettings(activeProfileID: activeID))
    }

    func saveProfile(_ profile: DisplayProfile) throws {
        try profile.validate()
        _ = try loadProfile(id: profile.id)
        try ensureUniqueProfile(profile, excluding: profile.id)
        try writeProfile(profile)
    }

    func saveProfileConfiguration(_ configuration: AppConfiguration, profileID: UUID) throws {
        try configuration.validate()
        let existing = try loadProfile(id: profileID).profile
        try saveProfile(configuration.displayProfile(id: profileID, name: existing.name))
    }

    func catalog() -> DisplayProfileCatalog {
        catalog(excludingFileName: pendingDeletionCanonicalFileName())
    }

    private func catalog(excludingFileName: String?) -> DisplayProfileCatalog {
        guard fileManager.fileExists(atPath: profilesDirectoryURL.path) else {
            return DisplayProfileCatalog(profiles: [], invalidProfiles: [])
        }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: profilesDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter {
                $0.pathExtension.lowercased() == "json"
                    && $0.lastPathComponent != excludingFileName
            }
        } catch {
            return DisplayProfileCatalog(profiles: [], invalidProfiles: [
                InvalidDisplayProfile(
                    fileName: profilesDirectoryURL.lastPathComponent,
                    profileID: nil,
                    embeddedProfileID: nil,
                    profileName: nil,
                    errorDescription: error.localizedDescription
                )
            ])
        }

        struct Candidate {
            var url: URL
            var fileID: UUID?
            var profile: DisplayProfile
            var problems: [String]
        }
        var candidates: [Candidate] = []
        var invalid: [InvalidDisplayProfile] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let fileID = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            do {
                let profile = try decodeProfile(at: url)
                var problems: [String] = []
                if fileID == nil {
                    problems.append("file name must be a UUID")
                } else if fileID != profile.id {
                    problems.append("file UUID does not match Profile ID")
                }
                candidates.append(Candidate(url: url, fileID: fileID, profile: profile, problems: problems))
            } catch {
                invalid.append(InvalidDisplayProfile(
                    fileName: url.lastPathComponent,
                    profileID: fileID,
                    embeddedProfileID: nil,
                    profileName: nil,
                    errorDescription: error.localizedDescription
                ))
            }
        }

        let idCounts = Dictionary(grouping: candidates, by: { $0.profile.id }).mapValues { $0.count }
        for index in candidates.indices where idCounts[candidates[index].profile.id, default: 0] > 1 {
            candidates[index].problems.append("duplicate Profile ID")
        }
        for index in candidates.indices {
            let name = candidates[index].profile.name
            if candidates.indices.filter({ DisplayProfile.namesAreEqual(candidates[$0].profile.name, name) }).count > 1 {
                candidates[index].problems.append("duplicate Profile name")
            }
        }

        var valid: [DisplayProfile] = []
        for candidate in candidates {
            if candidate.problems.isEmpty {
                valid.append(candidate.profile)
            } else {
                invalid.append(InvalidDisplayProfile(
                    fileName: candidate.url.lastPathComponent,
                    profileID: candidate.fileID,
                    embeddedProfileID: candidate.profile.id,
                    profileName: candidate.profile.name,
                    errorDescription: candidate.problems.joined(separator: "; ")
                ))
            }
        }
        valid.sort(by: DisplayProfile.orderedByName)
        invalid.sort {
            let lhs = $0.profileName ?? $0.fileName
            let rhs = $1.profileName ?? $1.fileName
            let order = lhs.compare(rhs, options: [.caseInsensitive])
            if order != .orderedSame { return order == .orderedAscending }
            return $0.fileName < $1.fileName
        }
        return DisplayProfileCatalog(profiles: valid, invalidProfiles: invalid)
    }

    func createBlankProfile(named name: String) throws -> DisplayProfile {
        try resumePendingProfileDeletion()
        _ = try loadSettings()
        let profile = DisplayProfile.blank(name: name)
        try profile.validate()
        try ensureUniqueProfile(profile, excluding: nil)
        try writeProfile(profile)
        return profile
    }

    func duplicateProfile(id: UUID, named name: String) throws -> DisplayProfile {
        try resumePendingProfileDeletion()
        _ = try loadSettings()
        let source = try loadProfile(id: id).profile
        var copy = DisplayProfile(
            schemaVersion: DisplayProfile.currentSchemaVersion,
            id: UUID(),
            name: name,
            automatic: source.automatic,
            polling: source.polling,
            rules: source.rules
        )
        for index in copy.rules.indices { copy.rules[index].id = UUID() }
        try copy.validate()
        try ensureUniqueProfile(copy, excluding: nil)
        try writeProfile(copy)
        return copy
    }

    func renameProfile(id: UUID, to name: String) throws -> DisplayProfile {
        try resumePendingProfileDeletion()
        var profile = try loadProfile(id: id).profile
        profile.name = name
        try profile.validate()
        try ensureUniqueProfile(profile, excluding: id)
        try writeProfile(profile)
        return profile
    }

    func deleteProfile(id: UUID) throws {
        try resumePendingProfileDeletion()
        let settings = try loadSettings().value
        guard settings.activeProfileID != id else {
            throw ConfigurationStoreError.cannotDeleteActiveProfile
        }
        _ = try loadProfile(id: id)
        let snapshot = catalog()
        guard snapshot.profiles.contains(where: { $0.id == id }) else {
            throw ConfigurationStoreError.profileCatalogConflict(id, "Profile is not a valid catalog member")
        }
        guard snapshot.profiles.count > 1 else {
            throw ConfigurationStoreError.cannotDeleteLastProfile
        }
        let state = ProfileDeletionState(
            schemaVersion: ProfileDeletionState.currentSchemaVersion,
            profileID: id
        )
        try AtomicFileWriter.write(
            try encoder.encode(state),
            to: profileDeletionStateURL,
            fileManager: fileManager
        )
        try completeProfileDeletion(state)
    }

    func restoreProfileFromLastKnownGood(id: UUID) throws -> DisplayProfile {
        try resumePendingProfileDeletion()
        let primaryURL = profileURL(for: id)
        if fileManager.fileExists(atPath: primaryURL.path),
           let primary = try? decodeProfile(at: primaryURL),
           primary.id == id,
           catalog().profiles.contains(where: { $0.id == id }) {
            throw ConfigurationStoreError.profileRestoreNotNeeded(id)
        }

        let backupURL = profileBackupURL(for: id)
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw ConfigurationStoreError.profileRestoreUnavailable(id, "backup is missing")
        }
        let profile: DisplayProfile
        do {
            profile = try decodeProfile(at: backupURL)
            guard profile.id == id else {
                throw ConfigurationStoreError.profileRestoreUnavailable(
                    id,
                    "backup contains Profile ID \(profile.id.uuidString)"
                )
            }
            try ensureUniqueProfile(
                profile,
                excluding: id,
                excludingInvalidFileName: primaryURL.lastPathComponent,
                ignoreInvalidEntriesForExcludedID: false
            )
        } catch let error as ConfigurationStoreError {
            throw error
        } catch {
            throw ConfigurationStoreError.profileRestoreUnavailable(id, error.localizedDescription)
        }

        try AtomicFileWriter.write(
            try encoder.encode(profile),
            to: primaryURL,
            fileManager: fileManager
        )
        return profile
    }

    func removeInvalidProfile(fileName: String) throws {
        try resumePendingProfileDeletion()
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              !fileName.contains("\\"),
              fileName != ".",
              fileName != "..",
              URL(fileURLWithPath: fileName).lastPathComponent == fileName else {
            throw ConfigurationStoreError.invalidProfileFileName(fileName)
        }

        let snapshot = catalog()
        guard snapshot.invalidProfiles.contains(where: { $0.fileName == fileName }) else {
            throw ConfigurationStoreError.invalidProfileNotFound(fileName)
        }
        let canonicalURL = profilesDirectoryURL.appendingPathComponent(fileName)
        let canonicalParentURL = canonicalURL.deletingLastPathComponent().standardizedFileURL
        guard canonicalParentURL == profilesDirectoryURL.standardizedFileURL,
              fileManager.fileExists(atPath: canonicalURL.path) else {
            throw ConfigurationStoreError.invalidProfileFileName(fileName)
        }

        let fileID = UUID(uuidString: canonicalURL.deletingPathExtension().lastPathComponent)
        let activeID = try loadSettings().value.activeProfileID
        if fileID == activeID {
            throw ConfigurationStoreError.cannotDeleteActiveProfile
        }
        let postRemovalCatalog = catalog(excludingFileName: fileName)
        guard !postRemovalCatalog.profiles.isEmpty,
              activeProfileIsUsable(activeID, in: postRemovalCatalog) else {
            throw ConfigurationStoreError.cannotDeleteLastProfile
        }

        // This user-requested removal deletes the exact invalid canonical first.
        // Its same-identity safety artifact is removed only after that succeeds.
        try fileManager.removeItem(at: canonicalURL)
        if let fileID {
            let backupURL = profileBackupURL(for: fileID)
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
        }
    }

    func previewProfile(id: UUID) throws -> AppConfiguration {
        try resumePendingProfileDeletion()
        let settings = try loadSettings().value
        let profile = try loadProfile(id: id).profile
        let configuration = AppConfiguration(settings: settings, profile: profile)
        try configuration.validate()
        return configuration
    }

    func activateProfile(id: UUID) throws -> ConfigurationLoadResult {
        try resumePendingProfileDeletion()
        var settings = try loadSettings().value
        let loadedProfile = try loadProfile(id: id)
        settings.activeProfileID = id
        try settings.validate()
        try writeSettings(settings)

        let configuration = AppConfiguration(settings: settings, profile: loadedProfile.profile)
        try configuration.validate()
        return ConfigurationLoadResult(
            configuration: configuration,
            source: loadedProfile.source == .primary ? .primary : .lastKnownGoodBackup,
            primaryErrorDescription: loadedProfile.primaryErrorDescription,
            activeProfile: loadedProfile.profile,
            settingsSource: .primary,
            profileSource: loadedProfile.source
        )
    }

    func loadProfile(id: UUID) throws -> DisplayProfileLoadResult {
        try resumePendingProfileDeletion()
        let loaded: StoredGeneration<DisplayProfile>
        do {
            loaded = try loadValidatedGenerations(
                primaryURL: profileURL(for: id),
                backupURL: profileBackupURL(for: id),
                decode: { url in
                    let profile = try self.decodeProfile(at: url)
                    guard profile.id == id else {
                        throw ConfigurationStoreError.profileCatalogConflict(
                            id,
                            "generation contains Profile ID \(profile.id.uuidString)"
                        )
                    }
                    return profile
                }
            )
        } catch ConfigurationStoreError.configurationMissing {
            throw ConfigurationStoreError.profileNotFound(id)
        }
        let snapshot = catalog()
        if let conflict = snapshot.invalidProfiles.first(where: {
            $0.profileID == id
                && $0.embeddedProfileID == id
                && $0.errorDescription.contains("duplicate")
        }) {
            throw ConfigurationStoreError.profileCatalogConflict(id, conflict.errorDescription)
        }
        if let duplicate = snapshot.profiles.first(where: {
            $0.id != id && DisplayProfile.namesAreEqual($0.name, loaded.value.name)
        }) {
            throw ConfigurationStoreError.profileCatalogConflict(
                id,
                "name duplicates Profile \(duplicate.id.uuidString)"
            )
        }
        return DisplayProfileLoadResult(
            profile: loaded.value,
            source: loaded.source,
            primaryErrorDescription: loaded.primaryErrorDescription
        )
    }

    private struct StoredGeneration<Value> {
        var value: Value
        var source: PersistenceGenerationSource
        var primaryErrorDescription: String?
    }

    private func loadConfiguration(
        settingsURL: URL,
        settingsSource: PersistenceGenerationSource
    ) throws -> ConfigurationLoadResult {
        let settings = try decodeSettings(at: settingsURL)
        let loadedProfile: DisplayProfileLoadResult
        do {
            loadedProfile = try loadProfile(id: settings.activeProfileID)
        } catch {
            throw ConfigurationStoreError.activeProfileUnavailable(
                id: settings.activeProfileID,
                reason: error.localizedDescription
            )
        }
        let configuration = AppConfiguration(settings: settings, profile: loadedProfile.profile)
        try configuration.validate()
        return ConfigurationLoadResult(
            configuration: configuration,
            source: settingsSource == .primary && loadedProfile.source == .primary
                ? .primary
                : .lastKnownGoodBackup,
            primaryErrorDescription: loadedProfile.primaryErrorDescription,
            activeProfile: loadedProfile.profile,
            settingsSource: settingsSource,
            profileSource: loadedProfile.source
        )
    }

    private func loadSettings() throws -> StoredGeneration<ApplicationSettings> {
        try loadValidatedGenerations(primaryURL: configurationURL, backupURL: backupURL, decode: decodeSettings(at:))
    }

    private func loadLegacyMonolithicConfiguration() throws -> StoredGeneration<AppConfiguration> {
        try loadValidatedGenerations(primaryURL: configurationURL, backupURL: backupURL, decode: decodeLegacyConfiguration(at:))
    }

    private func loadValidatedGenerations<Value>(
        primaryURL: URL,
        backupURL: URL,
        decode: (URL) throws -> Value
    ) throws -> StoredGeneration<Value> {
        let hasPrimary = fileManager.fileExists(atPath: primaryURL.path)
        let hasBackup = fileManager.fileExists(atPath: backupURL.path)
        guard hasPrimary || hasBackup else { throw ConfigurationStoreError.configurationMissing }

        var primaryError: Error?
        if hasPrimary {
            do {
                return StoredGeneration(value: try decode(primaryURL), source: .primary, primaryErrorDescription: nil)
            } catch { primaryError = error }
        }
        if hasBackup {
            do {
                return StoredGeneration(
                    value: try decode(backupURL),
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

    private func beginMigration(
        configuration: AppConfiguration,
        source: PersistenceGenerationSource,
        resultSource: ConfigurationLoadSource
    ) throws -> ConfigurationLoadResult {
        let state = ConfigurationMigrationState(
            schemaVersion: ConfigurationMigrationState.currentSchemaVersion,
            configuration: configuration,
            source: source,
            resultSource: resultSource,
            settingsPrimaryData: try existingData(at: configurationURL),
            settingsBackupData: try existingData(at: backupURL)
        )
        try state.validate()
        try validateMigrationDestinations(state)
        try AtomicFileWriter.write(
            try encoder.encode(state),
            to: migrationStateURL,
            fileManager: fileManager
        )
        return try resumeMigration(state)
    }

    private func resumePendingMigration() throws -> ConfigurationLoadResult {
        let state: ConfigurationMigrationState
        do {
            state = try decoder.decode(
                ConfigurationMigrationState.self,
                from: Data(contentsOf: migrationStateURL)
            )
            try state.validate()
        } catch {
            throw ConfigurationStoreError.migrationStateInvalid(error.localizedDescription)
        }
        return try resumeMigration(state)
    }

    private func resumeMigration(
        _ state: ConfigurationMigrationState
    ) throws -> ConfigurationLoadResult {
        try validateMigrationDestinations(state)
        let id = Self.migratedDefaultProfileID
        let profile = state.configuration.displayProfile(id: id, name: "默认")
        let settings = state.configuration.applicationSettings(activeProfileID: id)

        // The durable marker precedes every canonical write. Profile generations
        // become independently usable first, followed by both Settings generations.
        try writeProfile(profile)
        try writeSettings(settings)
        try fileManager.removeItem(at: migrationStateURL)
        return ConfigurationLoadResult(
            configuration: state.configuration,
            source: state.resultSource,
            primaryErrorDescription: state.source == .lastKnownGoodBackup
                ? "Migrated from the legacy last-known-good generation."
                : nil,
            activeProfile: profile,
            settingsSource: .primary,
            profileSource: .primary
        )
    }

    private func validateMigrationDestinations(
        _ state: ConfigurationMigrationState
    ) throws {
        try state.validate()
        let id = Self.migratedDefaultProfileID
        let expectedProfile = state.configuration.displayProfile(id: id, name: "默认")
        let expectedSettings = state.configuration.applicationSettings(activeProfileID: id)
        try expectedProfile.validate()
        try expectedSettings.validate()

        for url in [profileURL(for: id), profileBackupURL(for: id)] {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                let existing = try decodeProfile(at: url)
                guard existing == expectedProfile else {
                    throw ConfigurationStoreError.migrationProfileConflict(id)
                }
            } catch {
                throw ConfigurationStoreError.migrationProfileConflict(id)
            }
        }

        let snapshot = catalog()
        if let conflict = snapshot.profiles.first(where: {
            $0.id != id
                && ($0.id == expectedProfile.id
                    || DisplayProfile.namesAreEqual($0.name, expectedProfile.name))
        }) {
            throw ConfigurationStoreError.migrationCatalogConflict(
                "Profile \(conflict.id.uuidString) conflicts with 默认"
            )
        }
        if let conflict = snapshot.invalidProfiles.first(where: {
            ($0.embeddedProfileID ?? $0.profileID) == id
                || $0.profileName.map {
                    DisplayProfile.namesAreEqual($0, expectedProfile.name)
                } == true
        }) {
            throw ConfigurationStoreError.migrationCatalogConflict(
                "\(conflict.fileName): \(conflict.errorDescription)"
            )
        }

        try validateMigrationSettingsGeneration(
            at: configurationURL,
            expected: expectedSettings,
            allowedOriginalData: state.settingsPrimaryData
        )
        try validateMigrationSettingsGeneration(
            at: backupURL,
            expected: expectedSettings,
            allowedOriginalData: state.settingsBackupData
        )
    }

    private func validateMigrationSettingsGeneration(
        at url: URL,
        expected: ApplicationSettings,
        allowedOriginalData: Data?
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            guard allowedOriginalData == nil else {
                throw ConfigurationStoreError.migrationSettingsConflict
            }
            return
        }
        let data = try Data(contentsOf: url)
        if let allowedOriginalData, data == allowedOriginalData { return }
        do {
            let settings = try decoder.decode(ApplicationSettings.self, from: data)
            try settings.validate()
            if settings == expected { return }
        } catch {
            // A pending migration may replace only its captured original bytes
            // or its own fully validated staged Application Settings.
        }
        throw ConfigurationStoreError.migrationSettingsConflict
    }

    private func existingData(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func pendingDeletionCanonicalFileName() -> String? {
        guard fileManager.fileExists(atPath: profileDeletionStateURL.path),
              let data = try? Data(contentsOf: profileDeletionStateURL),
              let state = try? decoder.decode(ProfileDeletionState.self, from: data),
              state.schemaVersion == ProfileDeletionState.currentSchemaVersion else {
            return nil
        }
        return profileURL(for: state.profileID).lastPathComponent
    }

    private func resumePendingProfileDeletion() throws {
        guard fileManager.fileExists(atPath: profileDeletionStateURL.path) else { return }
        let state: ProfileDeletionState
        do {
            state = try decoder.decode(
                ProfileDeletionState.self,
                from: Data(contentsOf: profileDeletionStateURL)
            )
            guard state.schemaVersion == ProfileDeletionState.currentSchemaVersion,
                  state.profileID.uuidString != "00000000-0000-0000-0000-000000000000" else {
                throw ConfigurationStoreError.deletionStateInvalid(
                    "invalid schema or Profile identity"
                )
            }
        } catch let error as ConfigurationStoreError {
            throw error
        } catch {
            throw ConfigurationStoreError.deletionStateInvalid(error.localizedDescription)
        }
        try completeProfileDeletion(state)
    }

    private func completeProfileDeletion(_ state: ProfileDeletionState) throws {
        let primary = profileURL(for: state.profileID)
        if fileManager.fileExists(atPath: primary.path) { try removeFile(primary) }
        let backup = profileBackupURL(for: state.profileID)
        if fileManager.fileExists(atPath: backup.path) { try removeFile(backup) }
        try fileManager.removeItem(at: profileDeletionStateURL)
    }

    private func activeProfileIsUsable(
        _ id: UUID,
        in snapshot: DisplayProfileCatalog
    ) -> Bool {
        if snapshot.profiles.contains(where: { $0.id == id }) { return true }

        let loaded: StoredGeneration<DisplayProfile>
        do {
            loaded = try loadValidatedGenerations(
                primaryURL: profileURL(for: id),
                backupURL: profileBackupURL(for: id),
                decode: { url in
                    let profile = try self.decodeProfile(at: url)
                    guard profile.id == id else {
                        throw ConfigurationStoreError.profileCatalogConflict(
                            id,
                            "generation contains Profile ID \(profile.id.uuidString)"
                        )
                    }
                    return profile
                }
            )
        } catch {
            return false
        }

        if snapshot.profiles.contains(where: {
            $0.id != id && DisplayProfile.namesAreEqual($0.name, loaded.value.name)
        }) {
            return false
        }
        let activeCanonicalName = profileURL(for: id).lastPathComponent
        return !snapshot.invalidProfiles.contains(where: {
            guard $0.fileName != activeCanonicalName else { return false }
            return ($0.embeddedProfileID ?? $0.profileID) == id
                || $0.profileName.map {
                    DisplayProfile.namesAreEqual($0, loaded.value.name)
                } == true
        })
    }

    private func ensureUniqueProfile(
        _ profile: DisplayProfile,
        excluding excludedID: UUID?,
        excludingInvalidFileName: String? = nil,
        ignoreInvalidEntriesForExcludedID: Bool = true
    ) throws {
        let snapshot = catalog()
        var existingProfiles = snapshot.profiles.filter { $0.id != excludedID }
        if let settings = try? loadSettings(),
           settings.value.activeProfileID != excludedID,
           let active = try? loadProfile(id: settings.value.activeProfileID).profile,
           !existingProfiles.contains(where: { $0.id == active.id }) {
            existingProfiles.append(active)
        }
        let relevantInvalid = snapshot.invalidProfiles.filter {
            $0.fileName != excludingInvalidFileName
        }

        if existingProfiles.contains(where: { DisplayProfile.namesAreEqual($0.name, profile.name) })
            || relevantInvalid.contains(where: {
                let ignored = ignoreInvalidEntriesForExcludedID && $0.profileID == excludedID
                return !ignored
                    && $0.profileName.map { DisplayProfile.namesAreEqual($0, profile.name) } == true
            }) {
            throw ConfigurationStoreError.profileNameAlreadyExists(profile.name)
        }
        if existingProfiles.contains(where: { $0.id == profile.id })
            || relevantInvalid.contains(where: {
                let ignored = ignoreInvalidEntriesForExcludedID && $0.profileID == excludedID
                return !ignored
                    && ($0.embeddedProfileID ?? $0.profileID) == profile.id
            }) {
            throw ConfigurationStoreError.profileCatalogConflict(profile.id, "duplicate Profile ID")
        }
    }

    private func writeSettings(_ settings: ApplicationSettings) throws {
        try settings.validate()
        let data = try encoder.encode(settings)
        try AtomicFileWriter.write(data, to: backupURL, fileManager: fileManager)
        try AtomicFileWriter.write(data, to: configurationURL, fileManager: fileManager)
    }

    private func writeProfile(_ profile: DisplayProfile) throws {
        try profile.validate()
        let data = try encoder.encode(profile)
        try AtomicFileWriter.write(data, to: profileBackupURL(for: profile.id), fileManager: fileManager)
        try AtomicFileWriter.write(data, to: profileURL(for: profile.id), fileManager: fileManager)
    }

    private func decodeSettings(at url: URL) throws -> ApplicationSettings {
        let settings = try decoder.decode(ApplicationSettings.self, from: Data(contentsOf: url))
        try settings.validate()
        return settings
    }

    private func decodeProfile(at url: URL) throws -> DisplayProfile {
        let profile = try decoder.decode(DisplayProfile.self, from: Data(contentsOf: url))
        try profile.validate()
        return profile
    }

    private func decodeLegacyConfiguration(at url: URL) throws -> AppConfiguration {
        let configuration = try decoder.decode(AppConfiguration.self, from: Data(contentsOf: url))
        try configuration.validate()
        return configuration
    }

    private func hasAnyProfileArtifacts() -> Bool {
        for directory in [profilesDirectoryURL, profileBackupsDirectoryURL] {
            if let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
               contents.contains(where: { $0.pathExtension.lowercased() == "json" }) {
                return true
            }
        }
        return false
    }

    private func migrateLegacyRootIfNeeded() throws -> ConfigurationLoadResult? {
        guard let legacyRootURL,
              legacyRootURL.standardizedFileURL != rootURL.standardizedFileURL,
              fileManager.fileExists(atPath: legacyRootURL.path) else {
            return nil
        }

        if !fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.createDirectory(
                at: rootURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try fileManager.moveItem(at: legacyRootURL, to: rootURL)
            return nil
        }

        let hasDestinationSettings = fileManager.fileExists(atPath: configurationURL.path)
            || fileManager.fileExists(atPath: backupURL.path)
        guard !hasDestinationSettings, !hasAnyProfileArtifacts() else { return nil }

        let legacyConfigurationURL = legacyRootURL.appendingPathComponent("config.json")
        let legacyBackupURL = legacyRootURL.appendingPathComponent("config.last-good.json")
        let hasLegacyGeneration = fileManager.fileExists(atPath: legacyConfigurationURL.path)
            || fileManager.fileExists(atPath: legacyBackupURL.path)
        guard hasLegacyGeneration else { return nil }

        let legacy = try loadValidatedGenerations(
            primaryURL: legacyConfigurationURL,
            backupURL: legacyBackupURL,
            decode: decodeLegacyConfiguration(at:)
        )
        return try beginMigration(
            configuration: legacy.value,
            source: legacy.source,
            resultSource: .migratedMonolithicConfiguration
        )
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
