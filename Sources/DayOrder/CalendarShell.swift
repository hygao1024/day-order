import AppKit
import SwiftUI

struct CalendarShell: NSViewRepresentable {
    let header: AnyView
    let content: AnyView
    let footer: AnyView
    let yearOverview: Bool
    let showingSettings: Bool
    let calendarHeight: CGFloat

    func makeNSView(context: Context) -> CalendarShellView { CalendarShellView() }

    func updateNSView(_ view: CalendarShellView, context: Context) {
        view.setPage(yearOverview: yearOverview, showingSettings: showingSettings)
        view.calendarHeight = calendarHeight
        view.header.rootView = AnyView(header.frame(width: 320).fixedSize(horizontal: false, vertical: true))
        view.content.rootView = content
        view.footer.rootView = AnyView(footer.frame(width: 320).fixedSize(horizontal: false, vertical: true))
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CalendarShellView, context: Context) -> CGSize? {
        nsView.naturalSize
    }
}

// 三个页面共用这些托管视图；只替换内容，动画不隐藏上下栏。
final class CalendarShellView: NSView {
    let header = NSHostingView(rootView: AnyView(EmptyView()))
    let content = NSHostingView(rootView: AnyView(EmptyView()))
    let footer = NSHostingView(rootView: AnyView(EmptyView()))
    private let headerClip = CalendarShellClipView()
    private let footerClip = CalendarShellClipView()
    private var yearOverview = false
    var calendarHeight = CalendarTimelineView.viewportHeight
    private var settingsHeight: CGFloat?
    var transitionCard: NSRect?
    var transitionHeight: CGFloat?
    @MainActor private struct Geometry {
        let top: CGFloat
        let bottom: CGFloat
        let size: NSSize
        var card: NSRect {
            NSRect(x: CalendarTimelineView.cardInset, y: top,
                   width: size.width - 2 * CalendarTimelineView.cardInset,
                   height: size.height - top - bottom)
        }
    }
    private var animationGeometry: Geometry?
    private let oldHeader = CalendarChromeSnapshotView()
    private let oldFooter = CalendarChromeSnapshotView()
    var chromeCoverage: CGFloat {
        min(header.alphaValue + oldHeader.alphaValue, footer.alphaValue + oldFooter.alphaValue)
    }
    #if DEBUG
    var layoutObserver: ((CalendarShellView) -> Void)?
    #endif
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        headerClip.addSubview(header)
        footerClip.addSubview(footer)
        headerClip.addSubview(oldHeader)
        footerClip.addSubview(oldFooter)
        oldHeader.alphaValue = 0
        oldFooter.alphaValue = 0
        addSubview(headerClip)
        addSubview(content)
        addSubview(footerClip)
        content.wantsLayer = true
        content.layer?.cornerRadius = CalendarTimelineView.cornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPage(yearOverview: Bool, showingSettings: Bool) {
        // 更新托管内容之前保留入口高度，避免设置自身的布局反向决定弹窗大小。
        if showingSettings, settingsHeight == nil { settingsHeight = transitionHeight ?? naturalSize.height }
        if !showingSettings { settingsHeight = nil }
        self.yearOverview = yearOverview
    }

    private func measureGeometry() -> Geometry {
        let top = header.fittingSize.height
        let bottom = footer.fittingSize.height
        return Geometry(top: top, bottom: bottom,
                        size: NSSize(width: 320, height: settingsHeight ?? (yearOverview ? 430
                                     : top + calendarHeight + bottom)))
    }

    var naturalSize: NSSize { (animationGeometry ?? measureGeometry()).size }
    override var intrinsicContentSize: NSSize { naturalSize }

    override func layout() {
        super.layout()
        let geometry = animationGeometry ?? measureGeometry()
        header.frame = NSRect(x: 0, y: 0, width: 320, height: geometry.top)
        content.frame = geometry.card
        footer.frame = NSRect(x: 0, y: 0, width: 320, height: geometry.bottom)
        positionChrome(card: transitionCard ?? geometry.card,
                       height: transitionHeight ?? geometry.size.height)
        #if DEBUG
        layoutObserver?(self)
        #endif
    }

    func beginAnimation() {
        // 终点布局已确定，短过渡内只移动外壳，不再测量隐藏的 SwiftUI 内容。
        animationGeometry = measureGeometry()
    }

    func prepareTransition(preservesChrome: Bool = false) {
        if preservesChrome {
            for (snapshot, live) in [(oldHeader, header), (oldFooter, footer)] {
                snapshot.image = nil
                snapshot.alphaValue = 0
                live.alphaValue = 1
            }
            animationGeometry = nil
            return
        }
        // 中途重定向取当前合成结果，避免文字退回上一个页面的初始透明度。
        let headerImage = CalendarSnapshotImage.capture(headerClip, in: headerClip.bounds)
        let footerImage = CalendarSnapshotImage.capture(footerClip, in: footerClip.bounds)
        for (snapshot, image, live, clip) in [(oldHeader, headerImage, header, headerClip),
                                             (oldFooter, footerImage, footer, footerClip)] {
            snapshot.image = image
            snapshot.frame = NSRect(origin: .zero, size: clip.bounds.size)
            snapshot.alphaValue = image == nil ? 0 : 1
            live.alphaValue = image == nil ? 1 : 0
        }
        animationGeometry = nil
    }

    func updateChrome(fraction: CGFloat) {
        for (snapshot, live) in [(oldHeader, header), (oldFooter, footer)] {
            snapshot.alphaValue = snapshot.image == nil ? 0 : 1 - fraction
            live.alphaValue = snapshot.image == nil ? 1 : fraction
        }
    }

    func updateTransition(card: NSRect, height: CGFloat) {
        transitionCard = card
        transitionHeight = height
        positionChrome(card: card, height: height)
    }

    private func positionChrome(card: NSRect, height: CGFloat) {
        headerClip.frame = NSRect(x: 0, y: 0, width: 320, height: card.minY)
        footerClip.frame = NSRect(x: 0, y: card.maxY, width: 320,
                                  height: max(0, height - card.maxY))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            content.layer?.backgroundColor = CalendarSurface.contentColor.cgColor
        }
    }

    func endTransition() {
        animationGeometry = nil
        transitionCard = nil
        transitionHeight = nil
        content.alphaValue = 1
        header.alphaValue = 1
        footer.alphaValue = 1
        oldHeader.image = nil
        oldFooter.image = nil
        oldHeader.alphaValue = 0
        oldFooter.alphaValue = 0
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

private final class CalendarChromeSnapshotView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

private final class CalendarShellClipView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
