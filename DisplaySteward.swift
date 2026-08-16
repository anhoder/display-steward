import AppKit
import CoreGraphics
import Darwin
import Foundation
import Carbon.HIToolbox
private let logLock = NSLock()

fileprivate func writeLog(_ message: String) {
    let formatter = ISO8601DateFormatter()
    let line = "\(formatter.string(from: Date())) \(message)\n"
    let data = Data(line.utf8)
    logLock.lock()
    defer { logLock.unlock() }
    let logPath = "\(NSHomeDirectory())/Library/Logs/com.anhoder.display-steward.log"
    if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(atPath: logPath, contents: nil)
    }
    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}


private let defaultHotKey = KeyShortcut(
    keyCode: HotKeyConfiguration.default.keyCode,
    modifiers: HotKeyConfiguration.default.modifiers
)

/// Reliable CoreGraphics-level display-change signal. The AppKit
/// didChangeScreenParametersNotification is not posted for every topology
/// change (empirically missed external-display unplugs while the built-in was
/// closed), so the coordinator must also hear reconfiguration callbacks.
/// CGDisplayRegisterReconfigurationCallback is public API but absent from the
/// Swift CoreGraphics overlay, so it is resolved dynamically like the
/// adapter's private SPI.
private typealias DisplayReconfigurationCallback = @convention(c) (
    CGDirectDisplayID,
    UInt32,
    UnsafeMutableRawPointer?
) -> Void
private typealias RegisterDisplayReconfigurationFunction = @convention(c) (
    DisplayReconfigurationCallback?,
    UnsafeMutableRawPointer?
) -> Int32
private typealias RemoveDisplayReconfigurationFunction = @convention(c) (
    DisplayReconfigurationCallback?,
    UnsafeMutableRawPointer?
) -> Int32

private struct DisplayReconfigurationBridge {
    let register: RegisterDisplayReconfigurationFunction
    let remove: RemoveDisplayReconfigurationFunction
}

private func loadDisplayReconfigurationBridge() -> DisplayReconfigurationBridge? {
    guard let framework = dlopen(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        RTLD_LAZY
    ), let registerSymbol = dlsym(framework, "CGDisplayRegisterReconfigurationCallback"),
       let removeSymbol = dlsym(framework, "CGDisplayRemoveReconfigurationCallback") else {
        return nil
    }
    return DisplayReconfigurationBridge(
        register: unsafeBitCast(registerSymbol, to: RegisterDisplayReconfigurationFunction.self),
        remove: unsafeBitCast(removeSymbol, to: RemoveDisplayReconfigurationFunction.self)
    )
}

private let displayReconfigurationBridge = loadDisplayReconfigurationBridge()
/// kCGDisplayBeginConfigurationFlag == (1 << 0); the Swift overlay does not
/// expose the summary-flags constants.
private let displayReconfigurationBeginFlag: UInt32 = 1 << 0

private let displayReconfigurationCallback: DisplayReconfigurationCallback = { _, flags, userInfo in
    guard flags & displayReconfigurationBeginFlag == 0,
          let userInfo else { return }
    Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue().handleDisplayReconfiguration()
}

private enum DisplayStewardError: LocalizedError {
    case builtinDisplayNotFound
    case hotKeyReconciliationFailed(String)

    var errorDescription: String? {
        switch self {
        case .builtinDisplayNotFound:
            return "找不到内置显示器"
        case .hotKeyReconciliationFailed(let explanation):
            return explanation
        }
    }
}

private struct DisplaySnapshot {
    let builtinEnabled: Bool
}



final class DisplayController: DisplayManagingRuntime {
    private let coordinator: AutomationCoordinator

    init() throws {
        let adapter = try CoreGraphicsDisplayAdapter()
        coordinator = try AutomationCoordinator(adapter: adapter, log: writeLog)
    }

    var status: AutomationRuntimeStatus { coordinator.status }
    var configuration: AppConfiguration { coordinator.status.configuration }
    var onStatusChange: (() -> Void)? {
        get { coordinator.onStatusChange }
        set { coordinator.onStatusChange = newValue }
    }

    func start() { coordinator.start() }
    func stop() { coordinator.stop() }
    func handleDisplayEvent() { coordinator.handleDisplayEvent() }
    func handleWake() { coordinator.handleWake() }
    func previewConfigurationReadOnly(
        _ configuration: AppConfiguration,
        observation: ObservedDisplaySnapshot?
    ) throws -> ConfigurationPreview {
        try coordinator.previewConfigurationReadOnly(configuration, observation: observation)
    }
    func previewProfileActivation(
        id: UUID,
        observation: ObservedDisplaySnapshot?
    ) throws -> ProfileActivationPreview {
        try coordinator.previewProfileActivation(id: id, observation: observation)
    }

    @discardableResult
    func activateProfile(id: UUID) throws -> ProfileActivationResult {
        try coordinator.activateProfile(id: id)
    }
    @discardableResult
    func activateProfile(
        id: UUID,
        confirmedPreview: ProfileActivationPreview
    ) throws -> ProfileActivationResult {
        try coordinator.activateProfile(id: id, confirmedPreview: confirmedPreview)
    }


    @discardableResult
    func createBlankProfile(named name: String) throws -> DisplayProfile {
        try coordinator.createBlankProfile(named: name)
    }

    @discardableResult
    func duplicateProfile(id: UUID, named name: String) throws -> DisplayProfile {
        try coordinator.duplicateProfile(id: id, named: name)
    }

    @discardableResult
    func renameProfile(id: UUID, to name: String) throws -> DisplayProfile {
        try coordinator.renameProfile(id: id, to: name)
    }

    func deleteInactiveProfile(id: UUID) throws {
        try coordinator.deleteInactiveProfile(id: id)
    }

    @discardableResult
    func saveProfile(_ profile: DisplayProfile, applyImmediately: Bool) throws -> AutomationRuntimeStatus {
        try coordinator.saveProfile(profile, applyImmediately: applyImmediately)
    }
    @discardableResult
    func restoreProfileFromLastKnownGood(id: UUID) throws -> DisplayProfile {
        try coordinator.restoreProfileFromLastKnownGood(id: id)
    }

    @discardableResult
    func removeInvalidProfile(fileName: String) throws -> AutomationRuntimeStatus {
        try coordinator.removeInvalidProfile(fileName: fileName)
    }


    @discardableResult
    func reloadProfileCatalog() -> AutomationRuntimeStatus {
        coordinator.reloadProfileCatalog()
    }

    @discardableResult
    func updateConfiguration(_ configuration: AppConfiguration, applyImmediately: Bool) throws -> AutomationRuntimeStatus {
        try coordinator.updateConfiguration(configuration, applyImmediately: applyImmediately)
    }

    @discardableResult
    func performManualAction(runtimeID: UInt32, action: DisplayAction) throws -> AutomationRuntimeStatus {
        try coordinator.performManualAction(runtimeID: runtimeID, action: action)
    }

    @discardableResult
    func performManualAction(
        runtimeID: UInt32,
        action: DisplayAction,
        expectedTarget: DisplayTarget
    ) throws -> AutomationRuntimeStatus {
        try coordinator.performManualAction(
            runtimeID: runtimeID,
            action: action,
            expectedTarget: expectedTarget
        )
    }

    func prepareDisplayRecovery(only targets: [DisplayRecoveryTarget]?) throws -> DisplayRecoveryPlan {
        try coordinator.prepareDisplayRecovery(only: targets)
    }

    @discardableResult
    func restoreDisplays(_ plan: DisplayRecoveryPlan) -> DisplayRecoveryBatchResult {
        coordinator.restoreDisplays(plan)
    }

    func pause() { coordinator.pause() }
    func resume() { coordinator.resume() }

    @discardableResult
    func refresh() throws -> AutomationRuntimeStatus { try coordinator.refresh() }

    fileprivate func snapshot() throws -> DisplaySnapshot {
        DisplaySnapshot(builtinEnabled: coordinator.status.inventory.displays.contains {
            $0.isBuiltIn && $0.state.isOnline
        })
    }

    @discardableResult
    fileprivate func disableBuiltin() throws -> DisplaySnapshot {
        let inventory = try coordinator.refresh().inventory
        guard let runtimeID = inventory.displays.first(where: {
            $0.isBuiltIn && $0.state.isOnline
        })?.runtimeID else {
            return try snapshot()
        }
        _ = try coordinator.performManualAction(runtimeID: runtimeID, action: .disable)
        return try snapshot()
    }

    @discardableResult
    fileprivate func enableBuiltin() throws -> DisplaySnapshot {
        let inventory = try coordinator.refresh().inventory
        if inventory.displays.contains(where: { $0.isBuiltIn && $0.state.isOnline }) {
            return try snapshot()
        }
        guard let runtimeID = inventory.displays.first(where: {
            $0.isBuiltIn && $0.state == .disabledByThisAppConnectionUnknown
        })?.runtimeID else {
            throw DisplayStewardError.builtinDisplayNotFound
        }
        _ = try coordinator.performManualAction(runtimeID: runtimeID, action: .enable)
        return try snapshot()
    }
}


private final class ManualDisplayMenuCommand: NSObject {
    let rowID: String
    let expectedTarget: DisplayTarget
    let action: DisplayAction

    init(rowID: String, expectedTarget: DisplayTarget, action: DisplayAction) {
        self.rowID = rowID
        self.expectedTarget = expectedTarget
        self.action = action
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DisplayController!
    private var settingsWindowController: SettingsWindowController!
    private var statusItem: NSStatusItem!
    private var observer: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var activeHotKey: KeyShortcut?
    private var isReconcilingHotKey = false
    private lazy var severeNotifications = SevereNotificationPresenter(
        delivery: SystemSevereNotificationDelivery(log: writeLog)
    )

    private var configuredHotKey: KeyShortcut {
        let hotKey = controller?.configuration.hotKey ?? .default
        return KeyShortcut(keyCode: hotKey.keyCode, modifiers: hotKey.modifiers)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            controller = try DisplayController()
        } catch {
            showFatalError(error)
            return
        }

        settingsWindowController = SettingsWindowController(
            runtime: controller,
            shortcutProvider: { [weak self] in self?.configuredHotKey ?? defaultHotKey },
            shortcutSetter: { [weak self] shortcut in self?.setShortcut(shortcut) ?? false },
            shortcutResetter: { [weak self] in self?.resetShortcut() ?? false },
            onLastActiveSafetyBlock: { [weak self] in
                self?.severeNotifications.presentManualLastActiveSafetyBlock()
            }
        )
        setupStatusItem()
        registerGlobalHotKey()
        severeNotifications.requestAuthorization()
        controller.onStatusChange = { [weak self] in
            guard let self else { return }
            self.reconcileGlobalHotKeyIfNeeded()
            self.settingsWindowController?.refresh()
            self.updateMenu()
            self.severeNotifications.present(status: self.controller.status)
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            writeLog("[AUTO] screen parameters changed")
            self?.controller.handleDisplayEvent()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            writeLog("[AUTO] system wake received")
            self?.controller.handleWake()
        }
        if let bridge = displayReconfigurationBridge {
            let reconfigurationStatus = bridge.register(
                displayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
            if reconfigurationStatus != 0 {
                writeLog("[AUTO] display reconfiguration callback registration failed: \(reconfigurationStatus)")
            }
        } else {
            writeLog("[AUTO] display reconfiguration callback unavailable; relying on screen notifications and the safety guard")
        }
        controller.start()
        severeNotifications.present(status: controller.status)
        writeLog("[AUTO] application started; automatic=\(controller.configuration.automatic.isEnabled)")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let allowed = settingsWindowController?.prepareForExternalProfileActivation() ?? true
        switch ApplicationTerminationPolicy.decision(dirtyDraftGuardAllowsTermination: allowed) {
        case .terminateNow: return .terminateNow
        case .cancel: return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        if let bridge = displayReconfigurationBridge {
            _ = bridge.remove(
                displayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        unregisterGlobalHotKey()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    fileprivate func handleDisplayReconfiguration() {
        writeLog("[AUTO] display reconfiguration callback")
        controller.handleDisplayEvent()
    }

    private func setAutomatic(_ enabled: Bool) {
        var configuration = controller.configuration
        configuration.automatic.isEnabled = enabled
        do {
            _ = try controller.updateConfiguration(configuration, applyImmediately: true)
        } catch {
            showError(error)
        }
    }

    private func registerGlobalHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyEventHandler,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            writeLog("[HOTKEY] event handler registration failed: \(installStatus)")
            return
        }

        let shortcut = configuredHotKey
        let registerStatus = registerHotKey(shortcut)
        guard registerStatus == noErr else {
            writeLog("[HOTKEY] registration failed for \(shortcut.displayName): \(registerStatus)")
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            self.eventHandlerRef = nil
            return
        }
        activeHotKey = shortcut
        writeLog("[HOTKEY] registered \(shortcut.displayName)")
    }

    private func registerHotKey(_ shortcut: KeyShortcut) -> OSStatus {
        let hotKeyID = EventHotKeyID(signature: OSType(0x534D4447), id: 1)
        return RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func setShortcut(_ shortcut: KeyShortcut) -> Bool {
        let previous = activeHotKey
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        let status = registerHotKey(shortcut)
        guard status == noErr else {
            writeLog("[HOTKEY] registration failed for \(shortcut.displayName): \(status)")
            self.hotKeyRef = nil
            restoreHotKey(previous)
            return false
        }
        activeHotKey = shortcut

        var configuration = controller.configuration
        configuration.hotKey = HotKeyConfiguration(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers
        )
        do {
            _ = try controller.updateConfiguration(configuration, applyImmediately: false)
        } catch {
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
                self.hotKeyRef = nil
            }
            restoreHotKey(previous)
            writeLog("[HOTKEY] JSON save failed: \(error.localizedDescription)")
            return false
        }

        writeLog("[HOTKEY] shortcut changed to \(shortcut.displayName)")
        updateMenu()
        return true
    }

    private func restoreHotKey(_ shortcut: KeyShortcut?) {
        guard let shortcut else {
            activeHotKey = nil
            return
        }
        let status = registerHotKey(shortcut)
        activeHotKey = status == noErr ? shortcut : nil
        writeLog("[HOTKEY] previous shortcut restore status=\(status)")
    }

    private func reconcileGlobalHotKeyIfNeeded() {
        guard !isReconcilingHotKey, controller != nil else { return }
        let registered = activeHotKey.map {
            HotKeyConfiguration(keyCode: $0.keyCode, modifiers: $0.modifiers)
        }
        let plan = GlobalHotKeyReconciliationPolicy.plan(
            registered: registered,
            configured: controller.configuration.hotKey
        )
        guard plan.requiresRegistration else { return }

        isReconcilingHotKey = true
        defer { isReconcilingHotKey = false }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        let desired = KeyShortcut(keyCode: plan.desired.keyCode, modifiers: plan.desired.modifiers)
        let registerStatus = registerHotKey(desired)
        if registerStatus == noErr {
            activeHotKey = desired
            writeLog("[HOTKEY] reconciled registration to \(desired.displayName)")
            return
        }

        self.hotKeyRef = nil
        activeHotKey = nil
        var registrationWasRestored = false
        if let previous = plan.previous {
            let previousShortcut = KeyShortcut(keyCode: previous.keyCode, modifiers: previous.modifiers)
            let restoreStatus = registerHotKey(previousShortcut)
            registrationWasRestored = restoreStatus == noErr
            activeHotKey = registrationWasRestored ? previousShortcut : nil
            writeLog("[HOTKEY] reconciliation restore status=\(restoreStatus)")
        }

        let rollback = plan.persistedConfiguration(afterRegistrationSucceeded: false)
        var persistenceWasRestored = controller.configuration.hotKey == rollback
        if !persistenceWasRestored {
            var configuration = controller.configuration
            configuration.hotKey = rollback
            do {
                _ = try controller.updateConfiguration(configuration, applyImmediately: false)
                persistenceWasRestored = true
            } catch {
                writeLog("[HOTKEY] reconciliation persistence rollback failed: \(error.localizedDescription)")
            }
        }

        let restoration = registrationWasRestored && persistenceWasRestored
            ? "已恢复之前的快捷键注册与持久化设置。"
            : "无法完整恢复之前的快捷键；请在设置中重新选择快捷键。"
        let message = "无法注册快捷键 \(desired.displayName)（状态 \(registerStatus)）。\(restoration)"
        writeLog("[HOTKEY] \(message)")
        showError(DisplayStewardError.hotKeyReconciliationFailed(message))
    }

    private func resetShortcut() -> Bool { setShortcut(defaultHotKey) }

    private func unregisterGlobalHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        activeHotKey = nil
    }

    fileprivate func toggleBuiltinFromHotKey() {
        do {
            let current = try controller.snapshot()
            if current.builtinEnabled {
                _ = try controller.disableBuiltin()
                writeLog("[HOTKEY] builtin display disabled; automation paused")
            } else {
                _ = try controller.enableBuiltin()
                writeLog("[HOTKEY] builtin display enabled; automation paused")
            }
        } catch {
            writeLog("[HOTKEY] operation failed: \(error.localizedDescription)")
            if let coordinatorError = error as? AutomationCoordinatorError,
               case .lastActiveDisplay = coordinatorError {
                severeNotifications.presentManualLastActiveSafetyBlock()
            }
            showError(error)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: displayStewardAppName)
            button.toolTip = displayStewardAppName
        }
        updateMenu()
    }

    private func updateMenu() {
        guard statusItem != nil, controller != nil else { return }
        let status = controller.status
        let presentation = PresentationText.menu(status: status)
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "打开设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let profilesItem = NSMenuItem(title: "配置档", action: nil, keyEquivalent: "")
        let profilesMenu = NSMenu(title: "配置档")
        let profileEntries = PresentationText.profileMenuEntries(status: status)
        if profileEntries.isEmpty {
            let empty = NSMenuItem(title: "没有可用配置档", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            profilesMenu.addItem(empty)
        } else {
            for entry in profileEntries {
                let item = NSMenuItem(
                    title: entry.title,
                    action: #selector(activateProfileFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.state = entry.isActive ? .on : .off
                item.representedObject = entry.id
                profilesMenu.addItem(item)
            }
        }
        if !status.profileCatalog.invalidProfiles.isEmpty {
            profilesMenu.addItem(.separator())
            let invalid = NSMenuItem(title: "部分配置档无效", action: nil, keyEquivalent: "")
            invalid.isEnabled = false
            profilesMenu.addItem(invalid)
            let manage = NSMenuItem(title: "在设置中管理…", action: #selector(openSettings), keyEquivalent: "")
            manage.target = self
            profilesMenu.addItem(manage)
        }
        profilesItem.submenu = profilesMenu
        menu.addItem(profilesItem)
        menu.addItem(.separator())

        let summaryItem = NSMenuItem(title: PresentationText.settingsSummary(status: status).onlineActiveSummary, action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        let restoreAllItem = NSMenuItem(title: PresentationText.restoreAllTitle, action: #selector(restoreAllDisplays), keyEquivalent: "")
        restoreAllItem.target = self
        restoreAllItem.isEnabled = presentation.restoreAllEnabled
        menu.addItem(restoreAllItem)
        if !presentation.restoreAllEnabled {
            let recoveryExplanation = NSMenuItem(title: presentation.restoreAllExplanation, action: nil, keyEquivalent: "")
            recoveryExplanation.isEnabled = false
            menu.addItem(recoveryExplanation)
        }
        let automaticItem = NSMenuItem(title: "启用自动化", action: #selector(toggleAutomatic), keyEquivalent: "")
        automaticItem.target = self
        automaticItem.state = presentation.automaticEnabled ? .on : .off
        menu.addItem(automaticItem)
        let pauseItem = NSMenuItem(title: presentation.pauseTitle, action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.isEnabled = presentation.pauseEnabled
        menu.addItem(pauseItem)
        let evaluationItem = NSMenuItem(title: "最近评估：\(presentation.lastEvaluationSummary)", action: nil, keyEquivalent: "")
        evaluationItem.isEnabled = false
        menu.addItem(evaluationItem)
        menu.addItem(.separator())

        let displaysItem = NSMenuItem(title: "显示器", action: nil, keyEquivalent: "")
        let displaysMenu = NSMenu(title: "显示器")
        if presentation.displays.isEmpty {
            let empty = NSMenuItem(title: "当前没有显示器记录", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            displaysMenu.addItem(empty)
        } else {
            for row in presentation.displays {
                let item = NSMenuItem(title: "\(row.title) — \(row.stateSummary)", action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: row.title)
                let state = NSMenuItem(title: row.rowDetail, action: nil, keyEquivalent: "")
                state.isEnabled = false
                submenu.addItem(state)
                if let secondaryName = row.secondaryName {
                    let systemName = NSMenuItem(title: "系统名称：\(secondaryName)", action: nil, keyEquivalent: "")
                    systemName.isEnabled = false
                    submenu.addItem(systemName)
                }
                if row.runtimeID != nil, let expectedTarget = row.target, let action = row.manualAction {
                    submenu.addItem(.separator())
                    let actionItem = NSMenuItem(
                        title: row.manualActionTitle ?? (action == .enable ? "手动开启" : "手动关闭…"),
                        action: #selector(performDisplayMenuAction(_:)),
                        keyEquivalent: ""
                    )
                    actionItem.target = self
                    actionItem.representedObject = ManualDisplayMenuCommand(
                        rowID: row.id,
                        expectedTarget: expectedTarget,
                        action: action
                    )
                    submenu.addItem(actionItem)
                }
                item.submenu = submenu
                displaysMenu.addItem(item)
            }
        }
        displaysItem.submenu = displaysMenu
        menu.addItem(displaysItem)
        let hotKeyItem = NSMenuItem(title: "快捷键：\(configuredHotKey.displayName)（切换内置显示器）", action: nil, keyEquivalent: "")
        hotKeyItem.isEnabled = false
        menu.addItem(hotKeyItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func openSettings() { settingsWindowController.show() }
    @objc private func activateProfileFromMenu(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? UUID else { return }
        guard settingsWindowController.prepareForExternalProfileActivation() else { return }

        do {
            let preview = try controller.previewProfileActivation(id: profileID, observation: nil)
            let confirmation = PresentationText.profileActivationConfirmation(preview)
            if confirmation.requiresConfirmation {
                let alert = NSAlert()
                alert.alertStyle = confirmation.isCritical ? .critical : .warning
                alert.messageText = confirmation.title
                alert.informativeText = confirmation.explanation
                alert.addButton(withTitle: confirmation.confirmTitle)
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }

            let result = try controller.activateProfile(id: profileID, confirmedPreview: preview)
            settingsWindowController.refresh()
            updateMenu()
            presentProfileActivationResultIfNeeded(result)
        } catch {
            showError(error)
        }
    }

    private func presentProfileActivationResultIfNeeded(_ result: ProfileActivationResult) {
        let title: String
        let style: NSAlert.Style
        switch result.hardwareOutcome {
        case .partiallyFailed:
            title = "配置档已激活，但部分显示器操作失败"
            style = .warning
        case .failed:
            title = "配置档已激活，但显示器操作失败"
            style = .warning
        case .blockedBySafety:
            title = "配置档已激活，但显示器操作被安全策略阻止"
            style = .critical
        case .notNeeded, .applied:
            return
        }

        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = PresentationText.profileActivationResult(result)
        alert.runModal()
    }
    @objc private func toggleAutomatic() {
        guard settingsWindowController.prepareForExternalProfileActivation() else { return }
        setAutomatic(!controller.configuration.automatic.isEnabled)
    }
    @objc private func togglePause() { controller.status.isPaused ? controller.resume() : controller.pause() }
    @objc private func restoreAllDisplays() {
        runDisplayRecoveryFlow(runtime: controller, in: nil)
        updateMenu()
    }

    @objc private func performDisplayMenuAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? ManualDisplayMenuCommand else { return }
        do {
            let refreshed = try controller.refresh()
            let row = try PresentationText.resolveManualDisplayCommand(
                status: refreshed,
                rowID: command.rowID,
                expectedTarget: command.expectedTarget,
                expectedAction: command.action
            )
            guard let runtimeID = row.runtimeID else { throw PresentationError.staleManualDisplayCommand }
            if command.action == .disable {
                let confirmation = PresentationText.manualDisableConfirmation(
                    displayName: row.title,
                    isMain: row.isMain
                )
                let alert = NSAlert()
                alert.alertStyle = confirmation.isCritical ? .critical : .warning
                alert.messageText = confirmation.title
                alert.informativeText = confirmation.explanation
                alert.addButton(withTitle: confirmation.confirmTitle)
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            _ = try controller.performManualAction(
                runtimeID: runtimeID,
                action: command.action,
                expectedTarget: command.expectedTarget
            )
        } catch {
            if let coordinatorError = error as? AutomationCoordinatorError,
               case .lastActiveDisplay = coordinatorError {
                severeNotifications.presentManualLastActiveSafetyBlock()
            }
            showError(error)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Display Steward 操作失败"
        alert.informativeText = PresentationText.error(error)
        alert.runModal()
    }

    private func showFatalError(_ error: Error) {
        showError(error)
        NSApp.terminate(nil)
    }
}

private func globalHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    delegate.toggleBuiltinFromHotKey()
    return noErr
}

private final class SingleInstanceLock {
    private let descriptor: Int32

    init?() {
        let directory = "\(NSHomeDirectory())/Library/Application Support/Display Steward"
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }

        let path = "\(directory)/instance.lock"
        let fileDescriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard fileDescriptor >= 0 else { return nil }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(fileDescriptor)
            return nil
        }
        descriptor = fileDescriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}


private let instanceLock = SingleInstanceLock()
if instanceLock == nil { exit(0) }
private let entryDecision = ApplicationEntryPolicy.decision(arguments: CommandLine.arguments)
private let application: NSApplication = {
    switch entryDecision.mode {
    case .menuBarApplication:
        return NSApplication.shared
    }
}()
private let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
