import Foundation
import UserNotifications

protocol SevereNotificationDelivering: AnyObject {
    func requestAuthorization()
    func deliver(identifier: String, title: String, body: String)
}

final class SystemSevereNotificationDelivery: SevereNotificationDelivering {
    private let center: UNUserNotificationCenter
    private let log: (String) -> Void

    init(
        center: UNUserNotificationCenter = .current(),
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.center = center
        self.log = log
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                self.log("[NOTIFICATION] authorization failed: \(error.localizedDescription)")
            } else {
                self.log("[NOTIFICATION] authorization granted=\(granted)")
            }
        }
    }

    func deliver(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error {
                self.log("[NOTIFICATION] delivery failed: \(error.localizedDescription)")
            }
        }
    }
}

final class SevereNotificationPresenter {
    private let delivery: SevereNotificationDelivering
    private var activeKeys = Set<String>()

    init(delivery: SevereNotificationDelivering = SystemSevereNotificationDelivery()) {
        self.delivery = delivery
    }

    func requestAuthorization() { delivery.requestAuthorization() }

    func present(status: AutomationRuntimeStatus) {
        var notices: [String: (title: String, body: String)] = [:]
        for diagnostic in status.diagnostics {
            switch diagnostic.code {
            case .cycleRulesDisabled:
                notices["cycle:\(diagnostic.message)"] = (
                    "自动规则已隔离",
                    "检测到规则循环。相关规则已在本轮停止执行，请打开“自动规则”检查预览。"
                )
            case .configurationUnavailable:
                notices["configuration:\(diagnostic.message)"] = (
                    "配置持续失败",
                    "配置无法可靠读取或保存，自动化已停用。请打开 Display Steward 查看诊断。"
                )
            case .safetyRecovery:
                notices["safety-recovery:\(diagnostic.message)"] = (
                    "显示器安全恢复需要处理",
                    "显示器事务提交后未观察到活动屏幕。自动化已暂停，请立即检查屏幕状态并尝试手动恢复。"
                )
            default:
                break
            }
        }
        for block in status.lastEvaluation.safetyBlocks where block.reason == .retainedLastActiveDisplay {
            let runtimeID = block.display?.runtimeID ?? 0
            notices["last-active:\(runtimeID)"] = (
                "已阻止关闭最后一台活动显示器",
                "为避免黑屏，本轮规则没有执行该关闭操作。"
            )
        }
        deliverNew(notices)
    }

    func presentManualLastActiveSafetyBlock() {
        let key = "manual-last-active"
        guard !activeKeys.contains(key) else { return }
        activeKeys.insert(key)
        delivery.deliver(
            identifier: notificationIdentifier(key),
            title: "已阻止危险的显示器操作",
            body: "为避免黑屏，不能关闭最后一台活动且可绘制的显示器。"
        )
    }

    private func deliverNew(_ notices: [String: (title: String, body: String)]) {
        let currentKeys = Set(notices.keys)
        for key in currentKeys.subtracting(activeKeys) {
            guard let notice = notices[key] else { continue }
            delivery.deliver(
                identifier: notificationIdentifier(key),
                title: notice.title,
                body: notice.body
            )
        }
        activeKeys = currentKeys
    }

    private func notificationIdentifier(_ key: String) -> String {
        let bytes = key.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return "com.anhoder.display-steward.severe.\(String(bytes, radix: 16))"
    }
}
