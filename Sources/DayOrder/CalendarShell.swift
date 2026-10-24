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

    var naturalSize: NSSize {
        NSSize(width: 320, height: yearOverview ? 430
               : header.fittingSize.height + CalendarTimelineView.viewportHeight + footer.fittingSize.height)
    }

    override var intrinsicContentSize: NSSize { naturalSize }

    override func layout() {
        super.layout()
        let top = header.fittingSize.height
        let bottom = footer.fittingSize.height
        let size = naturalSize
        let card = NSRect(x: CalendarTimelineView.cardInset, y: top,
                          width: 320 - 2 * CalendarTimelineView.cardInset,
                          height: size.height - top - bottom)
        let visibleCard = transitionCard ?? card
        headerClip.frame = NSRect(x: 0, y: 0, width: 320, height: visibleCard.minY)
        header.frame = NSRect(x: 0, y: 0, width: 320, height: top)
        content.frame = card
        footerClip.frame = NSRect(x: 0, y: visibleCard.maxY, width: 320,
                                  height: max(0, (transitionHeight ?? size.height) - visibleCard.maxY))
        footer.frame = NSRect(x: 0, y: 0, width: 320, height: bottom)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            content.layer?.backgroundColor = CalendarSurface.contentColor.cgColor
        }
    }

    func endTransition() {
        transitionCard = nil
        transitionHeight = nil
        content.alphaValue = 1
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
