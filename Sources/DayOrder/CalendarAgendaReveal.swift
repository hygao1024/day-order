import AppKit

// 透明内容仅在端点准备；展开与周行移动共用展示控制器的弹簧和刷新驱动。
@MainActor final class CalendarAgendaReveal {
    private let source: NSImage?
    private let destination: NSImage?
    #if DEBUG
    private(set) static var snapshotBuildCount = 0
    #endif

    init?(source: NSImage?, destination: NSImage?) {
        guard source != nil || destination != nil else { return nil }
        self.source = source
        self.destination = destination
        #if DEBUG
        Self.snapshotBuildCount += (source == nil ? 0 : 1) + (destination == nil ? 0 : 1)
        #endif
    }

    private func visibleRect(in rect: CGRect, progress: CGFloat) -> CGRect {
        let amount = min(1, max(0, progress))
        return CGRect(x: rect.minX + 0.5, y: rect.minY + CalendarDayAgendaLayout.backgroundTopInset,
            width: rect.width - 1,
            height: max(0, rect.height - CalendarDayAgendaLayout.backgroundTopInset
                - CalendarDayAgendaLayout.backgroundBottomInset) * amount)
    }

    func draw(in rect: CGRect, progress: CGFloat, fraction: CGFloat) {
        guard progress > 0.0001, let context = NSGraphicsContext.current?.cgContext else { return }
        let visible = visibleRect(in: rect, progress: progress)
        context.saveGState()
        defer { context.restoreGState() }
        // 复用原生背景的颜色、圆角与内缩，只改变其可见尺寸。
        CalendarDayAgendaView.drawBackground(in: CGRect(x: visible.minX - 0.5,
            y: visible.minY - CalendarDayAgendaLayout.backgroundTopInset, width: visible.width + 1,
            height: visible.height + CalendarDayAgendaLayout.backgroundTopInset
                + CalendarDayAgendaLayout.backgroundBottomInset))
        let radius = min(8, visible.height / 2)
        NSBezierPath(roundedRect: visible, xRadius: radius, yRadius: radius).addClip()
        // 内容保持原始字号和坐标，通过裁切逐步显露。
        func paint(_ image: NSImage, operation: NSCompositingOperation, alpha: CGFloat) {
            image.draw(in: CGRect(origin: rect.origin, size: image.size), from: .zero,
                operation: operation, fraction: alpha, respectFlipped: true, hints: nil)
        }
        if let source, let destination {
            // 预乘颜色插值避免切换日期时同位置文字重复叠色。
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            paint(source, operation: .sourceOver, alpha: 1 - fraction)
            paint(destination, operation: .plusLighter, alpha: fraction)
            context.endTransparencyLayer()
        } else if let image = destination ?? source {
            paint(image, operation: .sourceOver, alpha: 1)
        }
    }

    #if DEBUG
    func sample(in rect: CGRect, progress: CGFloat) -> [String: Double] {
        let visible = visibleRect(in: rect, progress: progress)
        return ["probeX": visible.minX + visible.width * 0.85,
                "probeY": visible.minY + visible.height * 0.7,
                "visibleWidth": visible.width, "visibleHeight": visible.height,
                "targetWidth": rect.width - 1,
                "upperY": visible.minY + visible.height * 0.2,
                "lowerY": visible.minY + visible.height * 0.8,
                "topY": visible.minY, "bottomY": visible.maxY,
                "targetBottomY": rect.maxY - CalendarDayAgendaLayout.backgroundBottomInset]
    }
    #endif
}
