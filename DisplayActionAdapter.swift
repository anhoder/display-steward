import CoreGraphics
import Darwin
import Foundation

struct DisplayActionRequest: Equatable {
    var display: EvaluatedDisplayKey
    var action: DisplayAction
}

struct DisplayPolicySnapshotFingerprint: Equatable {
    var value: String

    init(snapshot: ObservedDisplaySnapshot) {
        value = snapshot.displays.map { display in
            let identity = display.stableIdentity.map {
                "\($0.family.vendorID):\($0.family.modelID):\($0.serialNumber)"
            } ?? "none"
            return [
                String(display.runtimeID ?? 0),
                identity,
                "\(display.family.vendorID):\(display.family.modelID)",
                display.state.rawValue,
                display.isBuiltIn ? "builtin" : "external",
                display.isMain ? "main" : "secondary"
            ].joined(separator: ":")
        }.sorted().joined(separator: "|")
    }
}

struct DisplayActionResult: Equatable {
    var request: DisplayActionRequest
    var succeeded: Bool
    var wasIdempotent: Bool
    var errorDescription: String?
}

struct DisplayTransactionOutcome: Equatable {
    var before: ObservedDisplaySnapshot
    var after: ObservedDisplaySnapshot
    var results: [DisplayActionResult]
    var transactionWasCommitted: Bool
    var requiresReevaluation: Bool = false

    init(
        before: ObservedDisplaySnapshot,
        after: ObservedDisplaySnapshot,
        results: [DisplayActionResult],
        transactionWasCommitted: Bool,
        requiresReevaluation: Bool = false
    ) {
        self.before = before
        self.after = after
        self.results = results
        self.transactionWasCommitted = transactionWasCommitted
        self.requiresReevaluation = requiresReevaluation
    }
}

protocol DisplayRuntimeAdapting: AnyObject {
    func observe(configuration: AppConfiguration, runtimeState: RuntimeState) throws -> ObservedDisplaySnapshot
    func apply(
        requests: [DisplayActionRequest],
        expectedFingerprint: DisplayPolicySnapshotFingerprint,
        configuration: AppConfiguration,
        runtimeState: RuntimeState,
        didCommit: () throws -> Void
    ) throws -> DisplayTransactionOutcome
}

enum DisplayActionAdapterError: Error, LocalizedError {
    case privateAPIUnavailable
    case beginConfiguration(Int32)
    case configureDisplay(runtimeID: UInt32, code: Int32)
    case completeConfiguration(Int32)
    case committedOutcomeUnknown(String)

    var errorDescription: String? {
        switch self {
        case .privateAPIUnavailable:
            return "CGSConfigureDisplayEnabled is unavailable on this macOS release."
        case .beginConfiguration(let code):
            return "CGBeginDisplayConfiguration failed with CoreGraphics error \(code)."
        case .configureDisplay(let runtimeID, let code):
            return "CGSConfigureDisplayEnabled failed for runtime display \(runtimeID) with error \(code)."
        case .completeConfiguration(let code):
            return "CGCompleteDisplayConfiguration failed with CoreGraphics error \(code)."
        case .committedOutcomeUnknown(let message):
            return "The display transaction committed but its final state is uncertain: \(message)"
        }
    }
}

private typealias CGSConfigureDisplayEnabledFunction = @convention(c) (
    CGDisplayConfigRef,
    CGDirectDisplayID,
    Bool
) -> Int32

final class CoreGraphicsDisplayAdapter: DisplayRuntimeAdapting {
    private let inventory: DisplayInventoryProviding
    private let configureDisplayEnabled: CGSConfigureDisplayEnabledFunction
    private let observationAttempts: Int
    private let observationDelay: TimeInterval
    private let sleep: (TimeInterval) -> Void
    private let lock = NSLock()

    init(
        inventory: DisplayInventoryProviding = CoreGraphicsDisplayInventory(),
        observationAttempts: Int = 8,
        observationDelay: TimeInterval = 0.25,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws {
        self.inventory = inventory
        self.observationAttempts = max(1, observationAttempts)
        self.observationDelay = max(0, observationDelay)
        self.sleep = sleep

        guard let framework = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ), let symbol = dlsym(framework, "CGSConfigureDisplayEnabled") else {
            throw DisplayActionAdapterError.privateAPIUnavailable
        }
        configureDisplayEnabled = unsafeBitCast(symbol, to: CGSConfigureDisplayEnabledFunction.self)
    }

    func observe(
        configuration: AppConfiguration,
        runtimeState: RuntimeState
    ) throws -> ObservedDisplaySnapshot {
        try inventory.snapshot(configuration: configuration, runtimeState: runtimeState)
    }

    func apply(
        requests: [DisplayActionRequest],
        expectedFingerprint: DisplayPolicySnapshotFingerprint,
        configuration: AppConfiguration,
        runtimeState: RuntimeState,
        didCommit: () throws -> Void
    ) throws -> DisplayTransactionOutcome {
        lock.lock()
        defer { lock.unlock() }

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
                        errorDescription: "The policy snapshot changed before the transaction began."
                    )
                },
                transactionWasCommitted: false,
                requiresReevaluation: true
            )
        }
        guard !requests.isEmpty else {
            return DisplayTransactionOutcome(
                before: before,
                after: before,
                results: [],
                transactionWasCommitted: false
            )
        }

        var results: [DisplayActionResult] = []
        var actionable: [DisplayActionRequest] = []
        var seenRuntimeIDs = Set<UInt32>()

        for request in requests {
            guard request.action != .noAction else {
                results.append(failure(request, "A display transaction cannot contain no-action requests."))
                continue
            }
            guard request.display.runtimeID != 0 else {
                results.append(failure(request, "Runtime display ID 0 is never actionable."))
                continue
            }
            guard request.display.family.isValid else {
                results.append(failure(request, "A display with unknown vendor/model identity is not actionable."))
                continue
            }
            guard seenRuntimeIDs.insert(request.display.runtimeID).inserted else {
                results.append(failure(request, "A display may be configured only once per transaction."))
                continue
            }
            guard let current = before.displays.first(where: {
                $0.runtimeID == request.display.runtimeID
                    && $0.stableIdentity == request.display.stableIdentity
                    && $0.family == request.display.family
            }) else {
                results.append(failure(request, "The boot-scoped runtime display identity is stale."))
                continue
            }

            switch request.action {
            case .noAction:
                break
            case .enable:
                let explicitRecovery = runtimeState.pendingDisableDisplays.contains {
                    $0.phase == .committedUncertain
                        && $0.runtimeID == request.display.runtimeID
                        && $0.stableIdentity == request.display.stableIdentity
                        && $0.family == request.display.family
                } || runtimeState.pendingRecoveryDisplays.contains {
                    record($0, matches: request.display)
                }
                if explicitRecovery {
                    actionable.append(request)
                } else if current.state.isOnline {
                    results.append(success(request, idempotent: true))
                } else if current.state == .disabledByThisAppConnectionUnknown,
                          (runtimeState.appDisabledDisplays + runtimeState.pendingDisableDisplays.map(\.disabledRecord) + runtimeState.pendingRecoveryDisplays).contains(where: {
                              record($0, matches: request.display)
                          }) {
                    actionable.append(request)
                } else {
                    results.append(failure(request, "Only a current-boot app-disabled record may be enabled while not online."))
                }
            case .disable:
                if current.state == .disabledByThisAppConnectionUnknown {
                    results.append(success(request, idempotent: true))
                } else if current.state.isOnline {
                    actionable.append(request)
                } else {
                    results.append(failure(request, "A display must be online before it can be disabled."))
                }
            }
        }

        let activeRuntimeIDs = Set(before.displays.compactMap {
            $0.state.isActive ? $0.runtimeID : nil
        })
        let requestedActiveDisables = Set(actionable.compactMap {
            $0.action == .disable && activeRuntimeIDs.contains($0.display.runtimeID)
                ? $0.display.runtimeID
                : nil
        })
        if !activeRuntimeIDs.isEmpty && activeRuntimeIDs.subtracting(requestedActiveDisables).isEmpty {
            let unsafe = actionable.filter { $0.action == .disable }
            actionable.removeAll { $0.action == .disable }
            results.append(contentsOf: unsafe.map {
                failure($0, "The transaction would remove every active usable display.")
            })
        }

        guard !actionable.isEmpty else {
            return DisplayTransactionOutcome(
                before: before,
                after: before,
                results: orderedResults(results, requests: requests),
                transactionWasCommitted: false
            )
        }

        var configurationRef: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&configurationRef)
        guard beginError == .success, let configurationRef else {
            throw DisplayActionAdapterError.beginConfiguration(beginError.rawValue)
        }

        for request in actionable {
            let enabled = request.action == .enable
            let code = configureDisplayEnabled(
                configurationRef,
                CGDirectDisplayID(request.display.runtimeID),
                enabled
            )
            guard code == 0 else {
                CGCancelDisplayConfiguration(configurationRef)
                let message = DisplayActionAdapterError.configureDisplay(
                    runtimeID: request.display.runtimeID,
                    code: code
                ).localizedDescription
                results.append(contentsOf: actionable.map { failure($0, message) })
                return DisplayTransactionOutcome(
                    before: before,
                    after: before,
                    results: orderedResults(results, requests: requests),
                    transactionWasCommitted: false
                )
            }
        }

        let completeError = CGCompleteDisplayConfiguration(configurationRef, .forSession)
        guard completeError == .success else {
            try? didCommit()
            throw DisplayActionAdapterError.committedOutcomeUnknown(
                "CGCompleteDisplayConfiguration returned \(completeError.rawValue)."
            )
        }
        do {
            try didCommit()
        } catch {
            throw DisplayActionAdapterError.committedOutcomeUnknown(error.localizedDescription)
        }

        let stableRecoveryEnableIDs: Set<UInt32> = Set(actionable.compactMap { request in
            guard request.action == .enable,
                  (runtimeState.appDisabledDisplays
                    + runtimeState.pendingDisableDisplays.map(\.disabledRecord)
                    + runtimeState.pendingRecoveryDisplays).contains(where: {
                      record($0, matches: request.display)
                  }) else { return nil }
            return request.display.runtimeID
        })
        var unstableRecoveryEnableIDs = Set<UInt32>()
        var after = before
        var pending = actionable
        do {
            for attempt in 0..<observationAttempts {
                after = try observe(configuration: configuration, runtimeState: runtimeState)
                for runtimeID in stableRecoveryEnableIDs where
                    after.displays.first(where: { $0.runtimeID == runtimeID })?.state.isOnline != true {
                    unstableRecoveryEnableIDs.insert(runtimeID)
                }
                pending = actionable.filter { request in
                    if stableRecoveryEnableIDs.contains(request.display.runtimeID) {
                        return unstableRecoveryEnableIDs.contains(request.display.runtimeID)
                            || attempt + 1 < observationAttempts
                            || !postcondition(request, in: after)
                    }
                    return !postcondition(request, in: after)
                }
                if pending.isEmpty { break }
                if attempt + 1 < observationAttempts { sleep(observationDelay) }
            }
        } catch {
            throw DisplayActionAdapterError.committedOutcomeUnknown(error.localizedDescription)
        }

        for request in actionable {
            if pending.contains(request) {
                results.append(failure(request, "The display did not reach the requested postcondition."))
            } else {
                results.append(success(request, idempotent: false))
            }
        }
        return DisplayTransactionOutcome(
            before: before,
            after: after,
            results: orderedResults(results, requests: requests),
            transactionWasCommitted: true
        )
    }

    private func postcondition(
        _ request: DisplayActionRequest,
        in snapshot: ObservedDisplaySnapshot
    ) -> Bool {
        let observed = snapshot.displays.first { $0.runtimeID == request.display.runtimeID }
        switch request.action {
        case .noAction:
            return true
        case .enable:
            return observed?.state.isOnline == true
        case .disable:
            return observed?.state.isOnline != true
        }
    }

    private func record(
        _ record: AppDisabledDisplayRecord,
        matches display: EvaluatedDisplayKey
    ) -> Bool {
        record.runtimeID == display.runtimeID
            && record.stableIdentity == display.stableIdentity
            && record.family == display.family
    }

    private func success(
        _ request: DisplayActionRequest,
        idempotent: Bool
    ) -> DisplayActionResult {
        DisplayActionResult(
            request: request,
            succeeded: true,
            wasIdempotent: idempotent,
            errorDescription: nil
        )
    }

    private func failure(
        _ request: DisplayActionRequest,
        _ message: String
    ) -> DisplayActionResult {
        DisplayActionResult(
            request: request,
            succeeded: false,
            wasIdempotent: false,
            errorDescription: message
        )
    }

    private func orderedResults(
        _ results: [DisplayActionResult],
        requests: [DisplayActionRequest]
    ) -> [DisplayActionResult] {
        requests.compactMap { request in results.first { $0.request == request } }
    }
}
