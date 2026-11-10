import AppKit
import SwiftUI

enum CalendarSurface {
    static let secondaryTextColor = NSColor(name: nil) { appearance in
        NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.96 : 0.34, alpha: 1)
    }
    static let adjacentTextColor = NSColor(name: nil) { appearance in
        NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.45 : 0.72, alpha: 1)
    }
    static let secondaryText = Color(nsColor: secondaryTextColor)

    static let settingsColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    }
    static let settings = Color(nsColor: settingsColor)
    static let contentColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.10, alpha: 1) : .white
    }
}

struct CalendarCardBackground: View {
    static let drawingInset: CGFloat = 12
    @Environment(\.colorScheme) private var colorScheme
    let usesMaterial: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalendarTimelineView.cornerRadius, style: .continuous)
        Group {
            if usesMaterial {
                shape.fill(.thickMaterial)
                    .overlay {
                        shape.fill(.white.opacity(colorScheme == .light ? 0.80 : 0))
                    }
                    .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 1)
            }
            else { shape.fill(Color(nsColor: CalendarSurface.contentColor)) }
        }
        // 为阴影留出绘制空间，卡片本身仍与正文边界对齐。
        .padding(Self.drawingInset)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

final class CalendarCardBackgroundHost: NSHostingView<CalendarCardBackground> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
