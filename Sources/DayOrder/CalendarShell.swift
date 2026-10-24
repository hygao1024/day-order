import AppKit
import SwiftUI

struct CalendarShell: NSViewRepresentable {
    let header: AnyView
    let content: AnyView
    let footer: AnyView
    let yearOverview: Bool

    func makeNSView(context: Context) -> CalendarShellView { CalendarShellView() }

    func updateNSView(_ view: CalendarShellView, context: Context) {
        view.header.rootView = AnyView(header.frame(width: 320).fixedSize(horizontal: false, vertical: true))
        view.content.rootView = content
        view.footer.rootView = AnyView(footer.frame(width: 320).fixedSize(horizontal: false, vertical: true))
        view.yearOverview = yearOverview
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CalendarShellView, context: Context) -> CGSize? {
        nsView.naturalSize
    }
}

// 这三个托管视图跨月／年切换保持身份；只替换内容，动画不隐藏上下栏。
final class CalendarShellView: NSView {
    let header = NSHostingView(rootView: AnyView(EmptyView()))
    let content = NSHostingView(rootView: AnyView(EmptyView()))
    let footer = NSHostingView(rootView: AnyView(EmptyView()))
    private let headerClip = CalendarShellClipView()
    private let footerClip = CalendarShellClipView()
    var yearOverview = false
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
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        headerClip.addSubview(header)
        footerClip.addSubview(footer)
        addSubview(headerClip)
        addSubview(content)
        addSubview(footerClip)
        content.wantsLayer = true
        content.layer?.cornerRadius = CalendarTimelineView.cornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func measureGeometry() -> Geometry {
        let top = header.fittingSize.height
        let bottom = footer.fittingSize.height
        return Geometry(top: top, bottom: bottom,
                        size: NSSize(width: 320, height: yearOverview ? 430
                                     : top + CalendarTimelineView.viewportHeight + bottom))
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
    }

    func beginAnimation() {
        // 终点布局已确定，短过渡内只移动外壳，不再测量隐藏的 SwiftUI 内容。
        animationGeometry = measureGeometry()
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
        invalidateIntrinsicContentSize()
        needsLayout = true
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
