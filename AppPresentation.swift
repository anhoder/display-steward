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
    case noSelectedProfile
    case staleProfileDraft
    case dirtyProfileDraft
    case profileAlreadyActive
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
        case .noSelectedProfile:
            return "请先选择一个显示配置档。"
        case .staleProfileDraft:
            return "配置档草稿已经过期。请重新选择配置档后再编辑。"
        case .dirtyProfileDraft:
            return "请先保存、放弃或取消当前配置档的修改。"
        case .profileAlreadyActive:
            return "所选配置档已经是当前配置档。"
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

struct SettingsSummaryPresentation: Equatable {
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
struct ProfileMenuEntryPresentation: Equatable {
    var id: UUID
    var title: String
    var isActive: Bool
}

struct ProfileActivationConfirmationPresentation: Equatable {
    var requiresConfirmation: Bool
    var title: String
    var explanation: String
    var confirmTitle: String
    var isCritical: Bool
}
enum ApplicationSettingsReloadSeverity: Equatable {
    case warning
    case critical
}

struct ApplicationSettingsReloadNoticePresentation: Equatable {
    var title: String
    var explanation: String
    var severity: ApplicationSettingsReloadSeverity
    var blocksProfileReloadApply: Bool
}


enum ProfileDraftResolution: Equatable {
    case save
    case discard
    case cancel
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

    static func settingsSummary(status: AutomationRuntimeStatus) -> SettingsSummaryPresentation {
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
        return SettingsSummaryPresentation(
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
    static func profileMenuEntries(status: AutomationRuntimeStatus) -> [ProfileMenuEntryPresentation] {
        let activeID = status.activeProfile?.id
        var profiles = status.profileCatalog.profiles
        if let active = status.activeProfile {
            if let index = profiles.firstIndex(where: { $0.id == active.id }) { profiles[index] = active }
            else { profiles.append(active) }
        }
        return profiles.sorted(by: DisplayProfile.orderedByName).map {
            ProfileMenuEntryPresentation(id: $0.id, title: $0.name, isActive: $0.id == activeID)
        }
    }

    static func profileRules(status: AutomationRuntimeStatus) -> [DisplayRule] {
        var rules = status.profileCatalog.profiles.flatMap(\.rules)
        if let active = status.activeProfile,
           !status.profileCatalog.profiles.contains(where: { $0 == active }) {
            rules.append(contentsOf: active.rules)
        }
        return rules.isEmpty ? status.configuration.rules : rules
    }
    static func applicationSettingsReloadNotices(
        status: AutomationRuntimeStatus
    ) -> [ApplicationSettingsReloadNoticePresentation] {
        var notices: [ApplicationSettingsReloadNoticePresentation] = []
        if status.externalSettingsGenerationSource == .lastKnownGoodBackup {
            notices.append(ApplicationSettingsReloadNoticePresentation(
                title: "磁盘应用设置正在使用上次可用版本",
                explanation: "主应用设置文件无法读取，本次重新加载只读到了上次可用备份。当前运行设置保持不变，主文件也未被自动修复；请修复文件后重试，或保存当前工作后重启应用。",
                severity: .warning,
                blocksProfileReloadApply: false
            ))
        } else if status.externalSettingsGenerationSource == nil,
                  status.externalSettingsErrorDescription != nil {
            notices.append(ApplicationSettingsReloadNoticePresentation(
                title: "无法读取磁盘应用设置",
                explanation: "磁盘上的主应用设置和上次可用备份都不可用。当前运行设置保持不变，也没有注册磁盘中的快捷键；请检查文件后重新加载或重启应用。",
                severity: .critical,
                blocksProfileReloadApply: true
            ))
        }

        if hasExternalGlobalSettingsDrift(status: status) {
            guard let external = status.externalApplicationSettings else { return notices }
            var differences: [String] = []
            if external.hotKey != status.configuration.hotKey { differences.append("全局快捷键") }
            if external.deviceHistory != status.configuration.deviceHistory { differences.append("显示器历史与别名") }
            notices.append(ApplicationSettingsReloadNoticePresentation(
                title: "磁盘应用设置与当前运行值不同",
                explanation: "检测到磁盘上的\(differences.joined(separator: "、"))发生变化。重新加载没有应用这些变化，也没有注册磁盘中的全局快捷键；当前运行值保持不变。若要采用磁盘值，请保存当前工作后重启应用，或修复文件后重试。若同时发现当前配置档变化，本次也不会应用。",
                severity: .warning,
                blocksProfileReloadApply: true
            ))
        }
        return notices
    }

    static func hasExternalGlobalSettingsDrift(status: AutomationRuntimeStatus) -> Bool {
        guard let external = status.externalApplicationSettings else { return false }
        return external.hotKey != status.configuration.hotKey
            || external.deviceHistory != status.configuration.deviceHistory
    }


    static func profileActivationConfirmation(
        _ preview: ProfileActivationPreview
    ) -> ProfileActivationConfirmationPresentation {
        let disableCount = preview.evaluation.winningActions.filter { $0.action == .disable }.count
        let conflictCount = preview.evaluation.conflicts.count
        let safetyCount = preview.evaluation.safetyBlocks.count
        let cycleRequiresConfirmation = preview.cycleAnalysis.status != .converged
        let usesFallback = preview.profileSource == .lastKnownGoodBackup
        let requiresConfirmation = disableCount > 0
            || conflictCount > 0
            || safetyCount > 0
            || cycleRequiresConfirmation
            || usesFallback

        var reasons: [String] = []
        if disableCount > 0 { reasons.append("当前预览包含 \(disableCount) 个关闭显示器操作") }
        if conflictCount > 0 { reasons.append("有 \(conflictCount) 个同优先级操作冲突，运行时不会猜测结果") }
        if safetyCount > 0 { reasons.append("有 \(safetyCount) 个操作已被最后活动显示器等安全约束阻止") }
        if cycleRequiresConfirmation {
            reasons.append("规则收敛检查为“\(cycleStatus(preview.cycleAnalysis.status))”")
        }
        if usesFallback {
            reasons.append("该配置档将从上次可用备份激活，原文件仍保持无效状态")
        }

        let explanation: String
        if reasons.isEmpty {
            explanation = "当前预览只包含开启操作或无需操作，将直接切换当前配置档并立即评估。"
        } else {
            explanation = reasons.map { "• \($0)" }.joined(separator: "\n")
                + "\n\n确认后会先保留新的当前配置档选择；即使部分显示器操作未完成，也不会回退选择。"
        }
        let severeCycle: Bool
        switch preview.cycleAnalysis.status {
        case .invalidInput, .indeterminate, .cycleDetected, .transitionLimitReached:
            severeCycle = true
        case .converged, .deferred:
            severeCycle = false
        }
        return ProfileActivationConfirmationPresentation(
            requiresConfirmation: requiresConfirmation,
            title: disableCount > 0
                ? "激活“\(preview.profile.name)”将关闭显示器"
                : "激活“\(preview.profile.name)”前请确认",
            explanation: explanation,
            confirmTitle: requiresConfirmation ? "仍要激活" : "激活",
            isCritical: disableCount > 0 || safetyCount > 0 || severeCycle
        )
    }

    static func profileActivationResult(_ result: ProfileActivationResult) -> String {
        let selection = "“\(result.activeProfile.name)”已设为当前配置档。"
        switch result.hardwareOutcome {
        case .notNeeded:
            return "\(selection) 当前显示器无需更改。"
        case .applied:
            return "\(selection) 显示器操作已全部应用。"
        case .partiallyFailed:
            return "\(selection) 部分显示器操作未完成；当前配置档选择仍已保留，请查看状态与诊断。"
        case .failed:
            return "\(selection) 显示器操作未完成；当前配置档选择仍已保留，请刷新状态后重试。"
        case .blockedBySafety:
            return "\(selection) 显示器操作已被安全约束阻止；当前配置档选择仍已保留。"
        }
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
            case .staleProfileActivationPreview: return "激活预览已过期：配置档内容或显示器拓扑已经变化。未切换当前配置档，也未执行显示器操作，请重新预览。"
            }
        }
        if let store = error as? ConfigurationStoreError {
            switch store {
            case .configurationMissing: return "应用设置不可用。"
            case .unreadablePrimaryAndBackup: return "主配置和上次可用备份都无法读取。"
            case .activeProfileUnavailable: return "当前配置档不可用。"
            case .profileNotFound: return "所选显示配置档不存在，请重新加载列表。"
            case .profileCatalogConflict: return "所选显示配置档与磁盘目录冲突，请先处理错误条目。"
            case .profileNameAlreadyExists(let name): return "已经存在名为“\(name)”的显示配置档。"
            case .cannotDeleteActiveProfile: return "不能删除当前配置档。请先激活另一个配置档。"
            case .cannotDeleteLastProfile: return "至少需要保留一个显示配置档。"
            case .profileRestoreNotNeeded: return "该显示配置档的主文件有效，无需恢复。"
            case .profileRestoreUnavailable: return "没有可用的上次可用备份，无法恢复该配置档。"
            case .invalidProfileFileName: return "错误配置档的文件名无效，未执行移除。"
            case .deletionStateInvalid:
                return "待完成的配置档删除记录无效，无法安全继续；应用已停止删除，请重新加载并检查配置档列表。"
            case .invalidProfileNotFound: return "该错误配置档条目已经变化，请重新加载列表。"
            case .migrationProfileConflict, .migrationSettingsConflict, .migrationCatalogConflict, .migrationStateInvalid:
                return "旧配置迁移存在冲突，未改写现有配置。"
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
        let referenceRules = profileRules(status: status)
        return status.inventory.displays.map { display in
            let target = target(for: display)
            let known = target.flatMap { matchingHistory(for: $0, in: status.configuration.deviceHistory) }
            let alias = known?.alias
            let systemName = display.name ?? known?.name ?? fallbackDisplayName(display)
            let referenced = target.map { isReferenced($0, by: referenceRules) } ?? false
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

final class SettingsSummaryViewModel {
    let runtime: DisplayManagingRuntime

    init(runtime: DisplayManagingRuntime) {
        self.runtime = runtime
    }

    var presentation: SettingsSummaryPresentation { PresentationText.settingsSummary(status: runtime.status) }

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

final class ProfileManagementViewModel {
    let runtime: DisplayManagingRuntime
    private(set) var selectedProfileID: UUID?
    private(set) var baselineProfile: DisplayProfile?
    private(set) var draftProfile: DisplayProfile?
    private(set) var selectedRuleID: UUID?
    private(set) var lastPreview: ConfigurationPreview?
    private var ignoredExternalActiveProfileID: UUID?

    init(runtime: DisplayManagingRuntime) {
        self.runtime = runtime
        let initial = runtime.status.activeProfile
            ?? runtime.status.profileCatalog.profiles.sorted(by: DisplayProfile.orderedByName).first
        installDraft(initial, preservingRuleSelection: false)
    }

    var profiles: [DisplayProfile] {
        var profiles = runtime.status.profileCatalog.profiles
        if let active = runtime.status.activeProfile {
            if let index = profiles.firstIndex(where: { $0.id == active.id }) { profiles[index] = active }
            else { profiles.append(active) }
        }
        return profiles.sorted(by: DisplayProfile.orderedByName)
    }

    var invalidProfiles: [InvalidDisplayProfile] {
        runtime.status.profileCatalog.invalidProfiles.sorted { $0.fileName < $1.fileName }
    }

    var activeProfileID: UUID? { runtime.status.activeProfile?.id }
    var isSelectedProfileActive: Bool { selectedProfileID != nil && selectedProfileID == activeProfileID }
    var isDirty: Bool { baselineProfile != draftProfile }
    var hasExternalActiveProfileDrift: Bool { externalActiveProfileID != nil }
    var externalActiveProfileID: UUID? {
        guard runtime.status.externalActiveProfileID != ignoredExternalActiveProfileID else { return nil }
        return runtime.status.externalActiveProfileID
    }

    var selectedRule: DisplayRule? {
        guard let selectedRuleID else { return nil }
        return draftProfile?.rules.first(where: { $0.id == selectedRuleID })
    }

    var draftConfiguration: AppConfiguration {
        guard let draftProfile else { return runtime.status.configuration }
        return configuration(assembling: draftProfile)
    }

    func refreshFromRuntime() {
        if runtime.status.externalActiveProfileID == nil { ignoredExternalActiveProfileID = nil }
        guard !isDirty else { return }
        let selected = selectedProfileID.flatMap { profileForEditing(id: $0) }
        let replacement = selected
            ?? runtime.status.activeProfile
            ?? profiles.first
        installDraft(replacement, preservingRuleSelection: true)
    }

    @discardableResult
    func selectProfile(
        id: UUID,
        resolvingDirtyWith resolution: ProfileDraftResolution? = nil
    ) throws -> Bool {
        guard id != selectedProfileID else { return true }
        if isDirty {
            guard let resolution else { return false }
            guard try resolveDirtyDraft(resolution) else { return false }
        }
        guard let profile = profileForEditing(id: id) else { throw PresentationError.noSelectedProfile }
        installDraft(profile, preservingRuleSelection: false)
        return true
    }

    @discardableResult
    func resolveDirtyDraft(_ resolution: ProfileDraftResolution) throws -> Bool {
        guard isDirty else { return true }
        switch resolution {
        case .save:
            _ = try saveSelectedProfile()
            return true
        case .discard:
            discardDraft()
            return true
        case .cancel:
            return false
        }
    }
    func prepareForExternalProfileActivation(
        resolve: () -> ProfileDraftResolution
    ) throws -> Bool {
        guard isDirty else { return true }
        return try resolveDirtyDraft(resolve())
    }

    func discardDraft() {
        draftProfile = baselineProfile
        selectedRuleID = draftProfile?.rules.first?.id
        lastPreview = nil
    }

    func updateDraft(_ change: (inout DisplayProfile) -> Void) {
        guard var profile = draftProfile, profile.id == selectedProfileID else { return }
        change(&profile)
        guard profile.id == selectedProfileID else { return }
        draftProfile = profile
        lastPreview = nil
    }

    func setProfileName(_ name: String) { updateDraft { $0.name = name } }
    func setAutomaticEnabled(_ enabled: Bool) { updateDraft { $0.automatic.isEnabled = enabled } }
    func setPollingEnabled(_ enabled: Bool) { updateDraft { $0.polling.isEnabled = enabled } }
    func setPollingInterval(_ interval: TimeInterval) {
        updateDraft { $0.polling.intervalSeconds = min(3600, max(1, interval)) }
    }

    @discardableResult
    func saveSelectedProfile() throws -> AutomationRuntimeStatus {
        synchronizeActionMatrix()
        try validateDraft()
        guard let selectedProfileID,
              let baselineProfile,
              let draftProfile,
              baselineProfile.id == selectedProfileID,
              draftProfile.id == selectedProfileID else {
            throw PresentationError.staleProfileDraft
        }
        let status = try runtime.saveProfile(draftProfile, applyImmediately: isSelectedProfileActive)
        let persisted = selectedProfileID == status.activeProfile?.id
            ? status.activeProfile
            : status.profileCatalog.profiles.first(where: { $0.id == selectedProfileID })
        installDraft(persisted ?? draftProfile, preservingRuleSelection: true)
        return status
    }

    func previewSelectedProfileActivation() throws -> ProfileActivationPreview {
        guard let selectedProfileID else { throw PresentationError.noSelectedProfile }
        guard !isDirty else { throw PresentationError.dirtyProfileDraft }
        return try runtime.previewProfileActivation(id: selectedProfileID, observation: nil)
    }

    @discardableResult
    func activateSelectedProfile(
        confirmedPreview: ProfileActivationPreview
    ) throws -> ProfileActivationResult {
        guard let selectedProfileID else { throw PresentationError.noSelectedProfile }
        guard !isDirty else { throw PresentationError.dirtyProfileDraft }
        guard selectedProfileID != activeProfileID else { throw PresentationError.profileAlreadyActive }
        guard confirmedPreview.profile.id == selectedProfileID else {
            throw AutomationCoordinatorError.staleProfileActivationPreview
        }
        let result = try runtime.activateProfile(id: selectedProfileID, confirmedPreview: confirmedPreview)
        installDraft(result.activeProfile, preservingRuleSelection: true)
        return result
    }

    @discardableResult
    func createBlankProfile(named name: String) throws -> DisplayProfile {
        guard !isDirty else { throw PresentationError.dirtyProfileDraft }
        let profile = try runtime.createBlankProfile(named: name)
        installDraft(profile, preservingRuleSelection: false)
        return profile
    }

    @discardableResult
    func createProfileCopy(named name: String) throws -> DisplayProfile {
        guard !isDirty else { throw PresentationError.dirtyProfileDraft }
        guard let activeProfileID else { throw PresentationError.noSelectedProfile }
        let profile = try runtime.duplicateProfile(id: activeProfileID, named: name)
        installDraft(profile, preservingRuleSelection: false)
        return profile
    }

    @discardableResult
    func duplicateSelectedProfile(named name: String) throws -> DisplayProfile {
        guard !isDirty else { throw PresentationError.dirtyProfileDraft }
        guard let selectedProfileID else { throw PresentationError.noSelectedProfile }
        let profile = try runtime.duplicateProfile(id: selectedProfileID, named: name)
        installDraft(profile, preservingRuleSelection: false)
        return profile
    }

    func deleteSelectedProfile() throws {
        guard !isDirty else { throw PresentationError.dirtyProfileDraft }
        guard let selectedProfileID else { throw PresentationError.noSelectedProfile }
        try runtime.deleteInactiveProfile(id: selectedProfileID)
        let replacement = runtime.status.activeProfile ?? profiles.first
        installDraft(replacement, preservingRuleSelection: false)
    }

    @discardableResult
    func restoreInvalidProfile(_ invalid: InvalidDisplayProfile) throws -> DisplayProfile {
        guard let id = invalid.profileID else { throw ConfigurationStoreError.invalidProfileFileName(invalid.fileName) }
        let profile = try runtime.restoreProfileFromLastKnownGood(id: id)
        if selectedProfileID == id && !isDirty { installDraft(profile, preservingRuleSelection: true) }
        return profile
    }

    @discardableResult
    func removeInvalidProfile(_ invalid: InvalidDisplayProfile) throws -> AutomationRuntimeStatus {
        try runtime.removeInvalidProfile(fileName: invalid.fileName)
    }

    @discardableResult
    func reloadProfileCatalog() throws -> AutomationRuntimeStatus {
        guard !isDirty else { throw PresentationError.dirtyProfileDraft }
        ignoredExternalActiveProfileID = nil
        let status = runtime.reloadProfileCatalog()
        refreshFromRuntime()
        return status
    }

    func keepCurrentProfileAfterExternalDrift() {
        ignoredExternalActiveProfileID = runtime.status.externalActiveProfileID
    }

    func previewExternalProfileReload() throws -> ProfileActivationPreview? {
        guard let id = externalActiveProfileID else { return nil }
        return try runtime.previewProfileActivation(id: id, observation: nil)
    }

    @discardableResult
    func reloadAndApplyExternalProfile(
        confirmedPreview: ProfileActivationPreview
    ) throws -> ProfileActivationResult {
        guard !isDirty else { throw PresentationError.dirtyProfileDraft }
        guard let id = externalActiveProfileID,
              confirmedPreview.profile.id == id else {
            throw AutomationCoordinatorError.staleProfileActivationPreview
        }
        let result = try runtime.activateProfile(id: id, confirmedPreview: confirmedPreview)
        ignoredExternalActiveProfileID = nil
        installDraft(result.activeProfile, preservingRuleSelection: false)
        return result
    }

    func selectRule(id: UUID?) { selectedRuleID = id }

    @discardableResult
    func addRule() throws -> DisplayRule {
        let targets = targetOptions()
        guard !targets.isEmpty else { throw PresentationError.noReliableDisplayTarget }
        let rule = DisplayRule(
            id: UUID(),
            name: "新规则",
            isEnabled: true,
            priority: nextLowestPriority(),
            conditions: [.always],
            actions: targets.map { TargetAction(target: $0.target, action: .noAction) }
        )
        updateDraft { $0.rules.append(rule) }
        selectedRuleID = rule.id
        return rule
    }

    @discardableResult
    func duplicateSelectedRule() throws -> DisplayRule {
        guard let selectedRule,
              let index = draftProfile?.rules.firstIndex(where: { $0.id == selectedRule.id }) else {
            throw PresentationError.emptyRuleName
        }
        var copy = selectedRule
        copy.id = UUID()
        copy.name = "\(selectedRule.name) 副本"
        updateDraft { $0.rules.insert(copy, at: index + 1) }
        selectedRuleID = copy.id
        return copy
    }

    func deleteSelectedRule() {
        guard let selectedRuleID,
              let index = draftProfile?.rules.firstIndex(where: { $0.id == selectedRuleID }) else { return }
        updateDraft { $0.rules.remove(at: index) }
        if let rules = draftProfile?.rules {
            self.selectedRuleID = rules.indices.contains(index) ? rules[index].id : rules.last?.id
        }
    }

    func moveRule(from source: Int, to destination: Int) {
        guard var profile = draftProfile, profile.rules.indices.contains(source) else { return }
        let rule = profile.rules.remove(at: source)
        let adjusted = source < destination ? destination - 1 : destination
        profile.rules.insert(rule, at: min(max(0, adjusted), profile.rules.count))
        let count = profile.rules.count
        for index in profile.rules.indices { profile.rules[index].priority = (count - index) * 10 }
        draftProfile = profile
        selectedRuleID = rule.id
        lastPreview = nil
    }

    func setRuleEnabled(id: UUID, enabled: Bool) {
        updateDraft { profile in
            guard let index = profile.rules.firstIndex(where: { $0.id == id }) else { return }
            profile.rules[index].isEnabled = enabled
        }
    }

    func updateSelectedRule(_ change: (inout DisplayRule) -> Void) {
        guard let selectedRuleID else { return }
        updateDraft { profile in
            guard let index = profile.rules.firstIndex(where: { $0.id == selectedRuleID }) else { return }
            change(&profile.rules[index])
        }
    }

    func addCondition() {
        updateSelectedRule { rule in
            let condition = RuleCondition.count(.init(kind: .online, scope: .all, comparison: .equal, value: 1))
            if rule.conditions == [.always] { rule.conditions = [condition] } else { rule.conditions.append(condition) }
        }
    }

    func removeCondition(at index: Int) throws {
        guard let rule = selectedRule, rule.conditions.count > 1 else { throw PresentationError.conditionCannotBeRemoved }
        updateSelectedRule { if $0.conditions.indices.contains(index) { $0.conditions.remove(at: index) } }
    }

    func replaceCondition(at index: Int, with condition: RuleCondition) {
        updateSelectedRule { rule in
            guard rule.conditions.indices.contains(index) else { return }
            if condition == .always { rule.conditions = [.always] } else { rule.conditions[index] = condition }
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
        updateDraft { profile in
            for index in profile.rules.indices {
                for target in targets where !profile.rules[index].actions.contains(where: { $0.target == target }) {
                    profile.rules[index].actions.append(TargetAction(target: target, action: .noAction))
                }
            }
        }
    }

    func validateDraft() throws {
        guard let draftProfile,
              draftProfile.id == selectedProfileID,
              baselineProfile?.id == selectedProfileID else { throw PresentationError.staleProfileDraft }
        for rule in draftProfile.rules {
            if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PresentationError.emptyRuleName }
            if rule.conditions.isEmpty { throw PresentationError.emptyConditions }
            if rule.actions.isEmpty { throw PresentationError.emptyActions }
        }
        try draftProfile.validate()
        try configuration(assembling: draftProfile).validate()
    }

    @discardableResult
    func preview() throws -> ConfigurationPreview {
        synchronizeActionMatrix()
        try validateDraft()
        let preview = try runtime.previewConfigurationReadOnly(draftConfiguration, observation: runtime.status.inventory)
        lastPreview = preview
        return preview
    }

    func defaultRulesCandidate() throws -> (profile: DisplayProfile, preview: ConfigurationPreview) {
        guard var profile = draftProfile else { throw PresentationError.noSelectedProfile }
        let options = targetOptions()
        let target = options.first(where: {
            guard $0.isBuiltIn, case .exact = $0.target else { return false }
            return true
        })?.target ?? options.first(where: { $0.isBuiltIn })?.target
            ?? runtime.status.configuration.deviceHistory.first(where: { $0.isBuiltIn })?.target
        guard let target else { throw PresentationError.noBuiltInDisplayTarget }
        profile.rules = LegacyConfigurationMigrator.defaultExternalRules(target: target)
        if profile.rules.indices.contains(0) { profile.rules[0].name = "检测到外接显示器" }
        if profile.rules.indices.contains(1) { profile.rules[1].name = "未检测到外接显示器" }
        try profile.validate()
        let candidate = configuration(assembling: profile)
        let preview = try runtime.previewConfigurationReadOnly(candidate, observation: runtime.status.inventory)
        return (profile, preview)
    }

    func useDefaultRulesCandidate(_ candidate: DisplayProfile) throws {
        guard candidate.id == selectedProfileID,
              baselineProfile?.id == selectedProfileID else { throw PresentationError.staleProfileDraft }
        try candidate.validate()
        draftProfile = candidate
        selectedRuleID = candidate.rules.first?.id
        lastPreview = nil
    }

    private func configuration(assembling profile: DisplayProfile) -> AppConfiguration {
        let settings = runtime.status.configuration.applicationSettings(
            activeProfileID: runtime.status.activeProfile?.id ?? profile.id
        )
        return AppConfiguration(settings: settings, profile: profile)
    }

    private func profileForEditing(id: UUID) -> DisplayProfile? {
        if runtime.status.activeProfile?.id == id { return runtime.status.activeProfile }
        return profiles.first(where: { $0.id == id })
    }

    private func installDraft(_ profile: DisplayProfile?, preservingRuleSelection: Bool) {
        let priorRuleID = preservingRuleSelection ? selectedRuleID : nil
        guard var profile else {
            selectedProfileID = nil
            baselineProfile = nil
            draftProfile = nil
            selectedRuleID = nil
            lastPreview = nil
            return
        }
        profile.rules = Self.rulesInPriorityOrder(profile.rules)
        selectedProfileID = profile.id
        baselineProfile = profile
        draftProfile = profile
        if let priorRuleID, profile.rules.contains(where: { $0.id == priorRuleID }) {
            selectedRuleID = priorRuleID
        } else {
            selectedRuleID = profile.rules.first?.id
        }
        lastPreview = nil
    }

    private func nextLowestPriority() -> Int {
        guard let minimum = draftProfile?.rules.map(\.priority).min() else { return 10 }
        return minimum == Int.min ? Int.min : minimum - 1
    }

    private static func rulesInPriorityOrder(_ rules: [DisplayRule]) -> [DisplayRule] {
        rules.enumerated().sorted { lhs, rhs in
            if lhs.element.priority != rhs.element.priority { return lhs.element.priority > rhs.element.priority }
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
        let referenceRules = PresentationText.profileRules(status: runtime.status)
        guard !PresentationText.isReferenced(target, by: referenceRules) else {
            throw PresentationError.historicalDisplayReferenced
        }
        var configuration = runtime.status.configuration
        configuration.deviceHistory.removeAll { $0.target == target }
        return try runtime.updateConfiguration(configuration, applyImmediately: false)
    }
}
