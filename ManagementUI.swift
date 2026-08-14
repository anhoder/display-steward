import AppKit

let displayStewardAppName = "Display Steward"

enum InterfaceMetrics {
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 24
    static let space6: CGFloat = 32
    static let mainWindowSize = NSSize(width: 540, height: 500)
    static let managementWindowSize = NSSize(width: 980, height: 680)
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

final class MainWindowController: NSWindowController {
    private let viewModel: OverviewViewModel
    private let shortcutProvider: () -> KeyShortcut
    private let shortcutSetter: (KeyShortcut) -> Bool
    private let shortcutResetter: () -> Bool
    private let onOpenManagement: () -> Void
    private let summaryLabel = makeLabel("", style: .title)
    private let stateLabel = makeLabel("", style: .body)
    private let evaluationLabel = makeLabel("", style: .secondary)
    private let automaticCheckbox = NSButton(checkboxWithTitle: "启用自动规则", target: nil, action: nil)
    private let pauseButton = NSButton(title: "暂停自动化", target: nil, action: nil)
    private let pollingCheckbox = NSButton(checkboxWithTitle: "启用定时检查", target: nil, action: nil)
    private let pollingIntervalField = NSTextField(string: "3")
    private let shortcutRecorder = ShortcutRecorderButton()
    private let resetShortcutButton = NSButton(title: "恢复默认", target: nil, action: nil)
    private let manageButton = NSButton(title: "管理自动规则与显示器…", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新状态", target: nil, action: nil)
    private let recoverySection = NSStackView()
    private let recoveryNoticeLabel = makeLabel("", style: .secondary)
    private let restoreAllButton = NSButton(title: PresentationText.restoreAllTitle, target: nil, action: nil)

    init(runtime: DisplayManagingRuntime, shortcutProvider: @escaping () -> KeyShortcut, shortcutSetter: @escaping (KeyShortcut) -> Bool, shortcutResetter: @escaping () -> Bool, onOpenManagement: @escaping () -> Void) {
        viewModel = OverviewViewModel(runtime: runtime)
        self.shortcutProvider = shortcutProvider
        self.shortcutSetter = shortcutSetter
        self.shortcutResetter = shortcutResetter
        self.onOpenManagement = onOpenManagement
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: InterfaceMetrics.mainWindowSize), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = displayStewardAppName
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildView()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        let presentation = viewModel.presentation
        summaryLabel.stringValue = presentation.onlineActiveSummary
        stateLabel.stringValue = presentation.automationState
        stateLabel.textColor = presentation.hasFailure ? InterfaceColors.destructive : InterfaceColors.secondaryText
        evaluationLabel.stringValue = "最近评估 · \(presentation.lastEvaluationSummary)"
        automaticCheckbox.state = presentation.automaticEnabled ? .on : .off
        pauseButton.title = presentation.pauseButtonTitle
        pauseButton.isEnabled = presentation.automaticEnabled || presentation.isPaused
        pollingCheckbox.state = presentation.pollingEnabled ? .on : .off
        pollingCheckbox.isEnabled = presentation.automaticEnabled
        pollingIntervalField.doubleValue = presentation.pollingInterval
        pollingIntervalField.isEnabled = presentation.automaticEnabled && presentation.pollingEnabled
        shortcutRecorder.shortcut = shortcutProvider()
        recoverySection.isHidden = presentation.recoveryCount == 0
        recoveryNoticeLabel.stringValue = presentation.recoveryNotice ?? ""
        restoreAllButton.isEnabled = presentation.recoveryCount > 0
    }

    private func buildView() {
        guard let contentView = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = InterfaceMetrics.space5
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = InterfaceMetrics.space2
        header.addArrangedSubview(makeLabel("显示器概览", style: .secondary))
        header.addArrangedSubview(summaryLabel)
        header.addArrangedSubview(stateLabel)
        header.addArrangedSubview(evaluationLabel)
        evaluationLabel.maximumNumberOfLines = 2
        root.addArrangedSubview(header)
        let automationSection = NSStackView()
        automationSection.orientation = .vertical
        automationSection.alignment = .leading
        automationSection.spacing = InterfaceMetrics.space3
        automationSection.addArrangedSubview(makeLabel("自动化", style: .section))
        let automaticRow = NSStackView(views: [automaticCheckbox, pauseButton])
        automaticRow.orientation = .horizontal
        automaticRow.spacing = InterfaceMetrics.space3
        automationSection.addArrangedSubview(automaticRow)
        let pollingRow = NSStackView()
        pollingRow.orientation = .horizontal
        pollingRow.spacing = InterfaceMetrics.space2
        pollingRow.addArrangedSubview(pollingCheckbox)
        pollingRow.addArrangedSubview(makeLabel("间隔", style: .secondary))
        pollingRow.addArrangedSubview(pollingIntervalField)
        pollingRow.addArrangedSubview(makeLabel("秒", style: .secondary))
        automationSection.addArrangedSubview(pollingRow)
        root.addArrangedSubview(automationSection)
        let shortcutSection = NSStackView()
        shortcutSection.orientation = .vertical
        shortcutSection.alignment = .leading
        shortcutSection.spacing = InterfaceMetrics.space3
        shortcutSection.addArrangedSubview(makeLabel("切换内置显示器快捷键", style: .section))
        shortcutSection.addArrangedSubview(makeLabel("快捷键独立于自动规则；手动切换后自动化会暂停。", style: .secondary))
        let shortcutRow = NSStackView(views: [shortcutRecorder, resetShortcutButton])
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = InterfaceMetrics.space2
        shortcutSection.addArrangedSubview(shortcutRow)
        root.addArrangedSubview(shortcutSection)
        recoverySection.orientation = .vertical
        recoverySection.alignment = .leading
        recoverySection.spacing = InterfaceMetrics.space2
        recoverySection.addArrangedSubview(makeLabel("安全恢复", style: .section))
        recoverySection.addArrangedSubview(recoveryNoticeLabel)
        recoverySection.addArrangedSubview(restoreAllButton)
        root.addArrangedSubview(recoverySection)
        let actions = NSStackView(views: [manageButton, refreshButton])
        actions.orientation = .horizontal
        actions.spacing = InterfaceMetrics.space2
        manageButton.keyEquivalent = "\r"
        root.addArrangedSubview(actions)
        automaticCheckbox.target = self
        automaticCheckbox.action = #selector(automaticChanged)
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        pollingCheckbox.target = self
        pollingCheckbox.action = #selector(pollingChanged)
        pollingIntervalField.target = self
        pollingIntervalField.action = #selector(pollingIntervalChanged)
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
        manageButton.target = self
        manageButton.action = #selector(manageClicked)
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        restoreAllButton.target = self
        restoreAllButton.action = #selector(restoreAllClicked)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: InterfaceMetrics.space5),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -InterfaceMetrics.space5),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: InterfaceMetrics.space5),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -InterfaceMetrics.space5),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            stateLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            evaluationLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            pollingIntervalField.widthAnchor.constraint(equalToConstant: InterfaceMetrics.compactControlWidth),
            shortcutRecorder.widthAnchor.constraint(equalToConstant: InterfaceMetrics.controlWidth)
        ])
    }

    @objc private func automaticChanged() {
        do { try viewModel.setAutomaticEnabled(automaticCheckbox.state == .on) } catch { showPresentationError(error, in: window) }
        refresh()
    }
    @objc private func pauseClicked() { viewModel.togglePause(); refresh() }
    @objc private func pollingChanged() {
        do { try viewModel.setPollingEnabled(pollingCheckbox.state == .on) } catch { showPresentationError(error, in: window) }
        refresh()
    }
    @objc private func pollingIntervalChanged() {
        do { try viewModel.setPollingInterval(pollingIntervalField.doubleValue) } catch { showPresentationError(error, in: window) }
        refresh()
    }
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
    @objc private func manageClicked() { onOpenManagement() }
    @objc private func refreshClicked() {
        do { try viewModel.refresh() } catch { showPresentationError(error, in: window) }
        refresh()
    }
    @objc private func restoreAllClicked() {
        runDisplayRecoveryFlow(runtime: viewModel.runtime, in: window)
        refresh()
    }
}

final class ManagementWindowController: NSWindowController, NSWindowDelegate {
    enum Page: Int { case rules, displays }
    private let navigation = NSSegmentedControl(labels: ["自动规则", "显示器"], trackingMode: .selectOne, target: nil, action: nil)
    private let pageContainer = NSView()
    private let rootController = NSViewController()
    let rulesController: RulesPageViewController
    let displaysController: DisplaysPageViewController
    private var selectedPage: Page = .rules

    init(runtime: DisplayManagingRuntime, onLastActiveSafetyBlock: @escaping () -> Void) {
        rulesController = RulesPageViewController(runtime: runtime)
        displaysController = DisplaysPageViewController(runtime: runtime, onLastActiveSafetyBlock: onLastActiveSafetyBlock)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: InterfaceMetrics.managementWindowSize), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Display Steward 管理"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = InterfaceMetrics.managementWindowSize
        super.init(window: window)
        buildView()
        window.delegate = self
        showPage(.rules)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(page: Page = .rules) {
        showPage(page)
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func refresh() { rulesController.refreshFromRuntime(); displaysController.refreshFromRuntime() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard rulesController.viewModel.isDirty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "放弃未保存的规则修改？"
        alert.informativeText = "关闭管理窗口会丢弃尚未“保存并应用”的规则修改。"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃修改")
        if alert.runModal() == .alertSecondButtonReturn { rulesController.viewModel.reloadFromRuntime(); return true }
        return false
    }
    private func buildView() {
        let root = NSView()
        rootController.view = root
        window?.contentViewController = rootController
        navigation.selectedSegment = selectedPage.rawValue
        navigation.target = self
        navigation.action = #selector(navigationChanged)
        navigation.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(navigation)
        root.addSubview(pageContainer)
        rootController.addChild(rulesController)
        rootController.addChild(displaysController)
        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: InterfaceMetrics.space5),
            navigation.topAnchor.constraint(equalTo: root.topAnchor, constant: InterfaceMetrics.space4),
            pageContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageContainer.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: InterfaceMetrics.space4),
            pageContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }
    @objc private func navigationChanged() { if let page = Page(rawValue: navigation.selectedSegment) { showPage(page) } }
    private func showPage(_ page: Page) {
        selectedPage = page
        navigation.selectedSegment = page.rawValue
        for subview in pageContainer.subviews { subview.removeFromSuperview() }
        let controller = page == .rules ? rulesController : displaysController
        let pageView = controller.view
        pageView.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            pageView.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor)
        ])
    }
}

private final class TargetPopUpButton: NSPopUpButton { var representedTargets: [DisplayTarget] = [] }
private final class ActionPopUpButton: NSPopUpButton { var representedTarget: DisplayTarget? }

final class RulesPageViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let viewModel: RulesEditorViewModel
    private let tableView = NSTableView()
    private let editorStack = NSStackView()
    private let previewLabel = makeLabel("尚未预览。预览不会更改配置或显示器状态。", style: .secondary)
    private let previewButton = NSButton(title: "预览", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存并应用", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复两条默认规则…", target: nil, action: nil)
    private let duplicateButton = NSButton(title: "复制", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    private let pasteboardType = NSPasteboard.PasteboardType("com.anhoder.display-steward.rule-row")

    init(runtime: DisplayManagingRuntime) { viewModel = RulesEditorViewModel(runtime: runtime); super.init(nibName: nil, bundle: nil) }
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
        if viewModel.isDirty { viewModel.synchronizeHistory(); viewModel.synchronizeActionMatrix() } else { viewModel.reloadFromRuntime() }
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
            editorStack.addArrangedSubview(makeLabel("没有自动规则", style: .title))
            editorStack.addArrangedSubview(makeLabel("可以保留空的全局规则列表。保存后不会自动恢复默认规则；也可以新建规则或恢复两条默认规则。", style: .secondary))
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
        restoreButton.target = self; restoreButton.action = #selector(restoreDefaults); restoreButton.contentTintColor = InterfaceColors.destructive
        previewButton.target = self; previewButton.action = #selector(previewRules)
        saveButton.target = self; saveButton.action = #selector(saveAndApply); saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [restoreButton, previewButton, saveButton]); buttons.orientation = .horizontal; buttons.spacing = InterfaceMetrics.space2
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
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "删除这条规则？"; alert.informativeText = "删除会保留其他规则与所有应用设置；在“保存并应用”之前不会写入配置。"; alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
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
    @objc private func saveAndApply() {
        do { _ = try viewModel.saveAndApply(); tableView.reloadData(); selectCurrentRule(); rebuildEditor() } catch { showPresentationError(error, message: "无法保存并应用规则", in: view.window) }
    }
    @objc private func restoreDefaults() {
        do {
            let candidate = try viewModel.defaultRulesCandidate()
            let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "恢复两条默认规则？"; alert.informativeText = "将仅替换自动规则，不会重置自动开关、轮询、快捷键、显示器历史或别名。\n\n预览：\(PresentationText.previewSummary(candidate.preview))"; alert.addButton(withTitle: "恢复并应用"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = try viewModel.applyDefaultRulesCandidate(candidate.configuration); tableView.reloadData(); selectCurrentRule(); rebuildEditor()
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
    private let detailStack = NSStackView()
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
            detailStack.addArrangedSubview(makeLabel("手动操作使用与自动规则相同的安全检查，并会暂停自动化。", style: .secondary))
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
