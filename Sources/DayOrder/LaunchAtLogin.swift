import ServiceManagement
import SwiftUI

@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var errorMessage: String?
    private let isAppBundle: Bool
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private let openSettings: () -> Void

    convenience init() {
        self.init(isAppBundle: Bundle.main.bundleURL.pathExtension == "app",
                  readStatus: { SMAppService.mainApp.status },
                  register: { try SMAppService.mainApp.register() },
                  unregister: { try SMAppService.mainApp.unregister() },
                  openSettings: { SMAppService.openSystemSettingsLoginItems() })
    }

    init(isAppBundle: Bool, readStatus: @escaping () -> SMAppService.Status,
         register: @escaping () throws -> Void, unregister: @escaping () throws -> Void,
         openSettings: @escaping () -> Void) {
        self.isAppBundle = isAppBundle
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        self.openSettings = openSettings
        refresh()
    }

    // 待批准仍表示已登记，开关允许用户撤销；是否生效由旁边的说明区分。
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var canChange: Bool { isAppBundle }

    var explanation: String {
        if !isAppBundle { return "请从构建后的 DayOrder.app 打开日序，再设置开机自启。" }
        switch status {
        case .notRegistered: return "开启后，登录 Mac 时自动启动日序。"
        case .enabled: return "登录 Mac 时自动启动日序。"
        case .requiresApproval: return "已登记，等待系统允许，尚未生效。请在系统登录项设置中允许日序。"
        case .notFound: return "系统未找到此应用的登录项服务，可尝试开启以重新登记。"
        @unknown default: return "无法识别系统登录项状态，请在系统设置中检查。"
        }
    }

    func refresh() {
        let latest = readStatus()
        if latest != status { errorMessage = nil }
        status = latest
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        guard canChange, enabled != isOn else { return }
        do {
            if enabled { try register() }
            else { try unregister() }
        } catch {
            refresh()
            errorMessage = "无法\(enabled ? "开启" : "关闭")开机自启：\(error.localizedDescription)"
            return
        }
        refresh()
    }

    func openSystemSettings() {
        openSettings()
    }
}

#if DEBUG
// 冒烟只替换系统服务边界，沿用生产控制器与真实设置控件，避免写入用户登录项。
@MainActor
final class SmokeLoginService {
    var status: SMAppService.Status = .notRegistered
    var registrationStatus: SMAppService.Status = .enabled
    var registrationFailureStatus: SMAppService.Status?
    var operationError: Error?
    var mutationCount = 0
    var settingsOpenCount = 0

    func makeController(isAppBundle: Bool = true) -> LaunchAtLogin {
        LaunchAtLogin(isAppBundle: isAppBundle, readStatus: { self.status }, register: {
            self.mutationCount += 1
            if let error = self.operationError {
                if let status = self.registrationFailureStatus { self.status = status }
                throw error
            }
            self.status = self.registrationStatus
        }, unregister: {
            self.mutationCount += 1
            if let error = self.operationError { throw error }
            self.status = .notRegistered
        }, openSettings: { self.settingsOpenCount += 1 })
    }
}
#endif
