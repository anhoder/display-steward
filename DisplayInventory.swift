import AppKit
import CoreGraphics
import Foundation

struct CoreGraphicsDisplayFact: Equatable {
    var runtimeID: UInt32
    var isActive: Bool
    var isMain: Bool
    var isBuiltIn: Bool
    var vendorID: UInt32
    var modelID: UInt32
    var serialNumber: UInt32
    var name: String?
    var mirrorsRuntimeID: UInt32?
    var mode: DisplayModeDetails?
}

protocol CoreGraphicsInventorySource {
    func readOnlineDisplayFacts() throws -> [CoreGraphicsDisplayFact]
}

enum DisplayInventoryError: Error, LocalizedError {
    case enumeration(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .enumeration(let operation, let code):
            return "\(operation) failed with CoreGraphics error \(code)."
        }
    }
}

final class SystemCoreGraphicsInventorySource: CoreGraphicsInventorySource {
    private let initialCapacity: UInt32

    init(initialCapacity: UInt32 = 16) {
        self.initialCapacity = max(1, initialCapacity)
    }

    func readOnlineDisplayFacts() throws -> [CoreGraphicsDisplayFact] {
        let online = try onlineDisplayIDs()
        let active = Set(try activeDisplayIDs())
        let main = CGMainDisplayID()
        let screenMetadata: [UInt32: (name: String?, scale: Double)] = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            guard let runtimeID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            return (UInt32(runtimeID), (name: name.isEmpty ? nil : name, scale: Double(screen.backingScaleFactor)))
        })

        return online.map { displayID in
            let runtimeID = UInt32(displayID)
            let metadata = screenMetadata[runtimeID]
            let mirrored = UInt32(CGDisplayMirrorsDisplay(displayID))
            let displayMode = CGDisplayCopyDisplayMode(displayID)
            let mode = displayMode.map {
                DisplayModeDetails(
                    logicalWidth: $0.width,
                    logicalHeight: $0.height,
                    pixelWidth: $0.pixelWidth,
                    pixelHeight: $0.pixelHeight,
                    refreshRate: $0.refreshRate,
                    rotationDegrees: CGDisplayRotation(displayID),
                    scaleFactor: metadata?.scale
                )
            }
            return CoreGraphicsDisplayFact(
                runtimeID: runtimeID,
                isActive: active.contains(displayID),
                isMain: displayID == main && active.contains(displayID),
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                vendorID: UInt32(CGDisplayVendorNumber(displayID)),
                modelID: UInt32(CGDisplayModelNumber(displayID)),
                serialNumber: UInt32(CGDisplaySerialNumber(displayID)),
                name: metadata?.name,
                mirrorsRuntimeID: mirrored == 0 ? nil : mirrored,
                mode: mode
            )
        }
    }

    private func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
        var capacity = initialCapacity
        while true {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
            var count: UInt32 = 0
            let error = CGGetOnlineDisplayList(capacity, &ids, &count)
            guard error == .success else {
                throw DisplayInventoryError.enumeration(operation: "CGGetOnlineDisplayList", code: error.rawValue)
            }
            if count <= capacity { return Array(ids.prefix(Int(count))) }
            capacity = count
        }
    }

    private func activeDisplayIDs() throws -> [CGDirectDisplayID] {
        var capacity = initialCapacity
        while true {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
            var count: UInt32 = 0
            let error = CGGetActiveDisplayList(capacity, &ids, &count)
            guard error == .success else {
                throw DisplayInventoryError.enumeration(operation: "CGGetActiveDisplayList", code: error.rawValue)
            }
            if count <= capacity { return Array(ids.prefix(Int(count))) }
            capacity = count
        }
    }
}

protocol DisplayInventoryProviding {
    func snapshot(configuration: AppConfiguration, runtimeState: RuntimeState) throws -> ObservedDisplaySnapshot
}

struct CoreGraphicsDisplayInventory: DisplayInventoryProviding {
    var source: CoreGraphicsInventorySource

    init(source: CoreGraphicsInventorySource = SystemCoreGraphicsInventorySource()) {
        self.source = source
    }

    func snapshot(
        configuration: AppConfiguration,
        runtimeState: RuntimeState
    ) throws -> ObservedDisplaySnapshot {
        let facts = try source.readOnlineDisplayFacts()
        let onlineRuntimeIDs = Set(facts.map(\.runtimeID))
        var displays = facts.map(observedDisplay)
        let recoveryRecords = runtimeState.appDisabledDisplays
            + runtimeState.pendingDisableDisplays.map(\.disabledRecord)
            + runtimeState.pendingRecoveryDisplays

        for record in recoveryRecords where !onlineRuntimeIDs.contains(record.runtimeID) {
            let known = matchingHistory(
                identity: record.stableIdentity,
                family: record.family,
                in: configuration.deviceHistory
            )
            displays.append(ObservedDisplay(
                runtimeID: record.runtimeID,
                stableIdentity: record.stableIdentity,
                family: record.family,
                name: known?.name,
                isBuiltIn: known?.isBuiltIn ?? false,
                isMain: false,
                state: .disabledByThisAppConnectionUnknown
            ))
        }

        for known in configuration.deviceHistory where !contains(known, in: displays) {
            let identity: StableDisplayIdentity?
            let family: DisplayFamily
            switch known.target {
            case .exact(let exact):
                identity = exact
                family = exact.family
            case .family(let knownFamily):
                identity = nil
                family = knownFamily
            }
            displays.append(ObservedDisplay(
                runtimeID: nil,
                stableIdentity: identity,
                family: family,
                name: known.name,
                isBuiltIn: known.isBuiltIn,
                isMain: false,
                state: .notObserved
            ))
        }

        displays.sort(by: displayOrder)
        return ObservedDisplaySnapshot(displays: displays)
    }

    private func observedDisplay(_ fact: CoreGraphicsDisplayFact) -> ObservedDisplay {
        let family = DisplayFamily(vendorID: fact.vendorID, modelID: fact.modelID)
        let identity = StableDisplayIdentity(family: family, serialNumber: fact.serialNumber)
        return ObservedDisplay(
            runtimeID: fact.runtimeID,
            stableIdentity: identity.isReliable ? identity : nil,
            family: family,
            name: fact.name,
            isBuiltIn: fact.isBuiltIn,
            isMain: fact.isMain,
            state: fact.isActive ? .active : .online,
            mirrorsRuntimeID: fact.mirrorsRuntimeID,
            mode: fact.mode
        )
    }

    private func matchingHistory(
        identity: StableDisplayIdentity?,
        family: DisplayFamily,
        in history: [KnownDisplay]
    ) -> KnownDisplay? {
        if let identity,
           let exact = history.first(where: {
               if case .exact(let knownIdentity) = $0.target { return knownIdentity == identity }
               return false
           }) {
            return exact
        }
        return history.first {
            if case .family(let knownFamily) = $0.target { return knownFamily == family }
            return false
        }
    }

    private func contains(_ known: KnownDisplay, in displays: [ObservedDisplay]) -> Bool {
        switch known.target {
        case .exact(let identity):
            return displays.contains { $0.stableIdentity == identity }
        case .family(let family):
            return displays.contains { $0.family == family }
        }
    }

    private func displayOrder(_ lhs: ObservedDisplay, _ rhs: ObservedDisplay) -> Bool {
        let leftState = stateOrder(lhs.state)
        let rightState = stateOrder(rhs.state)
        if leftState != rightState { return leftState < rightState }
        if lhs.isMain != rhs.isMain { return lhs.isMain }
        if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
        if lhs.stableIdentity != rhs.stableIdentity {
            switch (lhs.stableIdentity, rhs.stableIdentity) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
        }
        if lhs.family != rhs.family { return lhs.family < rhs.family }
        return (lhs.runtimeID ?? UInt32.max) < (rhs.runtimeID ?? UInt32.max)
    }

    private func stateOrder(_ state: ObservableDisplayState) -> Int {
        switch state {
        case .active: return 0
        case .online: return 1
        case .disabledByThisAppConnectionUnknown: return 2
        case .notObserved: return 3
        }
    }
}
