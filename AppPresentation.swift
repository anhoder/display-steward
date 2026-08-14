import Foundation

enum PresentationError: Error, LocalizedError, Equatable {
    case noReliableDisplayTarget
    case noBuiltInDisplayTarget
    case emptyRuleName
    case emptyConditions
    case emptyActions
    case conditionCannotBeRemoved
    case displayAliasUnavailable
    case historicalDisplayReferenced
    case historicalDisplayNotForgettable
    case manualActionUnavailable
    case staleManualDisplayCommand

    var errorDescription: String? {
        switch self {
        case .noReliableDisplayTarget:
            return "当前没有可用于规则的可靠显示器标识。请先连接显示器并刷新。"
        case .noBuiltInDisplayTarget:
            return "当前记录中没有内置显示器，无法生成默认规则。"
        case .emptyRuleName:
            return "规则名称不能为空。"
        case .emptyConditions:
            return "每条规则至少需要一个条件。"
        case .emptyActions:
            return "每条规则至少需要一个显示器操作。"
        case .conditionCannotBeRemoved:
            return "每条规则至少需要一个条件，不能删除最后一个条件。"
        case .displayAliasUnavailable:
            return "此显示器缺少可持久化的可靠标识，暂时不能设置别名。"
        case .historicalDisplayReferenced:
            return "此历史显示器仍被规则引用。请先从相关条件和操作中移除它。"
        case .historicalDisplayNotForgettable:
            return "只能遗忘当前未观察到、且没有被规则引用的历史显示器。"
        case .manualActionUnavailable:
            return "此记录当前没有可执行的手动开启或关闭操作。"
        case .staleManualDisplayCommand:
            return "显示器状态或身份已经变化。请重新打开菜单后再试。"
        }
    }
}

extension ObservableDisplayState {
    var presentationName: String {
        switch self {
        case .online: return "在线"
        case .active: return "活动且可绘制"
        case .disabledByThisAppConnectionUnknown: return "由本应用关闭（连接未知）"
        case .notObserved: return "当前未观察到"
        }
    }
}

extension DisplayAction {
    var presentationName: String {
        switch self {
        case .noAction: return "不处理"
        case .enable: return "开启"
        case .disable: return "关闭"
        }
    }
}

extension DisplayCountKind {
    var presentationName: String {
        switch self {
        case .online: return "在线数量"
        case .active: return "活动且可绘制数量"
        }
    }
}

extension DisplayCountScope {
    var presentationName: String {
        switch self {
        case .all: return "全部显示器"
        case .external: return "外接显示器"
        }
    }
}

extension CountComparisonOperator {
    var presentationName: String {
        switch self {
        case .equal: return "="
        case .greaterThan: return ">"
        case .greaterThanOrEqual: return "≥"
        case .lessThan: return "<"
        case .lessThanOrEqual: return "≤"
        }
    }
}

enum RuleConditionKind: CaseIterable {
    case always
    case count
    case exactState
    case familyState

    var presentationName: String {
        switch self {
        case .always: return "始终"
        case .count: return "显示器数量"
        case .exactState: return "指定显示器状态"
        case .familyState: return "厂商与型号状态"
        }
    }
}

struct DisplayPresentationRow: Equatable {
    var id: String
    var runtimeID: UInt32?
    var target: DisplayTarget?
    var alias: String?
    var systemName: String
    var isBuiltIn: Bool
    var isMain: Bool
    var state: ObservableDisplayState
    var mode: DisplayModeDetails?
    var mirrorsRuntimeID: UInt32?
    var family: DisplayFamily
    var stableIdentity: StableDisplayIdentity?
    var isHistorical: Bool
    var manualAction: DisplayAction?
    var recoveryEvidence: DisplayRecoveryEvidenceKind?
    var recoveryStatusText: String?
    var canForget: Bool
    var forgetExplanation: String

    var title: String {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? systemName : trimmed
    }

    var secondaryName: String? {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == systemName ? nil : systemName
    }

    var kindName: String { isBuiltIn ? "内置显示器" : "外接显示器" }
    var stateSummary: String {
        [state.presentationName, recoveryStatusText].compactMap { $0 }.joined(separator: " · ")
    }

    var manualActionTitle: String? {
        guard let manualAction else { return nil }
        if recoveryEvidence == .pendingConfirmation { return "确认恢复" }
        return manualAction == .enable ? "手动开启" : "手动关闭"
    }


    var rowDetail: String {
        var parts = [kindName, stateSummary]
        if isMain { parts.insert("主显示器", at: 1) }
        return parts.joined(separator: " · ")
    }

    var modeSummary: String {
        guard let mode else { return "当前无可观察模式" }
        let refresh = mode.refreshRate > 0 ? String(format: "%.2f Hz", mode.refreshRate) : "刷新率未知"
        let scale = mode.scaleFactor.map { String(format: "%.2f×", $0) } ?? "缩放未知"
        return "逻辑 \(mode.logicalWidth)×\(mode.logicalHeight) · 像素 \(mode.pixelWidth)×\(mode.pixelHeight) · \(refresh) · 旋转 \(String(format: "%.0f°", mode.rotationDegrees)) · \(scale)"
    }

    var stableIdentitySummary: String {
        guard let stableIdentity else { return "无可靠唯一标识" }
        return "\(stableIdentity.family.vendorID):\(stableIdentity.family.modelID):\(stableIdentity.serialNumber)"
    }
}

struct RuleDisplayOption: Equatable {
    var target: DisplayTarget
    var title: String
    var isBuiltIn: Bool
    var state: ObservableDisplayState?
}

struct OverviewPresentation: Equatable {
    var automaticEnabled: Bool
    var pollingEnabled: Bool
    var pollingInterval: TimeInterval
    var onlineActiveSummary: String
    var automationState: String
    var hasFailure: Bool
    var lastEvaluationSummary: String
    var isPaused: Bool
    var pauseButtonTitle: String
    var recoveryCount: Int
    var recoveryNotice: String?
}

struct MenuPresentation: Equatable {
    var automaticEnabled: Bool
    var pauseTitle: String
    var pauseEnabled: Bool
    var lastEvaluationSummary: String
    var displays: [DisplayPresentationRow]
    var restoreAllEnabled: Bool
    var restoreAllExplanation: String
}
struct ManualDisableConfirmation: Equatable {
    var title: String
    var explanation: String
    var confirmTitle: String
    var isCritical: Bool
}

enum DisplayRecoveryPresentationSeverity: Equatable {
    case normal
    case warning
    case critical
}

struct DisplayRecoveryConfirmationPresentation: Equatable {
    var title: String
    var explanation: String
    var confirmTitle: String
    var details: String
}

struct DisplayRecoveryResultPresentation: Equatable {
    var title: String
    var explanation: String
    var details: String
    var severity: DisplayRecoveryPresentationSeverity
    var retryAvailable: Bool
}


enum PresentationText {
    static let restoreAllTitle = "恢复所有由本应用关闭的显示器…"
    static let noRecoverableDisplays = "当前没有由 Display Steward 管理的可恢复显示器"

    static func displayRecoveryConfirmation(
        _ plan: DisplayRecoveryPlan
    ) -> DisplayRecoveryConfirmationPresentation {
        let details = plan.targets.map { target in
            let name = target.name ?? "运行 ID \(target.display.runtimeID)"
            let identity: String
            if let stable = target.display.stableIdentity {
                identity = "\(stable.family.vendorID):\(stable.family.modelID):\(stable.serialNumber)"
            } else {
                identity = "\(target.display.family.vendorID):\(target.display.family.modelID) · 运行 ID \(target.display.runtimeID)"
            }
            let state = target.evidence == .pendingConfirmation ? "恢复待确认" : "已关闭"
            return "• \(name)（\(identity)）— \(state)"
        }.joined(separator: "\n")
        return DisplayRecoveryConfirmationPresentation(
            title: "恢复这些可恢复显示器？",
            explanation: "将只操作本次系统启动中持有可信恢复证据的显示器。不会更改分辨率、布局、镜像或主显示器。确认后自动化会保持暂停。",
            confirmTitle: "恢复全部",
            details: details
        )
    }

    static func displayRecoveryResult(
        _ result: DisplayRecoveryBatchResult
    ) -> DisplayRecoveryResultPresentation {
        let restored = result.items.filter { $0.disposition == .restored }.count
        let unresolved = result.items.filter { $0.disposition == .unresolved }.count
        let uncertain = result.items.filter { $0.disposition == .uncertain }.count
        let skipped = result.items.filter { $0.disposition == .skipped }.count
        let title: String
        let severity: DisplayRecoveryPresentationSeverity
        if !result.items.isEmpty && restored == result.items.count {
            title = "所有显示器已恢复"
            severity = .normal
        } else if restored > 0 {
            title = "部分显示器已恢复"
            severity = .warning
        } else if unresolved > 0 || uncertain > 0 {
            title = "显示器恢复未完成"
            severity = .critical
        } else {
            title = "没有显示器需要恢复"
            severity = .warning
        }
        let details = result.items.map { item in
            let name = item.target.name ?? "运行 ID \(item.target.display.runtimeID)"
            let state: String
            switch item.disposition {
            case .restored: state = "已恢复"
            case .unresolved: state = "仍需恢复"
            case .uncertain: state = "恢复状态不确定"
            case .skipped: state = "已跳过"
            }
            return "• \(name) — \(state)：\(item.explanation)"
        }.joined(separator: "\n")
        return DisplayRecoveryResultPresentation(
            title: title,
            explanation: "已恢复 \(restored) 台 · 仍需恢复 \(unresolved) 台 · 状态不确定 \(uncertain) 台 · 已跳过 \(skipped) 台。自动化仍保持暂停。",
            details: details,
            severity: severity,
            retryAvailable: result.hasRetryableTargets
        )
    }

    static func manualDisableConfirmation(
        displayName: String,
        isMain: Bool
    ) -> ManualDisableConfirmation {
        if isMain {
            return ManualDisableConfirmation(
                title: "关闭当前主显示器？",
                explanation: "画面可能立即转移或短暂中断。运行时仍会阻止关闭最后一台活动且可绘制的显示器。",
                confirmTitle: "仍要关闭",
                isCritical: true
            )
        }
        return ManualDisableConfirmation(
            title: "手动关闭“\(displayName)”？",
            explanation: "关闭后，这台显示器可能从在线枚举中消失；自动化会暂停。运行时仍会阻止关闭最后一台活动且可绘制的显示器。",
            confirmTitle: "关闭",
            isCritical: false
        )
    }

    static func overview(status: AutomationRuntimeStatus) -> OverviewPresentation {
        let failure = status.diagnostics.last(where: { $0.severity == .error })
        let warning = status.diagnostics.last(where: { $0.severity == .warning })
        let stateText: String
        if let failure {
            stateText = runtimeDiagnostic(failure)
        } else if let pauseReason = status.pauseReason {
            switch pauseReason {
            case .manualDisplayAction:
                stateText = "自动化已暂停：等待显示器拓扑变化，或手动继续"
            case .explicit:
                stateText = "自动化已手动暂停"
            }
        } else if let warning {
            stateText = runtimeDiagnostic(warning)
        } else if !status.configuration.automatic.isEnabled {
            stateText = "自动化已关闭，手动操作与快捷键仍可使用"
        } else {
            stateText = "自动化正在监控显示器状态"
        }
        return OverviewPresentation(
            automaticEnabled: status.configuration.automatic.isEnabled,
            pollingEnabled: status.configuration.polling.isEnabled,
            pollingInterval: status.configuration.polling.intervalSeconds,
            onlineActiveSummary: "在线 \(status.inventory.onlineCount) 台 · 活动且可绘制 \(status.inventory.activeCount) 台",
            automationState: stateText,
            hasFailure: failure != nil,
            lastEvaluationSummary: evaluationSummary(status.lastEvaluation, trigger: status.lastTrigger),
            isPaused: status.isPaused,
            pauseButtonTitle: status.isPaused ? "继续自动化" : "暂停自动化",
            recoveryCount: status.recoveryPlan.targets.count,
            recoveryNotice: status.recoveryPlan.isEmpty
                ? nil
                : "检测到 \(status.recoveryPlan.targets.count) 台由本应用管理的可恢复显示器"
        )
    }

    static func menu(status: AutomationRuntimeStatus) -> MenuPresentation {
        MenuPresentation(
            automaticEnabled: status.configuration.automatic.isEnabled,
            pauseTitle: status.isPaused ? "继续自动化" : "暂停自动化",
            pauseEnabled: status.configuration.automatic.isEnabled || status.isPaused,
            lastEvaluationSummary: evaluationSummary(status.lastEvaluation, trigger: status.lastTrigger),
            displays: displayRows(status: status),
            restoreAllEnabled: !status.recoveryPlan.isEmpty,
            restoreAllExplanation: status.recoveryPlan.isEmpty
                ? noRecoverableDisplays
                : "将恢复 \(status.recoveryPlan.targets.count) 台显示器"
        )
    }

    static func resolveManualDisplayCommand(
        status: AutomationRuntimeStatus,
        rowID: String,
        expectedTarget: DisplayTarget,
        expectedAction: DisplayAction
    ) throws -> DisplayPresentationRow {
        guard let row = displayRows(status: status).first(where: { $0.id == rowID }),
              row.target == expectedTarget,
              row.manualAction == expectedAction,
              row.runtimeID != nil else {
            throw PresentationError.staleManualDisplayCommand
        }
        return row
    }

    static func evaluationSummary(_ plan: RuleEvaluationPlan, trigger: String? = nil) -> String {
        var parts = [
            "匹配 \(plan.matchedRuleIDs.count) 条规则",
            "计划 \(plan.winningActions.count) 个操作"
        ]
        if !plan.safetyBlocks.isEmpty { parts.append("安全阻止 \(plan.safetyBlocks.count) 个") }
        if !plan.conflicts.isEmpty { parts.append("冲突 \(plan.conflicts.count) 个") }
        if !plan.unavailableTargets.isEmpty { parts.append("不可用目标 \(plan.unavailableTargets.count) 个") }
        let summary = parts.joined(separator: " · ")
        guard let trigger, !trigger.isEmpty else { return summary }
        return "\(triggerName(trigger))：\(summary)"
    }

    static func previewSummary(_ preview: ConfigurationPreview) -> String {
        "\(evaluationSummary(preview.evaluation)) · 收敛检查：\(cycleStatus(preview.cycleAnalysis.status))"
    }

    static func cycleStatus(_ status: CycleAnalysisStatus) -> String {
        switch status {
        case .converged: return "可收敛"
        case .deferred: return "等待稳定状态"
        case .invalidInput: return "配置或快照无效"
        case .indeterminate: return "结果不确定"
        case .cycleDetected: return "检测到循环"
        case .transitionLimitReached: return "超过收敛步数"
        }
    }

    static func runtimeDiagnostic(_ diagnostic: RuntimeDiagnostic) -> String {
        switch diagnostic.code {
        case .configurationFallback:
            return "配置文件无效，已使用上次可用配置"
        case .configurationUnavailable:
            return "配置持续读取或写入失败，自动化已停用"
        case .runtimeStateUnavailable:
            return "运行状态不可用，自动化已停用"
        case .staleBootStateDiscarded:
            return "已丢弃上次启动遗留的临时显示器标识"
        case .staleRuntimeIdentityDiscarded:
            return "已丢弃被其他显示器复用的临时运行标识"
        case .legacyRecoveryImported:
            return "已安全导入旧版内置显示器恢复信息"
        case .automationPaused:
            return "自动化已暂停"
        case .actionSuppressed:
            return "暂时抑制了重复失败的显示器操作"
        case .actionFailed:
            return "显示器操作失败，未继续应用本轮计划"
        case .cycleRulesDisabled:
            return "检测到规则循环，相关规则已在本轮隔离"
        case .safetyRecovery:
            return "显示器事务提交后未观察到活动屏幕；自动化已暂停，请立即检查屏幕状态并尝试手动恢复"
        case .statePersistenceFailed:
            return "运行状态保存失败，自动化已停用"
        }
    }

    static func error(_ error: Error) -> String {
        if let presentation = error as? PresentationError {
            return presentation.localizedDescription
        }
        if let validation = error as? ConfigurationValidationError {
            let paths = validation.issues.map(\.path).joined(separator: "、")
            return "规则配置无效，请检查：\(paths)"
        }
        if let coordinator = error as? AutomationCoordinatorError {
            switch coordinator {
            case .displayNotFound: return "当前找不到这台显示器的运行标识，请刷新后重试。"
            case .displayIdentityChanged: return "显示器身份已经变化，请刷新后重试。"
            case .invalidManualAction: return "手动操作必须明确选择开启或关闭。"
            case .lastActiveDisplay: return "为避免黑屏，不能关闭最后一台活动且可绘制的显示器。"
            case .actionFailed: return "显示器操作失败，系统状态可能已经变化，请刷新后重试。"
            }
        }
        return "操作失败：\(error.localizedDescription)"
    }

    private static func triggerName(_ trigger: String) -> String {
        switch trigger {
        case "startup": return "启动检查"
        case "wake": return "唤醒检查"
        case "display-event": return "显示器变化"
        case "poll": return "定时检查"
        case "refresh": return "手动刷新"
        case "save", "save-and-apply": return "保存并应用"
        case "resume": return "继续自动化"
        case "manual", "manual-recovery": return "手动操作"
        case "manual-recovery-preview": return "恢复确认"
        default: return "最近检查"
        }
    }

    static func displayRows(status: AutomationRuntimeStatus) -> [DisplayPresentationRow] {
        status.inventory.displays.map { display in
            let target = target(for: display)
            let known = target.flatMap { matchingHistory(for: $0, in: status.configuration.deviceHistory) }
            let alias = known?.alias
            let systemName = display.name ?? known?.name ?? fallbackDisplayName(display)
            let referenced = target.map { isReferenced($0, by: status.configuration.rules) } ?? false
            let recoveryTarget = status.recoveryPlan.targets.first {
                $0.display.runtimeID == display.runtimeID
                    && $0.display.stableIdentity == display.stableIdentity
                    && $0.display.family == display.family
            }
            let recoveryResult = status.lastRecoveryResult?.items.first {
                $0.target.display.runtimeID == display.runtimeID
                    && $0.target.display.stableIdentity == display.stableIdentity
                    && $0.target.display.family == display.family
            }
            let recoveryStatusText: String?
            if let recoveryTarget {
                switch recoveryResult?.disposition {
                case .unresolved: recoveryStatusText = "仍需恢复"
                case .uncertain: recoveryStatusText = "恢复状态不确定"
                case .restored, .skipped, .none:
                    recoveryStatusText = recoveryTarget.evidence == .pendingConfirmation
                        ? "恢复待确认"
                        : nil
                }
            } else {
                recoveryStatusText = recoveryResult?.disposition == .restored ? "已恢复" : nil
            }
            let historical = display.state == .notObserved
            let hasActionableIdentity = display.runtimeID != nil && display.family.isValid
            let manualAction: DisplayAction?
            if recoveryTarget != nil {
                manualAction = hasActionableIdentity ? .enable : nil
            } else {
                switch display.state {
                case .active, .online:
                    manualAction = hasActionableIdentity ? .disable : nil
                case .disabledByThisAppConnectionUnknown:
                    manualAction = hasActionableIdentity ? .enable : nil
                case .notObserved:
                    manualAction = nil
                }
            }
            let forgetExplanation: String
            if !historical {
                forgetExplanation = "当前记录不能遗忘；只有未观察到的历史记录可以遗忘。"
            } else if referenced {
                forgetExplanation = "此历史记录仍被规则引用，请先移除相关条件或操作。"
            } else if target == nil {
                forgetExplanation = "此记录缺少可靠标识，无法从配置中安全移除。"
            } else {
                forgetExplanation = "遗忘只会移除这条历史记录和别名，不会更改显示器状态。"
            }
            return DisplayPresentationRow(
                id: displayRowID(display: display, target: target),
                runtimeID: display.runtimeID,
                target: target,
                alias: alias,
                systemName: systemName,
                isBuiltIn: display.isBuiltIn,
                isMain: display.isMain,
                state: display.state,
                mode: display.mode,
                mirrorsRuntimeID: display.mirrorsRuntimeID,
                family: display.family,
                stableIdentity: display.stableIdentity,
                isHistorical: historical,
                manualAction: manualAction,
                recoveryEvidence: recoveryTarget?.evidence,
                recoveryStatusText: recoveryStatusText,
                canForget: historical && !referenced && target != nil,
                forgetExplanation: forgetExplanation
            )
        }
    }

    static func targetOptions(configuration: AppConfiguration, inventory: ObservedDisplaySnapshot) -> [RuleDisplayOption] {
        var options: [DisplayTarget: RuleDisplayOption] = [:]
        let rows = displayRows(status: AutomationRuntimeStatus(
            configuration: configuration,
            inventory: inventory,
            lastEvaluation: .empty,
            lastCycleAnalysis: nil,
            lastTrigger: nil,
            pauseReason: nil,
            diagnostics: [],
            configurationLoadSource: nil
        ))
        for row in rows {
            guard let target = row.target else { continue }
            options[target] = RuleDisplayOption(
                target: target,
                title: row.title,
                isBuiltIn: row.isBuiltIn,
                state: row.state
            )
        }
        for known in configuration.deviceHistory where options[known.target] == nil {
            options[known.target] = RuleDisplayOption(
                target: known.target,
                title: nonempty(known.alias) ?? nonempty(known.name) ?? targetName(known.target),
                isBuiltIn: known.isBuiltIn,
                state: nil
            )
        }
        for rule in configuration.rules {
            for target in rule.actions.map(\.target) where options[target] == nil {
                options[target] = RuleDisplayOption(target: target, title: targetName(target), isBuiltIn: false, state: nil)
            }
            for condition in rule.conditions {
                let target: DisplayTarget?
                switch condition {
                case .exactState(let identity, _): target = .exact(identity)
                case .familyState(let family, _): target = .family(family)
                default: target = nil
                }
                if let target, options[target] == nil {
                    options[target] = RuleDisplayOption(target: target, title: targetName(target), isBuiltIn: false, state: nil)
                }
            }
        }
        let exactOptions = options.values.compactMap { option -> (RuleDisplayOption, StableDisplayIdentity)? in
            guard case .exact(let identity) = option.target else { return nil }
            return (option, identity)
        }
        for (option, identity) in exactOptions where identity.family.isValid {
            let familyTarget = DisplayTarget.family(identity.family)
            if var existing = options[familyTarget] {
                existing.isBuiltIn = existing.isBuiltIn || option.isBuiltIn
                options[familyTarget] = existing
            } else {
                options[familyTarget] = RuleDisplayOption(
                    target: familyTarget,
                    title: "\(targetName(familyTarget))（同系列全部）",
                    isBuiltIn: option.isBuiltIn,
                    state: nil
                )
            }
        }
        return options.values.sorted {
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    static func targetName(_ target: DisplayTarget) -> String {
        switch target {
        case .exact(let identity):
            return "显示器 \(identity.family.vendorID):\(identity.family.modelID) · 序列号 \(identity.serialNumber)"
        case .family(let family):
            return "显示器系列 \(family.vendorID):\(family.modelID)"
        }
    }

    static func target(for display: ObservedDisplay) -> DisplayTarget? {
        if let identity = display.stableIdentity, identity.isReliable { return .exact(identity) }
        if display.family.isValid { return .family(display.family) }
        return nil
    }

    static func matchingHistory(for target: DisplayTarget, in history: [KnownDisplay]) -> KnownDisplay? {
        history.first(where: { $0.target == target })
    }

    static func isReferenced(_ historyTarget: DisplayTarget, by rules: [DisplayRule]) -> Bool {
        rules.contains { rule in
            rule.actions.contains { $0.action != .noAction && targetsOverlap($0.target, historyTarget) }
                || rule.conditions.contains { condition in
                    switch condition {
                    case .exactState(let identity, _): return targetsOverlap(.exact(identity), historyTarget)
                    case .familyState(let family, _): return targetsOverlap(.family(family), historyTarget)
                    default: return false
                    }
                }
        }
    }

    static func targetsOverlap(_ lhs: DisplayTarget, _ rhs: DisplayTarget) -> Bool {
        switch (lhs, rhs) {
        case let (.exact(left), .exact(right)): return left == right
        case let (.family(left), .family(right)): return left == right
        case let (.exact(identity), .family(family)), let (.family(family), .exact(identity)):
            return identity.family == family
        }
    }

    private static func displayRowID(display: ObservedDisplay, target: DisplayTarget?) -> String {
        if display.state != .notObserved, let runtimeID = display.runtimeID {
            return target.map { "runtime:\(runtimeID):\(targetKey($0))" } ?? "runtime:\(runtimeID)"
        }
        if let target { return "history:\(targetKey(target))" }
        return "history:unknown:\(display.family.vendorID):\(display.family.modelID)"
    }

    private static func targetKey(_ target: DisplayTarget) -> String {
        switch target {
        case .exact(let identity):
            return "exact:\(identity.family.vendorID):\(identity.family.modelID):\(identity.serialNumber)"
        case .family(let family):
            return "family:\(family.vendorID):\(family.modelID)"
        }
    }

    private static func fallbackDisplayName(_ display: ObservedDisplay) -> String {
        display.isBuiltIn ? "内置显示器" : "未命名外接显示器"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

final class OverviewViewModel {
    let runtime: DisplayManagingRuntime

    init(runtime: DisplayManagingRuntime) {
        self.runtime = runtime
    }

    var presentation: OverviewPresentation { PresentationText.overview(status: runtime.status) }

    @discardableResult
    func setAutomaticEnabled(_ enabled: Bool) throws -> AutomationRuntimeStatus {
        var configuration = runtime.status.configuration
        configuration.automatic.isEnabled = enabled
        return try runtime.updateConfiguration(configuration, applyImmediately: true)
    }

    @discardableResult
    func setPollingEnabled(_ enabled: Bool) throws -> AutomationRuntimeStatus {
        var configuration = runtime.status.configuration
        configuration.polling.isEnabled = enabled
        return try runtime.updateConfiguration(configuration, applyImmediately: false)
    }

    @discardableResult
    func setPollingInterval(_ interval: TimeInterval) throws -> AutomationRuntimeStatus {
        var configuration = runtime.status.configuration
        configuration.polling.intervalSeconds = min(3600, max(1, interval))
        return try runtime.updateConfiguration(configuration, applyImmediately: false)
    }

    func togglePause() {
        runtime.status.isPaused ? runtime.resume() : runtime.pause()
    }

    @discardableResult
    func refresh() throws -> AutomationRuntimeStatus { try runtime.refresh() }

    func prepareDisplayRecovery(only targets: [DisplayRecoveryTarget]? = nil) throws -> DisplayRecoveryPlan {
        try runtime.prepareDisplayRecovery(only: targets)
    }

    func restoreDisplays(_ plan: DisplayRecoveryPlan) -> DisplayRecoveryBatchResult {
        runtime.restoreDisplays(plan)
    }
}

final class RulesEditorViewModel {
    let runtime: DisplayManagingRuntime
    private(set) var baselineConfiguration: AppConfiguration
    private(set) var draftConfiguration: AppConfiguration
    private(set) var selectedRuleID: UUID?
    private(set) var lastPreview: ConfigurationPreview?

    init(runtime: DisplayManagingRuntime) {
        self.runtime = runtime
        var initial = runtime.status.configuration
        initial.rules = Self.rulesInPriorityOrder(initial.rules)
        baselineConfiguration = initial
        draftConfiguration = initial
        selectedRuleID = draftConfiguration.rules.first?.id
    }

    var isDirty: Bool { draftConfiguration.rules != baselineConfiguration.rules }

    var selectedRule: DisplayRule? {
        guard let selectedRuleID else { return nil }
        return draftConfiguration.rules.first(where: { $0.id == selectedRuleID })
    }

    func reloadFromRuntime() {
        var current = runtime.status.configuration
        current.rules = Self.rulesInPriorityOrder(current.rules)
        baselineConfiguration = current
        draftConfiguration = current
        if let selectedRuleID, draftConfiguration.rules.contains(where: { $0.id == selectedRuleID }) {
            self.selectedRuleID = selectedRuleID
        } else {
            selectedRuleID = draftConfiguration.rules.first?.id
        }
        lastPreview = nil
    }

    func synchronizeHistory() {
        let latest = runtime.status.configuration.deviceHistory
        for known in latest {
            if let index = draftConfiguration.deviceHistory.firstIndex(where: { $0.target == known.target }) {
                let alias = draftConfiguration.deviceHistory[index].alias
                draftConfiguration.deviceHistory[index] = known
                draftConfiguration.deviceHistory[index].alias = alias ?? known.alias
            } else {
                draftConfiguration.deviceHistory.append(known)
            }
        }
    }

    func selectRule(id: UUID?) { selectedRuleID = id }

    @discardableResult
    func addRule() throws -> DisplayRule {
        let targets = targetOptions()
        guard !targets.isEmpty else { throw PresentationError.noReliableDisplayTarget }
        let priority = nextLowestPriority()
        let rule = DisplayRule(
            id: UUID(),
            name: "新规则",
            isEnabled: true,
            priority: priority,
            conditions: [.always],
            actions: targets.map { TargetAction(target: $0.target, action: .noAction) }
        )
        draftConfiguration.rules.append(rule)
        selectedRuleID = rule.id
        lastPreview = nil
        return rule
    }

    @discardableResult
    func duplicateSelectedRule() throws -> DisplayRule {
        guard let selectedRule,
              let index = draftConfiguration.rules.firstIndex(where: { $0.id == selectedRule.id }) else {
            throw PresentationError.emptyRuleName
        }
        var copy = selectedRule
        copy.id = UUID()
        copy.name = "\(selectedRule.name) 副本"
        draftConfiguration.rules.insert(copy, at: index + 1)
        selectedRuleID = copy.id
        lastPreview = nil
        return copy
    }

    func deleteSelectedRule() {
        guard let selectedRuleID,
              let index = draftConfiguration.rules.firstIndex(where: { $0.id == selectedRuleID }) else { return }
        draftConfiguration.rules.remove(at: index)
        if draftConfiguration.rules.indices.contains(index) {
            self.selectedRuleID = draftConfiguration.rules[index].id
        } else {
            self.selectedRuleID = draftConfiguration.rules.last?.id
        }
        lastPreview = nil
    }

    func moveRule(from source: Int, to destination: Int) {
        guard draftConfiguration.rules.indices.contains(source) else { return }
        let rule = draftConfiguration.rules.remove(at: source)
        let adjusted = source < destination ? destination - 1 : destination
        let target = min(max(0, adjusted), draftConfiguration.rules.count)
        draftConfiguration.rules.insert(rule, at: target)
        rebalancePriorities()
        selectedRuleID = rule.id
        lastPreview = nil
    }

    func setRuleEnabled(id: UUID, enabled: Bool) {
        guard let index = draftConfiguration.rules.firstIndex(where: { $0.id == id }) else { return }
        draftConfiguration.rules[index].isEnabled = enabled
        lastPreview = nil
    }

    func updateSelectedRule(_ change: (inout DisplayRule) -> Void) {
        guard let selectedRuleID,
              let index = draftConfiguration.rules.firstIndex(where: { $0.id == selectedRuleID }) else { return }
        change(&draftConfiguration.rules[index])
        lastPreview = nil
    }

    func addCondition() {
        updateSelectedRule { rule in
            let condition = RuleCondition.count(DisplayCountCondition(
                kind: .online,
                scope: .all,
                comparison: .equal,
                value: 1
            ))
            if rule.conditions == [.always] {
                rule.conditions = [condition]
            } else {
                rule.conditions.append(condition)
            }
        }
    }

    func removeCondition(at index: Int) throws {
        guard let rule = selectedRule, rule.conditions.count > 1 else {
            throw PresentationError.conditionCannotBeRemoved
        }
        updateSelectedRule { rule in
            guard rule.conditions.indices.contains(index) else { return }
            rule.conditions.remove(at: index)
        }
    }

    func replaceCondition(at index: Int, with condition: RuleCondition) {
        updateSelectedRule { rule in
            guard rule.conditions.indices.contains(index) else { return }
            if condition == .always {
                rule.conditions = [.always]
            } else {
                rule.conditions[index] = condition
            }
        }
    }

    func setAction(_ action: DisplayAction, for target: DisplayTarget) {
        updateSelectedRule { rule in
            if let index = rule.actions.firstIndex(where: { $0.target == target }) {
                rule.actions[index].action = action
            } else {
                rule.actions.append(TargetAction(target: target, action: action))
            }
        }
    }

    func targetOptions() -> [RuleDisplayOption] {
        PresentationText.targetOptions(configuration: draftConfiguration, inventory: runtime.status.inventory)
    }

    func synchronizeActionMatrix() {
        let targets = targetOptions().map(\.target)
        guard !targets.isEmpty else { return }
        for index in draftConfiguration.rules.indices {
            for target in targets where !draftConfiguration.rules[index].actions.contains(where: { $0.target == target }) {
                draftConfiguration.rules[index].actions.append(TargetAction(target: target, action: .noAction))
            }
        }
    }

    func validateDraft() throws {
        for rule in draftConfiguration.rules {
            if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PresentationError.emptyRuleName
            }
            if rule.conditions.isEmpty { throw PresentationError.emptyConditions }
            if rule.actions.isEmpty { throw PresentationError.emptyActions }
        }
        try candidateConfiguration(rules: draftConfiguration.rules).validate()
    }

    @discardableResult
    func preview() throws -> ConfigurationPreview {
        synchronizeActionMatrix()
        try validateDraft()
        let candidate = candidateConfiguration(rules: draftConfiguration.rules)
        let preview = try runtime.previewConfigurationReadOnly(
            candidate,
            observation: runtime.status.inventory
        )
        lastPreview = preview
        return preview
    }

    @discardableResult
    func saveAndApply() throws -> AutomationRuntimeStatus {
        synchronizeActionMatrix()
        try validateDraft()
        let candidate = candidateConfiguration(rules: draftConfiguration.rules)
        let status = try runtime.updateConfiguration(candidate, applyImmediately: true)
        var saved = status.configuration
        saved.rules = Self.rulesInPriorityOrder(saved.rules)
        baselineConfiguration = saved
        draftConfiguration = saved
        lastPreview = nil
        return status
    }

    func defaultRulesCandidate() throws -> (configuration: AppConfiguration, preview: ConfigurationPreview) {
        let options = targetOptions()
        let target = options.first(where: {
            guard $0.isBuiltIn, case .exact = $0.target else { return false }
            return true
        })?.target ?? options.first(where: { $0.isBuiltIn })?.target
            ?? runtime.status.configuration.deviceHistory.first(where: { $0.isBuiltIn })?.target
        guard let target else { throw PresentationError.noBuiltInDisplayTarget }
        var candidate = runtime.status.configuration
        candidate.rules = LegacyConfigurationMigrator.defaultExternalRules(target: target)
        if candidate.rules.indices.contains(0) { candidate.rules[0].name = "检测到外接显示器" }
        if candidate.rules.indices.contains(1) { candidate.rules[1].name = "未检测到外接显示器" }
        try candidate.validate()
        let preview = try runtime.previewConfigurationReadOnly(
            candidate,
            observation: runtime.status.inventory
        )
        return (candidate, preview)
    }

    @discardableResult
    func applyDefaultRulesCandidate(_ candidate: AppConfiguration) throws -> AutomationRuntimeStatus {
        let currentCandidate = candidateConfiguration(rules: candidate.rules)
        try currentCandidate.validate()
        let status = try runtime.updateConfiguration(currentCandidate, applyImmediately: true)
        var saved = status.configuration
        saved.rules = Self.rulesInPriorityOrder(saved.rules)
        baselineConfiguration = saved
        draftConfiguration = saved
        selectedRuleID = draftConfiguration.rules.first?.id
        lastPreview = nil
        return status
    }

    private func candidateConfiguration(rules: [DisplayRule]) -> AppConfiguration {
        var candidate = runtime.status.configuration
        candidate.rules = rules
        return candidate
    }

    private func nextLowestPriority() -> Int {
        guard let minimum = draftConfiguration.rules.map(\.priority).min() else { return 10 }
        return minimum == Int.min ? Int.min : minimum - 1
    }

    private func rebalancePriorities() {
        let count = draftConfiguration.rules.count
        for index in draftConfiguration.rules.indices {
            draftConfiguration.rules[index].priority = (count - index) * 10
        }
    }

    private static func rulesInPriorityOrder(_ rules: [DisplayRule]) -> [DisplayRule] {
        rules.enumerated().sorted { lhs, rhs in
            if lhs.element.priority != rhs.element.priority {
                return lhs.element.priority > rhs.element.priority
            }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }
}

final class DisplaysViewModel {
    let runtime: DisplayManagingRuntime

    init(runtime: DisplayManagingRuntime) {
        self.runtime = runtime
    }

    var rows: [DisplayPresentationRow] { PresentationText.displayRows(status: runtime.status) }
    var currentRows: [DisplayPresentationRow] { rows.filter { !$0.isHistorical } }
    var historicalRows: [DisplayPresentationRow] { rows.filter(\.isHistorical) }

    func row(id: String) -> DisplayPresentationRow? { rows.first(where: { $0.id == id }) }

    @discardableResult
    func refresh() throws -> AutomationRuntimeStatus { try runtime.refresh() }

    func prepareDisplayRecovery(only targets: [DisplayRecoveryTarget]? = nil) throws -> DisplayRecoveryPlan {
        try runtime.prepareDisplayRecovery(only: targets)
    }

    func restoreDisplays(_ plan: DisplayRecoveryPlan) -> DisplayRecoveryBatchResult {
        runtime.restoreDisplays(plan)
    }

    @discardableResult
    func setAlias(_ alias: String, for rowID: String) throws -> AutomationRuntimeStatus {
        guard let row = row(id: rowID), let target = row.target else {
            throw PresentationError.displayAliasUnavailable
        }
        var configuration = runtime.status.configuration
        let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = configuration.deviceHistory.firstIndex(where: { $0.target == target }) {
            configuration.deviceHistory[index].alias = normalized.isEmpty ? nil : normalized
        } else {
            configuration.deviceHistory.append(KnownDisplay(
                target: target,
                name: row.systemName,
                isBuiltIn: row.isBuiltIn,
                alias: normalized.isEmpty ? nil : normalized
            ))
        }
        return try runtime.updateConfiguration(configuration, applyImmediately: false)
    }

    @discardableResult
    func performManualAction(for rowID: String) throws -> AutomationRuntimeStatus {
        guard let row = row(id: rowID), let runtimeID = row.runtimeID, let action = row.manualAction else {
            throw PresentationError.manualActionUnavailable
        }
        return try runtime.performManualAction(runtimeID: runtimeID, action: action)
    }

    @discardableResult
    func forget(rowID: String) throws -> AutomationRuntimeStatus {
        guard let row = row(id: rowID), row.isHistorical, let target = row.target else {
            throw PresentationError.historicalDisplayNotForgettable
        }
        guard !PresentationText.isReferenced(target, by: runtime.status.configuration.rules) else {
            throw PresentationError.historicalDisplayReferenced
        }
        var configuration = runtime.status.configuration
        configuration.deviceHistory.removeAll { $0.target == target }
        return try runtime.updateConfiguration(configuration, applyImmediately: false)
    }
}
