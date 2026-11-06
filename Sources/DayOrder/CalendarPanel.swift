import AppKit

@MainActor
final class CalendarPanel: NSPanel {
    enum Behavior { case transient, applicationDefined }
    var behavior: Behavior = .transient
    var onShow: (() -> Void)?
    var onClose: (() -> Void)?
    var isShown: Bool { isVisible }
    var contentSize: NSSize { frame.size }
    private weak var anchor: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    func show(anchoredTo view: NSView) {
        guard view.window?.screen != nil, let controller = contentViewController else { return }
        anchor = view
        controller.view.wantsLayer = true
        controller.view.layer?.cornerRadius = 14
        controller.view.layer?.masksToBounds = true
        resizeContent(to: controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        displayIfNeeded()
        guard !isVisible else { return }
        makeKeyAndOrderFront(nil)
        installDismissalObservers()
        onShow?()
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
        let wasVisible = isVisible
        removeDismissalObservers()
        orderOut(nil)
        anchor = nil
        if wasVisible { onClose?() }
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
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc private func dismissIfTransient() {
        if behavior == .transient { close() }
    }

    @objc private func reposition() {
        if isVisible { resizeContent(to: contentSize) }
    }

    @objc private func screenChanged() { close() }

    private func removeDismissalObservers() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    #if DEBUG
    var hasDismissalMonitors: Bool { localMonitor != nil || globalMonitor != nil }
    #endif
}
