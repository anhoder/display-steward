import AppKit

let displayStewardAppName = "Display Steward"

enum InterfaceMetrics {
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 24
    static let space6: CGFloat = 32
    static let settingsWindowSize = NSSize(width: 1160, height: 720)
    static let settingsContentWidth: CGFloat = 760
    static let profilesListWidth: CGFloat = 272
    static let rulesListWidth: CGFloat = 248
    static let displaysListWidth: CGFloat = 292
    static let controlWidth: CGFloat = 160
    static let compactControlWidth: CGFloat = 80
    static let editorMinimumWidth: CGFloat = 560
}

enum InterfaceColors {
    static let primaryText = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let warning = NSColor.systemOrange
    static let destructive = NSColor.systemRed
}

private enum LabelStyle { case title, section, body, secondary }

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private func makeLabel(_ text: String, style: LabelStyle = .body) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    switch style {
    case .title:
        label.font = .systemFont(ofSize: NSFont.systemFontSize + 6, weight: .semibold)
        label.textColor = InterfaceColors.primaryText
    case .section:
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = InterfaceColors.primaryText
    case .body:
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = InterfaceColors.primaryText
    case .secondary:
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = InterfaceColors.secondaryText
    }
    return label
}

private func clearArrangedSubviews(_ stack: NSStackView) {
    for view in stack.arrangedSubviews {
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
    }
}

private func showPresentationError(_ error: Error, message: String = "操作未完成", in window: NSWindow?) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = message
    alert.informativeText = PresentationText.error(error)
    if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
}

func runDisplayRecoveryFlow(runtime: DisplayManagingRuntime, in window: NSWindow?) {
    var retryTargets: [DisplayRecoveryTarget]?
    while true {
        let plan: DisplayRecoveryPlan
        do {
            plan = try runtime.prepareDisplayRecovery(only: retryTargets)
        } catch {
            showPresentationError(error, message: "无法刷新可恢复显示器", in: window)
            return
        }
        guard !plan.isEmpty else { return }

        let confirmation = PresentationText.displayRecoveryConfirmation(plan)
        let confirmAlert = NSAlert()
        confirmAlert.alertStyle = .warning
        confirmAlert.messageText = confirmation.title
        confirmAlert.informativeText = [confirmation.explanation, confirmation.details]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        confirmAlert.addButton(withTitle: confirmation.confirmTitle)
        confirmAlert.addButton(withTitle: "取消")
        guard confirmAlert.runModal() == .alertFirstButtonReturn else { return }

        let result = runtime.restoreDisplays(plan)
        let presentation = PresentationText.displayRecoveryResult(result)
        let resultAlert = NSAlert()
        switch presentation.severity {
        case .normal: resultAlert.alertStyle = .informational
        case .warning: resultAlert.alertStyle = .warning
        case .critical: resultAlert.alertStyle = .critical
        }
        resultAlert.messageText = presentation.title
        resultAlert.informativeText = [presentation.explanation, presentation.details]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if presentation.retryAvailable {
            resultAlert.addButton(withTitle: "重试仍需恢复的显示器")
            resultAlert.addButton(withTitle: "关闭")
            guard resultAlert.runModal() == .alertFirstButtonReturn else { return }
            retryTargets = result.unresolvedTargets
        } else {
            resultAlert.addButton(withTitle: "好")
            resultAlert.runModal()
            return
        }
    }
}

private enum ProfileTableEntry {
    case profile(DisplayProfile)
    case invalid(InvalidDisplayProfile)
}

private final class InvalidProfileButton: NSButton {
    var invalidProfile: InvalidDisplayProfile?
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Detail: Equatable { case rules, displays }

    private let viewModel: SettingsSummaryViewModel
    let profileViewModel: ProfileManagementViewModel
    private let shortcutProvider: () -> KeyShortcut
    private let shortcutSetter: (KeyShortcut) -> Bool
    private let shortcutResetter: () -> Bool
    private let dirtyDraftResolutionProvider: (() -> ProfileDraftResolution)?
    private let rootController = NSViewController()
    private let profileSplit = NSSplitView()
    private let profileTable = NSTableView()
    private var profileEntries: [ProfileTableEntry] = []
    private var restoringProfileSelection = false
    private let contentContainer = NSView()
    private let summaryScroll = NSScrollView()
    private let summaryDocument = FlippedView()
    private let summaryStack = NSStackView()
    private let detailView = NSView()
    private let detailHost = NSView()
    private let detailTitleLabel = makeLabel("", style: .title)
    private let activeProfileLabel = makeLabel("", style: .title)
    private let selectedProfileLabel = makeLabel("", style: .section)
    private let stateLabel = makeLabel("", style: .body)
    private let evaluationLabel = makeLabel("", style: .secondary)
    private let rulesSummaryLabel = makeLabel("", style: .body)
    private let displaysSummaryLabel = makeLabel("", style: .body)
    private let profileNameField = NSTextField(string: "")
    private let automaticCheckbox = NSButton(checkboxWithTitle: "启用自动化", target: nil, action: nil)
    private let pauseButton = NSButton(title: "暂停自动化", target: nil, action: nil)
    private let pollingCheckbox = NSButton(checkboxWithTitle: "启用定时检查", target: nil, action: nil)
    private let pollingIntervalField = NSTextField(string: "3")
    private let shortcutRecorder = ShortcutRecorderButton()
    private let resetShortcutButton = NSButton(title: "恢复默认", target: nil, action: nil)
    private let recoverySection = NSStackView()
    private let recoveryNoticeLabel = makeLabel("", style: .secondary)
    private let restoreAllButton = NSButton(title: PresentationText.restoreAllTitle, target: nil, action: nil)
    private let profileReloadNoticeLabel = makeLabel("", style: .secondary)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let saveAndActivateButton = NSButton(title: "保存并激活", target: nil, action: nil)
    let rulesController: RulesPageViewController
    let displaysController: DisplaysPageViewController
    private(set) var activeDetail: Detail?

    init(
        runtime: DisplayManagingRuntime,
        shortcutProvider: @escaping () -> KeyShortcut,
        shortcutSetter: @escaping (KeyShortcut) -> Bool,
        shortcutResetter: @escaping () -> Bool,
        onLastActiveSafetyBlock: @escaping () -> Void,
        dirtyDraftResolutionProvider: (() -> ProfileDraftResolution)? = nil
    ) {
        viewModel = SettingsSummaryViewModel(runtime: runtime)
        let profileViewModel = ProfileManagementViewModel(runtime: runtime)
        self.profileViewModel = profileViewModel
        self.shortcutProvider = shortcutProvider
        self.shortcutSetter = shortcutSetter
        self.shortcutResetter = shortcutResetter
        self.dirtyDraftResolutionProvider = dirtyDraftResolutionProvider
        rulesController = RulesPageViewController(viewModel: profileViewModel)
        displaysController = DisplaysPageViewController(runtime: runtime, onLastActiveSafetyBlock: onLastActiveSafetyBlock)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: InterfaceMetrics.settingsWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(displayStewardAppName) 设置"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = InterfaceMetrics.settingsWindowSize
        super.init(window: window)
        buildView()
        window.delegate = self
        showSummary()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(detail: Detail? = nil) {
        if let detail { showDetail(detail) } else { showSummary() }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSummary() {
        activeDetail = nil
        installContent(summaryScroll)
    }

    func showDetail(_ detail: Detail) {
        activeDetail = detail
        detailTitleLabel.stringValue = detail == .rules ? "规则草稿" : "显示器"
        for subview in detailHost.subviews { subview.removeFromSuperview() }
        let controller = detail == .rules ? rulesController : displaysController
        let pageView = controller.view
        pageView.translatesAutoresizingMaskIntoConstraints = false
        detailHost.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.leadingAnchor.constraint(equalTo: detailHost.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: detailHost.trailingAnchor),
            pageView.topAnchor.constraint(equalTo: detailHost.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: detailHost.bottomAnchor)
        ])
        installContent(detailView)
        refresh()
    }

    func refresh() {
        profileViewModel.refreshFromRuntime()
        rulesController.refreshFromRuntime()
        displaysController.refreshFromRuntime()
        rebuildProfileEntries()
        restoringProfileSelection = true
        profileTable.reloadData()
        restoreProfileSelection()
        restoringProfileSelection = false

        let presentation = viewModel.presentation
        let activeName = viewModel.runtime.status.activeProfile?.name ?? "不可用"
        activeProfileLabel.stringValue = "当前配置档：\(activeName)"
        stateLabel.stringValue = presentation.automationState
        stateLabel.textColor = presentation.hasFailure ? InterfaceColors.destructive : InterfaceColors.secondaryText
        evaluationLabel.stringValue = "最近评估 · \(presentation.lastEvaluationSummary)"
        pauseButton.title = presentation.pauseButtonTitle
        pauseButton.isEnabled = presentation.automaticEnabled || presentation.isPaused
        shortcutRecorder.shortcut = shortcutProvider()
        recoverySection.isHidden = presentation.recoveryCount == 0
        recoveryNoticeLabel.stringValue = presentation.recoveryNotice ?? ""
        restoreAllButton.isEnabled = presentation.recoveryCount > 0
        let reloadNotices = PresentationText.applicationSettingsReloadNotices(status: viewModel.runtime.status)
        profileReloadNoticeLabel.isHidden = reloadNotices.isEmpty
        profileReloadNoticeLabel.stringValue = reloadNotices.map(\.title).joined(separator: "\n")
        profileReloadNoticeLabel.toolTip = reloadNotices.map(\.explanation).joined(separator: "\n\n")
        profileReloadNoticeLabel.textColor = reloadNotices.contains(where: { $0.severity == .critical })
            ? InterfaceColors.destructive
            : InterfaceColors.warning

        guard let profile = profileViewModel.draftProfile else {
            selectedProfileLabel.stringValue = "未选择配置档"
            profileNameField.stringValue = ""
            profileNameField.isEnabled = false
            automaticCheckbox.isEnabled = false
            pollingCheckbox.isEnabled = false
            pollingIntervalField.isEnabled = false
            rulesSummaryLabel.stringValue = "没有可编辑的规则"
            saveButton.isEnabled = false
            saveAndActivateButton.isHidden = true
            return
        }
        selectedProfileLabel.stringValue = profileViewModel.isSelectedProfileActive
            ? "正在编辑：\(profile.name) · 当前"
            : "正在编辑：\(profile.name) · 未激活"
        if window?.firstResponder !== profileNameField.currentEditor() { profileNameField.stringValue = profile.name }
        profileNameField.isEnabled = true
        automaticCheckbox.state = profile.automatic.isEnabled ? .on : .off
        automaticCheckbox.isEnabled = true
        pollingCheckbox.state = profile.polling.isEnabled ? .on : .off
        pollingCheckbox.isEnabled = profile.automatic.isEnabled
        if window?.firstResponder !== pollingIntervalField.currentEditor() {
            pollingIntervalField.doubleValue = profile.polling.intervalSeconds
        }
        pollingIntervalField.isEnabled = profile.automatic.isEnabled && profile.polling.isEnabled
        let enabledRules = profile.rules.filter(\.isEnabled).count
        rulesSummaryLabel.stringValue = "\(profile.rules.count) 条规则 · \(enabledRules) 条已启用 · \(profileViewModel.isDirty ? "有未保存修改" : "已保存")"
        displaysSummaryLabel.stringValue = "当前 \(displaysController.viewModel.currentRows.count) 台 · 历史 \(displaysController.viewModel.historicalRows.count) 条"
        saveButton.title = profileViewModel.isSelectedProfileActive ? "保存并应用" : "保存"
        saveButton.isEnabled = profileViewModel.isDirty
        saveAndActivateButton.isHidden = profileViewModel.isSelectedProfileActive
        saveAndActivateButton.isEnabled = !profileViewModel.isSelectedProfileActive
    }

    func prepareForExternalProfileActivation() -> Bool {
        window?.makeFirstResponder(nil)
        flushDraftFields()
        do {
            return try profileViewModel.prepareForExternalProfileActivation { [weak self] in
                self?.dirtyDraftResolution(reason: "切换当前配置档前") ?? .cancel
            }
        } catch {
            showPresentationError(error, message: "无法处理配置档草稿", in: window)
            return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { prepareForExternalProfileActivation() }

    private func buildView() {
        let root = NSView()
        rootController.view = root
        window?.contentViewController = rootController
        rootController.addChild(rulesController)
        rootController.addChild(displaysController)
        profileSplit.identifier = NSUserInterfaceItemIdentifier("settingsProfileSplit")
        profileSplit.isVertical = true
        profileSplit.dividerStyle = .thin
        profileSplit.translatesAutoresizingMaskIntoConstraints = false
        profileSplit.addArrangedSubview(buildProfileSidebar())
        profileSplit.addArrangedSubview(contentContainer)
        profileSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        root.addSubview(profileSplit)
        NSLayoutConstraint.activate([
            profileSplit.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            profileSplit.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            profileSplit.topAnchor.constraint(equalTo: root.topAnchor),
            profileSplit.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        buildSummaryView()
        buildDetailView()
    }

    private func buildProfileSidebar() -> NSView {
        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier("settingsProfileSidebar")
        let heading = makeLabel("显示配置档", style: .section)
        let explanation = makeLabel("选择只会打开草稿，不会激活或操作显示器。", style: .secondary)
        explanation.maximumNumberOfLines = 3
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        profileTable.identifier = NSUserInterfaceItemIdentifier("settingsProfileList")
        profileTable.addTableColumn(column)
        profileTable.headerView = nil
        profileTable.delegate = self
        profileTable.dataSource = self
        profileTable.allowsEmptySelection = false
        profileReloadNoticeLabel.identifier = NSUserInterfaceItemIdentifier("profileReloadNotice")
        profileReloadNoticeLabel.maximumNumberOfLines = 6
        scroll.documentView = profileTable
        let add = NSButton(title: "+", target: self, action: #selector(newProfileClicked))
        add.toolTip = "新建空白配置档或复制当前草稿的配置档"
        let duplicate = NSButton(title: "复制", target: self, action: #selector(duplicateProfileClicked))
        duplicate.identifier = NSUserInterfaceItemIdentifier("duplicateProfileButton")
        let delete = NSButton(title: "删除", target: self, action: #selector(deleteProfileClicked))
        delete.identifier = NSUserInterfaceItemIdentifier("deleteProfileButton")
        delete.contentTintColor = InterfaceColors.destructive
        let actions = NSStackView(views: [add, duplicate, delete])
        actions.orientation = .horizontal
        actions.spacing = InterfaceMetrics.space2
        let reload = NSButton(title: "重新加载配置档", target: self, action: #selector(reloadProfilesClicked))
        reload.identifier = NSUserInterfaceItemIdentifier("reloadProfilesButton")
        for child in [heading, explanation, scroll, profileReloadNoticeLabel, actions, reload] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: InterfaceMetrics.profilesListWidth),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: InterfaceMetrics.space4),
            heading.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -InterfaceMetrics.space4),
            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: InterfaceMetrics.space4),
            explanation.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            explanation.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: InterfaceMetrics.space1),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: InterfaceMetrics.space3),
            scroll.bottomAnchor.constraint(equalTo: profileReloadNoticeLabel.topAnchor, constant: -InterfaceMetrics.space2),
            profileReloadNoticeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: InterfaceMetrics.space4),
            profileReloadNoticeLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -InterfaceMetrics.space4),
            profileReloadNoticeLabel.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -InterfaceMetrics.space3),
            actions.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: InterfaceMetrics.space4),
            reload.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: InterfaceMetrics.space4),
            reload.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: InterfaceMetrics.space2),
            reload.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -InterfaceMetrics.space4)
        ])
        return container
    }

    private func buildSummaryView() {
        summaryScroll.hasVerticalScroller = true
        summaryScroll.drawsBackground = false
        summaryDocument.translatesAutoresizingMaskIntoConstraints = false
        summaryStack.orientation = .vertical
        summaryStack.alignment = .centerX
        summaryStack.spacing = InterfaceMetrics.space4
        summaryStack.translatesAutoresizingMaskIntoConstraints = false
        summaryDocument.addSubview(summaryStack)
        summaryScroll.documentView = summaryDocument
        let contentHeight = summaryDocument.heightAnchor.constraint(equalTo: summaryStack.heightAnchor, constant: InterfaceMetrics.space5 * 2)
        contentHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            summaryDocument.widthAnchor.constraint(equalTo: summaryScroll.contentView.widthAnchor),
            summaryDocument.heightAnchor.constraint(greaterThanOrEqualTo: summaryScroll.contentView.heightAnchor),
            summaryStack.widthAnchor.constraint(equalToConstant: InterfaceMetrics.settingsContentWidth),
            summaryStack.centerXAnchor.constraint(equalTo: summaryDocument.centerXAnchor),
            summaryStack.topAnchor.constraint(equalTo: summaryDocument.topAnchor, constant: InterfaceMetrics.space5),
            summaryStack.leadingAnchor.constraint(greaterThanOrEqualTo: summaryDocument.leadingAnchor, constant: InterfaceMetrics.space5),
            summaryStack.trailingAnchor.constraint(lessThanOrEqualTo: summaryDocument.trailingAnchor, constant: -InterfaceMetrics.space5),
            summaryStack.bottomAnchor.constraint(lessThanOrEqualTo: summaryDocument.bottomAnchor, constant: -InterfaceMetrics.space5),
            contentHeight
        ])

        let (statusCard, statusContent) = makeCard(identifier: "settingsStatusCard", title: "应用状态", explanation: "状态、手动恢复和暂停作用于当前配置档及整个应用。")
        statusContent.addArrangedSubview(activeProfileLabel)
        statusContent.addArrangedSubview(stateLabel)
        evaluationLabel.maximumNumberOfLines = 3
        statusContent.addArrangedSubview(evaluationLabel)
        let statusActions = NSStackView(views: [NSButton(title: "刷新显示器状态", target: self, action: #selector(refreshDisplaysClicked)), pauseButton])
        statusActions.orientation = .horizontal
        statusActions.spacing = InterfaceMetrics.space2
        statusContent.addArrangedSubview(statusActions)
        recoverySection.orientation = .vertical
        recoverySection.alignment = .leading
        recoverySection.spacing = InterfaceMetrics.space2
        recoverySection.addArrangedSubview(makeLabel("需要安全恢复", style: .section))
        recoverySection.addArrangedSubview(recoveryNoticeLabel)
        recoverySection.addArrangedSubview(restoreAllButton)
        statusContent.addArrangedSubview(recoverySection)
        summaryStack.addArrangedSubview(statusCard)
        statusCard.widthAnchor.constraint(equalTo: summaryStack.widthAnchor).isActive = true

        let (profileCard, profileContent) = makeCard(identifier: "settingsAutomationCard", title: "所选配置档草稿", explanation: "名称、自动化、定时检查和规则一起保存；编辑未激活配置档不会改变当前显示器。")
        profileCard.identifier = NSUserInterfaceItemIdentifier("settingsAutomationCard")
        profileContent.addArrangedSubview(selectedProfileLabel)
        profileNameField.identifier = NSUserInterfaceItemIdentifier("profileNameField")
        profileNameField.placeholderString = "配置档名称"
        profileNameField.widthAnchor.constraint(equalToConstant: InterfaceMetrics.controlWidth * 2).isActive = true
        let nameRow = NSStackView(views: [makeLabel("名称", style: .secondary), profileNameField])
        nameRow.orientation = .horizontal
        nameRow.spacing = InterfaceMetrics.space3
        profileContent.addArrangedSubview(nameRow)
        let automaticRow = NSStackView(views: [automaticCheckbox])
        automaticRow.orientation = .horizontal
        automaticRow.spacing = InterfaceMetrics.space3
        profileContent.addArrangedSubview(automaticRow)
        let pollingRow = NSStackView(views: [pollingCheckbox, makeLabel("间隔", style: .secondary), pollingIntervalField, makeLabel("秒", style: .secondary)])
        pollingRow.orientation = .horizontal
        pollingRow.spacing = InterfaceMetrics.space2
        profileContent.addArrangedSubview(pollingRow)
        summaryStack.addArrangedSubview(profileCard)
        profileCard.widthAnchor.constraint(equalTo: summaryStack.widthAnchor).isActive = true

        let (rulesCard, rulesContent) = makeCard(identifier: "settingsRulesCard", title: "规则", explanation: "规则矩阵编辑所选配置档的同一份草稿。")
        rulesContent.addArrangedSubview(rulesSummaryLabel)
        rulesContent.addArrangedSubview(NSButton(title: "编辑规则…", target: self, action: #selector(openRules)))
        let (displaysCard, displaysContent) = makeCard(identifier: "settingsDisplaysCard", title: "显示器", explanation: "当前状态、恢复与历史记录属于整个应用。")
        displaysContent.addArrangedSubview(displaysSummaryLabel)
        displaysContent.addArrangedSubview(NSButton(title: "管理显示器…", target: self, action: #selector(openDisplays)))
        let resourceCards = NSStackView(views: [rulesCard, displaysCard])
        resourceCards.orientation = .horizontal
        resourceCards.alignment = .top
        resourceCards.distribution = .fillEqually
        resourceCards.spacing = InterfaceMetrics.space4
        rulesCard.heightAnchor.constraint(equalTo: displaysCard.heightAnchor).isActive = true
        summaryStack.addArrangedSubview(resourceCards)
        resourceCards.widthAnchor.constraint(equalTo: summaryStack.widthAnchor).isActive = true

        let (applicationCard, applicationContent) = makeCard(identifier: "settingsApplicationCard", title: "应用快捷键", explanation: "切换内置显示器的全局快捷键独立于所有显示配置档。")
        let shortcutRow = NSStackView(views: [shortcutRecorder, resetShortcutButton])
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = InterfaceMetrics.space2
        applicationContent.addArrangedSubview(shortcutRow)
        summaryStack.addArrangedSubview(applicationCard)
        applicationCard.widthAnchor.constraint(equalTo: summaryStack.widthAnchor).isActive = true

        saveButton.identifier = NSUserInterfaceItemIdentifier("saveProfileButton")
        saveAndActivateButton.identifier = NSUserInterfaceItemIdentifier("saveAndActivateProfileButton")
        let saveActions = NSStackView(views: [saveButton, saveAndActivateButton])
        saveActions.orientation = .horizontal
        saveActions.spacing = InterfaceMetrics.space2
        summaryStack.addArrangedSubview(saveActions)

        automaticCheckbox.target = self
        automaticCheckbox.action = #selector(automaticChanged)
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        pollingCheckbox.target = self
        pollingCheckbox.action = #selector(pollingChanged)
        pollingIntervalField.target = self
        pollingIntervalField.action = #selector(pollingIntervalChanged)
        profileNameField.target = self
        profileNameField.action = #selector(profileNameChanged)
        let formatter = NumberFormatter()
        formatter.minimum = 1
        formatter.maximum = 3600
        formatter.allowsFloats = true
        pollingIntervalField.formatter = formatter
        shortcutRecorder.target = self
        shortcutRecorder.action = #selector(startShortcutRecording)
        shortcutRecorder.onShortcutRecorded = { [weak self] shortcut in self?.recordShortcut(shortcut) }
        shortcutRecorder.onInvalidInput = { [weak self] message in self?.shortcutRecorder.toolTip = message }
        resetShortcutButton.target = self
        resetShortcutButton.action = #selector(resetShortcutClicked)
        restoreAllButton.target = self
        restoreAllButton.action = #selector(restoreAllClicked)
        saveButton.target = self
        saveButton.action = #selector(saveProfileClicked)
        saveButton.keyEquivalent = "\r"
        saveAndActivateButton.target = self
        saveAndActivateButton.action = #selector(saveAndActivateClicked)
        pollingIntervalField.widthAnchor.constraint(equalToConstant: InterfaceMetrics.compactControlWidth).isActive = true
        shortcutRecorder.widthAnchor.constraint(equalToConstant: InterfaceMetrics.controlWidth).isActive = true
    }

    private func buildDetailView() {
        let backButton = NSButton(title: "返回配置档", target: self, action: #selector(backToSummary))
        let header = NSStackView(views: [backButton, detailTitleLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = InterfaceMetrics.space4
        header.translatesAutoresizingMaskIntoConstraints = false
        detailHost.translatesAutoresizingMaskIntoConstraints = false
        detailView.addSubview(header)
        detailView.addSubview(detailHost)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: detailView.leadingAnchor, constant: InterfaceMetrics.space5),
            header.trailingAnchor.constraint(lessThanOrEqualTo: detailView.trailingAnchor, constant: -InterfaceMetrics.space5),
            header.topAnchor.constraint(equalTo: detailView.topAnchor, constant: InterfaceMetrics.space4),
            detailHost.leadingAnchor.constraint(equalTo: detailView.leadingAnchor),
            detailHost.trailingAnchor.constraint(equalTo: detailView.trailingAnchor),
            detailHost.topAnchor.constraint(equalTo: header.bottomAnchor, constant: InterfaceMetrics.space4),
            detailHost.bottomAnchor.constraint(equalTo: detailView.bottomAnchor)
        ])
    }

    private func makeCard(identifier: String, title: String, explanation: String?) -> (NSBox, NSStackView) {
        let card = NSBox()
        card.identifier = NSUserInterfaceItemIdentifier(identifier)
        card.boxType = .custom
        card.borderWidth = 1
        card.cornerRadius = InterfaceMetrics.space2
        card.fillColor = .controlBackgroundColor
        card.borderColor = .separatorColor
        card.titlePosition = .noTitle
        card.contentViewMargins = NSSize(width: InterfaceMetrics.space4, height: InterfaceMetrics.space4)
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = InterfaceMetrics.space3
        content.addArrangedSubview(makeLabel(title, style: .section))
        if let explanation { content.addArrangedSubview(makeLabel(explanation, style: .secondary)) }
        card.contentView = content
        return (card, content)
    }

    private func installContent(_ view: NSView) {
        for subview in contentContainer.subviews { subview.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
    }

    private func rebuildProfileEntries() {
        profileEntries = profileViewModel.profiles.map(ProfileTableEntry.profile)
            + profileViewModel.invalidProfiles.map(ProfileTableEntry.invalid)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { profileEntries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard profileEntries.indices.contains(row) else { return InterfaceMetrics.space6 }
        if case .invalid = profileEntries[row] { return InterfaceMetrics.space6 * 3 }
        return InterfaceMetrics.space6 + InterfaceMetrics.space2
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard profileEntries.indices.contains(row) else { return false }
        if case .profile = profileEntries[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard profileEntries.indices.contains(row) else { return nil }
        switch profileEntries[row] {
        case .profile(let profile):
            let title = makeLabel(profile.name)
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let indicator = makeLabel(profile.id == profileViewModel.activeProfileID ? "当前" : "", style: .secondary)
            indicator.textColor = profile.id == profileViewModel.activeProfileID ? NSColor.controlAccentColor : InterfaceColors.secondaryText
            let stack = NSStackView(views: [title, indicator])
            stack.orientation = .horizontal
            stack.spacing = InterfaceMetrics.space2
            return stack
        case .invalid(let invalid):
            let title = makeLabel("错误配置档 · \(invalid.profileName ?? invalid.fileName)", style: .section)
            title.textColor = InterfaceColors.destructive
            let detail = makeLabel("\(invalid.fileName)：\(invalid.errorDescription)", style: .secondary)
            detail.maximumNumberOfLines = 2
            let restore = InvalidProfileButton(title: "从上次可用版本恢复", target: self, action: #selector(restoreInvalidProfile(_:)))
            restore.invalidProfile = invalid
            restore.isHidden = invalid.profileID == nil
            let remove = InvalidProfileButton(title: "移除此错误文件…", target: self, action: #selector(removeInvalidProfile(_:)))
            remove.invalidProfile = invalid
            remove.contentTintColor = InterfaceColors.destructive
            let actions = NSStackView(views: [restore, remove])
            actions.orientation = .horizontal
            actions.spacing = InterfaceMetrics.space2
            let stack = NSStackView(views: [title, detail, actions])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = InterfaceMetrics.space1
            return stack
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoringProfileSelection else { return }
        let row = profileTable.selectedRow
        guard profileEntries.indices.contains(row), case .profile(let profile) = profileEntries[row] else {
            restoreProfileSelection()
            return
        }
        guard profile.id != profileViewModel.selectedProfileID else { return }
        guard resolveDirtyDraft(reason: "切换所选配置档前") else { restoreProfileSelection(); return }
        do {
            _ = try profileViewModel.selectProfile(id: profile.id)
            if activeDetail == .rules { rulesController.refreshFromRuntime() }
            refresh()
        } catch {
            showPresentationError(error, message: "无法打开配置档", in: window)
            restoreProfileSelection()
        }
    }

    private func restoreProfileSelection() {
        let wasRestoring = restoringProfileSelection
        restoringProfileSelection = true
        defer { restoringProfileSelection = wasRestoring }
        guard let id = profileViewModel.selectedProfileID,
              let index = profileEntries.firstIndex(where: { if case .profile(let profile) = $0 { return profile.id == id }; return false }) else {
            profileTable.deselectAll(nil)
            return
        }
        profileTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    private func dirtyDraftResolution(reason: String) -> ProfileDraftResolution {
        if let dirtyDraftResolutionProvider { return dirtyDraftResolutionProvider() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(reason)处理未保存修改"
        alert.informativeText = "“\(profileViewModel.draftProfile?.name ?? "所选配置档")”的名称、自动化、定时检查或规则已修改。"
        alert.addButton(withTitle: profileViewModel.isSelectedProfileActive ? "保存并应用" : "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    private func resolveDirtyDraft(reason: String) -> Bool {
        window?.makeFirstResponder(nil)
        flushDraftFields()
        do {
            return try profileViewModel.prepareForExternalProfileActivation { [weak self] in
                self?.dirtyDraftResolution(reason: reason) ?? .cancel
            }
        } catch {
            showPresentationError(error, message: "无法保存配置档草稿", in: window)
            return false
        }
    }

    private func flushDraftFields() {
        profileViewModel.setProfileName(profileNameField.stringValue)
        profileViewModel.setPollingInterval(pollingIntervalField.doubleValue)
    }

    private func activationConfirmed(_ preview: ProfileActivationPreview) -> Bool {
        let presentation = PresentationText.profileActivationConfirmation(preview)
        guard presentation.requiresConfirmation else { return true }
        let alert = NSAlert()
        alert.alertStyle = presentation.isCritical ? .critical : .warning
        alert.messageText = presentation.title
        alert.informativeText = presentation.explanation
        alert.addButton(withTitle: presentation.confirmTitle)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentActivationResult(_ result: ProfileActivationResult) {
        let alert = NSAlert()
        switch result.hardwareOutcome {
        case .notNeeded, .applied: alert.alertStyle = .informational
        case .partiallyFailed: alert.alertStyle = .warning
        case .failed, .blockedBySafety: alert.alertStyle = .critical
        }
        alert.messageText = "当前配置档已更新"
        alert.informativeText = PresentationText.profileActivationResult(result)
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func suggestedProfileName(_ base: String) -> String {
        var candidate = base
        var suffix = 2
        let names = profileViewModel.profiles.map(\.name)
        while names.contains(where: { DisplayProfile.namesAreEqual($0, candidate) }) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func askProfileName(message: String, suggestion: String, firstButton: String, secondButton: String? = nil) -> (String, NSApplication.ModalResponse)? {
        let alert = NSAlert()
        alert.messageText = message
        let field = NSTextField(string: suggestion)
        field.placeholderString = "配置档名称"
        field.frame = NSRect(origin: .zero, size: NSSize(width: InterfaceMetrics.controlWidth * 2, height: InterfaceMetrics.space5))
        alert.accessoryView = field
        alert.addButton(withTitle: firstButton)
        if let secondButton { alert.addButton(withTitle: secondButton) }
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        let cancelResponse: NSApplication.ModalResponse = secondButton == nil ? .alertSecondButtonReturn : .alertThirdButtonReturn
        guard response != cancelResponse else { return nil }
        return (field.stringValue, response)
    }

    @objc private func newProfileClicked() {
        guard resolveDirtyDraft(reason: "新建配置档前") else { return }
        guard let answer = askProfileName(message: "新建显示配置档", suggestion: suggestedProfileName("新配置档"), firstButton: "新建空白配置档", secondButton: "复制当前配置档") else { return }
        do {
            if answer.1 == .alertFirstButtonReturn { _ = try profileViewModel.createBlankProfile(named: answer.0) }
            else { _ = try profileViewModel.createProfileCopy(named: answer.0) }
            showSummary()
            refresh()
        } catch { showPresentationError(error, message: "无法新建配置档", in: window) }
    }

    @objc private func duplicateProfileClicked() {
        guard let profile = profileViewModel.draftProfile, resolveDirtyDraft(reason: "复制配置档前") else { return }
        guard let answer = askProfileName(message: "复制“\(profile.name)”", suggestion: suggestedProfileName("\(profile.name) 副本"), firstButton: "复制") else { return }
        do { _ = try profileViewModel.duplicateSelectedProfile(named: answer.0); showSummary(); refresh() }
        catch { showPresentationError(error, message: "无法复制配置档", in: window) }
    }

    @objc private func deleteProfileClicked() {
        _ = deleteSelectedProfile()
    }

    @discardableResult
    func deleteSelectedProfile(
        confirm: ((DisplayProfile) -> Bool)? = nil
    ) -> Bool {
        guard resolveDirtyDraft(reason: "删除配置档前") else { return false }
        do {
            let confirmationProfile = try selectedPersistedProfileForDeletion()
            let isConfirmed: Bool
            if let confirm {
                isConfirmed = confirm(confirmationProfile)
            } else {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "删除“\(confirmationProfile.name)”？"
                alert.informativeText = "只会删除这个未激活配置档及其上次可用备份，不会激活其他配置档或操作显示器。"
                alert.addButton(withTitle: "删除")
                alert.addButton(withTitle: "取消")
                isConfirmed = alert.runModal() == .alertFirstButtonReturn
            }
            guard isConfirmed else { return false }

            let deletionProfile = try selectedPersistedProfileForDeletion()
            guard deletionProfile.id == confirmationProfile.id,
                  deletionProfile.name == confirmationProfile.name else {
                throw PresentationError.staleProfileDraft
            }
            try profileViewModel.deleteSelectedProfile()
            showSummary()
            refresh()
            return true
        } catch {
            showPresentationError(error, message: "无法删除配置档", in: window)
            return false
        }
    }

    private func selectedPersistedProfileForDeletion() throws -> DisplayProfile {
        guard !profileViewModel.isDirty,
              let selectedID = profileViewModel.selectedProfileID,
              let profile = profileViewModel.profiles.first(where: { $0.id == selectedID }) else {
            throw PresentationError.staleProfileDraft
        }
        guard selectedID != profileViewModel.activeProfileID else {
            throw ConfigurationStoreError.cannotDeleteActiveProfile
        }
        return profile
    }

    @objc private func reloadProfilesClicked() {
        guard resolveDirtyDraft(reason: "重新加载配置档前") else { return }
        do {
            let status = try profileViewModel.reloadProfileCatalog()
            let settingsNotices = PresentationText.applicationSettingsReloadNotices(status: status)
            refresh()
            presentApplicationSettingsReloadNotices(settingsNotices)
            guard !settingsNotices.contains(where: { $0.blocksProfileReloadApply }) else { return }
            guard let externalID = profileViewModel.externalActiveProfileID else { return }
            let externalName = profileViewModel.profiles.first(where: { $0.id == externalID })?.name ?? externalID.uuidString
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "磁盘上的当前配置档已变化"
            alert.informativeText = "磁盘指向或修改了“\(externalName)”。重新加载并应用会读取磁盘版本、更新当前配置档并立即评估；保留当前状态不会操作显示器，磁盘差异仍会保留。"
            alert.addButton(withTitle: "重新加载并应用")
            alert.addButton(withTitle: "保留当前状态")
            if alert.runModal() == .alertFirstButtonReturn {
                guard let preview = try profileViewModel.previewExternalProfileReload(), activationConfirmed(preview) else { return }
                presentActivationResult(
                    try profileViewModel.reloadAndApplyExternalProfile(confirmedPreview: preview)
                )
            } else {
                profileViewModel.keepCurrentProfileAfterExternalDrift()
            }
            refresh()
        } catch { showPresentationError(error, message: "无法重新加载配置档", in: window) }
    }

    private func presentApplicationSettingsReloadNotices(
        _ notices: [ApplicationSettingsReloadNoticePresentation]
    ) {
        guard !notices.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = notices.contains(where: { $0.severity == .critical }) ? .critical : .warning
        alert.messageText = notices.count == 1 ? notices[0].title : "磁盘应用设置需要处理"
        alert.informativeText = notices.map { "\($0.title)\n\($0.explanation)" }.joined(separator: "\n\n")
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func restoreInvalidProfile(_ sender: InvalidProfileButton) {
        guard let invalid = sender.invalidProfile else { return }
        do { _ = try profileViewModel.restoreInvalidProfile(invalid); refresh() }
        catch { showPresentationError(error, message: "无法从上次可用版本恢复", in: window) }
    }

    @objc private func removeInvalidProfile(_ sender: InvalidProfileButton) {
        guard let invalid = sender.invalidProfile else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "移除错误文件“\(invalid.fileName)”？"
        alert.informativeText = "只会移除列表中这个精确文件；不会自动修复、重命名或删除其他错误条目。若同一标识有上次可用备份，也会一并移除。"
        alert.addButton(withTitle: "移除精确文件")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { _ = try profileViewModel.removeInvalidProfile(invalid); refresh() }
        catch { showPresentationError(error, message: "无法移除错误配置档", in: window) }
    }

    @objc private func profileNameChanged() { profileViewModel.setProfileName(profileNameField.stringValue); refresh() }
    @objc private func automaticChanged() { profileViewModel.setAutomaticEnabled(automaticCheckbox.state == .on); refresh() }
    @objc private func pollingChanged() { profileViewModel.setPollingEnabled(pollingCheckbox.state == .on); refresh() }
    @objc private func pollingIntervalChanged() { profileViewModel.setPollingInterval(pollingIntervalField.doubleValue); refresh() }
    @objc private func pauseClicked() { viewModel.togglePause(); refresh() }
    @objc private func startShortcutRecording() { shortcutRecorder.beginRecording() }
    private func recordShortcut(_ shortcut: KeyShortcut) {
        guard shortcutSetter(shortcut) else {
            showPresentationError(NSError(domain: "DisplaySteward", code: 1, userInfo: [NSLocalizedDescriptionKey: "快捷键注册失败，已保留原快捷键。"]), in: window)
            refresh()
            return
        }
        shortcutRecorder.toolTip = "全局快捷键已生效：\(shortcut.displayName)"
        refresh()
    }
    @objc private func resetShortcutClicked() {
        guard shortcutResetter() else {
            showPresentationError(NSError(domain: "DisplaySteward", code: 2, userInfo: [NSLocalizedDescriptionKey: "默认快捷键注册失败，已保留原快捷键。"]), in: window)
            return
        }
        refresh()
    }
    @objc private func refreshDisplaysClicked() { do { try viewModel.refresh() } catch { showPresentationError(error, in: window) }; refresh() }
    @objc private func restoreAllClicked() { runDisplayRecoveryFlow(runtime: viewModel.runtime, in: window); refresh() }
    @objc private func saveProfileClicked() {
        flushDraftFields()
        do { _ = try profileViewModel.saveSelectedProfile(); refresh() }
        catch { showPresentationError(error, message: "无法保存配置档", in: window) }
    }
    @objc private func saveAndActivateClicked() {
        flushDraftFields()
        do {
            _ = try profileViewModel.saveSelectedProfile()
            let preview = try profileViewModel.previewSelectedProfileActivation()
            guard activationConfirmed(preview) else { refresh(); return }
            presentActivationResult(try profileViewModel.activateSelectedProfile(confirmedPreview: preview))
            refresh()
        } catch { showPresentationError(error, message: "无法保存并激活配置档", in: window) }
    }
    @objc private func openRules() { showDetail(.rules) }
    @objc private func openDisplays() { showDetail(.displays) }
    @objc private func backToSummary() { showSummary(); refresh() }
}

private final class TargetPopUpButton: NSPopUpButton { var representedTargets: [DisplayTarget] = [] }
private final class ActionPopUpButton: NSPopUpButton { var representedTarget: DisplayTarget? }

final class RulesPageViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let viewModel: ProfileManagementViewModel
    private let tableView = NSTableView()
    private let editorStack = FlippedStackView()
    private let previewLabel = makeLabel("尚未预览。预览不会更改配置或显示器状态。", style: .secondary)
    private let previewButton = NSButton(title: "预览", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复两条默认规则…", target: nil, action: nil)
    private let duplicateButton = NSButton(title: "复制", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    private let pasteboardType = NSPasteboard.PasteboardType("com.anhoder.display-steward.rule-row")

    init(viewModel: ProfileManagementViewModel) { self.viewModel = viewModel; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(buildRuleList())
        split.addArrangedSubview(buildEditor())
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        view = split
        rebuildEditor()
        selectCurrentRule()
    }
    func refreshFromRuntime() {
        if isViewLoaded, view.window?.isVisible == true, view.window?.firstResponder is NSTextView { return }
        viewModel.refreshFromRuntime()
        if viewModel.isDirty { viewModel.synchronizeActionMatrix() }
        guard isViewLoaded else { return }
        tableView.reloadData()
        selectCurrentRule()
        rebuildEditor()
    }
    private func buildRuleList() -> NSView {
        let container = NSView()
        let title = makeLabel("规则顺序", style: .section)
        let subtitle = makeLabel("优先级从上到下；拖动可重新排序。", style: .secondary)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = InterfaceMetrics.space6
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsEmptySelection = true
        tableView.registerForDraggedTypes([pasteboardType])
        scroll.documentView = tableView
        let addButton = NSButton(title: "+", target: self, action: #selector(addRule))
        addButton.toolTip = "新建规则"
        duplicateButton.target = self
        duplicateButton.action = #selector(duplicateRule)
        deleteButton.target = self
        deleteButton.action = #selector(deleteRule)
        deleteButton.contentTintColor = InterfaceColors.destructive
        let footer = NSStackView(views: [addButton, duplicateButton, deleteButton])
        footer.orientation = .horizontal
        footer.spacing = InterfaceMetrics.space2
        for child in [title, subtitle, scroll, footer] { child.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(child) }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: InterfaceMetrics.rulesListWidth),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: InterfaceMetrics.space4),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -InterfaceMetrics.space4),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: InterfaceMetrics.space4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: InterfaceMetrics.space1),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: InterfaceMetrics.space3),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -InterfaceMetrics.space3),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: InterfaceMetrics.space4),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -InterfaceMetrics.space4)
        ])
        return container
    }
    private func buildEditor() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        editorStack.orientation = .vertical
        editorStack.alignment = .leading
        editorStack.spacing = InterfaceMetrics.space4
        editorStack.edgeInsets = NSEdgeInsets(top: InterfaceMetrics.space4, left: InterfaceMetrics.space5, bottom: InterfaceMetrics.space5, right: InterfaceMetrics.space5)
        editorStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = editorStack
        NSLayoutConstraint.activate([
            editorStack.widthAnchor.constraint(greaterThanOrEqualToConstant: InterfaceMetrics.editorMinimumWidth),
            editorStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }
    private func rebuildEditor() {
        clearArrangedSubviews(editorStack)
        duplicateButton.isEnabled = viewModel.selectedRule != nil
        deleteButton.isEnabled = viewModel.selectedRule != nil
        guard let rule = viewModel.selectedRule else {
            editorStack.addArrangedSubview(makeLabel("没有规则", style: .title))
            editorStack.addArrangedSubview(makeLabel("所选配置档可以保留空规则列表。返回配置档保存前不会写入；也可以新建规则或恢复两条默认规则到同一草稿。", style: .secondary))
            addEditorFooter(); return
        }
        editorStack.addArrangedSubview(makeLabel("编辑规则", style: .title))
        let nameField = NSTextField(string: rule.name)
        nameField.identifier = NSUserInterfaceItemIdentifier("ruleName")
        nameField.delegate = self
        nameField.placeholderString = "规则名称"
        nameField.widthAnchor.constraint(equalToConstant: InterfaceMetrics.controlWidth * 2).isActive = true
        let enabled = NSButton(checkboxWithTitle: "启用此规则", target: self, action: #selector(selectedRuleEnabledChanged))
        enabled.state = rule.isEnabled ? .on : .off
        let nameRow = NSStackView(views: [makeLabel("名称", style: .secondary), nameField, enabled])
        nameRow.orientation = .horizontal
        nameRow.spacing = InterfaceMetrics.space3
        editorStack.addArrangedSubview(nameRow)
        editorStack.addArrangedSubview(sectionHeader(title: "条件（同时满足）", buttonTitle: "添加条件", action: #selector(addCondition)))
        for (index, condition) in rule.conditions.enumerated() { editorStack.addArrangedSubview(conditionRow(condition, index: index, count: rule.conditions.count)) }
        editorStack.addArrangedSubview(makeLabel("显示器操作", style: .section))
        editorStack.addArrangedSubview(makeLabel("矩阵包含当前与历史显示器。不处理表示这条规则对该显示器没有意见。", style: .secondary))
        let options = viewModel.targetOptions()
        if options.isEmpty {
            editorStack.addArrangedSubview(makeLabel("没有可靠的显示器目标。连接显示器并刷新后才能保存包含规则的配置。", style: .secondary))
        } else {
            for option in options {
                let action = rule.actions.first(where: { $0.target == option.target })?.action ?? .noAction
                editorStack.addArrangedSubview(actionRow(option: option, action: action))
            }
        }
        addEditorFooter()
    }
    private func sectionHeader(title: String, buttonTitle: String, action: Selector) -> NSView {
        let row = NSStackView(views: [makeLabel(title, style: .section), NSButton(title: buttonTitle, target: self, action: action)])
        row.orientation = .horizontal
        row.spacing = InterfaceMetrics.space3
        return row
    }
    private func conditionRow(_ condition: RuleCondition, index: Int, count: Int) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = InterfaceMetrics.space2
        let kindPopup = NSPopUpButton()
        kindPopup.addItems(withTitles: RuleConditionKind.allCases.map(\.presentationName))
        kindPopup.selectItem(at: kindIndex(condition))
        kindPopup.tag = index
        kindPopup.target = self
        kindPopup.action = #selector(conditionKindChanged(_:))
        row.addArrangedSubview(kindPopup)
        switch condition {
        case .always:
            row.addArrangedSubview(makeLabel("不添加其他限制", style: .secondary))
        case .count(let value):
            let kind = NSPopUpButton()
            kind.addItems(withTitles: [DisplayCountKind.online, .active].map(\.presentationName))
            kind.selectItem(at: value.kind == .online ? 0 : 1)
            kind.tag = index; kind.target = self; kind.action = #selector(countKindChanged(_:)); row.addArrangedSubview(kind)
            let scope = NSPopUpButton()
            scope.addItems(withTitles: [DisplayCountScope.all, .external].map(\.presentationName))
            scope.selectItem(at: value.scope == .all ? 0 : 1)
            scope.tag = index; scope.target = self; scope.action = #selector(countScopeChanged(_:)); row.addArrangedSubview(scope)
            let comparison = NSPopUpButton()
            let operators: [CountComparisonOperator] = [.equal, .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual]
            comparison.addItems(withTitles: operators.map(\.presentationName))
            comparison.selectItem(at: operators.firstIndex(of: value.comparison) ?? 0)
            comparison.tag = index; comparison.target = self; comparison.action = #selector(countComparisonChanged(_:)); row.addArrangedSubview(comparison)
            let field = NSTextField(string: String(value.value))
            field.tag = index; field.target = self; field.action = #selector(countValueChanged(_:)); field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: InterfaceMetrics.compactControlWidth).isActive = true
            row.addArrangedSubview(field)
        case .exactState(let identity, let state): addTargetStateControls(to: row, index: index, selected: .exact(identity), state: state, exactOnly: true)
        case .familyState(let family, let state): addTargetStateControls(to: row, index: index, selected: .family(family), state: state, exactOnly: false)
        }
        let remove = NSButton(title: "移除", target: self, action: #selector(removeCondition(_:)))
        remove.tag = index
        remove.isEnabled = count > 1
        remove.contentTintColor = InterfaceColors.destructive
        row.addArrangedSubview(remove)
        return row
    }
    private func addTargetStateControls(to row: NSStackView, index: Int, selected: DisplayTarget, state: ObservableDisplayState, exactOnly: Bool) {
        let popup = TargetPopUpButton()
        var targets: [DisplayTarget]
        if exactOnly {
            targets = viewModel.targetOptions().compactMap { if case .exact = $0.target { return $0.target }; return nil }
        } else {
            var families = Set<DisplayFamily>()
            targets = viewModel.targetOptions().compactMap {
                let family: DisplayFamily
                switch $0.target { case .exact(let identity): family = identity.family; case .family(let value): family = value }
                return families.insert(family).inserted ? .family(family) : nil
            }
        }
        if !targets.contains(selected) { targets.insert(selected, at: 0) }
        popup.representedTargets = targets
        popup.addItems(withTitles: targets.map(PresentationText.targetName))
        popup.selectItem(at: targets.firstIndex(of: selected) ?? 0)
        popup.tag = index; popup.target = self; popup.action = #selector(conditionTargetChanged(_:)); row.addArrangedSubview(popup)
        let states: [ObservableDisplayState] = [.active, .online, .disabledByThisAppConnectionUnknown, .notObserved]
        let statePopup = NSPopUpButton()
        statePopup.addItems(withTitles: states.map(\.presentationName))
        statePopup.selectItem(at: states.firstIndex(of: state) ?? 0)
        statePopup.tag = index; statePopup.target = self; statePopup.action = #selector(conditionStateChanged(_:)); row.addArrangedSubview(statePopup)
    }
    private func actionRow(option: RuleDisplayOption, action: DisplayAction) -> NSView {
        let title = makeLabel(option.title, style: .body)
        title.toolTip = PresentationText.targetName(option.target)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.widthAnchor.constraint(greaterThanOrEqualToConstant: InterfaceMetrics.controlWidth).isActive = true
        let popup = ActionPopUpButton()
        let actions: [DisplayAction] = [.noAction, .enable, .disable]
        popup.addItems(withTitles: actions.map(\.presentationName))
        popup.selectItem(at: actions.firstIndex(of: action) ?? 0)
        popup.representedTarget = option.target; popup.target = self; popup.action = #selector(actionChanged(_:))
        let targetScope: String
        switch option.target {
        case .exact: targetScope = option.state?.presentationName ?? "仅历史配置"
        case .family: targetScope = "同系列全部"
        }
        let row = NSStackView(views: [title, makeLabel(option.isBuiltIn ? "内置" : "外接", style: .secondary), makeLabel(targetScope, style: .secondary), popup])
        row.orientation = .horizontal; row.spacing = InterfaceMetrics.space3
        return row
    }
    private func addEditorFooter() {
        previewLabel.maximumNumberOfLines = 4
        previewLabel.stringValue = viewModel.lastPreview.map(PresentationText.previewSummary) ?? "尚未预览。预览只读取当前快照，不会保存配置或更改显示器状态。"
        editorStack.addArrangedSubview(previewLabel)
        editorStack.addArrangedSubview(makeLabel("规则与名称、自动化和定时检查属于同一配置档草稿；请返回配置档统一保存。", style: .secondary))
        restoreButton.target = self; restoreButton.action = #selector(restoreDefaults); restoreButton.contentTintColor = InterfaceColors.destructive
        previewButton.target = self; previewButton.action = #selector(previewRules)
        let buttons = NSStackView(views: [restoreButton, previewButton]); buttons.orientation = .horizontal; buttons.spacing = InterfaceMetrics.space2
        editorStack.addArrangedSubview(buttons)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { viewModel.draftConfiguration.rules.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard viewModel.draftConfiguration.rules.indices.contains(row) else { return nil }
        let rule = viewModel.draftConfiguration.rules[row]
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(ruleListEnabledChanged(_:)))
        checkbox.state = rule.isEnabled ? .on : .off; checkbox.tag = row
        let label = makeLabel(rule.name, style: .body); label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [checkbox, label, makeLabel("P\(rule.priority)", style: .secondary)]); stack.orientation = .horizontal; stack.spacing = InterfaceMetrics.space2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        viewModel.selectRule(id: viewModel.draftConfiguration.rules.indices.contains(row) ? viewModel.draftConfiguration.rules[row].id : nil)
        rebuildEditor()
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem(); item.setString(String(row), forType: pasteboardType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above); return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let value = info.draggingPasteboard.string(forType: pasteboardType), let source = Int(value) else { return false }
        viewModel.moveRule(from: source, to: row); tableView.reloadData(); selectCurrentRule(); rebuildEditor(); return true
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field.identifier == NSUserInterfaceItemIdentifier("ruleName") else { return }
        viewModel.updateSelectedRule { $0.name = field.stringValue }; tableView.reloadData()
    }
    @objc private func addRule() {
        do { _ = try viewModel.addRule(); tableView.reloadData(); selectCurrentRule(); rebuildEditor() } catch { showPresentationError(error, in: view.window) }
    }
    @objc private func duplicateRule() {
        do { _ = try viewModel.duplicateSelectedRule(); tableView.reloadData(); selectCurrentRule(); rebuildEditor() } catch { showPresentationError(error, in: view.window) }
    }
    @objc private func deleteRule() {
        guard viewModel.selectedRule != nil else { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "删除这条规则？"; alert.informativeText = "删除只会修改所选配置档草稿；返回配置档保存前不会写入。"; alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        viewModel.deleteSelectedRule(); tableView.reloadData(); selectCurrentRule(); rebuildEditor()
    }
    @objc private func ruleListEnabledChanged(_ sender: NSButton) {
        guard viewModel.draftConfiguration.rules.indices.contains(sender.tag) else { return }
        viewModel.setRuleEnabled(id: viewModel.draftConfiguration.rules[sender.tag].id, enabled: sender.state == .on); rebuildEditor()
    }
    @objc private func selectedRuleEnabledChanged(_ sender: NSButton) {
        guard let id = viewModel.selectedRuleID else { return }
        viewModel.setRuleEnabled(id: id, enabled: sender.state == .on); tableView.reloadData()
    }
    @objc private func addCondition() { viewModel.addCondition(); rebuildEditor() }
    @objc private func removeCondition(_ sender: NSButton) {
        do { try viewModel.removeCondition(at: sender.tag); rebuildEditor() } catch { showPresentationError(error, in: view.window) }
    }
    @objc private func conditionKindChanged(_ sender: NSPopUpButton) {
        guard let kind = RuleConditionKind.allCases[safe: sender.indexOfSelectedItem] else { return }
        let condition: RuleCondition
        switch kind {
        case .always: condition = .always
        case .count: condition = .count(.init(kind: .online, scope: .all, comparison: .equal, value: 1))
        case .exactState:
            guard let target = viewModel.targetOptions().map(\.target).first(where: { if case .exact = $0 { return true }; return false }), case .exact(let identity) = target else {
                showPresentationError(PresentationError.noReliableDisplayTarget, in: view.window); rebuildEditor(); return
            }
            condition = .exactState(identity: identity, state: .active)
        case .familyState:
            guard let target = viewModel.targetOptions().first?.target else { showPresentationError(PresentationError.noReliableDisplayTarget, in: view.window); rebuildEditor(); return }
            let family: DisplayFamily
            switch target { case .exact(let identity): family = identity.family; case .family(let value): family = value }
            condition = .familyState(family: family, state: .active)
        }
        viewModel.replaceCondition(at: sender.tag, with: condition); rebuildEditor()
    }
    @objc private func countKindChanged(_ sender: NSPopUpButton) { updateCountCondition(at: sender.tag) { $0.kind = sender.indexOfSelectedItem == 0 ? .online : .active } }
    @objc private func countScopeChanged(_ sender: NSPopUpButton) { updateCountCondition(at: sender.tag) { $0.scope = sender.indexOfSelectedItem == 0 ? .all : .external } }
    @objc private func countComparisonChanged(_ sender: NSPopUpButton) {
        let values: [CountComparisonOperator] = [.equal, .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual]
        if let value = values[safe: sender.indexOfSelectedItem] { updateCountCondition(at: sender.tag) { $0.comparison = value } }
    }
    @objc private func countValueChanged(_ sender: NSTextField) { updateCountCondition(at: sender.tag) { $0.value = max(0, sender.integerValue) }; rebuildEditor() }
    private func updateCountCondition(at index: Int, change: (inout DisplayCountCondition) -> Void) {
        guard let rule = viewModel.selectedRule, rule.conditions.indices.contains(index), case .count(var value) = rule.conditions[index] else { return }
        change(&value); viewModel.replaceCondition(at: index, with: .count(value))
    }
    @objc private func conditionTargetChanged(_ sender: TargetPopUpButton) {
        guard let target = sender.representedTargets[safe: sender.indexOfSelectedItem], let rule = viewModel.selectedRule, rule.conditions.indices.contains(sender.tag) else { return }
        switch (rule.conditions[sender.tag], target) {
        case let (.exactState(_, state), .exact(identity)): viewModel.replaceCondition(at: sender.tag, with: .exactState(identity: identity, state: state))
        case let (.familyState(_, state), .family(family)): viewModel.replaceCondition(at: sender.tag, with: .familyState(family: family, state: state))
        default: break
        }
    }
    @objc private func conditionStateChanged(_ sender: NSPopUpButton) {
        let states: [ObservableDisplayState] = [.active, .online, .disabledByThisAppConnectionUnknown, .notObserved]
        guard let state = states[safe: sender.indexOfSelectedItem], let rule = viewModel.selectedRule, rule.conditions.indices.contains(sender.tag) else { return }
        switch rule.conditions[sender.tag] {
        case .exactState(let identity, _): viewModel.replaceCondition(at: sender.tag, with: .exactState(identity: identity, state: state))
        case .familyState(let family, _): viewModel.replaceCondition(at: sender.tag, with: .familyState(family: family, state: state))
        default: break
        }
    }
    @objc private func actionChanged(_ sender: ActionPopUpButton) {
        let actions: [DisplayAction] = [.noAction, .enable, .disable]
        if let target = sender.representedTarget, let action = actions[safe: sender.indexOfSelectedItem] { viewModel.setAction(action, for: target) }
    }
    @objc private func previewRules() {
        do { previewLabel.stringValue = PresentationText.previewSummary(try viewModel.preview()) } catch { showPresentationError(error, message: "无法预览规则", in: view.window) }
    }
    @objc private func restoreDefaults() {
        do {
            let candidate = try viewModel.defaultRulesCandidate()
            let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "恢复两条默认规则到草稿？"; alert.informativeText = "将仅替换所选配置档草稿中的规则，不会重置自动化、定时检查、全局快捷键、显示器历史或别名，也不会立即应用。\n\n预览：\(PresentationText.previewSummary(candidate.preview))"; alert.addButton(withTitle: "替换草稿规则"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try viewModel.useDefaultRulesCandidate(candidate.profile); tableView.reloadData(); selectCurrentRule(); rebuildEditor()
        } catch { showPresentationError(error, message: "无法恢复默认规则", in: view.window) }
    }
    private func kindIndex(_ condition: RuleCondition) -> Int { switch condition { case .always: return 0; case .count: return 1; case .exactState: return 2; case .familyState: return 3 } }
    private func selectCurrentRule() {
        guard let id = viewModel.selectedRuleID, let row = viewModel.draftConfiguration.rules.firstIndex(where: { $0.id == id }) else { tableView.deselectAll(nil); return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
}

private enum DisplayTableEntry { case section(String); case display(DisplayPresentationRow) }
private final class AliasTextField: NSTextField { var rowID: String? }
private final class DisplayActionButton: NSButton { var rowID: String? }

final class DisplaysPageViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let viewModel: DisplaysViewModel
    private let onLastActiveSafetyBlock: () -> Void
    private let tableView = NSTableView()
    private let detailStack = FlippedStackView()
    private let restoreAllButton = NSButton(title: PresentationText.restoreAllTitle, target: nil, action: nil)
    private let recoveryExplanation = makeLabel("", style: .secondary)
    private var entries: [DisplayTableEntry] = []
    private var selectedRowID: String?
    init(runtime: DisplayManagingRuntime, onLastActiveSafetyBlock: @escaping () -> Void) { viewModel = DisplaysViewModel(runtime: runtime); self.onLastActiveSafetyBlock = onLastActiveSafetyBlock; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(buildDisplayList()); split.addArrangedSubview(buildDetails()); split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        view = split; rebuildEntries(); rebuildDetails()
    }
    func refreshFromRuntime() {
        guard isViewLoaded else { return }
        rebuildEntries(); tableView.reloadData(); restoreSelection(); rebuildDetails()
        updateRecoveryControls()
    }
    private func buildDisplayList() -> NSView {
        let container = NSView(); let heading = makeLabel("显示器", style: .section); let explanation = makeLabel("当前状态与历史记录分开显示。", style: .secondary)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("display"))); tableView.headerView = nil; tableView.delegate = self; tableView.dataSource = self; tableView.rowHeight = InterfaceMetrics.space6 + InterfaceMetrics.space3; scroll.documentView = tableView
        let refresh = NSButton(title: "刷新状态", target: self, action: #selector(refreshClicked))
        restoreAllButton.target = self; restoreAllButton.action = #selector(restoreAllClicked)
        updateRecoveryControls()
        for child in [heading, explanation, scroll, recoveryExplanation, refresh, restoreAllButton] { child.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(child) }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: InterfaceMetrics.displaysListWidth),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: InterfaceMetrics.space4), heading.topAnchor.constraint(equalTo: container.topAnchor, constant: InterfaceMetrics.space4),
            explanation.leadingAnchor.constraint(equalTo: heading.leadingAnchor), explanation.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: InterfaceMetrics.space1),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor), scroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: InterfaceMetrics.space3), scroll.bottomAnchor.constraint(equalTo: recoveryExplanation.topAnchor, constant: -InterfaceMetrics.space3),
            recoveryExplanation.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: InterfaceMetrics.space4), recoveryExplanation.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -InterfaceMetrics.space4), recoveryExplanation.bottomAnchor.constraint(equalTo: refresh.topAnchor, constant: -InterfaceMetrics.space2),
            refresh.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: InterfaceMetrics.space4), refresh.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -InterfaceMetrics.space4),
            restoreAllButton.leadingAnchor.constraint(equalTo: refresh.trailingAnchor, constant: InterfaceMetrics.space2), restoreAllButton.centerYAnchor.constraint(equalTo: refresh.centerYAnchor)
        ])
        return container
    }
    private func updateRecoveryControls() {
        let plan = viewModel.runtime.status.recoveryPlan
        restoreAllButton.isEnabled = !plan.isEmpty
        recoveryExplanation.stringValue = plan.isEmpty
            ? PresentationText.noRecoverableDisplays
            : "可恢复 \(plan.targets.count) 台显示器；执行前会再次确认。"
    }
    private func buildDetails() -> NSView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        detailStack.orientation = .vertical; detailStack.alignment = .leading; detailStack.spacing = InterfaceMetrics.space4; detailStack.edgeInsets = NSEdgeInsets(top: InterfaceMetrics.space4, left: InterfaceMetrics.space5, bottom: InterfaceMetrics.space5, right: InterfaceMetrics.space5); detailStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = detailStack
        NSLayoutConstraint.activate([detailStack.widthAnchor.constraint(greaterThanOrEqualToConstant: InterfaceMetrics.editorMinimumWidth), detailStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        return scroll
    }
    private func rebuildEntries() {
        entries = []
        if !viewModel.currentRows.isEmpty { entries.append(.section("当前及本应用可恢复")); entries.append(contentsOf: viewModel.currentRows.map(DisplayTableEntry.display)) }
        if !viewModel.historicalRows.isEmpty { entries.append(.section("历史记录")); entries.append(contentsOf: viewModel.historicalRows.map(DisplayTableEntry.display)) }
    }
    private func rebuildDetails() {
        clearArrangedSubviews(detailStack)
        guard let selectedRowID, let row = viewModel.row(id: selectedRowID) else {
            detailStack.addArrangedSubview(makeLabel("选择一台显示器", style: .title)); detailStack.addArrangedSubview(makeLabel("查看可观察状态、显示模式、身份信息和安全的手动操作。", style: .secondary)); return
        }
        detailStack.addArrangedSubview(makeLabel(row.title, style: .title))
        if let secondary = row.secondaryName { detailStack.addArrangedSubview(makeLabel("系统名称：\(secondary)", style: .secondary)) }
        let stateLabel = makeLabel(row.stateSummary, style: .section); stateLabel.textColor = row.state == .disabledByThisAppConnectionUnknown || row.recoveryEvidence != nil ? InterfaceColors.warning : InterfaceColors.primaryText
        detailStack.addArrangedSubview(stateLabel); detailStack.addArrangedSubview(makeLabel(row.rowDetail, style: .secondary))
        let alias = AliasTextField(string: row.alias ?? ""); alias.placeholderString = "可选别名"; alias.rowID = row.id; alias.delegate = self; alias.isEnabled = row.target != nil; alias.widthAnchor.constraint(equalToConstant: InterfaceMetrics.controlWidth * 2).isActive = true
        let aliasRow = NSStackView(views: [makeLabel("别名", style: .secondary), alias]); aliasRow.orientation = .horizontal; aliasRow.spacing = InterfaceMetrics.space3; detailStack.addArrangedSubview(aliasRow)
        if row.target == nil { detailStack.addArrangedSubview(makeLabel("缺少可靠厂商与型号标识，不能持久化别名。", style: .secondary)) }
        detailStack.addArrangedSubview(makeLabel("可观察详情", style: .section)); detailStack.addArrangedSubview(detailGrid(for: row))
        if let action = row.manualAction, let actionTitle = row.manualActionTitle {
            let button = DisplayActionButton(title: actionTitle, target: self, action: #selector(manualActionClicked(_:))); button.rowID = row.id; if action == .disable { button.contentTintColor = InterfaceColors.destructive }; detailStack.addArrangedSubview(button)
            detailStack.addArrangedSubview(makeLabel("手动操作使用与规则执行相同的安全检查，并会暂停自动化。", style: .secondary))
        } else { detailStack.addArrangedSubview(makeLabel("此历史记录当前没有可执行的手动操作。", style: .secondary)) }
        if row.isHistorical {
            let forget = DisplayActionButton(title: "遗忘此历史显示器…", target: self, action: #selector(forgetClicked(_:))); forget.rowID = row.id; forget.isEnabled = row.canForget; forget.contentTintColor = InterfaceColors.destructive
            detailStack.addArrangedSubview(forget); detailStack.addArrangedSubview(makeLabel(row.forgetExplanation, style: .secondary))
        }
    }
    private func detailGrid(for row: DisplayPresentationRow) -> NSGridView {
        let mirror = row.mirrorsRuntimeID.map { "镜像到运行 ID \($0)" } ?? "未镜像"; let runtimeID = row.runtimeID.map(String.init) ?? "当前不可用"; let serial = row.stableIdentity.map { String($0.serialNumber) } ?? "不可靠或不可用"
        let mode: String; let refresh: String
        if let value = row.mode { mode = "逻辑 \(value.logicalWidth)×\(value.logicalHeight)，像素 \(value.pixelWidth)×\(value.pixelHeight)，旋转 \(String(format: "%.0f°", value.rotationDegrees))"; refresh = value.refreshRate > 0 ? String(format: "%.2f Hz", value.refreshRate) : "未知" } else { mode = "当前不可观察"; refresh = "当前不可观察" }
        let rows: [[NSView]] = [
            [makeLabel("模式", style: .secondary), makeLabel(mode)], [makeLabel("刷新率", style: .secondary), makeLabel(refresh)], [makeLabel("镜像", style: .secondary), makeLabel(mirror)],
            [makeLabel("厂商 ID", style: .secondary), makeLabel(String(row.family.vendorID))], [makeLabel("型号 ID", style: .secondary), makeLabel(String(row.family.modelID))], [makeLabel("序列号", style: .secondary), makeLabel(serial)],
            [makeLabel("稳定标识", style: .secondary), makeLabel(row.stableIdentitySummary)], [makeLabel("运行 ID", style: .secondary), makeLabel(runtimeID)]
        ]
        let grid = NSGridView(views: rows); grid.rowSpacing = InterfaceMetrics.space2; grid.columnSpacing = InterfaceMetrics.space4; grid.column(at: 0).xPlacement = .trailing; grid.column(at: 1).xPlacement = .leading; return grid
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { entries.indices.contains(row) && { if case .section = entries[row] { return true }; return false }() }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { entries.indices.contains(row) && { if case .display = entries[row] { return true }; return false }() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard entries.indices.contains(index) else { return nil }
        switch entries[index] {
        case .section(let title): return makeLabel(title, style: .section)
        case .display(let row):
            let title = makeLabel(row.title); title.lineBreakMode = .byTruncatingTail
            let detailText = [row.secondaryName, row.rowDetail].compactMap { $0 }.joined(separator: " · ")
            let detail = makeLabel(detailText, style: .secondary); detail.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [title, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = InterfaceMetrics.space1; return stack
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = tableView.selectedRow
        guard entries.indices.contains(index), case .display(let row) = entries[index] else { selectedRowID = nil; rebuildDetails(); return }
        selectedRowID = row.id; rebuildDetails()
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? AliasTextField, let rowID = field.rowID else { return }
        do { _ = try viewModel.setAlias(field.stringValue, for: rowID); selectedRowID = rowID; refreshFromRuntime() } catch { showPresentationError(error, message: "无法保存显示器别名", in: view.window) }
    }
    @objc private func refreshClicked() { do { _ = try viewModel.refresh(); refreshFromRuntime() } catch { showPresentationError(error, message: "无法刷新显示器状态", in: view.window) } }
    @objc private func restoreAllClicked() {
        runDisplayRecoveryFlow(runtime: viewModel.runtime, in: view.window)
        refreshFromRuntime()
    }
    @objc private func manualActionClicked(_ sender: DisplayActionButton) {
        guard let rowID = sender.rowID, let row = viewModel.row(id: rowID), let action = row.manualAction else { return }
        if action == .disable && row.isMain {
            let alert = NSAlert(); alert.alertStyle = .critical; alert.messageText = "关闭当前主显示器？"; alert.informativeText = "画面可能立即转移或短暂中断。运行时仍会阻止关闭最后一台活动且可绘制的显示器。"; alert.addButton(withTitle: "仍要关闭"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do { _ = try viewModel.performManualAction(for: rowID); refreshFromRuntime() } catch {
            if let coordinatorError = error as? AutomationCoordinatorError,
               case .lastActiveDisplay = coordinatorError {
                onLastActiveSafetyBlock()
            }
            showPresentationError(error, message: "显示器操作未完成", in: view.window)
        }
    }
    @objc private func forgetClicked(_ sender: DisplayActionButton) {
        guard let rowID = sender.rowID, let row = viewModel.row(id: rowID) else { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "遗忘“\(row.title)”？"; alert.informativeText = "这只会删除历史记录和别名，不会尝试连接、开启或关闭显示器。"; alert.addButton(withTitle: "遗忘"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { _ = try viewModel.forget(rowID: rowID); selectedRowID = nil; refreshFromRuntime() } catch { showPresentationError(error, message: "无法遗忘历史显示器", in: view.window) }
    }
    private func restoreSelection() {
        guard let selectedRowID, let index = entries.firstIndex(where: { if case .display(let row) = $0 { return row.id == selectedRowID }; return false }) else { tableView.deselectAll(nil); return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
