import AppKit
import SwiftUI

enum CalendarSurface {
    @ViewBuilder static func chrome(blurEnabled: Bool) -> some View {
        if blurEnabled {
            PopoverMaterial().allowsHitTesting(false).accessibilityHidden(true)
        } else {
            settings
        }
    }
    static let settings = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    })
    static let contentColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.10, alpha: 1) : .white
    }
    static let content = Color(nsColor: contentColor)

    // 实色底覆盖接缝与末行横线，避免透明分隔区透出窗口后方的颜色。
    static var separator: some View {
        Color.primary.opacity(0.10)
            .frame(height: 0.5)
            .background(content)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        // 取样窗口后方的桌面，由系统处理模糊、外观和减少透明度偏好。
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
