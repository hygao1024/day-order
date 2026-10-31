import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyInstalls = false
    @Published private(set) var canCheck = false
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    private(set) var isAvailable = false
    private var updater: SPUUpdater?
    private var observations: Set<AnyCancellable> = []

    init(enabled: Bool = true, bundle: Bundle = .main) {
        super.init()
        guard enabled else {
            message = "界面验证中不连接更新服务。"
            return
        }
        #if arch(arm64)
        guard bundle.bundleURL.pathExtension == "app" else {
            message = "请从完整的 DayOrder.app 检查更新。"
            return
        }
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        self.updater = updater
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] value in
            self?.automaticallyChecks = value
        }.store(in: &observations)
        updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] value in
            self?.automaticallyInstalls = value
        }.store(in: &observations)
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
            self?.canCheck = value
        }.store(in: &observations)
        updater.publisher(for: \.sessionInProgress).sink { [weak self] value in
            self?.isBusy = value
        }.store(in: &observations)
        do {
            try updater.start()
            isAvailable = true
        } catch {
            message = "无法启动更新服务：\(error.localizedDescription)"
        }
        #else
        message = "自动更新仅支持 Apple 芯片的 Mac。"
        #endif
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        guard isAvailable, let updater else { return }
        if !enabled { updater.automaticallyDownloadsUpdates = false }
        updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyInstalls(_ enabled: Bool) {
        guard isAvailable, let updater, !enabled || automaticallyChecks else { return }
        updater.automaticallyDownloadsUpdates = enabled
    }

    func checkForUpdates() {
        guard isAvailable, canCheck, let updater else { return }
        message = nil
        updater.checkForUpdates()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        message = "发现新版本 \(item.displayVersionString)。"
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain, error.code == Int(SUError.noUpdateError.rawValue) {
            message = "未发现适用于此 Mac 的更新正式版本。"
        } else if error.domain == SUSparkleErrorDomain, error.code == Int(SUError.installationCanceledError.rawValue) {
            message = "已取消更新。"
        } else {
            message = "更新未完成：\(error.localizedDescription) 可稍后重试。"
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        self.updater(updater, didAbortWithError: error)
    }

    #if DEBUG
    // 使用真实 Sparkle 检查临时应用包的本地 feed，不展示模态窗口或触碰日常偏好。
    func checkForUpdateInformation() {
        updater?.checkForUpdateInformation()
    }
    #endif
}
