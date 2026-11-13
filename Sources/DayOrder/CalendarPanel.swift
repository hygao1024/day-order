import AppKit
import QuartzCore

@MainActor
final class CalendarPanel: NSPanel {
    enum Behavior { case transient, applicationDefined }
    var behavior: Behavior = .transient
    var onShow: (() -> Void)?
    var onClose: (() -> Void)?
    // 开关意图与物理可见状态分开，淡出期间再次点击才能反向打开。
    private(set) var isShown = false
    var contentSize: NSSize { frame.size }
    private weak var anchor: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private struct Fade {
        let from: CGFloat
        let target: CGFloat
        let start: CFTimeInterval
        let duration: CFTimeInterval
    }
    private var fade: Fade?
    private var fadeDisplayLink: CADisplayLink?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    deinit {
        MainActor.assumeIsolated {
            fadeDisplayLink?.invalidate()
            removeDismissalObservers()
        }
    }

    func show(anchoredTo view: NSView) {
        #if DEBUG
        recordVisibility("show")
        #endif
        guard view.window?.screen != nil, let controller = contentViewController else { return }
        anchor = view
        controller.view.wantsLayer = true
        controller.view.layer?.cornerRadius = 14
        controller.view.layer?.masksToBounds = true
        resizeContent(to: controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        displayIfNeeded()
        guard !isShown else { return }
        let startsSession = !isVisible
        isShown = true
        ignoresMouseEvents = false
        if startsSession { alphaValue = 0 }
        makeKeyAndOrderFront(nil)
        installDismissalObservers()
        if startsSession { onShow?() }
        beginFade(to: 1)
    }

    func resizeContent(to size: NSSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              let anchor, let window = anchor.window, let screen = window.screen else { return }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        let x = min(max(rect.midX - size.width / 2, visible.minX), max(visible.minX, visible.maxX - size.width))
        let top = min(rect.minY - 6, visible.maxY)
        let y = max(visible.minY, top - size.height)
        // 调整尺寸时仅更新几何；同步绘制可能重入尚未稳定的约束。
        setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
    }

    override func performClose(_ sender: Any?) { close() }

    override func close() {
        #if DEBUG
        recordVisibility("close")
        #endif
        guard isShown else { return }
        isShown = false
        ignoresMouseEvents = true
        beginFade(to: 0)
    }

    // 显示环境失效或应用退出时不等待帧回调；页面清理只在真正隐藏后执行一次。
    func closeImmediately() {
        #if DEBUG
        recordVisibility("closeImmediately")
        #endif
        let hadSession = isVisible || isShown || fade != nil
        stopFade()
        isShown = false
        removeDismissalObservers()
        orderOut(nil)
        alphaValue = 0
        ignoresMouseEvents = false
        anchor = nil
        if hadSession { onClose?() }
    }

    private var reducesMotion: Bool {
        #if DEBUG
        if let fadeReduceMotionOverride { return fadeReduceMotionOverride }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func beginFade(to target: CGFloat) {
        stopFade()
        guard !reducesMotion, abs(alphaValue - target) > 0.0001, let contentView else {
            finishFade(at: target)
            return
        }
        fade = Fade(from: alphaValue, target: target, start: CACurrentMediaTime(),
                    duration: (target == 1 ? 0.14 : 0.09) * Double(abs(alphaValue - target)))
        #if DEBUG
        if controlsFadeClock { return }
        #endif
        let driver = CalendarDisplayLinkTarget { [weak self] link in
            guard let self, self.fadeDisplayLink === link else { link.invalidate(); return }
            guard self.isVisible else { self.closeImmediately(); return }
            #if DEBUG
            self.fadeFrameCount += 1
            #endif
            self.advanceFade(at: CACurrentMediaTime())
        }
        let link = contentView.displayLink(target: driver, selector: #selector(CalendarDisplayLinkTarget.tick(_:)))
        fadeDisplayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func advanceFade(at time: CFTimeInterval) {
        guard let fade else { return }
        let progress = min(1, max(0, (time - fade.start) / fade.duration))
        if reducesMotion || progress == 1 {
            finishFade(at: fade.target)
            return
        }
        let eased = 1 - pow(1 - progress, 3)
        alphaValue = fade.from + (fade.target - fade.from) * eased
    }

    private func finishFade(at target: CGFloat) {
        #if DEBUG
        recordVisibility("finish \(target)")
        #endif
        if target == 0 { closeImmediately() }
        else {
            stopFade()
            alphaValue = 1
        }
    }

    private func stopFade() {
        fadeDisplayLink?.invalidate()
        fadeDisplayLink = nil
        fade = nil
    }

    private func installDismissalObservers() {
        guard localMonitor == nil else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.behavior == .transient else { return }
                // 图标的 mouseUp 动作拥有开关；提前关闭会让同一次点击再次打开。
                if let anchor = self.anchor, let window = anchor.window, event.window == window,
                   anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return }
                var window = event.window
                while let current = window {
                    if current === self { return }
                    window = current.parent
                }
                // 原生菜单有自己的窗口与跟踪循环，选择设置项不应关闭日历。
                if let window = event.window, window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue { return }
                self.close()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissIfTransient() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(dismissIfTransient),
            name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(reposition),
            name: NSWindow.didMoveNotification, object: anchor?.window)
        NotificationCenter.default.addObserver(self, selector: #selector(reposition),
            name: NSWindow.didResizeNotification, object: anchor?.window)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc private func dismissIfTransient() {
        if behavior == .transient { close() }
    }

    @objc private func reposition() {
        if isVisible { resizeContent(to: contentSize) }
    }

    @objc private func screenChanged(_ notification: Notification) {
        #if DEBUG
        recordVisibility(notification.name.rawValue)
        #endif
        closeImmediately()
    }

    private func removeDismissalObservers() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    #if DEBUG
    private(set) var visibilityTrace: [String] = []
    private func recordVisibility(_ event: String) {
        if visibilityTrace.count >= 128 { visibilityTrace.removeFirst() }
        visibilityTrace.append("\(event): shown=\(isShown), visible=\(isVisible), alpha=\(alphaValue), controlled=\(controlsFadeClock)")
    }
    var controlsFadeClock = false
    var fadeReduceMotionOverride: Bool?
    private(set) var fadeFrameCount = 0
    var hasFadeDriver: Bool { fadeDisplayLink != nil }
    var isFading: Bool { fade != nil }
    func sampleFade(elapsed: CFTimeInterval) {
        guard controlsFadeClock, let fade else { return }
        advanceFade(at: fade.start + elapsed)
    }
    var hasDismissalMonitors: Bool { localMonitor != nil || globalMonitor != nil }
    #endif
}
